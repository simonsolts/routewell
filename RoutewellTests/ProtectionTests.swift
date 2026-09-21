import Foundation
import Testing
import RoutewellKit
@testable import Routewell

@MainActor
private func eventually(_ predicate: () async -> Bool) async {
    for _ in 0..<10_000 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("Condition did not settle")
}

// MARK: - Outcome → banner text mapping

@Test func protectionOutcomeTextMatchesPlan() {
    #expect(ProtectionScreen.bannerText(for: .verifiedSuccess(.enabled)) == "Protection is now enabled.")
    #expect(ProtectionScreen.bannerText(for: .verifiedMismatch(expected: .enabled, actual: .disabled))
            == "The router did not apply the change. Protection is still disabled.")
    #expect(ProtectionScreen.bannerText(for: .verifiedRecovery(restored: .enabled))
            == "The change did not apply. Routewell restored the previous setting.")
    #expect(ProtectionScreen.bannerText(for: .recoveryFailed(expected: .enabled, actual: nil))
            == "The change did not apply and the previous setting could not be restored. Check AdGuard Home.")
    #expect(ProtectionScreen.bannerText(for: .conflictingExternalEdit(actual: .disabled))
            == "Protection changed from somewhere else. Routewell made no further change.")
    #expect(ProtectionScreen.bannerText(for: .unknownAfterDispatch)
            == "The router did not answer in time. The change may have applied. Refresh to check.")
    #expect(ProtectionScreen.bannerText(for: .rejected(.gateBusy)) == "Another change is still running.")
    #expect(ProtectionScreen.bannerText(for: .rejected(.capabilityUnavailable))
            == "AdGuard Home is not configured for this router.")
    #expect(ProtectionScreen.bannerText(for: .rejected(.staleSession))
            == "The router changed during the operation. Refresh to check.")
    #expect(ProtectionScreen.bannerText(for: .rejected(.preconditionFailed("status unavailable")))
            == "status unavailable")
    #expect(ProtectionScreen.bannerText(for: .rejected(.invalidIntent("Pause duration must be between 1 minute and 24 hours")))
            == "Pause duration must be between 1 minute and 24 hours")
}

// MARK: - MutationController

@MainActor @Test func secondSubmitWhileInFlightIsIgnored() async {
    let backend = BlockingProtectionBackend()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model)
    let mutation = MutationController(model: model, refresh: refresh)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value

    mutation.setProtection(.enable)
    await backend.waitUntilStarted()
    #expect(mutation.inFlight == .enable)
    mutation.setProtection(.disable)
    mutation.setProtection(.pause(.seconds(300)))
    #expect(await backend.callCount == 1)

    await backend.release(MutationReport(outcome: .verifiedSuccess(.enabled), dispatched: true, startedAt: .now, finishedAt: .now, failure: nil))
    await eventually { mutation.inFlight == nil }
    #expect(await backend.callCount == 1)
    #expect(mutation.lastReport?.outcome == .verifiedSuccess(.enabled))
}

@MainActor @Test func staleLeaseReportIsNotAppliedAndShowsStaleText() async {
    let backend = BlockingProtectionBackend()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model)
    let mutation = MutationController(model: model, refresh: refresh)
    await model.session.switchProfile("first", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value

    mutation.setProtection(.enable)
    await backend.waitUntilStarted()

    // Advance the session revision while the mutation is still in flight, so
    // `RouterSession.setProtection`'s `validateAfter` throws `.stale` once
    // the blocked call below returns.
    await model.session.switchProfile("second", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: BlockingProtectionBackend())
    }.value

    await backend.release(MutationReport(outcome: .verifiedSuccess(.enabled), dispatched: true, startedAt: .now, finishedAt: .now, failure: nil))
    await eventually { mutation.inFlight == nil }

    #expect(mutation.lastReport?.outcome == .rejected(.staleSession))
    // The acceptance gate in `AppModel.accept` rejects a report carrying a
    // now-stale token, so it never reaches `lastProtectionReport`.
    #expect(model.lastProtectionReport == nil)
}

@MainActor @Test func successfulMutationTriggersExactlyOneRefresh() async {
    let backend = BlockingProtectionBackend()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model)
    let mutation = MutationController(model: model, refresh: refresh)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value
    await refresh.waitForRefresh()
    let overviewCallsBeforeMutation = await backend.overviewCalls

    mutation.setProtection(.enable)
    await backend.waitUntilStarted()
    await backend.release(MutationReport(outcome: .verifiedSuccess(.enabled), dispatched: true, startedAt: .now, finishedAt: .now, failure: nil))
    await eventually { mutation.inFlight == nil }
    await refresh.waitForRefresh()

    #expect(await backend.overviewCalls == overviewCallsBeforeMutation + 1)
}

@MainActor @Test func rejectedMutationTriggersNoRefresh() async {
    let backend = BlockingProtectionBackend()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model)
    let mutation = MutationController(model: model, refresh: refresh)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value
    await refresh.waitForRefresh()
    let overviewCallsBeforeMutation = await backend.overviewCalls

    mutation.setProtection(.enable)
    await backend.waitUntilStarted()
    await backend.release(MutationReport(outcome: .rejected(.gateBusy), dispatched: false, startedAt: .now, finishedAt: .now, failure: nil))
    await eventually { mutation.inFlight == nil }

    #expect(await backend.overviewCalls == overviewCallsBeforeMutation)
}

// MARK: - Settings/Setup blocking

@MainActor @Test func reconnectLiveSessionRefusesWhileMutationInFlight() async {
    let backend = BlockingProtectionBackend()
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    let tokenBefore = model.session.expectedToken

    environment.mutation.setProtection(.enable)
    await backend.waitUntilStarted()

    environment.reconnectLiveSession()
    #expect(model.session.expectedToken == tokenBefore)

    await backend.release(MutationReport(outcome: .verifiedSuccess(.enabled), dispatched: true, startedAt: .now, finishedAt: .now, failure: nil))
    await eventually { environment.mutation.inFlight == nil }
}

// MARK: - Test doubles

private actor BlockingProtectionBackend: RouterBackend {
    private(set) var overviewCalls = 0
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<MutationReport<ProtectionState>, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func overview() async throws -> OverviewRefreshResult {
        overviewCalls += 1
        let date = Date.distantPast
        return .init(
            router: .success(.init(), observedAt: date, source: .mock),
            internet: .success(.init(), observedAt: date, source: .mock),
            adGuard: .success(.init(), observedAt: date, source: .mock),
            clients: .success(.init(), observedAt: date, source: .mock)
        )
    }

    nonisolated var protection: (any ProtectionService)? { BlockingProtectionService(backend: self) }

    func run() async -> MutationReport<ProtectionState> {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release(_ report: MutationReport<ProtectionState>) {
        continuation?.resume(returning: report)
        continuation = nil
    }
}

private struct BlockingProtectionService: ProtectionService {
    let backend: BlockingProtectionBackend
    func setProtection(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState> {
        await backend.run()
    }
}

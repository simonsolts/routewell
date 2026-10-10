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

@MainActor
private func controller(_ backend: BlockingSettingBackend, model: AppModel) async -> (AdGuardController, RefreshController) {
    let refresh = RefreshController(model: model)
    let adGuard = AdGuardController(model: model, refresh: refresh, store: AdGuardArchiveStore(root: nil))
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value
    return (adGuard, refresh)
}

private func report(_ outcome: MutationOutcome<AdGuardSettingState>, dispatched: Bool = true) -> MutationReport<AdGuardSettingState> {
    MutationReport(outcome: outcome, dispatched: dispatched, startedAt: .now, finishedAt: .now, failure: nil)
}

// MARK: - AdGuardController setting writes

@MainActor @Test func secondSettingWriteWhileInFlightIsIgnored() async {
    let backend = BlockingSettingBackend()
    let model = AppModel(mode: .mock)
    let (adGuard, _) = await controller(backend, model: model)

    adGuard.runSetting(.protection(.enable))
    await backend.waitUntilStarted()
    #expect(adGuard.settingInFlight == .protection(.enable))
    #expect(adGuard.isWriting)
    adGuard.runSetting(.protection(.disable))
    adGuard.runSetting(.feature(.parental, enabled: true))
    // A service write waits too: one write at a time.
    adGuard.run(.setHandlesDNS(true))
    #expect(adGuard.inFlight == nil)
    #expect(await backend.callCount == 1)

    await backend.release(report(.verifiedSuccess(.protection(.enabled))))
    await eventually { adGuard.settingInFlight == nil }
    #expect(await backend.callCount == 1)
    #expect(adGuard.lastSettingReport?.outcome == .verifiedSuccess(.protection(.enabled)))
}

@MainActor @Test func staleSettingReportIsDropped() async {
    let backend = BlockingSettingBackend()
    let model = AppModel(mode: .mock)
    let (adGuard, refresh) = await controller(backend, model: model)

    adGuard.runSetting(.protection(.enable))
    await backend.waitUntilStarted()

    // The session moves on while the write is in flight, so
    // `RouterSession.command`'s `validateAfter` throws `.stale`.
    await model.session.switchProfile("second", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: BlockingSettingBackend())
    }.value

    await backend.release(report(.verifiedSuccess(.protection(.enabled))))
    await eventually { adGuard.settingInFlight == nil }
    // The write may have happened; its report belongs to no one and is never re-sent.
    #expect(adGuard.lastSettingReport == nil)
    #expect(await backend.callCount == 1)
}

@MainActor @Test func successfulSettingWriteTriggersExactlyOneRefresh() async {
    let backend = BlockingSettingBackend()
    let model = AppModel(mode: .mock)
    let (adGuard, refresh) = await controller(backend, model: model)
    await refresh.waitForRefresh()
    let before = await backend.overviewCalls

    adGuard.runSetting(.feature(.safeBrowsing, enabled: false))
    await backend.waitUntilStarted()
    await backend.release(report(.verifiedSuccess(.feature(false))))
    await eventually { adGuard.settingInFlight == nil }
    await refresh.waitForRefresh()

    #expect(await backend.overviewCalls == before + 1)
}

@MainActor @Test func rejectedSettingWriteTriggersNoRefresh() async {
    let backend = BlockingSettingBackend()
    let model = AppModel(mode: .mock)
    let (adGuard, refresh) = await controller(backend, model: model)
    await refresh.waitForRefresh()
    let before = await backend.overviewCalls

    adGuard.runSetting(.protection(.enable))
    await backend.waitUntilStarted()
    await backend.release(report(.rejected(.gateBusy), dispatched: false))
    await eventually { adGuard.settingInFlight == nil }

    #expect(await backend.overviewCalls == before)
}

@MainActor @Test func reconnectLiveSessionRefusesWhileASettingWriteRuns() async {
    let backend = BlockingSettingBackend()
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    let tokenBefore = model.session.expectedToken

    environment.adGuard.runSetting(.protection(.enable))
    await backend.waitUntilStarted()

    environment.reconnectLiveSession()
    #expect(model.session.expectedToken == tokenBefore)

    await backend.release(report(.verifiedSuccess(.protection(.enabled))))
    await eventually { environment.adGuard.settingInFlight == nil }
}

// MARK: - Test doubles

private actor BlockingSettingBackend: RouterBackend {
    private(set) var overviewCalls = 0
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<MutationReport<AdGuardSettingState>, Never>?
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

    nonisolated var adGuardSettings: (any AdGuardSettingControl)? { BlockingSettingControl(backend: self) }

    func run() async -> MutationReport<AdGuardSettingState> {
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

    func release(_ report: MutationReport<AdGuardSettingState>) {
        continuation?.resume(returning: report)
        continuation = nil
    }
}

private struct BlockingSettingControl: AdGuardSettingControl {
    let backend: BlockingSettingBackend
    func run(_ intent: AdGuardSettingIntent, availability: AdGuardAvailability) async -> MutationReport<AdGuardSettingState> {
        await backend.run()
    }
}

// MARK: - Fixture recording

@Test func recordingFailureNamesTheRealReason() {
    #expect(AppEnvironment.recordingFailure(SessionError.stale).hasPrefix("The router session changed during the recording"))
    #expect(AppEnvironment.recordingFailure(SessionError.switching).hasPrefix("The router session was still connecting"))
    #expect(AppEnvironment.recordingFailure(RecorderError.unsafePlan).contains("not a read"))
    let write = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/tmp/example/a.json"])
    let text = AppEnvironment.recordingFailure(write)
    #expect(text.hasPrefix("A file could not be written:"))
    #expect(text.contains("/tmp/example/a.json"))
    #expect(AppEnvironment.recordingFailure(URLError(.timedOut)).hasPrefix("Unexpected error: NSURLErrorDomain"))
}

import Foundation
import Testing
import RoutewellKit
@testable import Routewell

@Test func backendSelectionNeverFallsBackToMockWithoutOptingIn() {
    #expect(BackendMode.resolve(nil, allowsMock: true) == .live)
    #expect(BackendMode.resolve("", allowsMock: true) == .live)
    #expect(BackendMode.resolve("live", allowsMock: true) == .live)
    #expect(BackendMode.resolve("mock", allowsMock: true) == .mock)
    #expect(BackendMode.resolve("mock", allowsMock: false) == .invalid)
    #expect(BackendMode.resolve("typo", allowsMock: true) == .invalid)
}

@MainActor @Test func appEnvironmentsDoNotShareState() {
    let first = AppEnvironment.configured(variables: ["ROUTEWELL_BACKEND": "mock"])
    let second = AppEnvironment.configured(variables: ["ROUTEWELL_BACKEND": "mock"])
    first.model.selection = .clients
    first.model.showInMenuBar = false
    #expect(second.model.selection == .overview)
    #expect(second.model.showInMenuBar)
    #expect(second.model.snapshot == nil)
}

@MainActor @Test func mockModeNeverConstructsALiveTransport() async {
    let environment = AppEnvironment.configured(variables: ["ROUTEWELL_BACKEND": "mock"], persist: false) {
        Issue.record("mock mode must never build a transport")
        return StubHTTPTransportForTest()
    }
    #expect(!environment.transportFactoryWasUsed)
}

@MainActor @Test func liveModeBuildsATransportThroughTheInjectedFactory() async {
    var calls = 0
    let environment = AppEnvironment.configured(variables: [:], persist: false) {
        calls += 1
        return StubHTTPTransportForTest()
    }
    #expect(environment.transportFactoryWasUsed)
    #expect(calls == 1)
}

private struct StubHTTPTransportForTest: HTTPTransport {
    func send(_ request: URLRequest, limits: HTTPRequestLimits) async throws -> (Data, HTTPURLResponse) {
        throw TransportError.invalidResponse
    }
}

@MainActor @Test func liveAppWithoutProfileDoesNotRefresh() async {
    let environment = AppEnvironment.configured(variables: [:])
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(!environment.refresh.isAvailable)
    #expect(!environment.model.isRefreshing)
    #expect(environment.model.snapshot == nil)
}

@MainActor @Test func refreshFailurePreservesPreviousObservation() async {
    let snapshot = OverviewSnapshot(observedAt: .distantPast)
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: FailingBackend())
    await environment.waitUntilReady()
    model.accept(.snapshot(snapshot), token: model.session.expectedToken!)
    let controller = environment.refresh
    await controller.waitForRefresh()
    #expect(model.snapshot == snapshot)
    #expect(model.refreshFailed)
    #expect(!model.isRefreshing)
}

@MainActor @Test func partialRefreshPreservesFailedAreaAndUpdatesOthers() async {
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: FailingBackend())
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    let token = model.session.expectedToken!
    let firstDate = Date(timeIntervalSince1970: 1_000)
    var router = RouterStatus()
    router.hostname = "before"
    var clients = ClientStatus()
    clients.activeCount = .value(7)
    model.accept(.result(.init(
        router: .success(router, observedAt: firstDate, source: .mock),
        internet: .success(.init(), observedAt: firstDate, source: .mock),
        adGuard: .success(.init(), observedAt: firstDate, source: .mock),
        clients: .success(clients, observedAt: firstDate, source: .mock)
    ), firstDate), token: token)

    let secondDate = firstDate.addingTimeInterval(30)
    router.hostname = "after"
    model.accept(.result(.init(
        router: .success(router, observedAt: secondDate, source: .mock),
        internet: .success(.init(), observedAt: secondDate, source: .mock),
        adGuard: .success(.init(), observedAt: secondDate, source: .mock),
        clients: .failure(.timeout, attemptedAt: secondDate)
    ), secondDate), token: token)

    #expect(model.snapshot?.router.hostname == "after")
    #expect(model.snapshot?.clients == clients)
    #expect(model.freshness[.clients]?.lastSuccess == firstDate)
    #expect(model.freshness[.clients]?.failure == .timeout)
    #expect(model.freshness[.router]?.failure == nil)
}

@MainActor @Test func mockScenarioChangesReuseSessionData() async {
    let environment = AppEnvironment.configured(variables: ["ROUTEWELL_BACKEND": "mock"])
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    let token = environment.model.session.expectedToken
    let clients = environment.model.snapshot?.clients

    environment.switchMockScenario("partial")
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()

    #expect(environment.model.session.expectedToken == token)
    #expect(environment.model.snapshot?.clients == clients)
    #expect(environment.model.freshness[.clients]?.failure == .timeout)
    #expect(environment.model.freshness[.router]?.failure == nil)
}

@MainActor @Test func repeatedRefreshesShareOneInFlightRead() async {
    let backend = SuspendedBackend()
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    let controller = environment.refresh
    for _ in 0..<100 { controller.refreshNow() }
    await backend.waitUntilStarted()
    #expect(await backend.calls == 1)
    await backend.finish()
    await backend.waitUntilStarted()
    #expect(await backend.calls == 2)
    await backend.finish()
    await controller.waitForRefresh()
    #expect(model.snapshot != nil)
    #expect(!model.isRefreshing)
}

@MainActor @Test func acceptanceGateRejectsStaleSuccessFailureAndBusyCompletion() async {
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: FailingBackend())
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    let old = model.session.expectedToken!
    let backend = SuspendedBackend()
    let switchTask = model.session.switchProfile("new", model: model, refresh: environment.refresh) {
        SessionLease(token: $0, backend: backend)
    }
    // Step 1 takes effect synchronously, before setup or a new result.
    #expect(model.session.switching)
    #expect(model.snapshot == nil)
    model.accept(.snapshot(OverviewSnapshot(observedAt: .distantPast)), token: old)
    model.accept(.failure(.unavailable, .distantPast), token: model.session.expectedToken!)
    model.accept(.busy(true, .distantPast), token: model.session.expectedToken!)
    #expect(model.snapshot == nil)
    #expect(!model.refreshFailed)
    #expect(!model.isRefreshing)
    await switchTask.value
    await backend.waitUntilStarted()
    model.accept(.snapshot(OverviewSnapshot(observedAt: .distantPast)), token: old)
    model.accept(.failure(.unavailable, .distantPast), token: old)
    model.accept(.busy(false, .distantPast), token: old)
    #expect(model.snapshot == nil)
    #expect(!model.refreshFailed)
    #expect(model.isRefreshing)
    await backend.finish()
    await environment.refresh.waitForRefresh()
    #expect(model.snapshot != nil)
    #expect(!model.isRefreshing)
}

@MainActor @Test(arguments: [false, true]) func cancelledOldRefreshCannotClearNewBusyState(fails: Bool) async {
    let oldBackend = SuspendedBackend()
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: oldBackend)
    await environment.waitUntilReady()
    await oldBackend.waitUntilStarted()
    let oldCompletion = environment.refresh.refreshNow()
    let newBackend = SuspendedBackend()
    await model.session.switchProfile("new", model: model, refresh: environment.refresh) {
        SessionLease(token: $0, backend: newBackend)
    }.value
    await newBackend.waitUntilStarted()
    await oldBackend.finish(fails: fails)
    await oldCompletion?.value
    #expect(model.snapshot == nil)
    #expect(!model.refreshFailed)
    #expect(model.isRefreshing)
    environment.refresh.refreshNow()
    #expect(await newBackend.calls == 1)
    await newBackend.finish()
    await newBackend.waitUntilStarted()
    await newBackend.finish()
    await environment.refresh.waitForRefresh()
    #expect(model.snapshot != nil)
}

@MainActor @Test func overlappingSwitchesIgnoreObsoleteSetupSuccessAndFailure() async {
    for fails in [false, true] {
        let model = AppModel(mode: .mock)
        let environment = AppEnvironment(model: model, backend: nil)
        let construction = HeldConstruction()
        let old = model.session.switchProfile("old", model: model, refresh: environment.refresh) { token in
            try await construction.build(token)
        }
        await construction.waitUntilStarted()
        let latest = model.session.switchProfile("new", model: model, refresh: environment.refresh) {
            SessionLease(token: $0, backend: FailingBackend())
        }
        await latest.value
        let token = model.session.expectedToken
        await construction.finish(fails: fails)
        await old.value
        #expect(model.session.expectedToken == token)
        #expect(model.session.lease?.token == token)
        #expect(model.session.isReady)
        #expect(!model.session.setupFailed)
        await environment.refresh.waitForRefresh()
    }
}

private actor HeldConstruction {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func build(_ token: SessionToken) async throws -> SessionLease {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
        return SessionLease(token: token, backend: FailingBackend())
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(fails: Bool) {
        if fails { continuation?.resume(throwing: FailingBackend.Failure()) }
        else { continuation?.resume() }
        continuation = nil
    }
}

private struct FailingBackend: RouterBackend {
    struct Failure: Error {}
    func overview() async throws -> OverviewRefreshResult { throw Failure() }
}

private actor SuspendedBackend: RouterBackend {
    var calls = 0
    private var continuation: CheckedContinuation<OverviewRefreshResult, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func overview() async throws -> OverviewRefreshResult {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(fails: Bool = false) {
        if fails { continuation?.resume(throwing: FailingBackend.Failure()) }
        else { continuation?.resume(returning: successfulResult()) }
        continuation = nil
    }
}

private func successfulResult(at date: Date = .distantPast) -> OverviewRefreshResult {
    .init(router: .success(.init(), observedAt: date, source: .mock),
          internet: .success(.init(), observedAt: date, source: .mock),
          adGuard: .success(.init(), observedAt: date, source: .mock),
          clients: .success(.init(), observedAt: date, source: .mock))
}

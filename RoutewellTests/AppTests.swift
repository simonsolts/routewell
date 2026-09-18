import Foundation
import Testing
import RoutewellKit
@testable import Routewell

@Test func backendSelectionNeverFallsBackToLiveAccess() {
    #expect(BackendMode.resolve(nil, allowsMock: true) == .unconfigured)
    #expect(BackendMode.resolve("mock", allowsMock: true) == .mock)
    #expect(BackendMode.resolve("mock", allowsMock: false) == .invalid)
    #expect(BackendMode.resolve("live", allowsMock: true) == .invalid)
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

@MainActor @Test func unconfiguredAppDoesNotRefresh() async {
    let environment = AppEnvironment.configured(variables: [:])
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(!environment.refresh.isAvailable)
    #expect(!environment.model.isRefreshing)
    #expect(environment.model.snapshot == nil)
}

@MainActor @Test func refreshFailurePreservesPreviousObservation() async {
    let snapshot = OverviewSnapshot(observedAt: .distantPast)
    let model = AppModel(mode: .mock, snapshot: snapshot)
    let controller = RefreshController(model: model, backend: FailingBackend())
    controller.refreshNow()
    await controller.waitForRefresh()
    #expect(model.snapshot == snapshot)
    #expect(model.refreshFailed)
    #expect(!model.isRefreshing)
}

@MainActor @Test func repeatedRefreshesShareOneInFlightRead() async {
    let backend = SuspendedBackend()
    let model = AppModel(mode: .mock)
    let controller = RefreshController(model: model, backend: backend)
    controller.refreshNow()
    controller.refreshNow()
    await backend.waitUntilStarted()
    #expect(await backend.calls == 1)
    await backend.finish()
    await controller.waitForRefresh()
    #expect(model.snapshot != nil)
    #expect(!model.isRefreshing)
}

private struct FailingBackend: RouterBackend {
    struct Failure: Error {}
    func overview() async throws -> OverviewSnapshot { throw Failure() }
}

private actor SuspendedBackend: RouterBackend {
    var calls = 0
    private var continuation: CheckedContinuation<OverviewSnapshot, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func overview() async throws -> OverviewSnapshot {
        calls += 1
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
    func finish() {
        continuation?.resume(returning: OverviewSnapshot(observedAt: .distantPast))
        continuation = nil
    }
}

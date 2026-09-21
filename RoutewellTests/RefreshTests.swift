import AppKit
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

private actor TestRefreshClock: RefreshClock {
    private struct Waiter {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var now: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]
    var count: Int { waiters.count }
    var nextDelay: Duration? { waiters.values.map { $0.deadline - now }.min() }

    func hasSingleWaiter(after delay: Duration) -> Bool { count == 1 && nextDelay == delay }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(deadline: now + duration, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    func advance(_ duration: Duration) {
        now += duration
        let due = waiters.filter { $0.value.deadline <= now }
        for (id, waiter) in due {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }
}

private final class TestWallClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}

private actor CountingRefreshBackend: RouterBackend {
    nonisolated var protection: (any ProtectionService)? { nil }
    private(set) var calls = 0
    func overview() async throws -> OverviewRefreshResult {
        calls += 1
        return successfulResult()
    }
}

@MainActor @Test func pollingChangesCadencePausesAndWakesWithoutCatchup() async {
    let clock = TestRefreshClock()
    let backend = CountingRefreshBackend()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model, clock: clock)
    refresh.setWindowVisible(true)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value
    await refresh.waitForRefresh()
    #expect(await backend.calls == 1)
    await eventually { await clock.nextDelay == .seconds(30) }
    // Repeated view attachments must not create producers or reset deadlines.
    await clock.advance(.seconds(10))
    for _ in 0..<10 { refresh.setWindowVisible(true) }
    #expect(await clock.count == 1)
    #expect(await clock.nextDelay == .seconds(20))
    await clock.advance(.seconds(20))
    await eventually { await backend.calls == 2 }
    await refresh.waitForRefresh()
    await eventually { await clock.nextDelay == .seconds(30) }

    model.refreshIntervalSeconds = 15
    await eventually { await clock.hasSingleWaiter(after: .seconds(15)) }
    await clock.advance(.seconds(15))
    await eventually { await backend.calls == 3 }
    await refresh.waitForRefresh()
    await eventually { await clock.nextDelay == .seconds(15) }

    refresh.setWindowVisible(false)
    await eventually { await clock.hasSingleWaiter(after: .seconds(60)) }
    await clock.advance(.seconds(60))
    await eventually { await backend.calls == 4 }
    await refresh.waitForRefresh()
    model.showInMenuBar = false
    await eventually { await clock.count == 0 }
    await clock.advance(.seconds(600))
    #expect(await backend.calls == 4)
    model.pauseWhenHidden = false
    await eventually { await clock.nextDelay == .seconds(15) }
    refresh.setSleeping(true)
    await eventually { await clock.count == 0 }
    refresh.refreshNow()
    await clock.advance(.seconds(3600))
    #expect(await backend.calls == 4)
    refresh.setSleeping(false)
    refresh.setSleeping(false)
    await refresh.waitForRefresh()
    #expect(await backend.calls == 5)
    await eventually { await clock.nextDelay == .seconds(15) }
    refresh.stop()
    await eventually { await clock.count == 0 }
    await clock.advance(.seconds(3600))
    #expect(await backend.calls == 5)
}

@MainActor @Test func scheduleTeardownAndReplacementIgnoreCancelledTicks() async {
    let clock = TestRefreshClock()
    var ticks = 0
    var schedule: RefreshSchedule? = RefreshSchedule(clock: clock)
    schedule?.update(interval: .seconds(30)) { ticks += 1 }
    await eventually { await clock.count == 1 }
    // Replacing the interval leaves one producer and one future tick.
    schedule?.update(interval: .seconds(15)) { ticks += 1 }
    await eventually { await clock.hasSingleWaiter(after: .seconds(15)) }
    await clock.advance(.seconds(30))
    await eventually { ticks == 1 }
    await eventually { await clock.count == 1 }
    schedule = nil
    await eventually { await clock.count == 0 }
    await clock.advance(.seconds(100))
    #expect(ticks == 1)
}

private actor HeldRefreshBackend: RouterBackend {
    nonisolated var protection: (any ProtectionService)? { nil }
    private(set) var calls = 0
    private let resultDate: Date
    private var completion: CheckedContinuation<OverviewRefreshResult, any Error>?
    init(resultDate: Date = .distantPast) { self.resultDate = resultDate }
    func overview() async throws -> OverviewRefreshResult {
        calls += 1
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    struct Failure: Error {}
    func finish(fails: Bool = false) {
        if fails { completion?.resume(throwing: Failure()) }
        else { completion?.resume(returning: successfulResult(at: resultDate)) }
        completion = nil
    }
}

private func successfulResult(at date: Date = .distantPast) -> OverviewRefreshResult {
    .init(router: .success(.init(), observedAt: date, source: .mock),
          internet: .success(.init(), observedAt: date, source: .mock),
          adGuard: .success(.init(), observedAt: date, source: .mock),
          clients: .success(.init(), observedAt: date, source: .mock))
}

@MainActor @Test func ticksAndManualRequestsShareOnePendingRead() async {
    let clock = TestRefreshClock()
    let backend = HeldRefreshBackend()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model, clock: clock)
    refresh.setWindowVisible(true)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value
    await eventually { await backend.calls == 1 }
    for _ in 0..<5 {
        await eventually { await clock.count == 1 }
        await clock.advance(.seconds(30))
        refresh.refreshNow()
    }
    #expect(await backend.calls == 1)
    await backend.finish()
    await eventually { await backend.calls == 2 }
    await backend.finish()
    await refresh.waitForRefresh()
    #expect(await backend.calls == 2)
    #expect(!model.isRefreshing)
    refresh.stop()
}

@MainActor @Test func sleepDropsPendingWorkAndWakeRequestsExactlyOneRead() async {
    let backend = HeldRefreshBackend()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value
    await eventually { await backend.calls == 1 }
    refresh.refreshNow()
    refresh.setSleeping(true)
    await backend.finish()
    await refresh.waitForRefresh()
    #expect(await backend.calls == 1)
    refresh.setSleeping(false)
    refresh.setSleeping(false)
    await eventually { await backend.calls == 2 }
    await backend.finish()
    await refresh.waitForRefresh()
    #expect(await backend.calls == 2)
}

@MainActor @Test func wakeRecomputesFreshnessBeforeRefreshCompletes() async {
    let date = Date(timeIntervalSince1970: 10_000)
    let wallClock = TestWallClock(date)
    let backend = HeldRefreshBackend(resultDate: date)
    let model = AppModel(mode: .mock, now: date)
    let refresh = RefreshController(model: model, wallClock: wallClock)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value
    await eventually { await backend.calls == 1 }
    await backend.finish()
    await refresh.waitForRefresh()
    #expect(model.healthChecks.contains { $0.kind == .freshness(.clients) && $0.state == .fresh })

    refresh.setSleeping(true)
    wallClock.advance(60 * 60 + 1)
    refresh.setSleeping(false)
    await eventually { await backend.calls == 2 }
    #expect(model.healthChecks.contains { $0.kind == .freshness(.clients) && $0.state == .stale })
    #expect(model.healthChecks.contains { $0.kind == .refreshing(.clients) })
    await backend.finish()
    await refresh.waitForRefresh()
}

@MainActor @Test func controllerTeardownStopsProducer() async {
    let clock = TestRefreshClock()
    let model = AppModel(mode: .mock)
    var refresh: RefreshController? = RefreshController(model: model, clock: clock)
    weak var weakRefresh = refresh
    refresh?.setWindowVisible(true)
    await model.session.switchProfile("test", model: model, refresh: refresh!) {
        SessionLease(token: $0, backend: CountingRefreshBackend())
    }.value
    await refresh?.waitForRefresh()
    await eventually { await clock.count == 1 }
    refresh = nil
    #expect(weakRefresh == nil)
    await eventually { await clock.count == 0 }
}

@MainActor @Test func lifecycleAdapterTracksOnlyMainWindowAndWorkspaceSleep() async {
    let clock = TestRefreshClock()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model, clock: clock)
    let delegate = AppDelegate()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer {
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        window.close()
    }
    delegate.attach(window: window, refresh: refresh)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: CountingRefreshBackend())
    }.value
    await refresh.waitForRefresh()
    await eventually { await clock.hasSingleWaiter(after: .seconds(60)) }
    window.orderFront(nil)
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await eventually { await clock.hasSingleWaiter(after: .seconds(30)) }
    // Closing a Settings window must not pause the main window's cadence.
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: NSWindow())
    #expect(await clock.hasSingleWaiter(after: .seconds(30)))
    window.orderOut(nil)
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    await eventually { await clock.hasSingleWaiter(after: .seconds(60)) }
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    await eventually { await clock.count == 0 }
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    await refresh.waitForRefresh()
    await eventually { await clock.hasSingleWaiter(after: .seconds(60)) }
}

@MainActor @Test func coalescedSuccessClearsEarlierFailure() async {
    let backend = HeldRefreshBackend()
    let model = AppModel(mode: .mock)
    let refresh = RefreshController(model: model)
    await model.session.switchProfile("test", model: model, refresh: refresh) {
        SessionLease(token: $0, backend: backend)
    }.value
    await eventually { await backend.calls == 1 }
    refresh.refreshNow()
    await backend.finish(fails: true)
    await eventually { await backend.calls == 2 }
    await backend.finish()
    await refresh.waitForRefresh()
    #expect(model.snapshot != nil)
    #expect(!model.refreshFailed)
    #expect(!model.isRefreshing)
}

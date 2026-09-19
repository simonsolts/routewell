import Foundation

public struct RefreshPolicy: Equatable, Sendable {
    public var interval: Duration
    public var summaryInterval: Duration
    public var pauseWhenHidden: Bool

    public init(interval: Duration = .seconds(30), summaryInterval: Duration = .seconds(60), pauseWhenHidden: Bool = true) {
        self.interval = interval
        self.summaryInterval = summaryInterval
        self.pauseWhenHidden = pauseWhenHidden
    }

    public func cadence(windowVisible: Bool, menuBarVisible: Bool, sleeping: Bool) -> Duration? {
        guard !sleeping else { return nil }
        let cadence: Duration
        if windowVisible || !pauseWhenHidden { cadence = interval }
        else if menuBarVisible { cadence = summaryInterval }
        else { return nil }
        return max(cadence, .seconds(1))
    }
}

/// Scheduling uses monotonic time; observation timestamps belong to the backend.
public protocol RefreshClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousRefreshClock: RefreshClock {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

/// One producer. Changes reset the deadline; delayed ticks are never replayed.
@MainActor
public final class RefreshSchedule {
    private let clock: any RefreshClock
    private var task: Task<Void, Never>?
    private var interval: Duration?

    public init(clock: any RefreshClock = ContinuousRefreshClock()) { self.clock = clock }

    public func update(interval: Duration?, tick: @escaping @MainActor @Sendable () -> Void) {
        guard self.interval != interval else { return }
        stop()
        self.interval = interval
        guard let interval else { return }
        let clock = clock
        task = Task {
            while !Task.isCancelled {
                do { try await clock.sleep(for: max(interval, .seconds(1))) }
                catch { return }
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        interval = nil
    }

    deinit { task?.cancel() }
}

import Foundation
import RoutewellKit

/// App-lifetime coordinator shared by the window and menu bar.
@MainActor
final class RefreshController {
    private let model: AppModel
    private let schedule: RefreshSchedule
    private var task: Task<Void, Never>?
    private var pending = false
    private var pollingEnabled = false
    private var windowVisible = false
    private var sleeping = false

    var isAvailable: Bool { model.session.isReady && !sleeping }

    init(model: AppModel, clock: any RefreshClock = ContinuousRefreshClock()) {
        self.model = model
        schedule = RefreshSchedule(clock: clock)
        model.refreshSettingsChanged = { [weak self] in self?.updateSchedule() }
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        pollingEnabled = true
        updateSchedule()
    }

    func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        if value { pending = false }
        updateSchedule()
        if !value { refreshNow() }
    }

    func sessionReady() {
        updateSchedule()
        refreshNow()
    }

    private func updateSchedule() {
        let policy = RefreshPolicy(interval: .seconds(model.refreshIntervalSeconds), pauseWhenHidden: model.pauseWhenHidden)
        let interval = pollingEnabled && model.session.isReady
            ? policy.cadence(windowVisible: windowVisible, menuBarVisible: model.showInMenuBar, sleeping: sleeping)
            : nil
        if pollingEnabled && interval == nil { pending = false }
        schedule.update(interval: interval) { [weak self] in self?.refreshNow() }
    }

    func cancelForSwitch() {
        schedule.stop()
        task?.cancel()
        task = nil
        pending = false
    }

    func stop() {
        pollingEnabled = false
        cancelForSwitch()
        if let token = model.session.expectedToken { model.accept(.busy(false), token: token) }
    }

    @discardableResult
    func refreshNow() -> Task<Void, Never>? {
        guard isAvailable, let lease = model.session.lease else { return nil }
        if let task {
            pending = true
            return task
        }
        model.accept(.busy(true), token: lease.token)
        let model = model
        task = Task { [weak self] in
            repeat {
                do {
                    if model.slowMockRefresh { try await Task.sleep(for: .seconds(5)) }
                    let snapshot = try await model.session.routerSession.overview(using: lease)
                    guard !Task.isCancelled else { return }
                    model.accept(.snapshot(snapshot), token: lease.token)
                } catch {
                    guard !Task.isCancelled else { return }
                    if !(error is CancellationError) { model.accept(.failure, token: lease.token) }
                }
                guard model.session.expectedToken == lease.token else { return }
                if self?.takePending() == true {
                    model.accept(.busy(true), token: lease.token)
                } else {
                    self?.task = nil
                    model.accept(.busy(false), token: lease.token)
                    return
                }
            } while !Task.isCancelled
        }
        return task
    }

    private func takePending() -> Bool {
        defer { pending = false }
        return pending && !sleeping
    }

    func waitForRefresh() async { await task?.value }

    deinit { task?.cancel() }
}

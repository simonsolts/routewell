import Foundation
import RoutewellKit

/// App-lifetime coordinator shared by the window and menu bar.
@MainActor
final class RefreshController {
    private let model: AppModel
    private let schedule: RefreshSchedule
    private let wallClock: any WallClock
    private let logging: LoggingController?
    private let registry: DeviceRegistry?
    private var telemetry = TelemetrySampler()
    private var task: Task<Void, Never>?
    private var pending = false
    private var pendingManual = false
    private var pollingEnabled = false
    private var windowVisible = false
    private var sleeping = false
    private var overviewElapsed: Duration = .zero
    private var featureElapsed: [DataArea: Duration] = [:]

    var isAvailable: Bool { model.session.isReady && !sleeping }

    init(
        model: AppModel,
        clock: any RefreshClock = ContinuousRefreshClock(),
        wallClock: any WallClock = SystemWallClock(),
        logging: LoggingController? = nil,
        registry: DeviceRegistry? = nil
    ) {
        self.model = model
        self.wallClock = wallClock
        self.logging = logging
        self.registry = registry
        schedule = RefreshSchedule(clock: clock)
        model.refreshSettingsChanged = { [weak self] in self?.updateSchedule() }
        model.screenChanged = { [weak self] in
            self?.updateSchedule()
            if self?.windowVisible == true { self?.refreshNow() }
        }
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
        if !value {
            model.evaluateFreshness(at: wallClock.now())
            refreshNow()
        }
    }

    func sessionReady() {
        updateSchedule()
        refreshNow()
    }

    private func updateSchedule() {
        let policy = RefreshPolicy(interval: .seconds(model.refreshIntervalSeconds), pauseWhenHidden: model.pauseWhenHidden)
        let baseInterval = pollingEnabled && model.session.isReady
            ? policy.cadence(windowVisible: windowVisible, menuBarVisible: model.showInMenuBar, sleeping: sleeping)
            : nil
        let requests = ScreenRefreshPlan.resolve(destination: model.selection.rawValue,
            segment: model.subpages[model.selection] ?? model.selection.segments.first,
            defaultInterval: .seconds(model.refreshIntervalSeconds))
        let interval = baseInterval.map { base in
            windowVisible ? min(base, requests.map(\.interval).min() ?? base) : base
        }
        if pollingEnabled && interval == nil { pending = false }
        schedule.update(interval: interval) { [weak self] in
            guard let self else { return }
            if self.windowVisible { self.model.evaluateFreshness(at: self.wallClock.now()) }
            self.refreshNow(automaticTick: interval)
        }
    }

    func cancelForSwitch() {
        schedule.stop()
        task?.cancel()
        task = nil
        pending = false
        pendingManual = false
        overviewElapsed = .zero
        featureElapsed = [:]
        telemetry = TelemetrySampler()
    }

    func stop() {
        pollingEnabled = false
        cancelForSwitch()
        if let token = model.session.expectedToken { model.accept(.busy(false, wallClock.now()), token: token) }
    }

    @discardableResult
    func refreshNow(automaticTick: Duration? = nil) -> Task<Void, Never>? {
        guard isAvailable, let lease = model.session.lease else { return nil }
        if let automaticTick { overviewElapsed += automaticTick }
        else { overviewElapsed = .seconds(model.refreshIntervalSeconds) }
        let activeRequests = ScreenRefreshPlan.resolve(destination: model.selection.rawValue,
            segment: model.subpages[model.selection] ?? model.selection.segments.first,
            defaultInterval: .seconds(model.refreshIntervalSeconds))
        for request in activeRequests {
            featureElapsed[request.area, default: .zero] += automaticTick ?? request.interval
        }
        if let task {
            pending = true
            if automaticTick == nil { pendingManual = true }
            return task
        }
        model.accept(.busy(true, wallClock.now()), token: lease.token)
        logging?.record(kind: .refresh, message: "Refresh started")
        let model = model
        let wallClock = wallClock
        let telemetry = telemetry
        let registry = registry
        task = Task { [weak self] in
            var force = automaticTick == nil
            repeat {
                do {
                    let overviewDue = self?.overviewElapsed ?? .zero >= .seconds(model.refreshIntervalSeconds)
                    if overviewDue {
                        var result = try await model.session.routerSession.overview(using: lease)
                        guard !Task.isCancelled else { return }
                        if case .success(var router, let observedAt, let source) = result.router {
                            let total = router.memoryTotalBytes
                            let used = router.memoryUsedBytes
                            let history = await telemetry.append(TelemetrySample(
                                capturedAt: observedAt,
                                cpuLoad: router.loadAverages.first.map(Observed.value) ?? .unknown,
                                memoryUsedBytes: used.map { .value(Double($0)) } ?? .unknown,
                                temperatureCelsius: router.temperatureCelsius
                            ))
                            guard !Task.isCancelled, model.session.expectedToken == lease.token else { return }
                            router.memoryHistory = history.memoryUsedBytes.compactMap {
                                guard let total, total > 0 else { return nil }
                                return $0.value / Double(total)
                            }
                            result.router = .success(router, observedAt: observedAt, source: source)
                        }
                        model.accept(.result(result, wallClock.now()), token: lease.token)
                        self?.overviewElapsed = .zero
                    }
                    if self?.windowVisible == true {
                        let requests = ScreenRefreshPlan.resolve(destination: model.selection.rawValue,
                            segment: model.subpages[model.selection] ?? model.selection.segments.first,
                            defaultInterval: .seconds(model.refreshIntervalSeconds))
                        for request in requests where !ScreenRefreshPlan.overviewAreas.contains(request.area) || request.area == .clients {
                            if !force, (self?.featureElapsed[request.area] ?? .zero) < request.interval { continue }
                            if request.area == .clients {
                                // The inventory is read only while the Clients screen is visible.
                                guard model.selection == .clients else { continue }
                                guard let result = try await model.session.routerSession.clientInventory(using: lease) else { continue }
                                guard !Task.isCancelled, model.session.expectedToken == lease.token else { return }
                                model.acceptCapability(result.capability, area: .clients, token: lease.token)
                                var observation: DeviceObservation?
                                if case .success(let inventory, _, _) = result.area, let registry {
                                    try await model.session.routerSession.validateBefore(lease)
                                    observation = try await registry.observe(inventory.clients, at: wallClock.now())
                                    guard !Task.isCancelled, model.session.expectedToken == lease.token else { return }
                                }
                                model.acceptClients(result.area, observation: observation, token: lease.token)
                                if let count = observation?.newDevices.count, count > 0 {
                                    self?.logging?.record(kind: .refresh, message: "New devices found", fields: ["count": String(count)])
                                }
                                self?.featureElapsed[.clients] = .zero
                                continue
                            }
                            guard let service = lease.backend.service(for: request.area) else { continue }
                            let capability = await service.probe()
                            guard !Task.isCancelled, model.session.expectedToken == lease.token else { return }
                            model.acceptCapability(capability, area: request.area, token: lease.token)
                            self?.featureElapsed[request.area] = .zero
                        }
                    }
                    self?.logging?.record(kind: .refresh, message: "Refresh completed")
                } catch {
                    guard !Task.isCancelled else { return }
                    if !(error is CancellationError) {
                        model.accept(.failure(.unavailable, wallClock.now()), token: lease.token)
                        self?.logging?.record(level: .warning, kind: .refresh, message: "Refresh failed",
                                              fields: ["failure": FailureCategory.unreachable.rawValue])
                    }
                }
                guard model.session.expectedToken == lease.token else { return }
                if self?.takePending() == true {
                    force = self?.takePendingManual() == true
                    if force {
                        self?.overviewElapsed = .seconds(model.refreshIntervalSeconds)
                    }
                    model.accept(.busy(true, wallClock.now()), token: lease.token)
                } else {
                    self?.task = nil
                    model.accept(.busy(false, wallClock.now()), token: lease.token)
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

    private func takePendingManual() -> Bool {
        defer { pendingManual = false }
        return pendingManual
    }

    func waitForRefresh() async { await task?.value }

    deinit { task?.cancel() }
}

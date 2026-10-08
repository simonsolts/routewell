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
    private let presence: PresenceLog?
    private var telemetry = TelemetrySampler()
    private var task: Task<Void, Never>?
    private var pending = false
    private var pendingManual = false
    private var pollingEnabled = false
    private var windowVisible = false
    private var sleeping = false
    private var overviewElapsed: Duration = .zero
    private var featureElapsed: [DataArea: Duration] = [:]
    /// SSH runs in its own task, one at a time, so a slow SSH probe or
    /// read never holds up the RPC refresh (chunk 15).
    private var sshTask: Task<Void, Never>?
    private var sshPending: SSHWork?
    /// The lease whose SSH probe has started. One probe per lease.
    private var sshProbedToken: SessionToken?
    /// Each overview's AdGuard Home reading, for the AdGuard Home screen and
    /// its saved copy (chunk 16).
    var onAdGuardReading: ((AdGuardServiceReading, SessionToken) async -> Void)?

    var isAvailable: Bool { model.session.isReady && !sleeping }

    init(
        model: AppModel,
        clock: any RefreshClock = ContinuousRefreshClock(),
        wallClock: any WallClock = SystemWallClock(),
        logging: LoggingController? = nil,
        registry: DeviceRegistry? = nil,
        presence: PresenceLog? = nil
    ) {
        self.model = model
        self.wallClock = wallClock
        self.logging = logging
        self.registry = registry
        self.presence = presence
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
        if value {
            pending = false
            interruptPresence()
        }
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

    /// Sampling stops, so the time until the next sample reads as unknown.
    private func interruptPresence() {
        guard let presence else { return }
        Task { await presence.interrupt() }
    }

    func cancelForSwitch() {
        interruptPresence()
        schedule.stop()
        task?.cancel()
        task = nil
        pending = false
        pendingManual = false
        overviewElapsed = .zero
        featureElapsed = [:]
        telemetry = TelemetrySampler()
        cancelSSH()
    }

    private func cancelSSH() {
        sshTask?.cancel()
        sshTask = nil
        sshPending = nil
        sshProbedToken = nil
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
        let presence = presence
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
                                cpuUtilizationPercent: router.cpuUtilizationPercent,
                                memoryUsedBytes: used.map { .value(Double($0)) } ?? .unknown,
                                memoryTotalBytes: total.map { .value(Double($0)) } ?? .unknown,
                                temperatureCelsius: router.temperatureCelsius
                            ))
                            let summary = await telemetry.session()
                            guard !Task.isCancelled, model.session.expectedToken == lease.token else { return }
                            model.acceptTelemetry(history: history, session: summary, token: lease.token)
                            router.memoryHistory = history.memoryUsedBytes.compactMap {
                                guard let total, total > 0 else { return nil }
                                return $0.value / Double(total)
                            }
                            result.router = .success(router, observedAt: observedAt, source: source)
                        }
                        model.accept(.result(result, wallClock.now()), token: lease.token)
                        self?.overviewElapsed = .zero
                        if let reading = result.adGuardService, let observe = self?.onAdGuardReading {
                            await observe(reading, lease.token)
                            guard !Task.isCancelled, model.session.expectedToken == lease.token else { return }
                        }
                        // One presence sample per refresh, from the overview's own client list.
                        if let presence, case .success(let clients, let observedAt, _) = result.clients, let listed = clients.listed {
                            let samples = PresenceLog.samples(listed: listed, known: model.deviceRegistry.records.keys)
                            let failure = await presence.record(samples, at: observedAt)
                            let state = await presence.snapshot()
                            guard !Task.isCancelled, model.session.expectedToken == lease.token else { return }
                            model.replacePresence(state, failure: failure)
                        }
                    }
                    // Enabling SSH (a new lease with SSH) runs the probe once.
                    self?.requestSSH(lease: lease, reads: [])
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
                            if request.area == .ssh {
                                // Logs read only on demand: a manual refresh or showing the segment.
                                self?.requestSSH(lease: lease, reads: self?.visibleSSHReads(includeLogs: force) ?? [])
                                self?.featureElapsed[.ssh] = .zero
                                continue
                            }
                            if request.area == .routerDetail {
                                // Wi-Fi and SQM are read only while the Router screen is visible.
                                guard model.selection == .router else { continue }
                                guard let result = try await model.session.routerSession.routerDetails(using: lease) else { continue }
                                guard !Task.isCancelled, model.session.expectedToken == lease.token else { return }
                                model.acceptRouterDetails(result, token: lease.token)
                                self?.featureElapsed[.routerDetail] = .zero
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

    // MARK: SSH (chunk 15)

    enum SSHRead: Hashable { case ports, storage, logs, adGuardProcess }

    private struct SSHWork {
        let lease: SessionLease
        var reads: Set<SSHRead>
    }

    /// The SSH reads the visible Router segment needs.
    private func visibleSSHReads(includeLogs: Bool) -> Set<SSHRead> {
        guard windowVisible, model.selection == .router else { return [] }
        switch model.subpages[.router] ?? SidebarDestination.router.segments.first {
        case "Overview": return [.adGuardProcess]
        case "Ports": return [.ports]
        case "Storage": return [.storage]
        case "Logs": return includeLogs ? [.logs] : []
        default: return []
        }
    }

    /// Runs the probe once per lease, then the requested reads, only after
    /// the probe reported supported. Work that arrives while SSH is busy is
    /// merged and runs next; nothing runs without an SSH service.
    private func requestSSH(lease: SessionLease, reads: Set<SSHRead>) {
        guard lease.backend.ssh != nil, model.session.expectedToken == lease.token else { return }
        let needsProbe = sshProbedToken != lease.token
        guard needsProbe || !reads.isEmpty else { return }
        if sshTask != nil {
            var pending = sshPending?.lease.token == lease.token ? sshPending! : SSHWork(lease: lease, reads: [])
            pending.reads.formUnion(reads)
            sshPending = pending
            return
        }
        sshProbedToken = lease.token
        let model = model
        sshTask = Task { [weak self] in
            await Self.runSSH(lease: lease, probe: needsProbe, reads: reads, model: model)
            guard let self, !Task.isCancelled else { return }
            self.sshTask = nil
            if let next = self.sshPending, next.lease.token == model.session.expectedToken {
                self.sshPending = nil
                self.requestSSH(lease: next.lease, reads: next.reads)
            }
        }
    }

    private static func runSSH(lease: SessionLease, probe: Bool, reads: Set<SSHRead>, model: AppModel) async {
        let session = model.session.routerSession
        let token = lease.token
        do {
            if probe {
                guard let result = try await session.sshProbe(using: lease) else { return }
                guard !Task.isCancelled else { return }
                model.acceptSSHProbe(result, token: token)
            }
            guard model.sshProbe?.capability.state == .supported else { return }
            for read in [SSHRead.adGuardProcess, .ports, .storage, .logs] where reads.contains(read) {
                switch read {
                case .ports:
                    guard let result = try await session.routerPorts(using: lease) else { return }
                    guard !Task.isCancelled else { return }
                    model.acceptPorts(result, token: token)
                case .storage:
                    guard let result = try await session.routerStorage(using: lease) else { return }
                    guard !Task.isCancelled else { return }
                    model.acceptStorage(result, token: token)
                case .logs:
                    guard let result = try await session.routerLogs(using: lease) else { return }
                    guard !Task.isCancelled else { return }
                    model.acceptRouterLogs(result, token: token)
                case .adGuardProcess:
                    guard let result = try await session.adGuardProcess(using: lease) else { return }
                    guard !Task.isCancelled else { return }
                    model.acceptAdGuardProcess(result, token: token)
                }
            }
        } catch {
            // Cancelled, or the session changed: the results belong to no one.
        }
    }

    /// "Check Again", and a mock scenario change: forget this lease's probe
    /// result and probe once more, then read what the screen shows.
    func reprobeSSH() {
        cancelSSH()
        model.sshBackendChanged()
        guard isAvailable, let lease = model.session.lease else { return }
        requestSSH(lease: lease, reads: visibleSSHReads(includeLogs: true))
    }

    /// Waits for the SSH probe and reads that are running now.
    func waitForSSH() async {
        while let task = sshTask { await task.value }
    }

    /// Reset Session…: peaks and the observation count start from now. A
    /// reset that finishes after a session switch is dropped.
    func resetTelemetrySession() async {
        guard let token = model.session.expectedToken else { return }
        let sampler = telemetry
        let summary = await sampler.resetSession(at: wallClock.now())
        guard sampler === telemetry else { return }
        model.acceptTelemetry(history: nil, session: summary, token: token)
    }

    deinit {
        task?.cancel()
        sshTask?.cancel()
    }
}

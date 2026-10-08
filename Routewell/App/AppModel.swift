import Foundation
import Observation
import RoutewellKit

@MainActor @Observable
final class AppModel {
    var selection: SidebarDestination = .overview { didSet { screenChanged?() } }
    var settingsTab = SettingsTab.general
    var subpages: [SidebarDestination: String] = [:] { didSet { screenChanged?() } }
    private(set) var capabilities: [DataArea: Capability] = [:]
    private(set) var snapshot: OverviewSnapshot?
    private(set) var freshness: [DataArea: Freshness] = [:]
    private(set) var healthChecks: [HealthCheck] = []
    private(set) var evaluatedAt: Date
    private(set) var isRefreshing = false
    private(set) var refreshFailed = false
    private(set) var logEvents: [LogEvent] = []
    private(set) var lastProtectionReport: MutationReport<ProtectionState>?
    let session = SessionController()
    var mockScenarioID = "healthy"
    private(set) var hasLiveEndpoint = false
    /// `.live` mode with no finished live profile selected. Onboarding runs
    /// in its own window and the main window stays closed (chunk 15A).
    var needsSetup: Bool { mode == .live && !hasLiveEndpoint }
    func setHasLiveEndpoint(_ value: Bool) { hasLiveEndpoint = value }
    var showInMenuBar = true { didSet { refreshSettingsChanged?(); persistenceSettingsChanged?() } }
    var refreshIntervalSeconds = 30 { didSet { refreshSettingsChanged?(); persistenceSettingsChanged?() } }
    var pauseWhenHidden = true { didSet { refreshSettingsChanged?(); persistenceSettingsChanged?() } }
    @ObservationIgnored var refreshSettingsChanged: (() -> Void)?
    @ObservationIgnored var screenChanged: (() -> Void)?
    @ObservationIgnored var persistenceSettingsChanged: (() -> Void)?
    var showStatusBar = true { didSet { persistenceSettingsChanged?() } }
    var clientsDetailsVisible = true { didSet { persistenceSettingsChanged?() } }
    var clientsDetailsHeight = 300.0 { didSet { persistenceSettingsChanged?() } }
    var clientsDetailsSection = ClientDetailsSection.overview.rawValue { didSet { persistenceSettingsChanged?() } }
    static let clientsDetailsHeightRange = 180.0...1200.0
    var persistedSettings: AppSettings {
        var settings = AppSettings()
        settings.showInMenuBar = showInMenuBar
        settings.refreshIntervalSeconds = refreshIntervalSeconds
        settings.pauseWhenHidden = pauseWhenHidden
        settings.showStatusBar = showStatusBar
        settings.clientsDetailsVisible = clientsDetailsVisible
        settings.clientsDetailsHeight = clientsDetailsHeight
        settings.clientsDetailsSection = clientsDetailsSection
        return settings
    }

    // MARK: Clients (chunk 12)

    /// The last successful inventory in this session. A failed refresh keeps
    /// it; a session switch clears it.
    private(set) var clientInventory: ClientInventory?
    private(set) var clientsFreshness = Freshness()
    /// Local device history. It is not session data, so a switch keeps it.
    private(set) var deviceRegistry = DeviceRegistryState()
    private(set) var deviceRegistryIssue: DeviceRegistryIssue?
    var newDeviceCount: Int { deviceRegistry.awaitingReview.count }

    enum DeviceRegistryIssue: Equatable {
        case notSaved, blocked
        var message: String {
            switch self {
            case .notSaved: "Device history could not be saved. New devices are reported once it saves."
            case .blocked: "Device history was written by a newer app or cannot be read, so it cannot be saved."
            }
        }
    }

    func acceptClients(_ result: AreaRefreshResult<ClientInventory>, observation: DeviceObservation?, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        switch result {
        case .success(let inventory, let observedAt, let source):
            clientInventory = inventory
            clientsFreshness = Freshness(lastSuccess: observedAt, lastAttempt: observedAt, source: source)
        case .failure(let category, let attemptedAt):
            clientsFreshness.lastAttempt = attemptedAt
            clientsFreshness.failure = category
        }
        clientsFreshness.isRefreshing = false
        if let observation {
            deviceRegistry = observation.state
            switch observation.saveFailure {
            case nil: deviceRegistryIssue = nil
            case .futureSchema?, .readFailed?: deviceRegistryIssue = .blocked
            case .corrupt?, .writeFailed?: deviceRegistryIssue = .notSaved
            }
        }
    }

    func replaceDeviceRegistry(_ state: DeviceRegistryState, issue: DeviceRegistryIssue? = nil) {
        deviceRegistry = state
        deviceRegistryIssue = issue
    }

    // MARK: Client details (chunk 13)

    /// The All Clients table selection. Kept here so Known Clients, the
    /// review sheet, and the context menu can open a device in the pane.
    var clientsSelection: Set<MACAddress> = []
    /// Local presence history, shared by every router session.
    private(set) var presence = PresenceLogState()
    private(set) var presenceIssue: PresenceIssue?
    /// The last result of a local write or client action, shown in the pane
    /// for that device only.
    var clientNotice: ClientNotice?

    enum PresenceIssue: Equatable {
        case notSaved, blocked
        var message: String {
            switch self {
            case .notSaved: "Presence history could not be saved. Routewell keeps it in memory and tries again."
            case .blocked: "Presence history was written by a newer app or cannot be read, so it is not saved."
            }
        }
    }

    struct ClientNotice: Equatable {
        let mac: MACAddress
        let text: String
        var tone: StatusTone = .unknown
    }

    func replacePresence(_ state: PresenceLogState, failure: StoreError? = nil) {
        presence = state
        switch failure {
        case nil: presenceIssue = nil
        case .futureSchema?, .readFailed?: presenceIssue = .blocked
        case .corrupt?, .writeFailed?: presenceIssue = .notSaved
        }
    }

    /// Clients' Show DNS Log: AdGuard Home › Query Log for that device. The
    /// tab is a placeholder until chunk 18, which reads this filter.
    var adGuardQueryLogClient: String?

    func showDNSLog(client: String) {
        adGuardQueryLogClient = client
        subpages[.adGuard] = AdGuardTab.queryLog.rawValue
        selection = .adGuard
    }

    /// Opens one device in the All Clients details pane.
    func revealClient(_ mac: MACAddress, section: ClientDetailsSection) {
        selection = .clients
        subpages[.clients] = SidebarDestination.clients.segments[0]
        clientsSelection = [mac]
        clientsDetailsVisible = true
        clientsDetailsSection = section.rawValue
    }
    // MARK: Router (chunk 14)

    /// The last successful Wi-Fi and SQM reads in this session. A failed
    /// refresh keeps them; a session switch clears them.
    private(set) var wireless: WirelessStatus?
    private(set) var wirelessFreshness = Freshness()
    private(set) var sqm: SQMConfiguration?
    private(set) var sqmFreshness = Freshness()
    private(set) var sqmCapability = Capability()
    /// The sampler's rings and Routewell's own session peaks.
    private(set) var telemetryHistory = TelemetryHistory.empty
    private(set) var telemetrySession = TelemetrySessionSummary()
    /// Multi-WAN active-path changes seen while Routewell runs.
    private(set) var wanPaths = WANPathTracker()

    func acceptRouterDetails(_ result: RouterDetailsResult, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        switch result.wireless {
        case .success(let value, let observedAt, let source):
            wireless = value
            wirelessFreshness = Freshness(lastSuccess: observedAt, lastAttempt: observedAt, source: source)
        case .failure(let category, let attemptedAt):
            wirelessFreshness.lastAttempt = attemptedAt
            wirelessFreshness.failure = category
        }
        switch result.sqm {
        case .success(let value, let observedAt, let source):
            sqm = value
            sqmFreshness = Freshness(lastSuccess: observedAt, lastAttempt: observedAt, source: source)
        case .failure(let category, let attemptedAt):
            // `-32601` proves the native API is absent: no earlier value stays.
            if result.sqmCapability.state == .unsupported { sqm = nil }
            sqmFreshness.lastAttempt = attemptedAt
            sqmFreshness.failure = category
        }
        sqmCapability = result.sqmCapability
    }

    // MARK: SSH (chunk 15)

    /// The probe result for this session; `nil` until the probe finishes.
    private(set) var sshProbe: SSHProbeResult?
    private(set) var ports: RouterPortsStatus?
    private(set) var portsFreshness = Freshness()
    /// Link changes seen while Routewell runs; never saved.
    private(set) var linkChanges = LinkChangeLog()
    private(set) var storage: StorageStatus?
    private(set) var storageFreshness = Freshness()
    private(set) var routerLogs: RouterLogTail?
    private(set) var routerLogsFreshness = Freshness()
    private(set) var adGuardProcessID: Observed<Int> = .unknown
    /// Bumped when the backend's SSH service may have changed without a
    /// session switch (the mock scenario), so views re-read it.
    private var sshRevision = 0

    /// True when the active profile has SSH set up. False shows
    /// `SSHRequiredView`, and nothing attempts SSH.
    var sshConfigured: Bool {
        _ = sshRevision
        return session.lease?.backend.ssh != nil
    }

    func sshBackendChanged() {
        sshRevision += 1
        sshProbe = nil
        ports = nil
        portsFreshness = Freshness()
        storage = nil
        storageFreshness = Freshness()
        routerLogs = nil
        routerLogsFreshness = Freshness()
        adGuardProcessID = .unknown
    }

    func acceptSSHProbe(_ probe: SSHProbeResult, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        sshProbe = probe
        capabilities[.ssh] = probe.capability
    }

    func acceptPorts(_ result: AreaRefreshResult<RouterPortsStatus>, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        if case .success(let value, let observedAt, _) = result { linkChanges.observe(value, at: observedAt) }
        Self.apply(result, to: &ports, freshness: &portsFreshness)
    }

    func acceptStorage(_ result: AreaRefreshResult<StorageStatus>, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        Self.apply(result, to: &storage, freshness: &storageFreshness)
    }

    func acceptRouterLogs(_ result: AreaRefreshResult<RouterLogTail>, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        Self.apply(result, to: &routerLogs, freshness: &routerLogsFreshness)
    }

    func acceptAdGuardProcess(_ value: Observed<Int>, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        adGuardProcessID = value
    }

    /// A failed read keeps the last value and records the failure.
    private static func apply<Value>(_ result: AreaRefreshResult<Value>, to value: inout Value?, freshness: inout Freshness) {
        switch result {
        case .success(let newValue, let observedAt, let source):
            value = newValue
            freshness = Freshness(lastSuccess: observedAt, lastAttempt: observedAt, source: source)
        case .failure(let category, let attemptedAt):
            freshness.lastAttempt = attemptedAt
            freshness.failure = category
        }
    }

    func acceptTelemetry(history: TelemetryHistory?, session summary: TelemetrySessionSummary, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        if let history { telemetryHistory = history }
        telemetrySession = summary
    }

    let mode: BackendMode

    init(mode: BackendMode, snapshot: OverviewSnapshot? = nil, now: Date = .now) {
        self.mode = mode
        self.snapshot = snapshot
        evaluatedAt = now
        if let snapshot {
            freshness = Dictionary(uniqueKeysWithValues: ScreenRefreshPlan.overviewAreas.map {
                ($0, Freshness(lastSuccess: snapshot.observedAt, lastAttempt: snapshot.observedAt, source: .mock))
            })
        }
        healthChecks = HealthEvaluator().evaluate(snapshot: snapshot, freshness: freshness, now: now)
    }

    func clearSession() {
        snapshot = nil
        freshness = [:]
        capabilities = [:]
        clientInventory = nil
        clientsFreshness = Freshness()
        wireless = nil
        wirelessFreshness = Freshness()
        sqm = nil
        sqmFreshness = Freshness()
        sqmCapability = Capability()
        telemetryHistory = .empty
        telemetrySession = TelemetrySessionSummary()
        wanPaths = WANPathTracker()
        sshBackendChanged()
        linkChanges = LinkChangeLog()
        healthChecks = HealthEvaluator().evaluate(snapshot: nil, freshness: freshness, now: evaluatedAt)
        isRefreshing = false
        refreshFailed = false
    }

    func replaceLogEvents(_ events: [LogEvent]) { logEvents = events }

    func acceptCapability(_ capability: Capability, area: DataArea, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        capabilities[area] = capability
    }

    enum Completion {
        case snapshot(OverviewSnapshot)
        case result(OverviewRefreshResult, Date)
        case failure(RefreshFailureCategory, Date)
        case busy(Bool, Date)
        case mutation(MutationReport<ProtectionState>)
    }

    func accept(_ completion: Completion, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        switch completion {
        case .snapshot(let value):
            snapshot = value
            for area in ScreenRefreshPlan.overviewAreas {
                freshness[area] = Freshness(lastSuccess: value.observedAt, lastAttempt: value.observedAt, source: .mock)
            }
        case .result(let result, _): apply(result)
        case .failure(let category, let date):
            for area in ScreenRefreshPlan.overviewAreas {
                var state = freshness[area] ?? Freshness()
                state.lastAttempt = date
                state.failure = category
                state.isRefreshing = false
                freshness[area] = state
            }
        case .busy(let value, let date):
            isRefreshing = value
            for area in ScreenRefreshPlan.overviewAreas {
                var state = freshness[area] ?? Freshness()
                state.isRefreshing = value
                if value { state.lastAttempt = date }
                freshness[area] = state
            }
        case .mutation(let report):
            lastProtectionReport = report
        }
        refreshFailed = freshness.values.contains { $0.failure != nil }
        evaluateFreshness(at: completion.date)
    }

    func evaluateFreshness(at date: Date) {
        evaluatedAt = date
        healthChecks = HealthEvaluator().evaluate(snapshot: snapshot, freshness: freshness, now: date)
    }

    private func apply(_ result: OverviewRefreshResult) {
        var value = snapshot ?? OverviewSnapshot(observedAt: evaluatedAt)
        apply(result.router, area: .router, value: &value.router)
        apply(result.internet, area: .internet, value: &value.internet)
        if case .success(let internet, let observedAt, _) = result.internet {
            wanPaths.observe(MultiWANStatus.derive(from: internet), at: observedAt)
        }
        apply(result.adGuard, area: .adGuard, value: &value.adGuard)
        apply(result.clients, area: .clients, value: &value.clients)
        if freshness.values.contains(where: { $0.lastSuccess != nil }) {
            value.observedAt = freshness.values.compactMap(\.lastSuccess).max() ?? evaluatedAt
            snapshot = value
        }
    }

    private func apply<Value>(_ result: AreaRefreshResult<Value>, area: DataArea, value: inout Value) {
        var state = freshness[area] ?? Freshness()
        state.isRefreshing = false
        switch result {
        case .success(let newValue, let observedAt, let source):
            value = newValue
            state.lastSuccess = observedAt
            state.lastAttempt = observedAt
            state.failure = nil
            state.source = source
        case .failure(let category, let attemptedAt):
            state.lastAttempt = attemptedAt
            state.failure = category
        }
        freshness[area] = state
    }
}

private extension AppModel.Completion {
    var date: Date {
        switch self {
        case .snapshot(let snapshot): snapshot.observedAt
        case .result(_, let date): date
        case .failure(_, let date), .busy(_, let date): date
        case .mutation(let report): report.finishedAt
        }
    }
}

enum BackendMode: Equatable {
    case mock, live, invalid

    static func resolve(_ value: String?, allowsMock: Bool) -> Self {
        switch value {
        case nil, "", "live": .live
        case "mock" where allowsMock: .mock
        default: .invalid
        }
    }
}

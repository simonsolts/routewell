import Foundation
import RoutewellKit

/// Synthetic data only. This backend has no transport or credential dependencies.
public actor MockRouterBackend: RouterBackend {
    public enum Scenario: String, CaseIterable, Sendable {
        case healthy, partial, offline, stale, slow
    }

    public enum FeatureBehavior: String, CaseIterable, Sendable {
        case supported, unsupported, unknown, slow, failing
    }

    public nonisolated let clients: (any ClientsService)?
    public nonisolated let mockClients = MockClientsService()
    public nonisolated let queryLog: (any QueryLogService)?
    public nonisolated let mockQueryLog = MockQueryLogService()
    public nonisolated let mockClientActions = MockClientActions()
    public nonisolated let mockRouter = MockRouterService()
    public nonisolated var router: (any RouterService)? { mockRouter }
    public nonisolated let mockSSH = MockSSHService()
    /// `nil` in the "SSH off" scenario, so SSH-only segments ask for SSH.
    public nonisolated var ssh: (any SSHService)? { mockSSH.scenario == .off ? nil : mockSSH }
    public nonisolated let network: (any NetworkService)?
    public nonisolated let maintenance: (any MaintenanceService)?
    public nonisolated let vpn: (any VPNService)?
    public nonisolated let plugins: (any PluginsService)?
    public nonisolated let telemetry: (any TelemetryService)?
    private let featureProbes: [DataArea: MockFeatureProbe]

    private var scenario: Scenario
    /// The router's one gate, shared by every mock AdGuard Home write, as
    /// `LiveRouterBackend` shares one.
    private let gate = MutationGate()
    public nonisolated let hostname: String
    /// The router's AdGuard Home setting and AdGuard Home itself.
    public nonisolated let mockAdGuard = MockAdGuardTransport()
    /// Turn On, Stop, Handle DNS, Restart through the real executor.
    public nonisolated var adGuardService: (any AdGuardServiceControl)? {
        AdGuardServiceExecutor(transport: mockAdGuard, gate: gate, policy: .mock)
    }
    /// Protection and the three switches through the real executor.
    public nonisolated var adGuardSettings: (any AdGuardSettingControl)? {
        AdGuardSettingExecutor(transport: mockAdGuard, gate: gate, policy: .mock)
    }
    public nonisolated var adGuardOverview: (any AdGuardOverviewService)? { mockAdGuard }
    /// Backups need SSH, as live.
    public nonisolated var adGuardBackups: (any AdGuardBackupControl)? {
        guard mockSSH.scenario != .off else { return nil }
        return AdGuardBackupExecutor(files: mockAdGuard, service: mockAdGuard, settings: mockAdGuard, gate: gate, policy: .mock)
    }

    public init(scenario: Scenario = .healthy, hostname: String = "flint-demo") {
        self.scenario = scenario
        self.hostname = hostname
        let probes = Dictionary(uniqueKeysWithValues: [DataArea.network, .maintenance, .vpn, .plugins, .telemetry].map { ($0, MockFeatureProbe()) })
        featureProbes = probes
        clients = mockClients
        queryLog = mockQueryLog
        network = probes[.network]
        maintenance = probes[.maintenance]
        vpn = probes[.vpn]
        plugins = probes[.plugins]
        telemetry = probes[.telemetry]
    }

    public func overview() async throws -> OverviewRefreshResult {
        try Task.checkCancellation()
        let scenario = scenario
        if scenario == .slow { try await Task.sleep(for: .seconds(5)) }
        var result = Self.result(scenario: scenario, hostname: hostname, at: .now)
        if case .success(var clients, let observedAt, let source) = result.clients {
            clients.listed = await mockClients.listedPresence()
            result.clients = .success(clients, observedAt: observedAt, source: source)
        }
        await applyAdGuardService(to: &result, scenario: scenario)
        return result
    }

    public func setScenario(_ scenario: Scenario) { self.scenario = scenario }

    /// The AdGuard area follows the mock service: off and not answering fail
    /// the area as live does; offline cannot read the router at all.
    private func applyAdGuardService(to result: inout OverviewRefreshResult, scenario: Scenario) async {
        let now = Date()
        guard scenario != .offline else {
            result.adGuardService = AdGuardServiceReading(config: .failure(.network), observedAt: now)
            return
        }
        let reading = await mockAdGuard.reading(at: now)
        result.adGuardService = reading
        switch reading.answer {
        case .answered(let status)?:
            if case .success(var adGuard, let observedAt, let source) = result.adGuard {
                if case .success(let config) = reading.config {
                    adGuard.handlesClientRequests = config.handlesDNS.map(Observed.value) ?? .unknown
                }
                adGuard.version = status.version
                adGuard.protection = AdGuardClient.adGuardStatus(status: status, stats: nil, now: now).protection
                result.adGuard = .success(adGuard, observedAt: observedAt, source: source)
            }
        case .failed(let category)?:
            result.adGuard = .failure(category, attemptedAt: now)
        case .notConfigured?, nil:
            result.adGuard = .failure(.unavailable, attemptedAt: now)
        }
    }

    public func setFeatureBehavior(_ behavior: FeatureBehavior, for area: DataArea) async {
        if area == .clients { await mockClients.setBehavior(behavior) }
        if area == .queryLog { await mockQueryLog.setBehavior(behavior) }
        await featureProbes[area]?.setBehavior(behavior)
    }

    public func setClientsScenario(_ scenario: MockClientsService.Scenario) async {
        await mockClients.setScenario(scenario)
    }

    /// Clients and the query log have mock data, so their capability starts
    /// supported; the other areas have none yet and start unknown.
    public static func defaultFeatureBehavior(for area: DataArea) -> FeatureBehavior {
        area == .clients || area == .queryLog ? .supported : .unknown
    }

    /// `nil` hides Ping and Wake.
    public nonisolated var clientActions: (any ClientActionsService)? {
        mockClientActions.currentMechanism == nil ? nil : mockClientActions
    }

    public static func result(
        scenario: Scenario = .healthy,
        hostname: String = "flint-demo",
        at date: Date
    ) -> OverviewRefreshResult {
        var snapshot = snapshot(at: date)
        snapshot.router.hostname = hostname
        let clients: AreaRefreshResult<ClientStatus> = switch scenario {
        case .partial: .failure(.timeout, attemptedAt: date)
        case .stale: .success(snapshot.clients, observedAt: date.addingTimeInterval(-65 * 60), source: .mock)
        case .offline: .failure(.network, attemptedAt: date)
        case .healthy, .slow: .success(snapshot.clients, observedAt: date, source: .mock)
        }
        if scenario == .offline {
            return OverviewRefreshResult(
                router: .failure(.network, attemptedAt: date),
                internet: .failure(.network, attemptedAt: date),
                adGuard: .failure(.network, attemptedAt: date),
                clients: clients
            )
        }
        return OverviewRefreshResult(
            router: .success(snapshot.router, observedAt: date, source: .mock),
            internet: .success(snapshot.internet, observedAt: date, source: .mock),
            adGuard: .success(snapshot.adGuard, observedAt: date, source: .mock),
            clients: clients
        )
    }

    public static func snapshot(at date: Date) -> OverviewSnapshot {
        var router = RouterStatus()
        router.reachability = .connected
        router.hostname = "flint-demo"
        router.model = "GL-BE14000"
        router.firmware = "4.9.1"
        router.openWrtVersion = "24.10"
        router.lanAddress = "192.168.8.1"
        router.uptimeSeconds = 1_198_800
        router.loadAverages = [0.18, 0.24, 0.21]
        router.memoryUsedBytes = 418_759_311
        router.memoryTotalBytes = 1_073_741_824
        router.temperatureCelsius = .value(54.1)
        router.kernelVersion = "5.4.281"
        router.architecture = "mediatek/mt7988"
        router.memoryFreeBytes = 350_000_000
        router.memoryBuffersAndCacheBytes = 304_982_513
        router.storageTotalBytes = 62_176_428_032
        router.storageFreeBytes = 60_738_560_000
        router.routerTime = date
        router.cpuUtilizationPercent = .value(2.9)
        router.sqmEnabled = .value(false)

        var internet = InternetStatus()
        internet.reachability = .connected
        internet.publicAddress = "203.0.113.24"
        internet.gateway = "192.0.2.1"
        internet.gatewayLatencyMilliseconds = 2.6
        internet.dnsServers = ["192.0.2.53", "192.0.2.54"]
        internet.wanProtocol = "dhcp"
        // Honest unknown: the mock reports no up/down state for any uplink.
        internet.uplinks = [UplinkInterface(name: "wan"), UplinkInterface(name: "wwan")]

        var adGuard = AdGuardStatus()
        adGuard.reachability = .connected
        adGuard.version = "0.107.65"
        adGuard.protection = .paused(until: date.addingTimeInterval(1800))
        adGuard.queriesToday = 45_852
        adGuard.blockedToday = 6_438
        adGuard.running = .value(true)
        adGuard.dnsPort = 3053
        adGuard.handlesClientRequests = .value(true)

        var clients = ClientStatus()
        clients.activeCount = .value(MockClientsService.defaultOnlineCount)
        clients.onlineByBand = [.ghz2_4: 5, .ghz6: 3]
        return OverviewSnapshot(router: router, internet: internet, adGuard: adGuard,
                                clients: clients, observedAt: date)
    }
}

private actor MockFeatureProbe: NetworkService,
    MaintenanceService, VPNService, PluginsService, TelemetryService {
    private var behavior: MockRouterBackend.FeatureBehavior = .unknown

    func setBehavior(_ value: MockRouterBackend.FeatureBehavior) { behavior = value }

    func probe() async -> Capability {
        let selected = behavior
        if selected == .slow {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return Capability() }
        }
        guard !Task.isCancelled else { return Capability() }
        switch selected {
        case .supported: return Capability(.supported, evidence: .mockScenario("supported"), observedAt: .now)
        case .unsupported: return Capability(.unsupported, evidence: .mockScenario("unsupported"), observedAt: .now)
        case .unknown, .slow, .failing: return Capability()
        }
    }
}

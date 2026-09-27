import Foundation
import RoutewellKit

/// Synthetic data only. This backend has no transport or credential dependencies.
public actor MockRouterBackend: RouterBackend {
    public enum Scenario: String, CaseIterable, Sendable {
        case healthy, partial, offline, stale, slow
    }

    /// Which outcome the mock Protection service produces on its next
    /// `setProtection` call. Selectable in DEBUG builds via a picker so the
    /// app's outcome-text mapping can be exercised without a live router.
    public enum ProtectionBehavior: String, CaseIterable, Sendable {
        case succeeds
        case mismatchThenRecovers
        case lostResponseThenApplied
        case externalEdit
        case unauthorized
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
    private var protectionBehavior: ProtectionBehavior = .succeeds
    /// Overrides `adGuard.protection` in the next `overview()` result once a
    /// mock mutation has run; `nil` means "use the scenario's own value."
    private var protectionOverride: ProtectionState?
    /// Serializes `runProtectionMutation` the same way the live path
    /// serializes through one `MutationGate` per backend: without it, an
    /// actor's reentrancy across `await Task.sleep` lets a second concurrent
    /// mutation read `protectionBehavior`/`protectionOverride` mid-update.
    private let protectionGate = MutationGate()
    public nonisolated let hostname: String

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
        if let protectionOverride, case .success(var adGuard, let observedAt, let source) = result.adGuard {
            adGuard.protection = protectionOverride
            result.adGuard = .success(adGuard, observedAt: observedAt, source: source)
        }
        return result
    }

    public func setScenario(_ scenario: Scenario) { self.scenario = scenario }

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

    public func setProtectionBehavior(_ behavior: ProtectionBehavior) {
        protectionBehavior = behavior
    }

    // MARK: - ProtectionService

    public nonisolated var protection: (any ProtectionService)? {
        MockProtectionService(backend: self)
    }

    /// Runs the currently selected `ProtectionBehavior` against `intent`,
    /// updating `protectionOverride` so the next `overview()` reflects the
    /// change, and returns the matching `MutationOutcome`. Never sleeps more
    /// than 100 ms. Serialized through `protectionGate`: a second concurrent
    /// call waits for the first to finish reading and writing shared state
    /// before it starts its own.
    func runProtectionMutation(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState> {
        let startedAt = Date()
        if let rejection = intent.validate() {
            return MutationReport(outcome: .rejected(rejection), dispatched: false, startedAt: startedAt, finishedAt: startedAt, failure: nil)
        }

        let token: MutationGateToken
        do {
            token = try await protectionGate.acquire()
        } catch {
            return MutationReport(
                outcome: .rejected(.preconditionFailed("Cancelled before dispatch")),
                dispatched: false, startedAt: startedAt, finishedAt: Date(), failure: nil
            )
        }
        let report = await performProtectionMutation(intent, allowRecovery: allowRecovery, startedAt: startedAt)
        await protectionGate.release(token)
        return report
    }

    private func performProtectionMutation(
        _ intent: ProtectionIntent, allowRecovery: Bool, startedAt: Date
    ) async -> MutationReport<ProtectionState> {
        try? await Task.sleep(for: .milliseconds(50))

        let intended = Self.intendedState(for: intent)
        let before = protectionOverride ?? .enabled

        switch protectionBehavior {
        case .succeeds:
            protectionOverride = intended
            return MutationReport(outcome: .verifiedSuccess(intended), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)

        case .mismatchThenRecovers:
            guard allowRecovery else {
                return MutationReport(outcome: .verifiedMismatch(expected: intended, actual: before), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)
            }
            protectionOverride = before
            return MutationReport(outcome: .verifiedRecovery(restored: before), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)

        case .lostResponseThenApplied:
            protectionOverride = intended
            return MutationReport(outcome: .verifiedSuccess(intended), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)

        case .externalEdit:
            let actual: ProtectionState = .paused(until: Date().addingTimeInterval(300))
            protectionOverride = actual
            return MutationReport(outcome: .conflictingExternalEdit(actual: actual), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)

        case .unauthorized:
            // Matches the live path's semantics: a 401/403 reaches the
            // server and is a definitive rejection, not an ambiguous one,
            // but a request was still sent — so `dispatched` is `true`.
            return MutationReport(
                outcome: .rejected(.preconditionFailed("AdGuard Home refused the login")),
                dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: .authentication
            )
        }
    }

    private static func intendedState(for intent: ProtectionIntent) -> ProtectionState {
        switch intent {
        case .enable: return .enabled
        case .disable: return .disabled
        case .pause(let duration):
            let components = duration.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            return .paused(until: Date().addingTimeInterval(seconds))
        }
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

private struct MockProtectionService: ProtectionService {
    let backend: MockRouterBackend

    func setProtection(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState> {
        await backend.runProtectionMutation(intent, allowRecovery: allowRecovery)
    }
}

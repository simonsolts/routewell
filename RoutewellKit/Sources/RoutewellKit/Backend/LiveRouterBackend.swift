import Foundation

/// What a live profile needs to reach the router and, optionally, an AdGuard
/// Home instance behind it. The caller derives `adGuardBaseURL`: the
/// router's host, `adGuard.port`, and the chosen scheme.
public struct LiveBackendConfiguration: Sendable {
    public var routerEndpoint: RouterEndpoint
    /// `nil` means no AdGuard Home instance is configured for this profile;
    /// the AdGuard area then always reports `.unavailable`.
    public var adGuard: AdGuardSettings?
    public var adGuardBaseURL: URL?

    public init(routerEndpoint: RouterEndpoint, adGuard: AdGuardSettings? = nil, adGuardBaseURL: URL? = nil) {
        self.routerEndpoint = routerEndpoint
        self.adGuard = adGuard
        self.adGuardBaseURL = adGuardBaseURL
    }
}

/// The result of "Test connection": enough to show "Connected: <model>,
/// firmware <version>" without waiting on a full overview refresh.
public struct RouterProbe: Sendable, Equatable {
    public var model: String?
    public var firmware: String?
    public var hostname: String?

    public init(model: String? = nil, firmware: String? = nil, hostname: String? = nil) {
        self.model = model
        self.firmware = firmware
        self.hostname = hostname
    }
}

/// A `RouterBackend` backed by the real GL.iNet router and (optionally) a
/// real AdGuard Home instance. It builds the services and the router's one
/// `MutationGate`, and forwards to them.
public actor LiveRouterBackend: RouterBackend, FixtureRecordableBackend, AdGuardHomeStateReading {
    private let configuration: LiveBackendConfiguration
    private let rpc: GLiNetRPCClient
    private let trustStore: any EndpointTrustStore
    private let trustPrompt: any TrustPromptHandler
    private let clock: @Sendable () -> Date
    private let log: SessionEventLog?
    private let fixtures: LiveFixtureRecorder
    private let overviewService: LiveOverviewService

    /// One `AdGuardSettingExecutor`, backed by the router's one
    /// `MutationGate`, shared across every call for the lifetime of this
    /// backend instance — never rebuilt per call, so "one mutation in
    /// flight per router" actually holds. `nil` when no AdGuard Home
    /// instance is configured.
    public nonisolated let adGuardSettings: (any AdGuardSettingControl)?
    /// AdGuard Home › Overview's reads. `nil` without AdGuard Home.
    public nonisolated let adGuardOverview: (any AdGuardOverviewService)?
    /// Reads the client inventory only when the Clients screen asks for it;
    /// `overview()` keeps its own client count.
    public nonisolated let clients: (any ClientsService)?
    /// Read on demand by the Clients details pane. `nil` without AdGuard Home.
    public nonisolated let queryLog: (any QueryLogService)?
    /// Ping and Wake run over SSH; there is no client-scoped RPC. Without an
    /// SSH runner (SSH is not set up) the buttons explain that.
    public nonisolated let clientActions: (any ClientActionsService)?
    /// Ports, Storage, Logs, and the AdGuard process ID. `nil` without an
    /// SSH runner, so nothing attempts SSH.
    public nonisolated let ssh: (any SSHService)?
    /// Wi-Fi, SQM, and the firmware check for the Router screen.
    public nonisolated let router: (any RouterService)?
    /// Turn On, Stop, Handle DNS, Restart, under the same gate as
    /// Protection and Wake. Without an AdGuard Home connection, writes are
    /// verified with the router's setting only.
    public nonisolated let adGuardService: (any AdGuardServiceControl)?
    /// The config file over SSH, the restart over RPC, the checks over
    /// AdGuard Home's API, under the same gate.
    public nonisolated let adGuardBackups: (any AdGuardBackupControl)?

    public init(
        configuration: LiveBackendConfiguration,
        rpc: GLiNetRPCClient,
        adGuard: AdGuardClient?,
        trustStore: any EndpointTrustStore,
        trustPrompt: any TrustPromptHandler,
        clock: @Sendable @escaping () -> Date = { Date() },
        log: SessionEventLog? = nil,
        sshRunner: (any SSHCommandRunning)? = nil
    ) {
        self.configuration = configuration
        self.rpc = rpc
        self.trustStore = trustStore
        self.trustPrompt = trustPrompt
        self.clock = clock
        self.log = log
        self.clients = LiveClientsService(rpc: rpc, adGuard: adGuard, clock: clock)
        self.queryLog = adGuard.map { LiveQueryLogService(adGuard: $0, clock: clock) }
        self.router = LiveRouterService(rpc: rpc, clock: clock)
        // One gate per router, shared by every write this backend runs.
        let gate = MutationGate()
        self.clientActions = sshRunner.map { SSHClientActions(runner: $0, gate: gate, clock: clock) } ?? SSHRequiredClientActions()
        self.ssh = sshRunner.map { LiveSSHService(runner: $0, clock: clock) }
        self.overviewService = LiveOverviewService(
            configuration: configuration, rpc: rpc, adGuard: adGuard,
            trustStore: trustStore, trustPrompt: trustPrompt, clock: clock, log: log
        )
        self.fixtures = LiveFixtureRecorder(rpc: rpc, adGuard: adGuard, sshRunner: sshRunner)
        self.adGuardSettings = adGuard.map {
            AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: $0), gate: gate, clock: clock, log: log)
        }
        self.adGuardOverview = adGuard.map { LiveAdGuardOverviewService(adGuard: $0, clock: clock) }
        self.adGuardService = AdGuardServiceExecutor(
            transport: LiveAdGuardServiceTransport(rpc: rpc, adGuard: adGuard), gate: gate, clock: clock, log: log
        )
        if let sshRunner, let adGuard {
            self.adGuardBackups = AdGuardBackupExecutor(
                files: SSHAdGuardConfigFileTransport(runner: sshRunner),
                service: LiveAdGuardServiceTransport(rpc: rpc, adGuard: adGuard),
                settings: LiveAdGuardSettingTransport(adGuard: adGuard), gate: gate, clock: clock, log: log)
        } else {
            self.adGuardBackups = nil
        }
    }

    // MARK: RouterBackend

    public func overview() async throws -> OverviewRefreshResult {
        try await overviewService.overview()
    }

    public func recordFixture(_ call: FixtureCall) async -> JSONValue {
        await fixtures.recordFixture(call)
    }

    public func recordSSHFixture(_ call: FixtureCall) async -> String? {
        await fixtures.recordSSHFixture(call)
    }

    /// For "Test connection": logs in and reads `system.get_info`.
    public func probe() async throws -> RouterProbe {
        do {
            return try await performProbe()
        } catch let error as GLiNetRPCError {
            guard case .transport(.untrustedServer(let decision)) = error else { throw error }
            let approved = await trustPrompt.requestTrust(host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port, decision: decision)
            guard approved else { throw error }
            try await trustStore.approve(
                TrustedEndpoint(host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port, fingerprint: decision.leafFingerprint, approvedAt: clock())
            )
            return try await performProbe()
        }
    }

    private func performProbe() async throws -> RouterProbe {
        let info = try await rpc.call(.init(object: "system", method: "get_info", params: .object([:])))
        let boardInfo = info["board_info"]
        return RouterProbe(
            model: boardInfo?["model"]?.string ?? info["model"]?.string,
            firmware: info["firmware_version"]?.string,
            hostname: boardInfo?["hostname"]?.string
        )
    }

    /// Onboarding's Finish row: one `adguardhome.get_config` read.
    public func adGuardHomeEnabled() async -> Observed<Bool> {
        do {
            let config = try await rpc.call(.init(object: "adguardhome", method: "get_config", params: .object([:])))
            return Self.adGuardHomeEnabled(config: config)
        } catch {
            return .unknown
        }
    }

    /// `enabled` from `adguardhome.get_config`; Unknown when absent.
    public static func adGuardHomeEnabled(config: JSONValue) -> Observed<Bool> {
        config["enabled"]?.bool.map(Observed.value) ?? .unknown
    }
}

import Foundation

public enum CapabilityState: String, Sendable, Equatable, Codable {
    case supported, unsupported, unknown
}

public enum CapabilityEvidence: Sendable, Equatable, Codable {
    case successfulResponse
    case methodNotFound(method: String)
    case mockScenario(String)
    /// The SSH probe failed for this reason (an `SSHFailure` name).
    case sshProbeFailed(String)
}

public struct Capability: Sendable, Equatable, Codable {
    public let state: CapabilityState
    public let evidence: CapabilityEvidence?
    public let observedAt: Date?

    public init(_ state: CapabilityState = .unknown, evidence: CapabilityEvidence? = nil, observedAt: Date? = nil) {
        self.state = state
        self.evidence = evidence
        self.observedAt = observedAt
    }
}

/// A probe never treats a timeout, malformed reply, or empty collection as
/// evidence of absence. Implementations retain unknown until they see a
/// successful response or an exact method-not-found response.
public protocol FeatureService: Sendable {
    func probe() async -> Capability
}

/// The Clients area. `inventory()` reads the router's client list
/// and joins AdGuard Home data. It throws only `CancellationError`; every
/// other failure is a per-area result, and only a failed router list fails
/// the area.
public protocol ClientsService: FeatureService {
    func inventory() async throws -> ClientInventoryResult
}
/// The AdGuard Home query log, per client and for the Query Log tab. One
/// bounded page per call, never persisted.
public protocol QueryLogService: FeatureService {
    /// One page for the Query Log tab. Throws only `CancellationError`.
    func page(_ query: QueryLogQuery) async throws -> AreaRefreshResult<QueryLogPage>
}

public extension QueryLogService {
    /// Throws only `CancellationError`; every other failure is a result.
    func recentQueries(search: String?, limit: Int) async throws -> AreaRefreshResult<QueryLogPage> {
        try await page(QueryLogQuery(search: search, limit: limit))
    }
}

/// AdGuard Home › Overview's reads, behind
/// `RouterBackend.adGuardOverview`. `nil` without an AdGuard Home connection.
public protocol AdGuardOverviewService: Sendable {
    /// Stats for `range`, the stats retention, the three switches, the
    /// blocklists, the DNS settings, and the query log retention. Throws only `CancellationError`; every other failure is
    /// a part of the reading.
    func overview(range: AdGuardStatsRange) async throws -> AdGuardOverviewReading
    /// `version.json` with `recheck_now` false. It can make AdGuard Home
    /// ask the internet, so the app reads it once per session, not on
    /// every refresh. Throws only `CancellationError`.
    func versionCheck() async throws -> Result<AdGuardVersionCheck, RefreshFailureCategory>
}

public extension AdGuardOverviewService {
    func versionCheck() async throws -> Result<AdGuardVersionCheck, RefreshFailureCategory> { .failure(.unavailable) }
}

/// The Router screen's RPC reads beyond the Overview areas.
/// Both calls throw only `CancellationError`; every other failure is a result.
public protocol RouterService: FeatureService {
    /// Wi-Fi radios and SSIDs, and the native SQM configuration.
    func details() async throws -> RouterDetailsResult
    /// Asks the router whether newer firmware exists. Nothing is downloaded
    /// or installed; Routewell never installs firmware.
    func checkFirmware() async throws -> FirmwareCheck
}

public struct RouterDetailsResult: Sendable {
    public var wireless: AreaRefreshResult<WirelessStatus>
    public var sqm: AreaRefreshResult<SQMConfiguration>
    /// `unsupported` only from `-32601` on `sqm.get_config`; any other
    /// error keeps it unknown (fail closed, as RouterPilot does).
    public var sqmCapability: Capability

    public init(wireless: AreaRefreshResult<WirelessStatus>, sqm: AreaRefreshResult<SQMConfiguration>, sqmCapability: Capability) {
        self.wireless = wireless
        self.sqm = sqm
        self.sqmCapability = sqmCapability
    }
}

/// SSH to the router, behind `RouterBackend.ssh`. The backend
/// has one only when the profile has SSH set up and its host key trusted.
/// Every call throws only `CancellationError`; every other failure is a
/// result. The app reads nothing until `check()` has reported supported.
public protocol SSHService: FeatureService {
    /// `ubus call system board`: success is supported; a timeout or an
    /// unreachable network is unknown; any other failure is unsupported.
    func check() async throws -> SSHProbeResult
    /// Router › Ports: the Ethernet interfaces from a prior enumeration.
    func ports() async throws -> AreaRefreshResult<RouterPortsStatus>
    /// Router › Storage: root filesystem, external volumes, Samba shares.
    func storage() async throws -> AreaRefreshResult<StorageStatus>
    /// Router › Logs: the last 250 lines, newest first.
    func logTail() async throws -> AreaRefreshResult<RouterLogTail>
    /// The AdGuard Home process ID; `unavailable` when no process runs.
    func adGuardProcess() async throws -> Observed<Int>
    /// AdGuard Home's memory and the query log's size on the router.
    func adGuardResources() async throws -> AdGuardResources
}

public extension SSHService {
    func adGuardResources() async throws -> AdGuardResources { AdGuardResources() }

    func probe() async -> Capability {
        (try? await check())?.capability ?? Capability()
    }
}

public struct SSHProbeResult: Sendable, Equatable {
    public var capability: Capability
    public var failure: SSHFailure?
    public var board: SystemBoard?

    public init(capability: Capability, failure: SSHFailure? = nil, board: SystemBoard? = nil) {
        self.capability = capability
        self.failure = failure
        self.board = board
    }
}

public protocol NetworkService: FeatureService {}
public protocol MaintenanceService: FeatureService {}
public protocol VPNService: FeatureService {}
public protocol PluginsService: FeatureService {}
public protocol TelemetryService: FeatureService {}

/// Whether AdGuard Home is switched on in the router's own settings
/// (`adguardhome.get_config` `enabled`). Onboarding's Finish row reads it.
public protocol AdGuardHomeStateReading: Sendable {
    func adGuardHomeEnabled() async -> Observed<Bool>
}

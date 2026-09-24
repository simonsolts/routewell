import Foundation

public enum CapabilityState: String, Sendable, Equatable, Codable {
    case supported, unsupported, unknown
}

public enum CapabilityEvidence: Sendable, Equatable, Codable {
    case successfulResponse
    case methodNotFound(method: String)
    case mockScenario(String)
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

/// The Clients area (chunk 12). `inventory()` reads the router's client list
/// and joins AdGuard Home data. It throws only `CancellationError`; every
/// other failure is a per-area result, and only a failed router list fails
/// the area.
public protocol ClientsService: FeatureService {
    func inventory() async throws -> ClientInventoryResult
}
/// The AdGuard Home query log (chunk 13 reads it per client; chunk 16 adds
/// the DNS Activity screen). One bounded page per call, never persisted.
public protocol QueryLogService: FeatureService {
    /// Throws only `CancellationError`; every other failure is a result.
    func recentQueries(search: String?, limit: Int) async throws -> AreaRefreshResult<QueryLogPage>
}

public enum QueryLogLimits {
    /// One fetch never asks for more than this many entries.
    public static let maximum = 500
}
/// The Router screen's RPC reads beyond the Overview areas (chunk 14).
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

public protocol NetworkService: FeatureService {}
public protocol MaintenanceService: FeatureService {}
public protocol VPNService: FeatureService {}
public protocol PluginsService: FeatureService {}
public protocol TelemetryService: FeatureService {}

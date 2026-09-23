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
public protocol QueryLogService: FeatureService {}
public protocol NetworkService: FeatureService {}
public protocol MaintenanceService: FeatureService {}
public protocol VPNService: FeatureService {}
public protocol PluginsService: FeatureService {}
public protocol TelemetryService: FeatureService {}

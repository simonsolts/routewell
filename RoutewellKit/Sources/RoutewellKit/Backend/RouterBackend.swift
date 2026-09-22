/// Runs one verified Protection mutation. `nil` from `RouterBackend.protection`
/// means the capability itself is unavailable (no AdGuard Home configured for
/// this router), not a transient failure.
public protocol ProtectionService: Sendable {
    func setProtection(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState>
}

public protocol RouterBackend: Sendable {
    func overview() async throws -> OverviewRefreshResult
    var protection: (any ProtectionService)? { get }
    var clients: (any ClientsService)? { get }
    var queryLog: (any QueryLogService)? { get }
    var network: (any NetworkService)? { get }
    var maintenance: (any MaintenanceService)? { get }
    var vpn: (any VPNService)? { get }
    var plugins: (any PluginsService)? { get }
    var telemetry: (any TelemetryService)? { get }
}

public extension RouterBackend {
    var clients: (any ClientsService)? { nil }
    var queryLog: (any QueryLogService)? { nil }
    var network: (any NetworkService)? { nil }
    var maintenance: (any MaintenanceService)? { nil }
    var vpn: (any VPNService)? { nil }
    var plugins: (any PluginsService)? { nil }
    var telemetry: (any TelemetryService)? { nil }

    func service(for area: DataArea) -> (any FeatureService)? {
        switch area {
        case .clients: clients
        case .queryLog: queryLog
        case .network: network
        case .maintenance: maintenance
        case .vpn: vpn
        case .plugins: plugins
        case .telemetry: telemetry
        default: nil
        }
    }
}

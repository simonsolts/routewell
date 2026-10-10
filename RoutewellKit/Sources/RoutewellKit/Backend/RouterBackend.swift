public protocol RouterBackend: Sendable {
    func overview() async throws -> OverviewRefreshResult
    var clients: (any ClientsService)? { get }
    var queryLog: (any QueryLogService)? { get }
    var network: (any NetworkService)? { get }
    var maintenance: (any MaintenanceService)? { get }
    var vpn: (any VPNService)? { get }
    var plugins: (any PluginsService)? { get }
    var telemetry: (any TelemetryService)? { get }
    /// Ping and Wake for one client. `nil` hides both buttons: no mechanism
    /// exists for this router.
    var clientActions: (any ClientActionsService)? { get }
    /// The Router screen's own reads. `nil` shows the RPC segments from the
    /// Overview areas only.
    var router: (any RouterService)? { get }
    /// SSH reads. `nil` means SSH is not set up for this profile:
    /// SSH-only segments show `SSHRequiredView` and nothing attempts SSH.
    var ssh: (any SSHService)? { get }
    /// Turn On, Stop, Handle DNS, and Restart for AdGuard Home.
    /// `nil` when the profile has no AdGuard Home connection.
    var adGuardService: (any AdGuardServiceControl)? { get }
    /// Protection on, off, and paused, and the three Protection switches
    ///. `nil` when the profile has no AdGuard Home connection:
    /// the capability is unavailable, not a transient failure.
    var adGuardSettings: (any AdGuardSettingControl)? { get }
    /// AdGuard Home › Overview's reads. `nil` without an AdGuard
    /// Home connection.
    var adGuardOverview: (any AdGuardOverviewService)? { get }
    /// Back Up Now and Restore… for AdGuard Home's config.
    /// `nil` without SSH or without an AdGuard Home connection.
    var adGuardBackups: (any AdGuardBackupControl)? { get }
}

public extension RouterBackend {
    var clients: (any ClientsService)? { nil }
    var queryLog: (any QueryLogService)? { nil }
    var network: (any NetworkService)? { nil }
    var maintenance: (any MaintenanceService)? { nil }
    var vpn: (any VPNService)? { nil }
    var plugins: (any PluginsService)? { nil }
    var telemetry: (any TelemetryService)? { nil }
    var clientActions: (any ClientActionsService)? { nil }
    var router: (any RouterService)? { nil }
    var ssh: (any SSHService)? { nil }
    var adGuardService: (any AdGuardServiceControl)? { nil }
    var adGuardSettings: (any AdGuardSettingControl)? { nil }
    var adGuardOverview: (any AdGuardOverviewService)? { nil }
    var adGuardBackups: (any AdGuardBackupControl)? { nil }

    func service(for area: DataArea) -> (any FeatureService)? {
        switch area {
        case .clients: clients
        case .queryLog: queryLog
        case .network: network
        case .maintenance: maintenance
        case .vpn: vpn
        case .plugins: plugins
        case .telemetry: telemetry
        case .routerDetail: router
        case .ssh: ssh
        default: nil
        }
    }
}

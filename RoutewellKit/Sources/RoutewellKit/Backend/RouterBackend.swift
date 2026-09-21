/// Runs one verified Protection mutation. `nil` from `RouterBackend.protection`
/// means the capability itself is unavailable (no AdGuard Home configured for
/// this router), not a transient failure.
public protocol ProtectionService: Sendable {
    func setProtection(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState>
}

public protocol RouterBackend: Sendable {
    func overview() async throws -> OverviewRefreshResult
    var protection: (any ProtectionService)? { get }
}

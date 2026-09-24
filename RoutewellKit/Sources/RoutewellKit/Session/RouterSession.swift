import Foundation

public struct SessionToken: Sendable, Hashable {
    public let profileID: String
    public let revision: UInt64

    public init(profileID: String, revision: UInt64) {
        self.profileID = profileID
        self.revision = revision
    }
}

public struct SessionLease: Sendable {
    public let token: SessionToken
    public let backend: any RouterBackend
    fileprivate let identity = UUID()

    public init(token: SessionToken, backend: any RouterBackend) {
        self.token = token
        self.backend = backend
    }
}

public enum SessionError: Error, Equatable {
    case stale, switching
}

public actor RouterSession {
    private var pending: SessionToken?
    private var active: SessionLease?

    public init() {}

    public func beginRevision(_ token: SessionToken) throws {
        if let pending, token.revision <= pending.revision { throw SessionError.stale }
        pending = token
        active = nil
    }

    public func installLease(_ lease: SessionLease) throws {
        guard pending == lease.token else { throw SessionError.stale }
        guard active == nil else { throw SessionError.stale }
        active = lease
    }

    public func validateBefore(_ lease: SessionLease) throws {
        guard pending == lease.token else { throw SessionError.stale }
        guard let active else { throw SessionError.switching }
        guard active.identity == lease.identity else { throw SessionError.stale }
    }

    public func validateAfter(_ lease: SessionLease) throws {
        try validateBefore(lease)
    }

    public func overview(using lease: SessionLease) async throws -> OverviewRefreshResult {
        try validateBefore(lease)
        let result: Result<OverviewRefreshResult, any Error>
        do { result = .success(try await lease.backend.overview()) }
        catch { result = .failure(error) }
        try validateAfter(lease)
        return try result.get()
    }

    /// Reads the client inventory, fenced like `overview(using:)`. `nil` when
    /// the backend has no Clients service.
    public func clientInventory(using lease: SessionLease) async throws -> ClientInventoryResult? {
        try validateBefore(lease)
        guard let service = lease.backend.clients else { return nil }
        let result: Result<ClientInventoryResult, any Error>
        do { result = .success(try await service.inventory()) }
        catch { result = .failure(error) }
        try validateAfter(lease)
        return try result.get()
    }

    /// Reads one query-log page, fenced like `overview(using:)`. `nil` when
    /// the backend has no query-log service (no AdGuard Home configured).
    public func recentQueries(using lease: SessionLease, search: String?, limit: Int) async throws -> AreaRefreshResult<QueryLogPage>? {
        try validateBefore(lease)
        guard let service = lease.backend.queryLog else { return nil }
        let result: Result<AreaRefreshResult<QueryLogPage>, any Error>
        do { result = .success(try await service.recentQueries(search: search, limit: min(max(limit, 1), QueryLogLimits.maximum))) }
        catch { result = .failure(error) }
        try validateAfter(lease)
        return try result.get()
    }

    /// Reads the Router screen's Wi-Fi and SQM, fenced like `overview(using:)`.
    /// `nil` when the backend has no Router service.
    public func routerDetails(using lease: SessionLease) async throws -> RouterDetailsResult? {
        try validateBefore(lease)
        guard let service = lease.backend.router else { return nil }
        let result: Result<RouterDetailsResult, any Error>
        do { result = .success(try await service.details()) }
        catch { result = .failure(error) }
        try validateAfter(lease)
        return try result.get()
    }

    /// One on-demand firmware check, fenced like a read. `nil` when the
    /// backend has no Router service.
    public func checkFirmware(using lease: SessionLease) async throws -> FirmwareCheck? {
        try validateBefore(lease)
        guard let service = lease.backend.router else { return nil }
        let result: Result<FirmwareCheck, any Error>
        do { result = .success(try await service.checkFirmware()) }
        catch { result = .failure(error) }
        try validateAfter(lease)
        return try result.get()
    }

    /// Pings one client from the router, fenced like a read. `nil` when the
    /// backend offers no client actions.
    public func ping(using lease: SessionLease, address: IPv4Literal) async throws -> Result<PingResult, RefreshFailureCategory>? {
        try validateBefore(lease)
        guard let service = lease.backend.clientActions else { return nil }
        let result: Result<Result<PingResult, RefreshFailureCategory>, any Error>
        do { result = .success(try await service.ping(address)) }
        catch { result = .failure(error) }
        try validateAfter(lease)
        return try result.get()
    }

    /// Sends one Wake-on-LAN packet. Like `setProtection`, a `.stale` from
    /// `validateAfter` means the packet may have been sent.
    public func wake(using lease: SessionLease, mac: MACAddress) async throws -> MutationReport<WakeResult>? {
        try validateBefore(lease)
        guard let service = lease.backend.clientActions else { return nil }
        let report = await service.wake(mac)
        try validateAfter(lease)
        return report
    }

    /// Runs one Protection mutation against `lease.backend`. `validateBefore`
    /// fences it against a lease that's already stale or mid-switch;
    /// `validateAfter` fences the result. If `validateAfter` throws
    /// `.stale`, the write may still have reached the router — the caller
    /// must treat the outcome as unknown and refresh rather than re-send,
    /// since a `MutationReport` is never returned in that case.
    public func setProtection(
        using lease: SessionLease, intent: ProtectionIntent, allowRecovery: Bool
    ) async throws -> MutationReport<ProtectionState> {
        try validateBefore(lease)
        let startedAt = Date()
        let report: MutationReport<ProtectionState>
        if let protection = lease.backend.protection {
            report = await protection.setProtection(intent, allowRecovery: allowRecovery)
        } else {
            report = MutationReport(
                outcome: .rejected(.capabilityUnavailable),
                dispatched: false, startedAt: startedAt, finishedAt: startedAt, failure: nil
            )
        }
        try validateAfter(lease)
        return report
    }
}

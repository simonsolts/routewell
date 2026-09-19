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
}

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

    /// Runs one read against `lease.backend`. It is validated before it
    /// starts and after it ends, so a result from an old lease is dropped:
    /// the call throws `.stale` or `.switching` instead. Return `nil` from
    /// `body` when the backend has no service for the read.
    public func query<Value: Sendable>(
        _ lease: SessionLease, _ body: @Sendable (any RouterBackend) async throws -> Value
    ) async throws -> Value {
        try await fenced(lease, body)
    }

    /// Runs one write against `lease.backend`, fenced like `query`. If the
    /// check after `body` throws `.stale`, the write may still have reached
    /// the router: no report comes back, so the caller must treat the outcome
    /// as unknown and refresh rather than send it again.
    public func command<Value: Sendable>(
        _ lease: SessionLease, _ body: @Sendable (any RouterBackend) async throws -> Value
    ) async throws -> Value {
        try await fenced(lease, body)
    }

    private func fenced<Value: Sendable>(
        _ lease: SessionLease, _ body: @Sendable (any RouterBackend) async throws -> Value
    ) async throws -> Value {
        try validateBefore(lease)
        let result: Result<Value, any Error>
        do { result = .success(try await body(lease.backend)) }
        catch { result = .failure(error) }
        try validateAfter(lease)
        return try result.get()
    }
}

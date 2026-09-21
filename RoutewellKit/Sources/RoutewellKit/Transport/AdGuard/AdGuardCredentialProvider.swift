import Foundation

/// Supplies the headers `AdGuardClient` needs on every request, and decides
/// whether a 401/403 is worth retrying once.
public protocol AdGuardCredentialProvider: Sendable {
    /// Headers to add to every AdGuard request (e.g. Cookie or Authorization). May log in.
    func authorizationHeaders() async throws -> [String: String]
    /// Called after 401/403 so the provider can refresh. Return true if a retry makes sense.
    func handleUnauthorized() async -> Bool
}

/// Router-login-backed AdGuard auth: `Cookie: Admin-Token=<sid>`. Per the
/// GL.iNet API research this stopped working reliably on firmware >= 4.9.0,
/// so `handleUnauthorized()` still tries once (invalidating the cached sid)
/// but callers should prefer `BasicAdGuardCredentials` when it fails.
public struct RouterTokenAdGuardCredentials: AdGuardCredentialProvider {
    private let session: any RouterSessionTokenProvider

    public init(session: any RouterSessionTokenProvider) {
        self.session = session
    }

    public func authorizationHeaders() async throws -> [String: String] {
        let sid = try await session.sessionID()
        return ["Cookie": "Admin-Token=\(sid)"]
    }

    public func handleUnauthorized() async -> Bool {
        await session.invalidateSession()
        return true
    }
}

/// AdGuard Home's own account: `Authorization: Basic base64(user:password)`.
public struct BasicAdGuardCredentials: AdGuardCredentialProvider {
    private let username: String
    private let password: @Sendable () async throws -> String

    public init(username: String, password: @Sendable @escaping () async throws -> String) {
        self.username = username
        self.password = password
    }

    public func authorizationHeaders() async throws -> [String: String] {
        let password = try await password()
        let raw = "\(username):\(password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return ["Authorization": "Basic \(encoded)"]
    }

    public func handleUnauthorized() async -> Bool {
        // A fixed account/password pair will not become valid on retry.
        false
    }
}

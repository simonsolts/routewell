import Foundation

/// Errors surfaced by the GL.iNet JSON-RPC transport and by the login
/// hashing it depends on. `.rpcError`'s message is truncated to 120 chars
/// and never includes `params` (which may carry a session id or similar).
public enum GLiNetRPCError: Error, Equatable, Sendable {
    case transport(TransportError)
    case httpStatus(Int)
    case malformedResponse
    case accessDenied
    /// `-32003`, seen after about eight refused logins: sign-in is paused.
    case loginPaused
    case methodNotFound(String)
    case invalidParameters
    case rpcError(code: Int, message: String)
    case unsupportedAlgorithm(Int)
    case unsupportedHashMethod(String)
    case credentialUnavailable(CredentialError)
}

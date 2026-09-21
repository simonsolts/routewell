import Foundation

/// Supplies a valid GL.iNet session id (`sid`), logging in on demand. Any
/// caller that needs an authenticated call goes through this instead of
/// managing login itself, so one login is shared across concurrent callers.
public protocol RouterSessionTokenProvider: Sendable {
    /// Returns a valid sid, logging in if needed. Throws `GLiNetRPCError`.
    func sessionID() async throws -> String
    /// Forget the cached sid so the next call logs in again.
    func invalidateSession() async
}

/// One authenticated GL.iNet `object.method` call and its parameters.
public struct GLiNetRPCCall: Sendable, Equatable {
    public let object: String
    public let method: String
    /// Must be `.object`.
    public let params: JSONValue

    public init(object: String, method: String, params: JSONValue) {
        self.object = object
        self.method = method
        self.params = params
    }
}

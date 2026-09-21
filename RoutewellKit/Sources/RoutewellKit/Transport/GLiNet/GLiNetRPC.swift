/// NOTE: kept minimal on purpose — this file is one of two duplicated between
/// chunk 09 task 5 and task 6 branches. The coordinator keeps one copy at merge.
public protocol RouterSessionTokenProvider: Sendable {
    /// Returns a valid sid, logging in if needed. Throws GLiNetRPCError.
    func sessionID() async throws -> String
    /// Forget the cached sid so the next call logs in again.
    func invalidateSession() async
}

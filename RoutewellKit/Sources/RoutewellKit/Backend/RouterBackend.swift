public protocol RouterBackend: Sendable {
    func overview() async throws -> OverviewRefreshResult
}

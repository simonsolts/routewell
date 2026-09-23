import Foundation

/// Reads AdGuard Home's query log. A successful read proves support; any
/// failure leaves the capability unknown, because AdGuard Home has no
/// method-not-found answer for a missing endpoint.
public actor LiveQueryLogService: QueryLogService {
    private let adGuard: AdGuardClient
    private let clock: @Sendable () -> Date

    public init(adGuard: AdGuardClient, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.adGuard = adGuard
        self.clock = clock
    }

    public func probe() async -> Capability {
        do {
            _ = try await adGuard.queryLog(search: nil, limit: 1)
            return Capability(.supported, evidence: .successfulResponse, observedAt: clock())
        } catch {
            return Capability()
        }
    }

    public func recentQueries(search: String?, limit: Int) async throws -> AreaRefreshResult<QueryLogPage> {
        let attemptedAt = clock()
        let bounded = min(max(limit, 1), QueryLogLimits.maximum)
        let json: JSONValue
        do {
            json = try await adGuard.queryLog(search: search, limit: bounded)
        } catch let error as AdGuardClientError {
            try LiveRouterBackend.rethrowIfCancelled(error)
            return .failure(LiveRouterBackend.category(for: error), attemptedAt: attemptedAt)
        }
        guard let page = QueryLogParser.parse(json, limit: bounded) else {
            return .failure(.malformedResponse, attemptedAt: attemptedAt)
        }
        return .success(page, observedAt: attemptedAt, source: .adGuardAPI)
    }
}

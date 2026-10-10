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

    public func page(_ query: QueryLogQuery) async throws -> AreaRefreshResult<QueryLogPage> {
        let attemptedAt = clock()
        let adGuard = adGuard
        let json: JSONValue
        switch try await LiveRouterBackend.adGuardResult({ try await adGuard.queryLog(query) }) {
        case .success(let value): json = value
        case .failure(let category): return .failure(category, attemptedAt: attemptedAt)
        }
        guard let page = QueryLogParser.parse(json, limit: query.limit) else {
            return .failure(.malformedResponse, attemptedAt: attemptedAt)
        }
        return .success(page, observedAt: attemptedAt, source: .adGuardAPI)
    }
}

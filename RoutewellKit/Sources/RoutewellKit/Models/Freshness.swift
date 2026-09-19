import Foundation

public enum DataArea: String, CaseIterable, Sendable, Hashable, Codable {
    case router, internet, adGuard, clients
}

public enum ObservationSource: Sendable, Equatable, Codable {
    case mock, routerRPC, adGuardAPI
}

public enum RefreshFailureCategory: Sendable, Equatable, Hashable, Codable, Error {
    case network, authentication, timeout, malformedResponse, unavailable
}

public struct Freshness: Sendable, Equatable, Codable {
    public var lastSuccess: Date?
    public var lastAttempt: Date?
    public var failure: RefreshFailureCategory?
    public var source: ObservationSource?
    public var isRefreshing: Bool

    public init(
        lastSuccess: Date? = nil,
        lastAttempt: Date? = nil,
        failure: RefreshFailureCategory? = nil,
        source: ObservationSource? = nil,
        isRefreshing: Bool = false
    ) {
        self.lastSuccess = lastSuccess
        self.lastAttempt = lastAttempt
        self.failure = failure
        self.source = source
        self.isRefreshing = isRefreshing
    }
}

public enum AreaRefreshResult<Value: Sendable>: Sendable {
    case success(Value, observedAt: Date, source: ObservationSource)
    case failure(RefreshFailureCategory, attemptedAt: Date)
}

public struct OverviewRefreshResult: Sendable {
    public var router: AreaRefreshResult<RouterStatus>
    public var internet: AreaRefreshResult<InternetStatus>
    public var adGuard: AreaRefreshResult<AdGuardStatus>
    public var clients: AreaRefreshResult<ClientStatus>

    public init(
        router: AreaRefreshResult<RouterStatus>,
        internet: AreaRefreshResult<InternetStatus>,
        adGuard: AreaRefreshResult<AdGuardStatus>,
        clients: AreaRefreshResult<ClientStatus>
    ) {
        self.router = router
        self.internet = internet
        self.adGuard = adGuard
        self.clients = clients
    }
}

public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}

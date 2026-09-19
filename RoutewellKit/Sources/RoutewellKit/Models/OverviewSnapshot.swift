import Foundation

public enum Reachability: Sendable, Equatable {
    case connected, unreachable, unknown
}

public enum Observed<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    case unavailable
    case unknown
}

public enum ProtectionState: Sendable, Equatable {
    case enabled, disabled, paused(until: Date), unknown
}

public struct RouterStatus: Sendable, Equatable {
    public var reachability: Reachability = .unknown
    public var hostname: String?
    public var model: String?
    public var firmware: String?
    public var openWrtVersion: String?
    public var lanAddress: String?
    public var uptimeSeconds: Int?
    public var loadAverages: [Double] = []
    public var memoryUsedBytes: Int64?
    public var memoryTotalBytes: Int64?
    public var memoryHistory: [Double] = []
    public var temperatureCelsius: Observed<Double> = .unknown
    public init() {}
}

public struct InternetStatus: Sendable, Equatable {
    public var reachability: Reachability = .unknown
    public var publicAddress: String?
    public var gateway: String?
    public var gatewayLatencyMilliseconds: Double?
    public var dnsServers: [String] = []
    public init() {}
}

public struct AdGuardStatus: Sendable, Equatable {
    public var reachability: Reachability = .unknown
    public var version: String?
    public var protection: ProtectionState = .unknown
    public var queriesToday: Int?
    public var blockedToday: Int?
    public init() {}
}

public struct ClientStatus: Sendable, Equatable {
    public var activeCount: Observed<Int> = .unknown
    public init() {}
}

public struct OverviewSnapshot: Sendable, Equatable {
    public var router: RouterStatus
    public var internet: InternetStatus
    public var adGuard: AdGuardStatus
    public var clients: ClientStatus
    public var observedAt: Date

    public init(
        router: RouterStatus = .init(),
        internet: InternetStatus = .init(),
        adGuard: AdGuardStatus = .init(),
        clients: ClientStatus = .init(),
        observedAt: Date
    ) {
        self.router = router
        self.internet = internet
        self.adGuard = adGuard
        self.clients = clients
        self.observedAt = observedAt
    }
}

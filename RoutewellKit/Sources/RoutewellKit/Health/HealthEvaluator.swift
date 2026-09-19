import Foundation

public enum StatusTone: Sendable, Equatable {
    case healthy, attention, degraded, error, unknown, inProgress
}

public enum DestinationKey: Sendable, Equatable {
    case overview, protection, network, router, clients
}

public struct HealthCheck: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable, Hashable {
        case reachability(DataArea)
        case data(DataArea)
        case freshness(DataArea)
        case refreshFailure(DataArea, RefreshFailureCategory)
        case refreshing(DataArea)
    }

    public enum State: Sendable, Equatable {
        case connected, unreachable, available, unknown
        case fresh, stale, neverLoaded
        case recentlyFailed(RefreshFailureCategory)
        case refreshing
    }

    public let kind: Kind
    public let state: State
    public let tone: StatusTone
    public let destination: DestinationKey
    public var id: Kind { kind }

    public init(kind: Kind, state: State, tone: StatusTone, destination: DestinationKey) {
        self.kind = kind
        self.state = state
        self.tone = tone
        self.destination = destination
    }
}

public struct HealthEvaluator: Sendable {
    public static let staleAfter: TimeInterval = 60 * 60

    public init() {}

    public func evaluate(
        snapshot: OverviewSnapshot?,
        freshness: [DataArea: Freshness],
        now: Date
    ) -> [HealthCheck] {
        var checks: [HealthCheck] = []
        for area in DataArea.allCases {
            let state = freshness[area] ?? Freshness()
            if state.isRefreshing {
                checks.append(.init(kind: .refreshing(area), state: .refreshing,
                                    tone: .inProgress, destination: destination(for: area)))
            }
            if let failure = state.failure {
                checks.append(.init(kind: .refreshFailure(area, failure), state: .recentlyFailed(failure),
                                    tone: .degraded, destination: destination(for: area)))
            }
            if let success = state.lastSuccess {
                let stale = now.timeIntervalSince(success) > Self.staleAfter
                checks.append(.init(kind: .freshness(area), state: stale ? .stale : .fresh,
                                    tone: stale ? .attention : .healthy, destination: destination(for: area)))
            } else {
                checks.append(.init(kind: .freshness(area), state: .neverLoaded,
                                    tone: .unknown, destination: destination(for: area)))
            }
        }

        checks.append(reachability(.router, snapshot?.router.reachability ?? .unknown))
        checks.append(reachability(.internet, snapshot?.internet.reachability ?? .unknown))
        checks.append(reachability(.adGuard, snapshot?.adGuard.reachability ?? .unknown))
        let clientState: HealthCheck.State
        let clientTone: StatusTone
        switch snapshot?.clients.activeCount ?? .unknown {
        case .value: (clientState, clientTone) = (.available, .healthy)
        case .unavailable, .unknown: (clientState, clientTone) = (.unknown, .unknown)
        }
        checks.append(.init(kind: .data(.clients), state: clientState, tone: clientTone, destination: .clients))
        return checks
    }

    private func reachability(_ area: DataArea, _ value: Reachability) -> HealthCheck {
        let state: HealthCheck.State
        let tone: StatusTone
        switch value {
        case .connected: (state, tone) = (.connected, .healthy)
        case .unreachable: (state, tone) = (.unreachable, .error)
        case .unknown: (state, tone) = (.unknown, .unknown)
        }
        return .init(kind: .reachability(area), state: state, tone: tone, destination: destination(for: area))
    }

    private func destination(for area: DataArea) -> DestinationKey {
        switch area {
        case .router: .router
        case .internet: .network
        case .adGuard: .protection
        case .clients: .clients
        }
    }
}

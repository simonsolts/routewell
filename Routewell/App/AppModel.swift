import Foundation
import Observation
import RoutewellKit

@MainActor @Observable
final class AppModel {
    var selection: SidebarDestination = .overview
    var subpages: [SidebarDestination: String] = [:]
    private(set) var snapshot: OverviewSnapshot?
    private(set) var freshness: [DataArea: Freshness] = [:]
    private(set) var healthChecks: [HealthCheck] = []
    private(set) var evaluatedAt: Date
    private(set) var isRefreshing = false
    private(set) var refreshFailed = false
    let session = SessionController()
    var mockScenarioID = "healthy"
    var showInMenuBar = true { didSet { refreshSettingsChanged?() } }
    var refreshIntervalSeconds = 30 { didSet { refreshSettingsChanged?() } }
    var pauseWhenHidden = true { didSet { refreshSettingsChanged?() } }
    @ObservationIgnored var refreshSettingsChanged: (() -> Void)?
    var showStatusBar = true
    let mode: BackendMode

    init(mode: BackendMode, snapshot: OverviewSnapshot? = nil, now: Date = .now) {
        self.mode = mode
        self.snapshot = snapshot
        evaluatedAt = now
        if let snapshot {
            freshness = Dictionary(uniqueKeysWithValues: DataArea.allCases.map {
                ($0, Freshness(lastSuccess: snapshot.observedAt, lastAttempt: snapshot.observedAt, source: .mock))
            })
        }
        healthChecks = HealthEvaluator().evaluate(snapshot: snapshot, freshness: freshness, now: now)
    }

    func clearSession() {
        snapshot = nil
        freshness = [:]
        healthChecks = HealthEvaluator().evaluate(snapshot: nil, freshness: freshness, now: evaluatedAt)
        isRefreshing = false
        refreshFailed = false
    }

    enum Completion {
        case snapshot(OverviewSnapshot)
        case result(OverviewRefreshResult, Date)
        case failure(RefreshFailureCategory, Date)
        case busy(Bool, Date)
    }

    func accept(_ completion: Completion, token: SessionToken) {
        guard session.isReady, token == session.expectedToken else { return }
        switch completion {
        case .snapshot(let value):
            snapshot = value
            for area in DataArea.allCases {
                freshness[area] = Freshness(lastSuccess: value.observedAt, lastAttempt: value.observedAt, source: .mock)
            }
        case .result(let result, _): apply(result)
        case .failure(let category, let date):
            for area in DataArea.allCases {
                var state = freshness[area] ?? Freshness()
                state.lastAttempt = date
                state.failure = category
                state.isRefreshing = false
                freshness[area] = state
            }
        case .busy(let value, let date):
            isRefreshing = value
            for area in DataArea.allCases {
                var state = freshness[area] ?? Freshness()
                state.isRefreshing = value
                if value { state.lastAttempt = date }
                freshness[area] = state
            }
        }
        refreshFailed = freshness.values.contains { $0.failure != nil }
        evaluateFreshness(at: completion.date)
    }

    func evaluateFreshness(at date: Date) {
        evaluatedAt = date
        healthChecks = HealthEvaluator().evaluate(snapshot: snapshot, freshness: freshness, now: date)
    }

    private func apply(_ result: OverviewRefreshResult) {
        var value = snapshot ?? OverviewSnapshot(observedAt: evaluatedAt)
        apply(result.router, area: .router, value: &value.router)
        apply(result.internet, area: .internet, value: &value.internet)
        apply(result.adGuard, area: .adGuard, value: &value.adGuard)
        apply(result.clients, area: .clients, value: &value.clients)
        if freshness.values.contains(where: { $0.lastSuccess != nil }) {
            value.observedAt = freshness.values.compactMap(\.lastSuccess).max() ?? evaluatedAt
            snapshot = value
        }
    }

    private func apply<Value>(_ result: AreaRefreshResult<Value>, area: DataArea, value: inout Value) {
        var state = freshness[area] ?? Freshness()
        state.isRefreshing = false
        switch result {
        case .success(let newValue, let observedAt, let source):
            value = newValue
            state.lastSuccess = observedAt
            state.lastAttempt = observedAt
            state.failure = nil
            state.source = source
        case .failure(let category, let attemptedAt):
            state.lastAttempt = attemptedAt
            state.failure = category
        }
        freshness[area] = state
    }
}

private extension AppModel.Completion {
    var date: Date {
        switch self {
        case .snapshot(let snapshot): snapshot.observedAt
        case .result(_, let date): date
        case .failure(_, let date), .busy(_, let date): date
        }
    }
}

enum BackendMode: Equatable {
    case mock, unconfigured, invalid

    static func resolve(_ value: String?, allowsMock: Bool) -> Self {
        switch value {
        case nil, "": .unconfigured
        case "mock" where allowsMock: .mock
        default: .invalid
        }
    }
}

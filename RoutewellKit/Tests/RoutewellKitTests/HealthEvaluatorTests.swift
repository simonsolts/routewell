import Foundation
import Testing
@testable import RoutewellKit

@Test func freshnessCanShowRefreshingFailureAndStalenessTogether() {
    let now = Date(timeIntervalSince1970: 10_000)
    let freshness = Freshness(lastSuccess: now.addingTimeInterval(-3_601), lastAttempt: now,
                              failure: .timeout, source: .mock, isRefreshing: true)
    let checks = HealthEvaluator().evaluate(snapshot: nil, freshness: [.clients: freshness], now: now)
    #expect(checks.contains { $0.kind == .refreshing(.clients) && $0.tone == .inProgress })
    #expect(checks.contains { $0.kind == .refreshFailure(.clients, .timeout) && $0.tone == .degraded })
    #expect(checks.contains { $0.kind == .freshness(.clients) && $0.state == .stale })
}

@Test func unknownTelemetryNeverProducesHealthyHealth() {
    let now = Date(timeIntervalSince1970: 10_000)
    var router = RouterStatus()
    router.loadAverages = [12, 10, 8]
    router.temperatureCelsius = .unknown
    let snapshot = OverviewSnapshot(router: router, observedAt: now)
    let checks = HealthEvaluator().evaluate(snapshot: snapshot, freshness: [:], now: now)
    let routerReachability = checks.first { $0.kind == .reachability(.router) }
    #expect(routerReachability?.state == .unknown)
    #expect(routerReachability?.tone == .unknown)
    #expect(!checks.contains { check in
        if case .data(.router) = check.kind { return check.tone == .healthy }
        return false
    })
}

@Test func freshnessBoundaryIsAfterSixtyMinutes() {
    let now = Date(timeIntervalSince1970: 10_000)
    let exactly = Freshness(lastSuccess: now.addingTimeInterval(-3_600))
    let later = Freshness(lastSuccess: now.addingTimeInterval(-3_601))
    let evaluator = HealthEvaluator()
    #expect(evaluator.evaluate(snapshot: nil, freshness: [.clients: exactly], now: now)
        .contains { $0.kind == .freshness(.clients) && $0.state == .fresh })
    #expect(evaluator.evaluate(snapshot: nil, freshness: [.clients: later], now: now)
        .contains { $0.kind == .freshness(.clients) && $0.state == .stale })
}

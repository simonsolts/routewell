import Foundation
import RoutewellKit

/// Synthetic data only. This backend has no transport or credential dependencies.
public struct MockRouterBackend: RouterBackend {
    public enum Scenario: Sendable { case healthy, unknown }
    public let scenario: Scenario
    public let hostname: String

    public init(scenario: Scenario = .healthy, hostname: String = "flint-demo") {
        self.scenario = scenario
        self.hostname = hostname
    }

    public func overview() async throws -> OverviewSnapshot {
        try Task.checkCancellation()
        var snapshot = Self.snapshot(scenario: scenario, at: .now)
        if scenario == .healthy { snapshot.router.hostname = hostname }
        return snapshot
    }

    public static func snapshot(scenario: Scenario = .healthy, at date: Date) -> OverviewSnapshot {
        guard scenario == .healthy else { return OverviewSnapshot(observedAt: date) }
        var router = RouterStatus()
        router.reachability = .connected
        router.hostname = "flint-demo"
        router.model = "GL-BE14000"
        router.firmware = "4.9.1"
        router.openWrtVersion = "24.10"
        router.lanAddress = "192.168.8.1"
        router.uptimeSeconds = 1_198_800
        router.loadAverages = [0.18, 0.24, 0.21]
        router.memoryUsedBytes = 418_759_311
        router.memoryTotalBytes = 1_073_741_824
        router.memoryHistory = [0.36, 0.36, 0.37, 0.37, 0.38, 0.38, 0.39, 0.40, 0.39, 0.39]
        router.temperatureCelsius = .value(52)

        var internet = InternetStatus()
        internet.reachability = .connected
        internet.publicAddress = "203.0.113.24"
        internet.gateway = "192.0.2.1"
        internet.gatewayLatencyMilliseconds = 2.6
        internet.dnsServers = ["192.0.2.53", "192.0.2.54"]

        var adGuard = AdGuardStatus()
        adGuard.reachability = .connected
        adGuard.version = "0.107.65"
        adGuard.protection = .paused(until: date.addingTimeInterval(1800))
        adGuard.queriesToday = 45_852
        adGuard.blockedToday = 6_438
        return OverviewSnapshot(router: router, internet: internet, adGuard: adGuard, observedAt: date)
    }
}

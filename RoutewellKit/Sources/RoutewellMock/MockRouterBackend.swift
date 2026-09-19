import Foundation
import RoutewellKit

/// Synthetic data only. This backend has no transport or credential dependencies.
public actor MockRouterBackend: RouterBackend {
    public enum Scenario: String, CaseIterable, Sendable {
        case healthy, partial, offline, stale, slow
    }
    private var scenario: Scenario
    public nonisolated let hostname: String

    public init(scenario: Scenario = .healthy, hostname: String = "flint-demo") {
        self.scenario = scenario
        self.hostname = hostname
    }

    public func overview() async throws -> OverviewRefreshResult {
        try Task.checkCancellation()
        let scenario = scenario
        if scenario == .slow { try await Task.sleep(for: .seconds(5)) }
        return Self.result(scenario: scenario, hostname: hostname, at: .now)
    }

    public func setScenario(_ scenario: Scenario) { self.scenario = scenario }

    public static func result(
        scenario: Scenario = .healthy,
        hostname: String = "flint-demo",
        at date: Date
    ) -> OverviewRefreshResult {
        var snapshot = snapshot(at: date)
        snapshot.router.hostname = hostname
        let clients: AreaRefreshResult<ClientStatus> = switch scenario {
        case .partial: .failure(.timeout, attemptedAt: date)
        case .stale: .success(snapshot.clients, observedAt: date.addingTimeInterval(-65 * 60), source: .mock)
        case .offline: .failure(.network, attemptedAt: date)
        case .healthy, .slow: .success(snapshot.clients, observedAt: date, source: .mock)
        }
        if scenario == .offline {
            return OverviewRefreshResult(
                router: .failure(.network, attemptedAt: date),
                internet: .failure(.network, attemptedAt: date),
                adGuard: .failure(.network, attemptedAt: date),
                clients: clients
            )
        }
        return OverviewRefreshResult(
            router: .success(snapshot.router, observedAt: date, source: .mock),
            internet: .success(snapshot.internet, observedAt: date, source: .mock),
            adGuard: .success(snapshot.adGuard, observedAt: date, source: .mock),
            clients: clients
        )
    }

    public static func snapshot(at date: Date) -> OverviewSnapshot {
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

        var clients = ClientStatus()
        clients.activeCount = .value(18)
        return OverviewSnapshot(router: router, internet: internet, adGuard: adGuard,
                                clients: clients, observedAt: date)
    }
}

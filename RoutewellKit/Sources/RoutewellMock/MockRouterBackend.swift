import Foundation
import RoutewellKit

/// Synthetic data only. This backend has no transport or credential dependencies.
public actor MockRouterBackend: RouterBackend {
    public enum Scenario: String, CaseIterable, Sendable {
        case healthy, partial, offline, stale, slow
    }

    /// Which outcome the mock Protection service produces on its next
    /// `setProtection` call. Selectable in DEBUG builds via a picker so the
    /// app's outcome-text mapping can be exercised without a live router.
    public enum ProtectionBehavior: String, CaseIterable, Sendable {
        case succeeds
        case mismatchThenRecovers
        case lostResponseThenApplied
        case externalEdit
        case unauthorized
    }

    private var scenario: Scenario
    private var protectionBehavior: ProtectionBehavior = .succeeds
    /// Overrides `adGuard.protection` in the next `overview()` result once a
    /// mock mutation has run; `nil` means "use the scenario's own value."
    private var protectionOverride: ProtectionState?
    /// Serializes `runProtectionMutation` the same way the live path
    /// serializes through one `MutationGate` per backend: without it, an
    /// actor's reentrancy across `await Task.sleep` lets a second concurrent
    /// mutation read `protectionBehavior`/`protectionOverride` mid-update.
    private let protectionGate = MutationGate()
    public nonisolated let hostname: String

    public init(scenario: Scenario = .healthy, hostname: String = "flint-demo") {
        self.scenario = scenario
        self.hostname = hostname
    }

    public func overview() async throws -> OverviewRefreshResult {
        try Task.checkCancellation()
        let scenario = scenario
        if scenario == .slow { try await Task.sleep(for: .seconds(5)) }
        var result = Self.result(scenario: scenario, hostname: hostname, at: .now)
        if let protectionOverride, case .success(var adGuard, let observedAt, let source) = result.adGuard {
            adGuard.protection = protectionOverride
            result.adGuard = .success(adGuard, observedAt: observedAt, source: source)
        }
        return result
    }

    public func setScenario(_ scenario: Scenario) { self.scenario = scenario }

    public func setProtectionBehavior(_ behavior: ProtectionBehavior) {
        protectionBehavior = behavior
    }

    // MARK: - ProtectionService

    public nonisolated var protection: (any ProtectionService)? {
        MockProtectionService(backend: self)
    }

    /// Runs the currently selected `ProtectionBehavior` against `intent`,
    /// updating `protectionOverride` so the next `overview()` reflects the
    /// change, and returns the matching `MutationOutcome`. Never sleeps more
    /// than 100 ms. Serialized through `protectionGate`: a second concurrent
    /// call waits for the first to finish reading and writing shared state
    /// before it starts its own.
    func runProtectionMutation(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState> {
        let startedAt = Date()
        if let rejection = intent.validate() {
            return MutationReport(outcome: .rejected(rejection), dispatched: false, startedAt: startedAt, finishedAt: startedAt, failure: nil)
        }

        let token: MutationGateToken
        do {
            token = try await protectionGate.acquire()
        } catch {
            return MutationReport(
                outcome: .rejected(.preconditionFailed("Cancelled before dispatch")),
                dispatched: false, startedAt: startedAt, finishedAt: Date(), failure: nil
            )
        }
        let report = await performProtectionMutation(intent, allowRecovery: allowRecovery, startedAt: startedAt)
        await protectionGate.release(token)
        return report
    }

    private func performProtectionMutation(
        _ intent: ProtectionIntent, allowRecovery: Bool, startedAt: Date
    ) async -> MutationReport<ProtectionState> {
        try? await Task.sleep(for: .milliseconds(50))

        let intended = Self.intendedState(for: intent)
        let before = protectionOverride ?? .enabled

        switch protectionBehavior {
        case .succeeds:
            protectionOverride = intended
            return MutationReport(outcome: .verifiedSuccess(intended), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)

        case .mismatchThenRecovers:
            guard allowRecovery else {
                return MutationReport(outcome: .verifiedMismatch(expected: intended, actual: before), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)
            }
            protectionOverride = before
            return MutationReport(outcome: .verifiedRecovery(restored: before), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)

        case .lostResponseThenApplied:
            protectionOverride = intended
            return MutationReport(outcome: .verifiedSuccess(intended), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)

        case .externalEdit:
            let actual: ProtectionState = .paused(until: Date().addingTimeInterval(300))
            protectionOverride = actual
            return MutationReport(outcome: .conflictingExternalEdit(actual: actual), dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: nil)

        case .unauthorized:
            // Matches the live path's semantics: a 401/403 reaches the
            // server and is a definitive rejection, not an ambiguous one,
            // but a request was still sent — so `dispatched` is `true`.
            return MutationReport(
                outcome: .rejected(.preconditionFailed("AdGuard Home refused the login")),
                dispatched: true, startedAt: startedAt, finishedAt: Date(), failure: .authentication
            )
        }
    }

    private static func intendedState(for intent: ProtectionIntent) -> ProtectionState {
        switch intent {
        case .enable: return .enabled
        case .disable: return .disabled
        case .pause(let duration):
            let components = duration.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            return .paused(until: Date().addingTimeInterval(seconds))
        }
    }

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

private struct MockProtectionService: ProtectionService {
    let backend: MockRouterBackend

    func setProtection(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState> {
        await backend.runProtectionMutation(intent, allowRecovery: allowRecovery)
    }
}

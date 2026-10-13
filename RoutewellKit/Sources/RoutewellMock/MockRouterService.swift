import Foundation
import RoutewellKit

/// Synthetic Router screen data: SQM available or not, and the three firmware check outcomes. "Never checked" is the
/// state before the first Check for Updates.
public actor MockRouterService: RouterService {
    public enum SQMBehavior: String, CaseIterable, Sendable {
        /// Native SQM answers, switched off with no limits (as on 4.9.1).
        case available
        /// Native SQM is enabled with limits.
        case enabled
        /// `-32601`: every SQM control is disabled.
        case unavailable
        /// A timeout: capability stays unknown.
        case failing
    }

    public enum FirmwareBehavior: String, CaseIterable, Sendable {
        case updateAvailable, upToDate, unableToCheck
    }

    private var sqmBehavior: SQMBehavior = .unavailable
    private var firmwareBehavior: FirmwareBehavior = .unableToCheck

    public init() {}

    public func setSQMBehavior(_ value: SQMBehavior) { sqmBehavior = value }
    public func setFirmwareBehavior(_ value: FirmwareBehavior) { firmwareBehavior = value }

    public func probe() async -> Capability {
        Capability(.supported, evidence: .mockScenario("router"), observedAt: .now)
    }

    public func details() async throws -> RouterDetailsResult {
        try Task.checkCancellation()
        let now = Date()
                switch sqmBehavior {
        case .available:
            return RouterDetailsResult(
                sqm: .success(SQMConfiguration(enabled: .value(false), queueDiscipline: "cake"), observedAt: now, source: .mock),
                sqmCapability: Capability(.supported, evidence: .mockScenario("sqm available"), observedAt: now))
        case .enabled:
            return RouterDetailsResult(
                sqm: .success(SQMConfiguration(enabled: .value(true), queueDiscipline: "cake", upload: "40", download: "450"), observedAt: now, source: .mock),
                sqmCapability: Capability(.supported, evidence: .mockScenario("sqm enabled"), observedAt: now))
        case .unavailable:
            return RouterDetailsResult(sqm: .failure(.unavailable, attemptedAt: now),
                sqmCapability: Capability(.unsupported, evidence: .methodNotFound(method: "sqm.get_config"), observedAt: now))
        case .failing:
            return RouterDetailsResult(sqm: .failure(.timeout, attemptedAt: now), sqmCapability: Capability())
        }
    }

    public func checkFirmware() async throws -> FirmwareCheck {
        try await Task.sleep(for: .milliseconds(400))
        let now = Date()
        switch firmwareBehavior {
        case .updateAvailable:
            return FirmwareCheck(current: .value("4.9.1"), latest: .value("4.9.2"), status: .updateAvailable,
                                 releaseNotes: "Sample release notes.\n• Improves Wi-Fi stability.\n• Updates AdGuard Home.", checkedAt: now)
        case .upToDate:
            return FirmwareCheck(current: .value("4.9.1"), latest: .value("4.9.1"), status: .upToDate, checkedAt: now)
        case .unableToCheck:
            return FirmwareCheck(current: .value("4.9.1"), status: .unableToCheck(.failed(.network)), checkedAt: now)
        }
    }
}

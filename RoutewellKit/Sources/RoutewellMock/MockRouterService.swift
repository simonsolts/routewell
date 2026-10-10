import Foundation
import RoutewellKit

/// Synthetic Router screen data: three populated Wi-Fi bands, SQM available
/// or not, and the three firmware check outcomes. "Never checked" is the
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
        let wireless: AreaRefreshResult<WirelessStatus> = .success(Self.wireless, observedAt: now, source: .mock)
        switch sqmBehavior {
        case .available:
            return RouterDetailsResult(wireless: wireless,
                sqm: .success(SQMConfiguration(enabled: .value(false), queueDiscipline: "cake"), observedAt: now, source: .mock),
                sqmCapability: Capability(.supported, evidence: .mockScenario("sqm available"), observedAt: now))
        case .enabled:
            return RouterDetailsResult(wireless: wireless,
                sqm: .success(SQMConfiguration(enabled: .value(true), queueDiscipline: "cake", upload: "40", download: "450"), observedAt: now, source: .mock),
                sqmCapability: Capability(.supported, evidence: .mockScenario("sqm enabled"), observedAt: now))
        case .unavailable:
            return RouterDetailsResult(wireless: wireless, sqm: .failure(.unavailable, attemptedAt: now),
                sqmCapability: Capability(.unsupported, evidence: .methodNotFound(method: "sqm.get_config"), observedAt: now))
        case .failing:
            return RouterDetailsResult(wireless: wireless, sqm: .failure(.timeout, attemptedAt: now), sqmCapability: Capability())
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

    /// The three radios and nine SSIDs of the mockup tables, with neutral names.
    public static let wireless = WirelessStatus(radios: [
        WirelessRadio(device: "MT7990_1_1", band: .ghz2_4, configuredChannel: 0, currentChannel: 9, htmode: "EHT40", networks: [
            WirelessNetwork(interface: "rai0", ssid: "Flint Home", enabled: .value(true)),
            WirelessNetwork(interface: "rai1", ssid: "GL-BE14000-2bd-Guest", enabled: .value(false), guest: true),
            WirelessNetwork(interface: "rai2", ssid: "GL-BE14000-2bd-IoT", enabled: .value(false), iot: true),
            WirelessNetwork(interface: "rai3", ssid: "GL-BE14000-2bd-MLO", enabled: .value(false)),
        ]),
        WirelessRadio(device: "MT7990_1_2", band: .ghz5, configuredChannel: 0, currentChannel: 44, htmode: "EHT80", networks: [
            WirelessNetwork(interface: "ra0", ssid: "Flint Home", enabled: .value(true)),
            WirelessNetwork(interface: "ra1", ssid: "GL-BE14000-5-Guest", enabled: .value(false), guest: true),
            WirelessNetwork(interface: "ra2", ssid: "GL-BE14000-5-IoT", enabled: .value(false), iot: true),
        ]),
        WirelessRadio(device: "MT7990_1_3", band: .ghz6, configuredChannel: 0, currentChannel: 37, htmode: "EHT160", networks: [
            WirelessNetwork(interface: "rax0", ssid: "Flint Home Fast", enabled: .value(true)),
            WirelessNetwork(interface: "rax1", ssid: "GL-BE14000-6-Guest", enabled: .value(false), guest: true),
        ]),
    ])
}

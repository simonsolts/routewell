import Foundation
import RoutewellKit

/// The AdGuard Home screen's mock scenarios (chunk 16).
public enum MockAdGuardScenario: String, CaseIterable, Sendable {
    case off
    case running
    case runningWithoutDNS
    case cached
    case unreachable
    case turnOnFails

    public var title: String {
        switch self {
        case .off: "Off, no saved copy"
        case .running: "Running"
        case .runningWithoutDNS: "Running, not handling DNS"
        case .cached: "Off, saved copy"
        case .unreachable: "On, not answering"
        case .turnOnFails: "Turn On fails"
        }
    }

    /// The saved copy this scenario starts with. Neutral sample values.
    public func seedArchive(now: Date) -> AdGuardArchive? {
        switch self {
        case .cached, .unreachable:
            let savedAt = now.addingTimeInterval(-26 * 60 * 60)
            var status = AdGuardStatusResponse(version: MockAdGuardTransport.version, running: true, protectionEnabled: true,
                                               protectionDisabledDurationMilliseconds: 0)
            status.startTime = savedAt.addingTimeInterval(-3 * 24 * 60 * 60)
            return AdGuardArchive(status: .init(savedAt: savedAt, value: status),
                                  config: .init(savedAt: savedAt, value: AdGuardRouterConfig(enabled: true, handlesDNS: true)))
        case .off, .running, .runningWithoutDNS, .turnOnFails:
            return nil
        }
    }
}

/// A router and AdGuard Home in memory. Writes go through the real
/// `AdGuardServiceExecutor`, so the mock shows the same outcomes as live.
/// After it is switched on, AdGuard Home answers only after a short start.
public actor MockAdGuardTransport: AdGuardServiceTransport {
    public static let version = "0.107.65"
    static let startDelay: TimeInterval = 1.5

    private var config = AdGuardRouterConfig(enabled: true, handlesDNS: true)
    private var answers = true
    private var refusesTurnOn = false
    private var answersAfter: Date?
    private var startTime = Date().addingTimeInterval(-5 * 24 * 60 * 60)

    public init() {}

    public func setScenario(_ scenario: MockAdGuardScenario) {
        answersAfter = nil
        refusesTurnOn = scenario == .turnOnFails
        answers = scenario != .unreachable
        switch scenario {
        case .off, .cached, .turnOnFails: config = AdGuardRouterConfig(enabled: false, handlesDNS: true)
        case .running, .unreachable: config = AdGuardRouterConfig(enabled: true, handlesDNS: true)
        case .runningWithoutDNS: config = AdGuardRouterConfig(enabled: true, handlesDNS: false)
        }
    }

    public func readConfig() async throws -> AdGuardRouterConfig { config }

    /// The router's own refusal, as GL.iNet documents it: `err_code` 1,
    /// "Other DNS not closed".
    public func writeConfig(enabled: Bool, handlesDNS: Bool?) async throws -> Int? {
        try? await Task.sleep(for: .milliseconds(150))
        if enabled, refusesTurnOn { return 1 }
        if enabled, config.enabled != true {
            answersAfter = Date().addingTimeInterval(Self.startDelay)
            startTime = Date()
        }
        config.enabled = enabled
        if let handlesDNS { config.handlesDNS = handlesDNS }
        return nil
    }

    public func readStatus() async throws -> AdGuardStatusResponse {
        guard let status = currentStatus() else { throw AdGuardClientError.transport(.timedOut) }
        return status
    }

    /// What `control/status` answers now, or `nil` when it does not answer.
    func currentStatus(now: Date = Date()) -> AdGuardStatusResponse? {
        guard config.enabled == true, answers, answersAfter.map({ now >= $0 }) ?? true else { return nil }
        var status = AdGuardStatusResponse(version: Self.version, running: true, protectionEnabled: true,
                                           protectionDisabledDurationMilliseconds: 0)
        status.dnsPort = 3053
        status.startTime = startTime
        return status
    }

    /// The reading `overview()` reports.
    func reading(at date: Date) -> AdGuardServiceReading {
        var reading = AdGuardServiceReading(config: .success(config), observedAt: date)
        if config.enabled == true {
            reading.answer = currentStatus(now: date).map { .answered($0) } ?? .failed(answers ? .timeout : .authentication)
        }
        return reading
    }
}

extension AdGuardServiceVerifyPolicy {
    /// Short waits, so the mock's start delay shows the spinner briefly.
    static var mock: AdGuardServiceVerifyPolicy {
        var policy = AdGuardServiceVerifyPolicy()
        policy.configDeadline = .seconds(2)
        policy.answerDeadline = .seconds(4)
        policy.pollInterval = .milliseconds(250)
        return policy
    }
}

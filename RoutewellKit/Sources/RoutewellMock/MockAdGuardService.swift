import Foundation
import RoutewellKit

/// The AdGuard Home screen's mock scenarios.
public enum MockAdGuardScenario: String, CaseIterable, Sendable {
    case off
    case running
    case paused
    case runningWithoutDNS
    case cached
    case unreachable
    case turnOnFails
    case switchFails
    case addListFails
    case refreshPartial
    case rulesConflict
    case slowUpstream
    case dnsApplyMismatch
    case upstreamTestFails
    case updateAvailable
    case updateCheckOff
    case restoreFails

    public var title: String {
        switch self {
        case .off: "Off, no saved copy"
        case .running: "Running"
        case .paused: "Running, protection paused"
        case .runningWithoutDNS: "Running, not handling DNS"
        case .cached: "Off, saved copy"
        case .unreachable: "On, not answering"
        case .turnOnFails: "Turn On fails"
        case .switchFails: "Running, Block adult content fails"
        case .addListFails: "Running, adding a list fails"
        case .refreshPartial: "Running, Update Now updates one list"
        case .rulesConflict: "Running, rules change elsewhere"
        case .slowUpstream: "Running, one upstream is slow"
        case .dnsApplyMismatch: "Running, DNS Apply keeps the old cache size"
        case .upstreamTestFails: "Running, Test Upstreams finds a bad server"
        case .updateAvailable: "Running, an update is available"
        case .updateCheckOff: "Running, update check not available"
        case .restoreFails: "Running, Restore fails and rolls back"
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
            let overview = MockAdGuardTransport.overview(range: .day, now: savedAt, options: MockAdGuardTransport.defaultOptions)
            return AdGuardArchive(status: .init(savedAt: savedAt, value: status),
                                  config: .init(savedAt: savedAt, value: AdGuardRouterConfig(enabled: true, handlesDNS: true)),
                                  stats: (try? overview.stats.get()).map { [AdGuardStatsRange.day.rawValue: .init(savedAt: savedAt, value: $0)] },
                                  statsConfig: (try? overview.statsConfig.get()).map { .init(savedAt: savedAt, value: $0) },
                                  protection: (try? overview.protection.get()).map { .init(savedAt: savedAt, value: $0) },
                                  filtering: (try? overview.filtering.get()).map { .init(savedAt: savedAt, value: $0) },
                                  dns: .init(savedAt: savedAt, value: MockAdGuardTransport.defaultDNS),
                                  instance: .init(savedAt: savedAt, value: AdGuardInstanceInfo(
                                      version: AdGuardVersionCheck(disabled: false),
                                      queryLog: AdGuardQueryLogConfig(enabled: true, intervalMilliseconds: MockAdGuardTransport.queryLogRetention))))
        case .off, .running, .paused, .runningWithoutDNS, .turnOnFails, .switchFails, .addListFails, .refreshPartial, .rulesConflict,
             .slowUpstream, .dnsApplyMismatch, .upstreamTestFails, .updateAvailable, .updateCheckOff, .restoreFails:
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
    // Settings inside AdGuard Home.
    var protectionEnabled = true
    /// A timed pause ends on its own, as in AdGuard Home.
    var pausedUntil: Date?
    var options = MockAdGuardTransport.defaultOptions
    /// "Filter requests".
    var filteringEnabled = true
    /// Custom rules, changed by Block and Unblock Domain.
    public internal(set) var userRules: [String] = MockAdGuardTransport.defaultRules
    static let defaultRules = ["! Example custom rules", "||ads.example.com^", "@@||cdn.example.net^", ""]
    var filterLists = MockAdGuardTransport.filtering(enabled: true)
    /// When each added list has its rules ("Downloading…" until then).
    var downloads: [String: Date] = [:]
    static let downloadDelay: TimeInterval = 2
    var failsListAdd = false
    var refreshesPartly = false
    var changesRulesElsewhere = false
    var dns = MockAdGuardTransport.defaultDNS
    var slowUpstream = false
    /// A `dns_config` field AdGuard Home accepts but does not change.
    var ignoredDNSField: String?
    var failsUpstreamTest = false
    // The Instance tab.
    var statsRetention = MockAdGuardTransport.retentionMilliseconds
    var queryLogRetention = MockAdGuardTransport.queryLogRetention
    /// `config.yaml` on the router; `nil` builds it from the settings.
    var configFile: Data?
    /// A restored file AdGuard Home cannot start with ("Restore fails").
    var failsRestore = false
    var brokenConfig = false
    /// How often `version.json` was read, for tests.
    public internal(set) var versionChecks = 0
    /// Safe Search's engine flags, sent back unchanged by the switch.
    var safeSearchEngines: [String: JSONValue] = ["bing": .bool(true), "duckduckgo": .bool(true), "ecosia": .bool(true),
        "google": .bool(true), "pixabay": .bool(true), "yandex": .bool(true), "youtube": .bool(true)]
    /// A switch that accepts writes but never changes (the "switch fails" scenario).
    var stuckFeature: AdGuardFeature?
    /// Every write AdGuard Home received, for tests.
    public internal(set) var writes: [AdGuardWrite] = []

    public private(set) var scenario: MockAdGuardScenario = .running

    public init() {}

    public func setScenario(_ scenario: MockAdGuardScenario) {
        self.scenario = scenario
        answersAfter = nil
        refusesTurnOn = scenario == .turnOnFails
        answers = scenario != .unreachable
        protectionEnabled = scenario != .paused
        pausedUntil = scenario == .paused ? Date().addingTimeInterval(10 * 60) : nil
        options = Self.defaultOptions
        filteringEnabled = true
        stuckFeature = scenario == .switchFails ? .parental : nil
        userRules = Self.defaultRules
        filterLists = Self.filtering(enabled: true)
        downloads = [:]
        failsListAdd = scenario == .addListFails
        refreshesPartly = scenario == .refreshPartial
        changesRulesElsewhere = scenario == .rulesConflict
        dns = Self.defaultDNS
        slowUpstream = scenario == .slowUpstream
        ignoredDNSField = scenario == .dnsApplyMismatch ? "cache_size" : nil
        failsUpstreamTest = scenario == .upstreamTestFails
        statsRetention = Self.retentionMilliseconds
        queryLogRetention = Self.queryLogRetention
        configFile = nil
        failsRestore = scenario == .restoreFails
        brokenConfig = false
        switch scenario {
        case .off, .cached, .turnOnFails: config = AdGuardRouterConfig(enabled: false, handlesDNS: true)
        case .running, .paused, .unreachable, .switchFails, .addListFails, .refreshPartial, .rulesConflict,
             .slowUpstream, .dnsApplyMismatch, .upstreamTestFails, .updateAvailable, .updateCheckOff, .restoreFails:
            config = AdGuardRouterConfig(enabled: true, handlesDNS: true)
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
        guard config.enabled == true, answers, !brokenConfig, answersAfter.map({ now >= $0 }) ?? true else { return nil }
        if let until = pausedUntil, until <= now {
            // The pause ended: AdGuard Home turns protection back on.
            pausedUntil = nil
            protectionEnabled = true
        }
        let remaining = pausedUntil.map { Int(($0.timeIntervalSince(now) * 1000).rounded()) } ?? 0
        var status = AdGuardStatusResponse(version: Self.version, running: true, protectionEnabled: protectionEnabled,
                                           protectionDisabledDurationMilliseconds: remaining)
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

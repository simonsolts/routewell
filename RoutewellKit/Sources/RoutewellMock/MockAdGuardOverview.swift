import Foundation
import RoutewellKit

/// Chunk 17: protection and the switches run through the real
/// `AdGuardSettingExecutor` against the in-memory AdGuard Home, and the
/// Overview reads its stats. Every name and address is a neutral sample.
extension MockAdGuardTransport: AdGuardSettingTransport, AdGuardOverviewService {
    static let defaultOptions = ProtectionOptions(safeBrowsing: true, parental: false, safeSearch: false)
    /// Seven days, so "Last 30 days" shows as not available.
    static let retentionMilliseconds = 7 * 86_400_000

    public func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue {
        guard currentStatus() != nil else { throw AdGuardClientError.transport(.timedOut) }
        var object: [String: JSONValue] = ["enabled": .bool(options[feature] ?? false)]
        if feature == .safeSearch { object.merge(safeSearchEngines) { $1 } }
        if feature == .parental { object["sensitivity"] = .number(13) }
        return .object(object)
    }

    public func write(_ write: AdGuardWrite) async throws {
        guard currentStatus() != nil else { throw AdGuardClientError.transport(.timedOut) }
        try? await Task.sleep(for: .milliseconds(150))
        writes.append(write)
        switch write {
        case .protection(let enabled, let duration):
            protectionEnabled = enabled
            pausedUntil = !enabled && duration > 0 ? Date().addingTimeInterval(TimeInterval(duration) / 1000) : nil
        case .feature(let feature, let enabled):
            if feature != stuckFeature { options[feature] = enabled }
        case .safeSearchSettings(let settings):
            guard stuckFeature != .safeSearch else { return }
            options.safeSearch = settings["enabled"]?.bool
            for (key, value) in settings.object ?? [:] where key != "enabled" { safeSearchEngines[key] = value }
        }
    }

    public func overview(range: AdGuardStatsRange) async throws -> AdGuardOverviewReading {
        try Task.checkCancellation()
        let now = Date()
        guard currentStatus(now: now) != nil else {
            return AdGuardOverviewReading(range: range, stats: .failure(.timeout), statsConfig: .failure(.timeout),
                                          protection: .failure(.timeout), filtering: .failure(.timeout), observedAt: now)
        }
        return Self.overview(range: range, now: now, options: options)
    }

    /// The Overview a running mock shows at `now`. A range longer than the
    /// retention answers 400, as AdGuard Home does.
    static func overview(range: AdGuardStatsRange, now: Date, options: ProtectionOptions) -> AdGuardOverviewReading {
        let available = range.isAvailable(retentionMilliseconds: retentionMilliseconds)
        return AdGuardOverviewReading(
            range: range,
            stats: available ? .success(stats(range: range)) : .failure(.malformedResponse),
            statsConfig: .success(AdGuardStatsConfig(enabled: true, intervalMilliseconds: retentionMilliseconds)),
            protection: .success(options),
            filtering: .success(filtering),
            observedAt: now
        )
    }

    /// A daily curve: quiet at night, busy in the evening.
    static func stats(range: AdGuardStatsRange) -> AdGuardStats {
        let shape = range.expectedShape
        var stats = AdGuardStats()
        stats.timeUnits = shape.units
        stats.queriesSeries = (0..<shape.count).map { index in
            if shape.units == .hours {
                let hour = Double((index + 12) % 24)
                return Int(900 + 1_100 * (0.5 + 0.5 * sin((hour - 9) / 24 * 2 * .pi)))
            }
            return 31_000 + (index * 7_919) % 9_000
        }
        stats.blockedSeries = stats.queriesSeries.enumerated().map { index, value in value * (12 + index % 5) / 100 }
        let queries = stats.queriesSeries.reduce(0, +)
        let blocked = stats.blockedSeries.reduce(0, +)
        stats.queries = queries
        stats.blockedFiltering = blocked
        stats.replacedSafeBrowsing = shape.units == .hours ? 3 : 41
        stats.replacedParental = 0
        stats.replacedSafeSearch = 0
        stats.averageProcessingSeconds = 0.0021
        let domains = ["example.com", "cdn.example.net", "api.example.org", "time.example.com", "updates.example.net", "mail.example.org"]
        let blockedDomains = ["ads.example.com", "metrics.example.net", "tracker.example.org", "telemetry.example.com", "pixel.example.net"]
        stats.topQueried = domains.enumerated().map { .init(name: $1, count: queries / (12 + $0 * 4)) }
        stats.topBlocked = blockedDomains.enumerated().map { .init(name: $1, count: blocked / (3 + $0 * 3)) }
        // The mock clients' addresses, so names resolve; .177 has no name.
        let clients = ["192.168.8.192", "192.168.8.177", "192.168.8.199", "192.168.8.105", "192.168.8.20", "192.168.8.228", "192.168.8.150"]
        stats.topClients = clients.enumerated().map { .init(name: $1, count: queries / (4 + $0 * 2)) }
        stats.topUpstreams = [.init(name: "https://dns.example.net/dns-query", count: queries / 2)]
        return stats
    }

    static var filtering: AdGuardFilteringStatus {
        var status = AdGuardFilteringStatus()
        status.enabled = true
        status.intervalHours = 24
        status.blocklists = [
            AdGuardFilterList(id: 1, name: "Example base list", url: "https://lists.example.com/base.txt", enabled: true, rulesCount: 183_412),
            AdGuardFilterList(id: 2, name: "Example malware list", url: "https://lists.example.com/malware.txt", enabled: true, rulesCount: 164_790),
            AdGuardFilterList(id: 3, name: "Example tracking list", url: "https://lists.example.org/tracking.txt", enabled: true, rulesCount: 243_701),
            AdGuardFilterList(id: 4, name: "Example social list", url: "https://lists.example.org/social.txt", enabled: false, rulesCount: 0),
        ]
        return status
    }
}

extension AdGuardSettingVerifyPolicy {
    /// Short waits for the mock.
    static var mock: AdGuardSettingVerifyPolicy {
        var policy = AdGuardSettingVerifyPolicy()
        policy.deadline = .seconds(1)
        policy.pollInterval = .milliseconds(200)
        return policy
    }
}

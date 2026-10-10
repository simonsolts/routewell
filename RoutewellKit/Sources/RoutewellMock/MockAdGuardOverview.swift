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

    public func readFiltering() async throws -> AdGuardFilteringStatus {
        guard currentStatus() != nil else { throw AdGuardClientError.transport(.timedOut) }
        return currentFiltering()
    }

    public func readUserRules() async throws -> [String] {
        guard currentStatus() != nil else { throw AdGuardClientError.transport(.timedOut) }
        if changesRulesElsewhere {
            // "Rules conflict": another edit lands just before Save.
            changesRulesElsewhere = false
            userRules.insert("||changed-elsewhere.example^", at: 0)
        }
        return userRules
    }

    public func refreshLists(_ kind: FilterListKind) async throws -> Int? {
        guard currentStatus() != nil else { throw AdGuardClientError.transport(.timedOut) }
        try? await Task.sleep(for: .milliseconds(600))
        writes.append(.refreshLists(whitelist: kind.isAllowlist))
        let now = Self.timestamp(Date())
        var updated = 0
        func refresh(_ lists: inout [AdGuardFilterList]) {
            for index in lists.indices where lists[index].enabled == true {
                // "Refresh partial": only the first list on is updated.
                if refreshesPartly, updated == 1 { break }
                lists[index].lastUpdated = now
                updated += 1
            }
        }
        if kind == .blocklist { refresh(&filterLists.blocklists) } else { refresh(&filterLists.allowlists) }
        return updated
    }

    /// The lists as AdGuard Home reports them now: a list added less than
    /// `downloadDelay` ago has no rules yet.
    public func currentFiltering(now: Date = Date()) -> AdGuardFilteringStatus {
        var status = filterLists
        status.enabled = filteringEnabled
        status.userRules = userRules
        func settle(_ lists: inout [AdGuardFilterList]) {
            for index in lists.indices {
                guard let url = lists[index].url, let ready = downloads[url] else { continue }
                if now >= ready {
                    lists[index].rulesCount = 48_000 + (url.count * 1_337) % 90_000
                    lists[index].lastUpdated = Self.timestamp(ready)
                } else {
                    lists[index].rulesCount = 0
                    lists[index].lastUpdated = nil
                }
            }
        }
        settle(&status.blocklists)
        settle(&status.allowlists)
        return status
    }

    static func timestamp(_ date: Date) -> String { date.formatted(.iso8601) }

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
        case .filteringConfig(let enabled, _):
            filteringEnabled = enabled
        case .setRules(let rules):
            userRules = rules
        case .addList(let name, let url, let whitelist):
            if failsListAdd { throw AdGuardClientError.httpStatus(400) }
            let list = AdGuardFilterList(id: Int(Date().timeIntervalSince1970), name: name, url: url, enabled: true, rulesCount: 0)
            downloads[url] = Date().addingTimeInterval(Self.downloadDelay)
            if whitelist { filterLists.allowlists.append(list) } else { filterLists.blocklists.append(list) }
        case .setList(let url, let whitelist, let name, let enabled):
            func update(_ lists: inout [AdGuardFilterList]) {
                for index in lists.indices where lists[index].url == url {
                    lists[index].name = name
                    lists[index].enabled = enabled
                    if enabled, lists[index].rulesCount == 0 { downloads[url] = Date().addingTimeInterval(Self.downloadDelay) }
                }
            }
            if whitelist { update(&filterLists.allowlists) } else { update(&filterLists.blocklists) }
        case .removeList(let url, let whitelist):
            if whitelist { filterLists.allowlists.removeAll { $0.url == url } } else { filterLists.blocklists.removeAll { $0.url == url } }
        case .refreshLists:
            break
        }
        if case .filteringConfig(_, let hours) = write { filterLists.intervalHours = hours }
    }

    public func overview(range: AdGuardStatsRange) async throws -> AdGuardOverviewReading {
        try Task.checkCancellation()
        let now = Date()
        guard currentStatus(now: now) != nil else {
            return AdGuardOverviewReading(range: range, stats: .failure(.timeout), statsConfig: .failure(.timeout),
                                          protection: .failure(.timeout), filtering: .failure(.timeout), observedAt: now)
        }
        var reading = Self.overview(range: range, now: now, options: options, filteringEnabled: filteringEnabled)
        reading.filtering = .success(currentFiltering(now: now))
        return reading
    }

    /// The Overview a running mock shows at `now`. A range longer than the
    /// retention is not read, as in the live service.
    static func overview(range: AdGuardStatsRange, now: Date, options: ProtectionOptions,
                         filteringEnabled: Bool = true) -> AdGuardOverviewReading {
        let available = range.isAvailable(retentionMilliseconds: retentionMilliseconds)
        return AdGuardOverviewReading(
            range: range,
            stats: available ? .success(stats(range: range)) : .failure(.unavailable),
            statsConfig: .success(AdGuardStatsConfig(enabled: true, intervalMilliseconds: retentionMilliseconds)),
            protection: .success(options),
            filtering: .success(filtering(enabled: filteringEnabled)),
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

    static func filtering(enabled: Bool) -> AdGuardFilteringStatus {
        var status = AdGuardFilteringStatus()
        status.enabled = enabled
        status.intervalHours = 24
        status.userRules = defaultRules
        let updated = timestamp(Calendar.current.startOfDay(for: Date()).addingTimeInterval(6 * 60 * 60))
        status.allowlists = [
            AdGuardFilterList(id: 11, name: "Example allowlist", url: "https://lists.example.net/allow.txt", enabled: true,
                              rulesCount: 214, lastUpdated: updated),
        ]
        status.blocklists = [
            AdGuardFilterList(id: 1, name: "Example base list", url: "https://lists.example.com/base.txt", enabled: true,
                              rulesCount: 183_412, lastUpdated: updated),
            AdGuardFilterList(id: 2, name: "Example malware list", url: "https://lists.example.com/malware.txt", enabled: true,
                              rulesCount: 164_790, lastUpdated: updated),
            AdGuardFilterList(id: 3, name: "Example tracking list", url: "https://lists.example.org/tracking.txt", enabled: true,
                              rulesCount: 243_701, lastUpdated: updated),
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

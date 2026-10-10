import Foundation
import RoutewellKit

/// Protection and the switches run through the real
/// `AdGuardSettingExecutor` against the in-memory AdGuard Home, and the
/// Overview reads its stats. Every name and address is a neutral sample.
extension MockAdGuardTransport: AdGuardSettingTransport, AdGuardOverviewService {
    static let defaultOptions = ProtectionOptions(safeBrowsing: true, parental: false, safeSearch: false)
    /// Seven days, so "Last 30 days" shows as not available.
    static let retentionMilliseconds = 7 * 86_400_000
    static let queryLogRetention = 90 * 86_400_000
    static let newVersion = "0.107.70"

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

    public func versionCheck() async throws -> Result<AdGuardVersionCheck, RefreshFailureCategory> {
        try Task.checkCancellation()
        guard currentStatus() != nil else { return .failure(.timeout) }
        versionChecks += 1
        return .success(currentVersionCheck())
    }

    func currentVersionCheck() -> AdGuardVersionCheck {
        switch scenario {
        case .updateAvailable: AdGuardVersionCheck(disabled: false, newVersion: "v\(Self.newVersion)",
                                                   announcement: "AdGuard Home v\(Self.newVersion) is now available!")
        case .updateCheckOff: AdGuardVersionCheck(disabled: true)
        default: AdGuardVersionCheck(disabled: false)
        }
    }

    public func readDataConfig(_ kind: AdGuardDataKind) async throws -> JSONValue {
        guard currentStatus() != nil else { throw AdGuardClientError.transport(.timedOut) }
        var config: [String: JSONValue] = ["enabled": .bool(true), "ignored": .array([]), "ignored_enabled": .bool(false)]
        switch kind {
        case .queryLog:
            config["interval"] = .number(Double(queryLogRetention))
            config["anonymize_client_ip"] = .bool(false)
        case .stats:
            config["interval"] = .number(Double(statsRetention))
        }
        return .object(config)
    }

    public func readDNS() async throws -> AdGuardDNSSettings {
        guard currentStatus() != nil else { throw AdGuardClientError.transport(.timedOut) }
        return dns
    }

    public func testUpstreams(_ request: UpstreamTestRequest) async throws -> JSONValue? {
        guard currentStatus() != nil else { throw AdGuardClientError.transport(.timedOut) }
        try? await Task.sleep(for: .milliseconds(900))
        writes.append(.testUpstreams(request))
        let addresses = (request.upstreams + request.bootstrap + request.fallback).compactMap { UpstreamLine($0).address }
        return .object(Dictionary(addresses.map { address in
            let fails = failsUpstreamTest && address.contains("dns.example.org")
            return (address, JSONValue.string(fails ? "couldn't communicate with upstream: i/o timeout" : "OK"))
        }) { first, _ in first })
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
        case .refreshLists, .clearDNSCache, .testUpstreams, .versionCheck, .clearQueryLog, .resetStats:
            break
        case .queryLogConfig(let config):
            if let interval = config["interval"]?.int { queryLogRetention = interval }
        case .statsConfig(let config):
            if let interval = config["interval"]?.int { statsRetention = interval }
        case .dnsConfig(let changes):
            dns = dns.applying(changes.filter { $0.key != ignoredDNSField })
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
        var reading = Self.overview(range: range, now: now, options: options, filteringEnabled: filteringEnabled,
                                    slowUpstream: slowUpstream)
        reading.filtering = .success(currentFiltering(now: now))
        reading.dns = .success(dns)
        reading.statsConfig = .success(AdGuardStatsConfig(enabled: true, intervalMilliseconds: statsRetention))
        if !range.isAvailable(retentionMilliseconds: statsRetention) { reading.stats = .failure(.unavailable) }
        reading.queryLog = .success(AdGuardQueryLogConfig(enabled: true, intervalMilliseconds: queryLogRetention, anonymizeClientIP: false))
        return reading
    }

    /// The Overview a running mock shows at `now`. A range longer than the
    /// retention is not read, as in the live service.
    static func overview(range: AdGuardStatsRange, now: Date, options: ProtectionOptions,
                         filteringEnabled: Bool = true, slowUpstream: Bool = false) -> AdGuardOverviewReading {
        let available = range.isAvailable(retentionMilliseconds: retentionMilliseconds)
        return AdGuardOverviewReading(
            range: range,
            stats: available ? .success(stats(range: range, slowUpstream: slowUpstream)) : .failure(.unavailable),
            statsConfig: .success(AdGuardStatsConfig(enabled: true, intervalMilliseconds: retentionMilliseconds)),
            protection: .success(options),
            filtering: .success(filtering(enabled: filteringEnabled)),
            dns: .success(defaultDNS),
            observedAt: now
        )
    }

    /// A daily curve: quiet at night, busy in the evening.
    static func stats(range: AdGuardStatsRange, slowUpstream: Bool = false) -> AdGuardStats {
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
        // Stats name upstreams with their port, as AdGuard Home does.
        stats.topUpstreams = [.init(name: "https://dns.example.net:443/dns-query", count: queries * 6 / 10),
                              .init(name: "tls://dns.example.org:853", count: queries * 3 / 10),
                              .init(name: "192.0.2.53:53", count: queries / 10)]
        stats.topUpstreamTimes = [.init(name: "https://dns.example.net:443/dns-query", seconds: 0.018),
                                  .init(name: "tls://dns.example.org:853", seconds: slowUpstream ? 0.74 : 0.034),
                                  .init(name: "192.0.2.53:53", seconds: 0.009)]
        return stats
    }

    /// `dns_info` with neutral addresses, including fields the tab does not
    /// show.
    static let defaultDNS = AdGuardDNSSettings(fields: [
        "upstream_dns": .array(["https://dns.example.net/dns-query", "tls://dns.example.org", "192.0.2.53",
                                "# Local names", "[/home.arpa/]192.0.2.1"].map(JSONValue.string)),
        "upstream_mode": .string("load_balance"),
        "fallback_dns": .array([.string("203.0.113.53")]),
        "bootstrap_dns": .array([.string("192.0.2.10"), .string("198.51.100.10")]),
        "blocking_mode": .string("default"),
        "blocking_ipv4": .string(""),
        "blocking_ipv6": .string(""),
        "blocked_response_ttl": .number(10),
        "cache_enabled": .bool(true),
        "cache_size": .number(4_194_304),
        "cache_ttl_min": .number(0),
        "cache_ttl_max": .number(0),
        "cache_optimistic": .bool(false),
        "dnssec_enabled": .bool(false),
        "edns_cs_enabled": .bool(false),
        "disable_ipv6": .bool(false),
        "ratelimit": .number(20),
        "upstream_timeout": .number(10),
        "ratelimit_subnet_len_ipv4": .number(24),
        "ratelimit_whitelist": .array([]),
        "use_private_ptr_resolvers": .bool(true),
        "local_ptr_upstreams": .array([]),
    ])

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

/// `config.yaml` in memory. A written file's DNS values become
/// AdGuard Home's when it starts again. In "Restore fails" the first file
/// written stops AdGuard Home from answering.
extension MockAdGuardTransport: AdGuardConfigFileTransport {
    public func readConfigFile() async throws -> Data {
        try? await Task.sleep(for: .milliseconds(300))
        return configFile ?? Self.configYAML(dns)
    }

    public func writeConfigFile(_ data: Data) async throws {
        try? await Task.sleep(for: .milliseconds(300))
        configFile = data
        brokenConfig = failsRestore
        failsRestore = false
        guard let file = AdGuardConfigFile(data) else { return }
        if let upstreams = file.dns.upstreams { dns.upstreams = upstreams }
        if let mode = file.dns.blockingMode.flatMap(AdGuardBlockingMode.init(rawValue:)) { dns.blockingMode = mode }
        if let size = file.dns.cacheSize { dns.cacheSize = size }
        if let limit = file.dns.rateLimit { dns.rateLimit = limit }
    }

    /// A short config with neutral values. The password hash is a placeholder.
    static func configYAML(_ dns: AdGuardDNSSettings) -> Data {
        let upstreams = (dns.upstreams ?? []).map { "    - '\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: "\n")
        return Data("""
        http:
          address: 0.0.0.0:3000
        users:
          - name: admin
            password: example-placeholder-hash
        dns:
          bind_hosts:
            - 0.0.0.0
          port: 3053
          upstream_dns:
        \(upstreams)
          blocking_mode: \(dns.blockingMode?.rawValue ?? "default")
          cache_size: \(dns.cacheSize ?? 4_194_304)
          ratelimit: \(dns.rateLimit ?? 20)
        schema_version: 28

        """.utf8)
    }
}

extension AdGuardRestorePolicy {
    static var mock: AdGuardRestorePolicy {
        var policy = AdGuardRestorePolicy()
        policy.configDeadline = .seconds(2)
        policy.answerDeadline = .seconds(4)
        policy.settingsDeadline = .seconds(1)
        policy.pollInterval = .milliseconds(250)
        return policy
    }
}

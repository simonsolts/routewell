import Foundation

/// The Activity range pop-up (chunk 17). AdGuard Home reads a range with
/// `GET control/stats?recent=<ms>`; a range longer than the stats retention
/// is not offered.
public enum AdGuardStatsRange: String, CaseIterable, Sendable, Codable {
    case day, week, month

    public var title: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }

    public var milliseconds: Int {
        switch self {
        case .day: 86_400_000
        case .week: 604_800_000
        case .month: 2_592_000_000
        }
    }

    /// What a reply that honoured `recent` looks like: 24 hours, or 7 or 30 days.
    public var expectedShape: (units: AdGuardStats.TimeUnits, count: Int) {
        AdGuardStats.expectedShape(recentMilliseconds: milliseconds)
    }

    /// 24 hours is always offered. A longer range needs a known retention
    /// at least as long (`recent` must not exceed it).
    public func isAvailable(retentionMilliseconds: Int?) -> Bool {
        if self == .day { return true }
        guard let retentionMilliseconds else { return false }
        return milliseconds <= retentionMilliseconds
    }

    /// The `recent` value to send: the range, or a shorter retention cut to
    /// whole hours (AdGuard Home refuses anything else). `nil` when the
    /// retention is under one hour: the plain read.
    public func recentMilliseconds(retentionMilliseconds: Int?) -> Int? {
        guard let retentionMilliseconds, retentionMilliseconds < milliseconds else { return milliseconds }
        let hours = retentionMilliseconds / 3_600_000
        return hours > 0 ? hours * 3_600_000 : nil
    }
}

/// `GET control/stats` (AdGuard Home 0.107 schema `Stats`). Missing lists are
/// empty and missing numbers `nil` (Unknown); nothing is invented.
public struct AdGuardStats: Sendable, Equatable, Codable {
    public enum TimeUnits: String, Sendable, Codable { case hours, days }

    /// One top-list row: a domain, client IP, or upstream, and its count.
    public struct Entry: Sendable, Equatable, Codable {
        public var name: String
        public var count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public var timeUnits: TimeUnits?
    public var queries: Int?
    public var blockedFiltering: Int?
    public var replacedSafeBrowsing: Int?
    public var replacedParental: Int?
    public var replacedSafeSearch: Int?
    /// `avg_processing_time`, in seconds.
    public var averageProcessingSeconds: Double?
    /// One value per time unit, oldest first; the last is the current unit.
    public var queriesSeries: [Int] = []
    public var blockedSeries: [Int] = []
    public var topQueried: [Entry] = []
    public var topBlocked: [Entry] = []
    /// Keys are client IPs `[verified live]`.
    public var topClients: [Entry] = []
    public var topUpstreams: [Entry] = []
    /// `top_upstreams_avg_time`, in seconds. Optional so
    /// an older saved copy still loads.
    public var topUpstreamTimes: [TimeEntry]?

    public struct TimeEntry: Sendable, Equatable, Codable {
        public var name: String
        public var seconds: Double

        public init(name: String, seconds: Double) {
            self.name = name
            self.seconds = seconds
        }
    }

    public init() {}

    public static func parse(_ json: JSONValue) -> AdGuardStats {
        var stats = AdGuardStats()
        stats.timeUnits = json["time_units"]?.string.flatMap(TimeUnits.init(rawValue:))
        stats.queries = json["num_dns_queries"]?.int
        stats.blockedFiltering = json["num_blocked_filtering"]?.int
        stats.replacedSafeBrowsing = json["num_replaced_safebrowsing"]?.int
        stats.replacedParental = json["num_replaced_parental"]?.int
        stats.replacedSafeSearch = json["num_replaced_safesearch"]?.int
        stats.averageProcessingSeconds = json["avg_processing_time"]?.double
        stats.queriesSeries = series(json["dns_queries"])
        stats.blockedSeries = series(json["blocked_filtering"])
        stats.topQueried = entries(json["top_queried_domains"])
        stats.topBlocked = entries(json["top_blocked_domains"])
        stats.topClients = entries(json["top_clients"])
        stats.topUpstreams = entries(json["top_upstreams_responses"])
        stats.topUpstreamTimes = (json["top_upstreams_avg_time"]?.array ?? []).compactMap { element in
            guard let object = element.object, object.count == 1, let (name, value) = object.first,
                  let seconds = value.double, seconds >= 0 else { return nil }
            return TimeEntry(name: name, seconds: seconds)
        }
        return stats
    }

    /// A series keeps its length: a missing or odd value counts as 0, so the
    /// bars stay on their hour or day.
    private static func series(_ value: JSONValue?) -> [Int] {
        value?.array?.map { $0.int ?? 0 } ?? []
    }

    /// Each element is a one-key object `{"<name>": <count>}`.
    private static func entries(_ value: JSONValue?) -> [Entry] {
        (value?.array ?? []).compactMap { element in
            guard let object = element.object, object.count == 1, let (name, count) = object.first,
                  let value = count.double, value >= 0, let count = Int(exactly: value.rounded()) else { return nil }
            return Entry(name: name, count: count)
        }
    }

    /// "Threats blocked" `[decision]`: Safe Browsing plus Parental
    /// replacements. Unknown when either is missing.
    public var threatsBlocked: Int? {
        guard let replacedSafeBrowsing, let replacedParental else { return nil }
        return replacedSafeBrowsing + replacedParental
    }

    /// Blocked by filtering as a share of all queries, 0...100.
    public var blockedPercent: Double? {
        guard let queries, let blockedFiltering, queries > 0 else { return nil }
        return Double(blockedFiltering) / Double(queries) * 100
    }

    /// AdGuard Home keeps at most this many rows per top list.
    public static let topListLimit = 100

    /// The device count from `top_clients`. `atLeast` when the list is full,
    /// so more clients may exist than AdGuard Home lists.
    public var deviceCount: (count: Int, atLeast: Bool) {
        (topClients.count, topClients.count >= Self.topListLimit)
    }

    /// The shape of a reply to `recent`: one bar per hour up to 24 hours,
    /// else one per day `[assumed]` from AdGuard Home's stats code.
    public static func expectedShape(recentMilliseconds: Int) -> (units: TimeUnits, count: Int) {
        let hours = recentMilliseconds / 3_600_000
        return hours <= 24 ? (.hours, hours) : (.days, hours / 24)
    }

    /// True when the reply has the shape `range` asks for. An AdGuard Home
    /// that ignores `recent` answers with its whole retention instead.
    public func matches(_ range: AdGuardStatsRange) -> Bool {
        matches(recentMilliseconds: range.milliseconds)
    }

    /// One bucket more or less still matches: AdGuard Home builds days from
    /// aligned hours `[assumed]`. A version that ignores `recent` answers with
    /// its whole retention, which differs by more (or in units).
    public func matches(recentMilliseconds: Int) -> Bool {
        let shape = Self.expectedShape(recentMilliseconds: recentMilliseconds)
        return timeUnits == shape.units && abs(queriesSeries.count - shape.count) <= 1
    }

    /// The start of each bar's hour or day, oldest first, counted back from
    /// `now`. `nil` when the units are unknown.
    public func bucketStarts(now: Date, calendar: Calendar = .current) -> [Date]? {
        guard let timeUnits else { return nil }
        let component: Calendar.Component = timeUnits == .hours ? .hour : .day
        let current: Date = timeUnits == .hours
            ? calendar.dateInterval(of: .hour, for: now)?.start ?? now
            : calendar.startOfDay(for: now)
        let count = queriesSeries.count
        return (0..<count).compactMap { index in
            calendar.date(byAdding: component, value: index - (count - 1), to: current)
        }
    }
}

/// `GET control/stats/config` (`GetStatsConfigResponse`) `[assumed]`.
public struct AdGuardStatsConfig: Sendable, Equatable, Codable {
    public var enabled: Bool?
    /// Retention in milliseconds.
    public var intervalMilliseconds: Int?
    public var ignored: [String] = []
    public var ignoredEnabled: Bool?

    public init(enabled: Bool? = nil, intervalMilliseconds: Int? = nil) {
        self.enabled = enabled
        self.intervalMilliseconds = intervalMilliseconds
    }

    public static func parse(_ json: JSONValue) -> AdGuardStatsConfig {
        var config = AdGuardStatsConfig(enabled: json["enabled"]?.bool,
                                        intervalMilliseconds: json["interval"]?.int)
        config.ignored = json["ignored"]?.array?.compactMap(\.string) ?? []
        config.ignoredEnabled = json["ignored_enabled"]?.bool
        return config
    }
}

/// The three Protection switches. Each comes from its own status call, so
/// one failed call leaves only that switch Unknown (`nil`).
public struct ProtectionOptions: Sendable, Equatable, Codable {
    public var safeBrowsing: Bool?
    public var parental: Bool?
    public var safeSearch: Bool?

    public init(safeBrowsing: Bool? = nil, parental: Bool? = nil, safeSearch: Bool? = nil) {
        self.safeBrowsing = safeBrowsing
        self.parental = parental
        self.safeSearch = safeSearch
    }

    public subscript(feature: AdGuardFeature) -> Bool? {
        get {
            switch feature {
            case .safeBrowsing: safeBrowsing
            case .parental: parental
            case .safeSearch: safeSearch
            }
        }
        set {
            switch feature {
            case .safeBrowsing: safeBrowsing = newValue
            case .parental: parental = newValue
            case .safeSearch: safeSearch = newValue
            }
        }
    }
}

/// A Protection switch and its AdGuard Home calls.
public enum AdGuardFeature: String, CaseIterable, Sendable, Codable {
    case safeBrowsing, parental, safeSearch

    public var statusPath: String {
        switch self {
        case .safeBrowsing: "control/safebrowsing/status"
        case .parental: "control/parental/status"
        case .safeSearch: "control/safesearch/status"
        }
    }
}

/// One blocklist or allowlist from `control/filtering/status`.
public struct AdGuardFilterList: Sendable, Equatable, Codable {
    public var id: Int?
    public var name: String?
    public var url: String?
    public var enabled: Bool?
    public var rulesCount: Int?
    public var lastUpdated: String?

    public init(id: Int? = nil, name: String? = nil, url: String? = nil, enabled: Bool? = nil,
                rulesCount: Int? = nil, lastUpdated: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.rulesCount = rulesCount
        self.lastUpdated = lastUpdated
    }

    /// The host of `url`, for the Source column. `nil` when it has none.
    public var host: String? {
        url.flatMap { URL(string: $0)?.host() }
    }

    public var lastUpdatedDate: Date? {
        guard let lastUpdated else { return nil }
        if let date = try? Date(lastUpdated, strategy: .iso8601) { return date }
        return try? Date(lastUpdated, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    static func parse(_ json: JSONValue) -> AdGuardFilterList {
        AdGuardFilterList(id: json["id"]?.int, name: json["name"]?.string, url: json["url"]?.string,
                          enabled: json["enabled"]?.bool, rulesCount: json["rules_count"]?.int,
                          lastUpdated: json["last_updated"]?.string)
    }
}

/// `GET control/filtering/status`. Chunk 17 shows only the Blocklists row;
/// chunk 19 edits the lists and adds the custom rules.
public struct AdGuardFilteringStatus: Sendable, Equatable, Codable {
    public var enabled: Bool?
    /// Update check interval, in hours.
    public var intervalHours: Int?
    public var blocklists: [AdGuardFilterList] = []
    /// `whitelist_filters`; `null` on 4.9.1 when there are none `[verified live]`.
    public var allowlists: [AdGuardFilterList] = []
    /// `null` is an empty list, `nil` when the field is missing.
    public var userRules: [String]?

    public init() {}

    public func lists(_ kind: FilterListKind) -> [AdGuardFilterList] {
        kind == .blocklist ? blocklists : allowlists
    }

    /// The list with this URL, compared as `FilterListURL.matches` does.
    public func list(_ kind: FilterListKind, url: String) -> AdGuardFilterList? {
        lists(kind).first { $0.url.map { FilterListURL.matches($0, url) } ?? false }
    }

    public static func parse(_ json: JSONValue) -> AdGuardFilteringStatus {
        var status = AdGuardFilteringStatus()
        status.enabled = json["enabled"]?.bool
        status.intervalHours = json["interval"]?.int
        status.blocklists = json["filters"]?.array?.map(AdGuardFilterList.parse) ?? []
        status.allowlists = json["whitelist_filters"]?.array?.map(AdGuardFilterList.parse) ?? []
        switch json["user_rules"] {
        case .array(let rules)?: status.userRules = rules.compactMap(\.string)
        case .null?: status.userRules = []
        default: status.userRules = nil
        }
        return status
    }

    public var enabledBlocklists: [AdGuardFilterList] { blocklists.filter { $0.enabled == true } }

    /// Rules in the blocklists that are on. Unknown when one of them has no count.
    public var activeRuleCount: Int? {
        let counts = enabledBlocklists.map(\.rulesCount)
        guard !counts.contains(nil) else { return nil }
        return counts.compactMap { $0 }.reduce(0, +)
    }
}

/// What one Overview read got. Each part is read on its own; one failure
/// leaves the others.
public struct AdGuardOverviewReading: Sendable, Equatable {
    public var range: AdGuardStatsRange
    public var stats: Result<AdGuardStats, RefreshFailureCategory>
    /// False when AdGuard Home did not honour `recent` (it answered 400 or
    /// with another shape); the stats are then its whole retention.
    public var rangeHonoured: Bool
    public var statsConfig: Result<AdGuardStatsConfig, RefreshFailureCategory>
    /// A failure only when all three status calls failed.
    public var protection: Result<ProtectionOptions, RefreshFailureCategory>
    public var filtering: Result<AdGuardFilteringStatus, RefreshFailureCategory>
    /// `control/dns_info`, for the DNS tab.
    public var dns: Result<AdGuardDNSSettings, RefreshFailureCategory>
    /// The Instance tab: `querylog/config`.
    public var queryLog: Result<AdGuardQueryLogConfig, RefreshFailureCategory> = .failure(.unavailable)
    public var observedAt: Date

    public init(range: AdGuardStatsRange, stats: Result<AdGuardStats, RefreshFailureCategory>, rangeHonoured: Bool = true,
                statsConfig: Result<AdGuardStatsConfig, RefreshFailureCategory>,
                protection: Result<ProtectionOptions, RefreshFailureCategory>,
                filtering: Result<AdGuardFilteringStatus, RefreshFailureCategory>,
                dns: Result<AdGuardDNSSettings, RefreshFailureCategory> = .failure(.unavailable), observedAt: Date) {
        self.range = range
        self.stats = stats
        self.rangeHonoured = rangeHonoured
        self.statsConfig = statsConfig
        self.protection = protection
        self.filtering = filtering
        self.dns = dns
        self.observedAt = observedAt
    }
}

/// The banner's Pause menu (design): 30 seconds, 1 minute, 10 minutes,
/// 1 hour, then until tomorrow at 08:00 local time `[decision]`. The Router
/// menu uses the same items.
public enum ProtectionPauseChoice: String, CaseIterable, Sendable {
    case thirtySeconds, oneMinute, tenMinutes, oneHour, untilTomorrow

    public var title: String {
        switch self {
        case .thirtySeconds: "Pause for 30 seconds"
        case .oneMinute: "Pause for 1 minute"
        case .tenMinutes: "Pause for 10 minutes"
        case .oneHour: "Pause for 1 hour"
        case .untilTomorrow: "Pause until tomorrow"
        }
    }

    /// The local hour "until tomorrow" ends.
    public static let tomorrowHour = 8

    /// When the pause ends if it starts at `now`.
    public func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .thirtySeconds: return now.addingTimeInterval(30)
        case .oneMinute: return now.addingTimeInterval(60)
        case .tenMinutes: return now.addingTimeInterval(10 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: Self.tomorrowHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }

    /// The protection write for this choice, in whole milliseconds.
    public func intent(from now: Date, calendar: Calendar = .current) -> ProtectionIntent {
        let milliseconds = Int((end(from: now, calendar: calendar).timeIntervalSince(now) * 1000).rounded())
        return .pause(.milliseconds(milliseconds))
    }
}

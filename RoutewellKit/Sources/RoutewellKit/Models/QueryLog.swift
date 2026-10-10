import Foundation

/// What AdGuard Home did with one query, from its `reason` field. The four
/// known cases match the Query Log's status pop-up.
public enum QueryResult: String, Sendable, Equatable, CaseIterable {
    /// A rule allowed it (`NotFilteredWhiteList`, an `@@` rule).
    case allowed
    /// No rule matched; AdGuard Home sent it upstream or answered from cache.
    case processed
    case blocked
    /// Answered by a rewrite or Safe Search, not blocked.
    case rewritten
    /// A reason Routewell does not know.
    case unknown

    /// `NotFilteredNotFound`, `NotFilteredWhiteList`, `FilteredBlackList`, and
    /// `FilteredBlockedService` are `[verified live]` (4.9.1 and AdGuard Home
    /// v1.0.0-b.1); the rest are AdGuard Home's other documented reasons
    /// `[assumed]`.
    public init(reason: String?) {
        switch reason {
        case "FilteredBlackList", "FilteredBlockedService", "FilteredSafeBrowsing", "FilteredParental", "FilteredInvalid":
            self = .blocked
        case "FilteredSafeSearch", "Rewrite", "RewriteEtcHosts", "RewriteRule":
            self = .rewritten
        case "NotFilteredWhiteList":
            self = .allowed
        case let value? where value.hasPrefix("NotFiltered"):
            self = .processed
        default:
            self = .unknown
        }
    }
}

/// One `control/querylog` entry. Every field is optional; a missing field
/// stays unknown rather than failing the page.
public struct QueryLogEntry: Sendable, Equatable, Identifiable {
    public var time: Date?
    /// `time` exactly as AdGuard Home wrote it, with nanoseconds. Part of `id`.
    public var timeText: String?
    /// The client address AdGuard Home saw (`client`), an IP `[verified live]`.
    public var client: String?
    /// `client_info.name`; empty on the recorded router, so usually `nil`.
    public var clientName: String?
    public var domain: String?
    /// `question.type`: A, AAAA, HTTPS, PTR, …
    public var type: String?
    public var reason: String?
    public var result: QueryResult
    /// The upstream address; empty when the query was blocked or cached.
    public var upstream: String?
    /// `elapsedMs`, a string on the recorded router `[verified live]`.
    public var elapsedMilliseconds: Double?
    public var cached: Bool?
    /// `client_proto`: empty for plain DNS `[verified live]`, else `doh`,
    /// `dot`, `doq`, `dnscrypt` `[assumed]`.
    public var clientProtocol: String?
    /// The first matching rule's text and list (`rules[]`).
    public var rule: String?
    /// The list the rule came from: a blocklist id from `filtering/status`
    /// `[verified live]`, or AdGuard Home's own negative ids.
    public var filterID: Int?
    /// `service_name`, for a blocked service `[verified live]`.
    public var serviceName: String?
    /// The DNS response code (`status`): NOERROR, NXDOMAIN, …
    public var responseCode: String?
    /// Every answer value, in order (`answer[].value`).
    public var answers: [String]

    public init(time: Date? = nil, timeText: String? = nil, client: String? = nil, clientName: String? = nil,
                domain: String? = nil, type: String? = nil, reason: String? = nil, upstream: String? = nil,
                elapsedMilliseconds: Double? = nil, cached: Bool? = nil, clientProtocol: String? = nil,
                rule: String? = nil, filterID: Int? = nil, serviceName: String? = nil,
                responseCode: String? = nil, answers: [String] = []) {
        self.time = time
        self.timeText = timeText
        self.client = client
        self.clientName = clientName
        self.domain = domain
        self.type = type
        self.reason = reason
        result = QueryResult(reason: reason)
        self.upstream = upstream
        self.elapsedMilliseconds = elapsedMilliseconds
        self.cached = cached
        self.clientProtocol = clientProtocol
        self.rule = rule
        self.filterID = filterID
        self.serviceName = serviceName
        self.responseCode = responseCode
        self.answers = answers
    }

    /// Stable across pages and Live reads: the nanosecond time, client,
    /// domain, and type together.
    public var id: String {
        [timeText ?? time.map { String($0.timeIntervalSince1970) } ?? "", client ?? "", domain ?? "", type ?? ""].joined(separator: "|")
    }
}

/// One page of entries, newest first. Never saved.
public struct QueryLogPage: Sendable, Equatable {
    public var entries: [QueryLogEntry]
    /// AdGuard Home's `oldest` cursor: the time of the oldest entry it looked at.
    public var oldest: Date?
    /// `oldest` exactly as sent, for the next page's `older_than`.
    public var oldestText: String?
    public var limit: Int

    public init(entries: [QueryLogEntry], oldest: Date? = nil, oldestText: String? = nil, limit: Int) {
        self.entries = entries
        self.oldest = oldest
        self.oldestText = oldestText
        self.limit = limit
    }

    /// A full page means older entries exist that Routewell did not read.
    /// A filtered page can be short and still have older matches.
    public var isFull: Bool { entries.count >= limit }
}

/// The status pop-up. Each case sends AdGuard Home's `response_status`;
/// the values are from its schema. `filtered` is not used: it also matches
/// allowed and rewritten queries.
public enum QueryLogStatusFilter: String, Sendable, Equatable, CaseIterable {
    case all, blocked, processed, allowed, rewritten

    /// `blocked` is `[verified live]` (only `FilteredBlackList` and
    /// `FilteredBlockedService`); the others are `[assumed]`.
    public var responseStatus: String {
        switch self {
        case .all: "all"
        case .blocked: "blocked"
        case .processed: "processed"
        case .allowed: "whitelisted"
        case .rewritten: "rewritten"
        }
    }
}

/// One `control/querylog` read: newest first, at most `limit` entries
/// older than `olderThan` (exclusive, `[verified live]`).
public struct QueryLogQuery: Sendable, Equatable {
    public var search: String?
    public var status: QueryLogStatusFilter
    /// The previous page's `oldest`, exactly as AdGuard Home sent it.
    public var olderThan: String?
    public var limit: Int

    public init(search: String? = nil, status: QueryLogStatusFilter = .all, olderThan: String? = nil, limit: Int) {
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.search = trimmed?.isEmpty == false ? trimmed : nil
        self.status = status
        self.olderThan = olderThan
        self.limit = min(max(limit, 1), QueryLogLimits.maximum)
    }
}

public struct DomainCount: Sendable, Equatable {
    public let domain: String
    public let count: Int

    public init(domain: String, count: Int) {
        self.domain = domain
        self.count = count
    }
}

/// One client's slice of a query-log page, for the details pane. Counts
/// cover only the page's window, never AdGuard Home's 24-hour statistics.
public struct ClientQueryActivity: Sendable, Equatable {
    /// Newest first.
    public var entries: [QueryLogEntry]
    public var blocked: Int
    public var topRequested: [DomainCount]
    public var topBlocked: [DomainCount]
    /// The oldest time the counts cover.
    public var windowStart: Date?
    /// True when older entries for this client may exist outside the page.
    public var windowLimited: Bool
    public var fetchedAt: Date

    public var total: Int { entries.count }

    public static let topCount = 5

    /// Matches entries whose `client` equals `clientIP` exactly; a search on
    /// the server may return near matches such as `.10` for `.1`.
    public static func summarize(_ page: QueryLogPage, clientIP: String, fetchedAt: Date) -> ClientQueryActivity {
        let matched = page.entries
            .filter { $0.client == clientIP }
            .sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
        let blocked = matched.filter { $0.result == .blocked }
        let times = matched.compactMap(\.time)
        return ClientQueryActivity(
            entries: matched,
            blocked: blocked.count,
            topRequested: top(matched),
            topBlocked: top(blocked),
            windowStart: page.oldest ?? times.min(),
            windowLimited: page.isFull,
            fetchedAt: fetchedAt
        )
    }

    /// Most frequent first; equal counts sort by domain so the list is stable.
    private static func top(_ entries: [QueryLogEntry]) -> [DomainCount] {
        var counts: [String: Int] = [:]
        for domain in entries.compactMap(\.domain) { counts[domain, default: 0] += 1 }
        return counts
            .map { DomainCount(domain: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.domain) > ($1.count, $0.domain) }
            .prefix(topCount)
            .map { $0 }
    }
}

public enum QueryLogLimits {
    /// One fetch never asks for more than this many entries.
    public static let maximum = 500
    /// The Query Log tab keeps at most this many entries in memory.
    public static let loadedCap = 5_000
    /// A Live read asks for this many of the newest entries.
    public static let liveLimit = 100
}

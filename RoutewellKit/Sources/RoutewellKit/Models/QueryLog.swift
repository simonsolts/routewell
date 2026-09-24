import Foundation

/// What AdGuard Home did with one query, from its `reason` field.
public enum QueryResult: String, Sendable, Equatable {
    case allowed, blocked
    /// Answered by a rewrite or Safe Search, not blocked.
    case rewritten
    /// A reason Routewell does not know.
    case unknown

    /// `NotFilteredNotFound`, `FilteredBlackList`, and `FilteredBlockedService`
    /// are `[verified live]` on 4.9.1; the rest are AdGuard Home's other
    /// documented reasons `[assumed]`.
    public init(reason: String?) {
        switch reason {
        case "FilteredBlackList", "FilteredBlockedService", "FilteredSafeBrowsing", "FilteredParental", "FilteredInvalid":
            self = .blocked
        case "FilteredSafeSearch", "Rewrite", "RewriteEtcHosts", "RewriteRule":
            self = .rewritten
        case let value? where value.hasPrefix("NotFiltered"):
            self = .allowed
        default:
            self = .unknown
        }
    }
}

/// One `control/querylog` entry. Every field is optional; a missing field
/// stays unknown rather than failing the page.
public struct QueryLogEntry: Sendable, Equatable {
    public var time: Date?
    /// The client address AdGuard Home saw (`client`), an IP on 4.9.1.
    public var client: String?
    public var domain: String?
    public var reason: String?
    public var result: QueryResult

    public init(time: Date? = nil, client: String? = nil, domain: String? = nil, reason: String? = nil) {
        self.time = time
        self.client = client
        self.domain = domain
        self.reason = reason
        result = QueryResult(reason: reason)
    }
}

/// One bounded page of the newest entries. There is no paging: the page is
/// the whole window Routewell knows about, and it is never saved.
public struct QueryLogPage: Sendable, Equatable {
    public var entries: [QueryLogEntry]
    /// AdGuard Home's `oldest` cursor: the time of the oldest entry returned.
    public var oldest: Date?
    public var limit: Int

    public init(entries: [QueryLogEntry], oldest: Date? = nil, limit: Int) {
        self.entries = entries
        self.oldest = oldest
        self.limit = limit
    }

    /// A full page means older entries exist that Routewell did not read.
    public var isFull: Bool { entries.count >= limit }
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

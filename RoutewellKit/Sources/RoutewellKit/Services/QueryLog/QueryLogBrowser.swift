import Foundation

/// The Query Log tab's loaded entries, newest first, in memory
/// only. Page one, then Load More pages read with `older_than`, at most
/// `QueryLogLimits.loadedCap` entries. A new search or status starts again.
public struct QueryLogBrowser: Sendable, Equatable {
    public let search: String?
    public let status: QueryLogStatusFilter
    public private(set) var entries: [QueryLogEntry] = []
    /// The `older_than` value for Load More.
    public private(set) var cursor: String?
    /// The last page was empty: AdGuard Home has nothing older.
    public private(set) var reachedEnd = false
    /// Page one has been read.
    public private(set) var loaded = false
    public let cap: Int

    public init(search: String? = nil, status: QueryLogStatusFilter = .all, cap: Int = QueryLogLimits.loadedCap) {
        let first = QueryLogQuery(search: search, status: status, limit: QueryLogLimits.maximum)
        self.search = first.search
        self.status = status
        self.cap = cap
    }

    public var isFiltered: Bool { search != nil || status != .all }
    public var isAtCap: Bool { entries.count >= cap }
    public var canLoadMore: Bool { loaded && !reachedEnd && !isAtCap && cursor != nil }
    /// The time of the oldest loaded entry, for the footer.
    public var oldestLoaded: Date? { entries.last(where: { $0.time != nil })?.time }

    /// Page one: newest first.
    public var firstPageQuery: QueryLogQuery {
        QueryLogQuery(search: search, status: status, limit: QueryLogLimits.maximum)
    }

    /// The next older page, or `nil` when there is none to read.
    public var nextPageQuery: QueryLogQuery? {
        guard canLoadMore else { return nil }
        return QueryLogQuery(search: search, status: status, olderThan: cursor, limit: QueryLogLimits.maximum)
    }

    /// The Live read: the newest entries, unfiltered.
    public static let liveQuery = QueryLogQuery(limit: QueryLogLimits.liveLimit)

    /// Replaces everything with page one.
    public mutating func replace(with page: QueryLogPage) {
        entries = []
        cursor = nil
        reachedEnd = false
        loaded = true
        append(page)
    }

    /// Adds an older page. A filtered page can be short while older matches
    /// exist `[verified live]`, so only an empty page ends the log.
    public mutating func append(_ page: QueryLogPage) {
        let known = Set(entries.map(\.id))
        let added = page.entries.filter { !known.contains($0.id) }
        entries.append(contentsOf: added.prefix(max(0, cap - entries.count)))
        let next = page.oldestText ?? page.entries.last?.timeText
        // No entries, or a cursor that does not move, would read the same page again.
        if page.entries.isEmpty || next == nil || next == cursor {
            reachedEnd = true
        }
        cursor = next ?? cursor
        if isAtCap { cursor = entries.last?.timeText ?? cursor }
    }

    public enum LiveMerge: Sendable, Equatable {
        /// `count` newer entries were added at the top.
        case merged(count: Int)
        /// Every entry in a full Live read is newer: entries are missing
        /// between the two, so page one must be read again.
        case reloadNeeded
    }

    /// Adds the entries of a Live read that are newer than the newest shown.
    public mutating func mergeLive(_ page: QueryLogPage) -> LiveMerge {
        guard let newest = entries.first else {
            replace(with: page)
            return .merged(count: entries.count)
        }
        let newer: [QueryLogEntry]
        if let index = page.entries.firstIndex(where: { $0.id == newest.id }) {
            newer = Array(page.entries[..<index])
        } else {
            guard let newestTime = newest.time else { return .reloadNeeded }
            newer = page.entries.filter { ($0.time ?? .distantPast) > newestTime }
            if page.isFull, newer.count == page.entries.count { return .reloadNeeded }
        }
        let known = Set(entries.map(\.id))
        let added = newer.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return .merged(count: 0) }
        entries.insert(contentsOf: added, at: 0)
        if entries.count > cap {
            // The oldest leave memory; Load More can read them again.
            entries.removeLast(entries.count - cap)
            cursor = entries.last?.timeText ?? cursor
            reachedEnd = false
        }
        return .merged(count: added.count)
    }
}

/// The Query Log's dates. Rows show the time for today and the
/// date and time for older entries; the inspector shows the full date.
public enum QueryLogTimeFormat {
    /// "21:14:05" today, "Yesterday 21:14", "6 Oct 21:14" this year, else
    /// "6 Oct 2025 21:14" (shown here for an English (UK) locale).
    public static func row(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(time.hour().minute().second())
        }
        let short = date.formatted(time.hour().minute())
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(short)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? time.day().month(.abbreviated) : time.day().month(.abbreviated).year()
        return "\(date.formatted(day)) \(short)"
    }

    /// "Today at 21:14:05", "Yesterday at 21:14:05", else
    /// "6 October 2026 at 21:14:05".
    public static func full(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute().second())
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday at \(time)"
        }
        return "\(date.formatted(style.day().month(.wide).year())) at \(time)"
    }
}

/// Block Domain and Unblock Domain: one custom rule each.
public enum DomainRuleAction: String, Sendable, Equatable {
    case block, unblock

    /// `||domain^` blocks the domain and its subdomains; `@@||domain^`
    /// allows them, over any blocklist. `nil` for a name that is not a
    /// plain domain, so no other rule text can be written.
    public func rule(for domain: String) -> String? {
        guard let name = Self.normalized(domain) else { return nil }
        switch self {
        case .block: return "||\(name)^"
        case .unblock: return "@@||\(name)^"
        }
    }

    var opposite: DomainRuleAction { self == .block ? .unblock : .block }

    /// The custom rules after the action: the opposite rule for the same
    /// domain is removed, and the rule is added at the end unless present.
    /// Every other line stays as it was. Trailing empty lines are dropped.
    public func apply(to rules: [String], domain: String) -> [String]? {
        guard let rule = rule(for: domain), let opposite = opposite.rule(for: domain) else { return nil }
        var result = rules.filter { $0.trimmingCharacters(in: .whitespaces) != opposite }
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        if !result.contains(where: { $0.trimmingCharacters(in: .whitespaces) == rule }) { result.append(rule) }
        return result
    }

    /// The rule is present and the opposite one is not.
    public func isApplied(in rules: [String], domain: String) -> Bool {
        guard let rule = rule(for: domain), let opposite = opposite.rule(for: domain) else { return false }
        let lines = Set(rules.map { $0.trimmingCharacters(in: .whitespaces) })
        return lines.contains(rule) && !lines.contains(opposite)
    }

    /// Lowercase, without a final dot; letters, digits, `-`, and `_` in
    /// dot-separated labels, at most 253 characters.
    static func normalized(_ domain: String) -> String? {
        var name = domain.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard name.count <= 253,
              name.range(of: #"^[a-z0-9_-]+(\.[a-z0-9_-]+)*$"#, options: .regularExpression) != nil else { return nil }
        return name
    }
}

import SwiftUI
import RoutewellKit

/// Texts for AdGuard Home › Query Log (chunk 18). Copy follows the design
/// (`design/adguard-home.md`); lines marked "not in design" are Routewell's.
enum QueryLogPresentation {
    static let searchPrompt = "Domain or client"
    static let emptyInspector = "Select a query to see where it went and why."

    static func statusTitle(_ status: QueryLogStatusFilter) -> String {
        switch status {
        case .all: "All statuses"
        case .blocked: "Blocked"
        case .processed: "Processed"
        case .allowed: "Allowed"
        case .rewritten: "Rewritten"
        }
    }

    /// The table's status word.
    static func statusText(_ result: QueryResult) -> String {
        switch result {
        case .blocked: "Blocked"
        case .processed: "Processed"
        case .allowed: "Allowed"
        case .rewritten: "Rewritten"
        case .unknown: "Unknown"
        }
    }

    static func statusColor(_ result: QueryResult) -> Color {
        switch result {
        case .blocked: .red
        case .processed: .green
        case .allowed: .teal
        case .rewritten: .indigo
        case .unknown: .gray
        }
    }

    /// The inspector's pill. The design labels a Processed query "Allowed".
    static func pillText(_ result: QueryResult) -> String {
        result == .processed ? "Allowed" : statusText(result)
    }

    /// A known blocklist or allowlist name for `filterID`.
    static func listName(_ id: Int?, filtering: AdGuardFilteringStatus?) -> String? {
        guard let id, let filtering else { return nil }
        return (filtering.blocklists + filtering.allowlists).first { $0.id == id }?.name
    }

    /// What decided a blocked, allowed, or rewritten query; `nil` otherwise.
    /// List id 0 is custom rules in AdGuard Home's web UI `[assumed]`.
    static func decidedBy(_ entry: QueryLogEntry, filtering: AdGuardFilteringStatus?) -> String? {
        switch entry.reason {
        case "FilteredBlockedService":
            // Not in design.
            return entry.serviceName.map { "Blocked service: \($0)" } ?? "Blocked service"
        case "FilteredSafeBrowsing": return "Safe Browsing" // Not in design.
        case "FilteredParental": return "Parental control" // Not in design.
        case "FilteredSafeSearch": return "Safe search" // Not in design.
        default: break
        }
        switch entry.result {
        case .rewritten:
            return "DNS rewrite"
        case .blocked, .allowed:
            if let name = listName(entry.filterID, filtering: filtering) { return name }
            return entry.filterID == 0 || entry.filterID == nil ? "Custom rules" : "Unknown list"
        case .processed, .unknown:
            return nil
        }
    }

    /// The Reason column: who decided, "From cache", or the upstream.
    static func reasonCell(_ entry: QueryLogEntry, filtering: AdGuardFilteringStatus?) -> String {
        if let decided = decidedBy(entry, filtering: filtering) { return decided }
        if entry.cached == true { return "From cache" }
        return entry.upstream ?? "Unknown"
    }

    /// The inspector's label and value for the Reason row.
    static func reasonRow(_ entry: QueryLogEntry, filtering: AdGuardFilteringStatus?) -> (label: String, value: String) {
        let label = entry.result == .blocked ? "Blocked by" : "Reason"
        if let decided = decidedBy(entry, filtering: filtering) { return (label, decided) }
        if entry.result == .processed {
            return (label, entry.cached == true ? "Not filtered · answered from cache" : "Not filtered")
        }
        return (label, entry.reason ?? "Unknown")
    }

    /// The table shows the name, else the IP.
    static func deviceCell(_ entry: QueryLogEntry, name: String?) -> String {
        name ?? entry.clientName ?? entry.client ?? "Unknown"
    }

    /// The inspector shows "name · IP", or the IP alone.
    static func deviceRow(_ entry: QueryLogEntry, name: String?) -> String {
        let resolved = name ?? entry.clientName
        switch (resolved, entry.client) {
        case let (name?, ip?): return "\(name) · \(ip)"
        case let (name?, nil): return name
        case let (nil, ip?): return ip
        case (nil, nil): return "Unknown"
        }
    }

    /// "A · Plain DNS". An empty `client_proto` is plain DNS.
    static func typeRow(_ entry: QueryLogEntry) -> String {
        let type = entry.type ?? "Unknown"
        guard let proto = entry.clientProtocol else { return type }
        let name: String
        switch proto.lowercased() {
        case "": name = "Plain DNS"
        case "doh": name = "DNS-over-HTTPS"
        case "dot": name = "DNS-over-TLS"
        case "doq": name = "DNS-over-QUIC"
        case "dnscrypt": name = "DNSCrypt"
        default: name = proto
        }
        return "\(type) · \(name)"
    }

    static func upstreamRow(_ entry: QueryLogEntry) -> String {
        if entry.result == .blocked { return "—" }
        if entry.cached == true { return "Cache" }
        return entry.upstream ?? "—"
    }

    /// "0.25 ms" below 1 ms, else "12 ms".
    static func response(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite else { return "—" }
        if milliseconds < 1 { return "\(milliseconds.formatted(.number.precision(.fractionLength(2)))) ms" }
        return "\(milliseconds.rounded().formatted(.number.precision(.fractionLength(0)))) ms"
    }

    /// The answer values, "HTTPS record" for an HTTPS query.
    static func answerRow(_ entry: QueryLogEntry) -> String {
        if entry.type == "HTTPS" { return "HTTPS record" }
        guard !entry.answers.isEmpty else { return "—" }
        return entry.answers.prefix(3).joined(separator: ", ") + (entry.answers.count > 3 ? ", …" : "")
    }

    /// "1,000 queries loaded · since 6 Oct 21:14". AdGuard Home gives no total.
    static func footer(count: Int, oldest: Date?, filtered: Bool, now: Date,
                       calendar: Calendar = .current, locale: Locale = .current) -> String {
        let noun = count == 1 ? "query" : "queries"
        var text = "\(count.formatted()) \(filtered ? "matching \(noun)" : noun) loaded"
        if let oldest { text += " · since \(QueryLogTimeFormat.row(oldest, now: now, calendar: calendar, locale: locale))" }
        return text
    }

    /// At the 5,000 cap. Not in design.
    static let capNote = "Showing the newest 5,000. Narrow the search to see older queries."

    /// No rows. The filtered line is the design's.
    static func emptyTable(filtered: Bool) -> String {
        filtered ? "No queries match these filters." : "AdGuard Home has no queries in its log."
    }

    /// AdGuard Home is not running: no log to show. Not in design.
    static let unavailableTitle = "No Query Log"
    static func unavailableMessage(_ availability: AdGuardAvailability) -> String {
        switch availability {
        case .unreachable:
            "The Query Log is read from AdGuard Home while it runs. AdGuard Home does not answer, and Routewell does not keep a copy."
        default:
            "The Query Log is read from AdGuard Home while it runs. Routewell does not keep a copy."
        }
    }

    static func failure(_ category: RefreshFailureCategory) -> String {
        "AdGuard Home did not send its query log (\(FailureText.text(category)))."
    }
}

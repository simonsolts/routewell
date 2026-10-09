import Foundation
import RoutewellKit

/// The Availability section's 24H / 7D switch.
enum PresenceRange: String, CaseIterable, Identifiable {
    case day = "24H"
    case week = "7D"

    var id: Self { self }
    var interval: TimeInterval { self == .day ? 86_400 : 7 * 86_400 }
    var startLabel: String { self == .day ? "24 h ago" : "7 d ago" }
}

struct AvailabilityModel: Equatable {
    let segments: [PresenceSegment]
    let window: DateInterval
    let rows: [DetailRowModel]
    let historySummary: String
    let hasHistory: Bool
}

/// The Forget device section's button state.
struct ForgetState: Equatable {
    let enabled: Bool
    let status: String?
    let tone: StatusTone
}

/// Every string the five details sections show, beside `ClientsFormat`.
enum ClientDetailsFormat {
    static let footnote = "Observed while Routewell is running; unmonitored time is shown as unknown."

    // MARK: Availability

    static func availability(_ entry: ClientListEntry, history: PresenceHistory?, range: PresenceRange, now: Date,
                             calendar: Calendar = .current) -> AvailabilityModel {
        let continuity = PresenceLog.continuity
        let window = DateInterval(start: now.addingTimeInterval(-range.interval), end: now)
        let segments = PresenceTimeline.segments(history, window: window, now: now, continuity: continuity)
        let observed = history?.runs.isEmpty == false
        let online = PresenceTimeline.currentOnlinePeriod(history, now: now, continuity: continuity)
        let onlineToday = observed ? duration(PresenceTimeline.onlineToday(history, now: now, continuity: continuity, calendar: calendar)) : ClientsFormat.unknown
        let period: String = switch (online, observed) {
        case (let period?, _): period.atLeast ? "At least \(duration(period.duration))" : duration(period.duration)
        case (nil, true): "Not online now"
        case (nil, false): ClientsFormat.unknown
        }
        let firstObserved = entry.record?.firstSeen ?? history?.firstObserved
        let rows = [
            DetailRowModel(label: "Online today", value: onlineToday, monospaced: true),
            DetailRowModel(label: "Current online period", value: period, monospaced: true),
            DetailRowModel(label: "Last observed", value: history?.lastObserved.map { dateTime($0) } ?? "Not observed", monospaced: true),
            DetailRowModel(label: "Last offline", value: PresenceTimeline.lastOffline(history).map { dateTime($0) } ?? "None observed", monospaced: true),
            DetailRowModel(label: "First observed", value: firstObserved.map { dateTime($0) } ?? "Not observed", monospaced: true),
            DetailRowModel(label: "Last seen by Routewell", value: entry.record?.lastSeen.map { dateTime($0) } ?? "Never", monospaced: true),
        ]
        return AvailabilityModel(segments: segments, window: window, rows: rows,
                                 historySummary: historySummary(history, now: now), hasHistory: observed)
    }

    /// `< 1 min`, `12 min`, `3 h 5 min`, `2 d 4 h`.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        switch minutes {
        case ..<1: return "< 1 min"
        case ..<60: return "\(minutes) min"
        case ..<(24 * 60): return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
        default:
            let hours = minutes / 60
            return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
        }
    }

    /// `21 Sept 2026, 23:14` in the person's locale.
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// `3 days · 41 observations`, counting days from the first stored sample.
    static func historyCounts(_ history: PresenceHistory?, now: Date) -> String? {
        guard let history, let first = history.firstObserved else { return nil }
        let days = max(1, Int((now.timeIntervalSince(first) / 86_400).rounded(.up)))
        let observations = history.observations
        return "\(days) \(days == 1 ? "day" : "days") · \(observations.formatted()) \(observations == 1 ? "observation" : "observations")"
    }

    static func historySummary(_ history: PresenceHistory?, now: Date) -> String {
        guard let counts = historyCounts(history, now: now) else { return "No presence history is stored for this device." }
        return "\(counts) · stored on this Mac."
    }

    // MARK: DNS activity

    static let recentLimit = 10

    static func dnsHeader(_ activity: ClientQueryActivity?, paused: Bool) -> String {
        let mode = paused ? "paused" : "live"
        guard let activity else { return mode }
        return "Latest \(min(recentLimit, activity.total)) of \(activity.total.formatted()) · \(mode)"
    }

    /// Says which window the counts cover, so they are never read as 24-hour totals.
    static func dnsWindow(_ activity: ClientQueryActivity) -> String {
        let since = activity.windowStart.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        if activity.windowLimited {
            return "Counts cover the newest \(QueryLogLimits.maximum) matching entries in AdGuard Home's query log\(since). Older requests are not read."
        }
        return "Counts cover every request AdGuard Home's query log keeps for this client\(since). Nothing is saved on this Mac."
    }

    static func resultText(_ result: QueryResult) -> (text: String, tone: StatusTone) {
        switch result {
        // The pane keeps one word for every query that was not blocked.
        case .allowed, .processed: ("Allowed", .healthy)
        case .blocked: ("Blocked", .error)
        case .rewritten: ("Rewritten", .unknown)
        case .unknown: (ClientsFormat.unknown, .unknown)
        }
    }

    static func time(_ date: Date?) -> String {
        date?.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) ?? ClientsFormat.dash
    }

    // MARK: VPN routing

    /// Client-specific routing is read in chunk 28; until then every value
    /// is unknown rather than a guessed "None".
    static let vpnClientRows = [
        DetailRowModel(label: "Route", value: ClientsFormat.unknown, tone: .unknown),
        DetailRowModel(label: "Policy source", value: ClientsFormat.unknown),
        DetailRowModel(label: "Matched by", value: ClientsFormat.unknown),
    ]
    static let vpnGlobalRows = [
        DetailRowModel(label: "Global VPN", value: ClientsFormat.unknown, tone: .unknown),
        DetailRowModel(label: "Client", value: ClientsFormat.unknown),
        DetailRowModel(label: "Policy mode", value: ClientsFormat.unknown),
    ]
    static let vpnFootnote = "Routewell does not read VPN routing yet, so it cannot say whether this client has its own policy or follows the router's global VPN policy."

    // MARK: Personalise and Forget

    static func personalised(_ record: DeviceRecord?) -> String {
        record?.personalisedAt.map { "Personalised \(day($0))" } ?? "Not personalised"
    }

    static func savedOnThisMac(_ entry: ClientListEntry, history: PresenceHistory?, now: Date) -> [DetailRowModel] {
        let notes = entry.record?.notes.isEmpty == false ? 1 : 0
        return [
            DetailRowModel(label: "Presence history", value: historyCounts(history, now: now) ?? "None", monospaced: true),
            DetailRowModel(label: "Profile", value: personalised(entry.record)),
            DetailRowModel(label: "Notes", value: "\(notes)", monospaced: true),
            DetailRowModel(label: "Matched by", value: entry.mac.colonSeparated, monospaced: true),
        ]
    }

    /// The online state the forget rule checks: a remembered device the
    /// router no longer lists counts as offline once a list has loaded.
    static func onlineForForget(_ entry: ClientListEntry, inventoryLoaded: Bool) -> Observed<Bool> {
        if let client = entry.client { return client.online }
        return inventoryLoaded ? .value(false) : .unknown
    }

    static func forgetState(_ entry: ClientListEntry, inventoryLoaded: Bool) -> ForgetState {
        guard entry.record != nil else {
            return ForgetState(enabled: false, status: "Nothing is stored on this Mac for this device.", tone: .unknown)
        }
        switch onlineForForget(entry, inventoryLoaded: inventoryLoaded) {
        case .value(false): return ForgetState(enabled: true, status: nil, tone: .unknown)
        case .value(true): return ForgetState(enabled: false, status: "Currently on the network — disconnect it before forgetting.", tone: .healthy)
        case .unknown, .unavailable: return ForgetState(enabled: false, status: "Its network state is unknown. Refresh, then try again.", tone: .unknown)
        }
    }

    // MARK: Copy Details

    static func copyDetails(_ entry: ClientListEntry, now: Date) -> String {
        let status = ClientsFormat.status(entry, now: now).text
        let lines: [(String, String?)] = [
            ("Name", ClientsFormat.name(entry, mode: .automatic)),
            ("Status", status),
            ("IP address", entry.client?.ip ?? entry.record?.lastIP),
            ("MAC address", entry.mac.colonSeparated),
            ("Vendor", ClientsFormat.vendor(entry.client?.vendor ?? .resolve(reported: nil, mac: entry.mac))),
            ("Hostname", entry.client?.hostname ?? entry.record?.lastHostname),
            ("Connection", ClientsFormat.connection(entry.client)),
            ("Category", ClientsFormat.category(entry.record?.category)),
            ("Queries (24 h)", entry.queries == .unknown ? nil : ClientsFormat.count(entry.queries)),
        ]
        return lines.compactMap { label, value in value.map { "\(label): \($0)" } }.joined(separator: "\n")
    }
}

import Foundation
import RoutewellKit

/// Text for the Filters tab.
enum FiltersPresentation {
    static let checkEvery = "Check every"
    static let updateNow = "Update Now"
    static let updating = "Updating…"
    static let downloading = "Downloading…"
    static let allowlistNote = "These domains are never blocked, even if a blocklist includes them."
    static let rulesNote = "Rules here override every list."
    static let customURLNote = "Hosts files and AdGuard-syntax lists both work. Lists are downloaded by the router."
    static let namePlaceholder = "My blocklist"
    static let urlPlaceholder = "https://example.com/hosts.txt"

    static let syntax: [(code: String, text: String)] = [
        ("||example.com^", "Block a domain and its subdomains"),
        ("@@||example.com^", "Never block this domain"),
        ("192.0.2.20 nas.home", "Point a name at an address"),
        ("! comment", "Notes for yourself"),
    ]

    static func intervalTitle(_ hours: Int) -> String {
        switch hours {
        case 0: "Never"
        case 1: "1 hour"
        case 72: "3 days"
        case 168: "7 days"
        default: "\(hours) hours"
        }
    }

    /// Adds the current value when it is not one of the standard items.
    static func intervalChoices(current: Int?) -> [Int] {
        guard let current, !FilterUpdateInterval.isValid(current) else { return FilterUpdateInterval.hours }
        return FilterUpdateInterval.hours + [current]
    }

    static func rules(_ list: AdGuardFilterList, downloading: Bool) -> String {
        if downloading { return Self.downloading }
        guard let count = list.rulesCount else { return "Unknown" }
        if count == 0, list.enabled != true || list.lastUpdated == nil { return "—" }
        return count.formatted(.number)
    }

    /// "Just now" in the first minute, "Today at 14:05", else the date
    /// and time; "—" without a time.
    static func lastUpdated(_ list: AdGuardFilterList, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date = list.lastUpdatedDate else { return list.lastUpdated == nil ? "—" : "Unknown" }
        if abs(now.timeIntervalSince(date)) < 60 { return "Just now" }
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday at \(time)"
        }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
    }

    /// "3 of 6 on · 581,421 rules". Always counts the blocklists.
    static func summary(_ status: AdGuardFilteringStatus?) -> String {
        guard let status else { return "" }
        let on = "\(status.enabledBlocklists.count) of \(status.blocklists.count) on"
        guard let rules = status.activeRuleCount else { return on }
        return "\(on) · \(rules.formatted(.number)) rules"
    }

    static func updateResult(_ count: Int?) -> String? {
        switch count {
        case nil: nil
        case 0?: "Lists are up to date"
        case 1?: "Updated 1 list"
        case let count?: "Updated \(count) lists"
        }
    }

    static func sheetTitle(_ kind: FilterListKind) -> String {
        kind == .blocklist ? "Add blocklists" : "Add allowlists"
    }

    static func addTitle(selected: Int) -> String {
        selected == 0 ? "Add" : "Add \(selected)"
    }

    // MARK: Rules conflict

    static let conflictTitle = "Custom rules changed on AdGuard Home"
    static let conflictMessage = "The rules changed after you started to edit them. Your changes are not saved."
    static let conflictDiscard = "Discard My Changes"
    static let conflictKeep = "Keep Editing"
}

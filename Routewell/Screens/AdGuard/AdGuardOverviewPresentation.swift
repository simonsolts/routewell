import Foundation
import RoutewellKit

/// Text for AdGuard Home › Overview (design/adguard-home.md, chunk 17).
extension AdGuardPresentation {
    // MARK: Banner

    enum BannerTone: Equatable { case on, paused, notFiltering, readOnly }
    enum BannerAction: Equatable { case pause, resume, turnOnProtection, handleDNS }

    struct Banner: Equatable {
        let tone: BannerTone
        let title: String
        let message: String
        let actions: [BannerAction]
    }

    /// The four design variants, plus "Protection is off" for protection
    /// turned off (from the Pause menu or elsewhere) and an unknown state.
    static func banner(
        _ availability: AdGuardAvailability, protection: ProtectionState?, handlesDNS: Bool?,
        stats: AdGuardStats?, filtering: AdGuardFilteringStatus?, savedAt: Date?,
        now: Date, calendar: Calendar = .current
    ) -> Banner {
        switch availability {
        case .running:
            break
        case .unreachable(let problem):
            return Banner(tone: .readOnly, title: problemTitle(problem), message: savedMessage(savedAt), actions: [])
        case .cached, .off, .unknown:
            return Banner(tone: .readOnly, title: "AdGuard Home is off", message: savedMessage(savedAt), actions: [])
        }
        switch protection {
        case .paused(let until)?:
            return Banner(tone: .paused, title: "Protection paused until \(pauseEnd(until, now: now, calendar: calendar))",
                          message: "Requests are passing through unfiltered. Filtering resumes on its own.", actions: [.resume])
        case .disabled?:
            return Banner(tone: .paused, title: "Protection is off",
                          message: "Requests are passing through unfiltered until you turn protection on.", actions: [.turnOnProtection])
        case .enabled?, .unknown?, nil:
            break
        }
        if handlesDNS == false {
            return Banner(tone: .notFiltering, title: "Running, but not filtering your network",
                          message: "The router isn’t sending devices’ DNS here. Only devices set up by hand are protected.",
                          actions: [.handleDNS, .pause])
        }
        guard case .enabled? = protection else {
            return Banner(tone: .readOnly, title: "AdGuard Home is running",
                          message: "AdGuard Home did not say whether protection is on.", actions: [])
        }
        return Banner(tone: .on, title: "Protection is on", message: onMessage(stats: stats, filtering: filtering), actions: [.pause])
    }

    private static func savedMessage(_ savedAt: Date?) -> String {
        guard let savedAt else { return "Routewell has no saved numbers for this router." }
        return "These numbers are from \(savedDate(savedAt)), when it was last running."
    }

    /// "Filtering DNS for 14 devices · 581,421 rules active".
    static func onMessage(stats: AdGuardStats?, filtering: AdGuardFilteringStatus?) -> String {
        var parts: [String] = []
        if let stats, !stats.topClients.isEmpty || stats.queries != nil {
            parts.append("Filtering DNS for \(devices(stats.deviceCount))")
        }
        if let rules = filtering?.activeRuleCount {
            parts.append("\(rules.formatted()) \(rules == 1 ? "rule" : "rules") active")
        }
        return parts.isEmpty ? "Filtering DNS requests." : parts.joined(separator: " · ")
    }

    /// "14 devices", "1 device", "at least 100 devices".
    static func devices(_ count: (count: Int, atLeast: Bool)) -> String {
        let noun = count.count == 1 ? "device" : "devices"
        return count.atLeast ? "at least \(count.count) \(noun)" : "\(count.count) \(noun)"
    }

    /// "11:25" today, "tomorrow, 08:00", else the date and time.
    static func pauseEnd(_ until: Date, now: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        let time = until.formatted(style)
        if calendar.isDate(until, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(until, inSameDayAs: tomorrow) {
            return "tomorrow, \(time)"
        }
        var day = Date.FormatStyle().month(.abbreviated).day()
        day.timeZone = calendar.timeZone
        return "\(until.formatted(day)), \(time)"
    }

    // MARK: Activity

    struct Metric: Equatable {
        let label: String
        let value: String?
        let detail: String?
    }

    /// Queries, Blocked (with percent), Threats blocked, Avg. processing.
    /// `nil` values show as Unknown.
    static func metrics(_ stats: AdGuardStats?) -> [Metric] {
        [
            Metric(label: "Queries", value: stats?.queries?.formatted(), detail: nil),
            Metric(label: "Blocked", value: stats?.blockedFiltering?.formatted(), detail: stats?.blockedPercent.map(percent)),
            Metric(label: "Threats blocked", value: stats?.threatsBlocked?.formatted(), detail: nil),
            Metric(label: "Avg. processing", value: stats?.averageProcessingSeconds.map(milliseconds), detail: nil),
        ]
    }

    /// The period stats cover, from their own shape: "Last 24 hours",
    /// "Last 7 days". `nil` when the units are unknown.
    static func span(_ stats: AdGuardStats) -> String? {
        guard let units = stats.timeUnits else { return nil }
        let count = stats.queriesSeries.count
        switch units {
        case .hours: return count == 1 ? "Last hour" : "Last \(count) hours"
        case .days: return count == 1 ? "Last day" : "Last \(count) days"
        }
    }

    /// "14.3%", "4%".
    static func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    /// "1 ms", "1.5 ms", "12 ms".
    static func milliseconds(_ seconds: Double) -> String {
        let ms = seconds * 1000
        let text = ms >= 10 ? ms.formatted(.number.precision(.fractionLength(0)))
                            : ms.formatted(.number.precision(.fractionLength(0...1)))
        return "\(text) ms"
    }

    /// One bar of the chart and its tooltip.
    struct Bar: Equatable, Identifiable {
        let start: Date
        let queries: Int
        let blocked: Int
        var id: Date { start }
        var allowed: Int { max(0, queries - blocked) }
    }

    static func bars(_ stats: AdGuardStats, now: Date, calendar: Calendar = .current) -> [Bar] {
        guard let starts = stats.bucketStarts(now: now, calendar: calendar) else { return [] }
        return starts.enumerated().map { index, start in
            Bar(start: start, queries: stats.queriesSeries[index],
                blocked: stats.blockedSeries.indices.contains(index) ? stats.blockedSeries[index] : 0)
        }
    }

    /// "12:00 — 1,234 queries, 123 blocked"; days show the date.
    static func barTip(_ bar: Bar, units: AdGuardStats.TimeUnits, calendar: Calendar = .current) -> String {
        var style = units == .hours ? Date.FormatStyle(date: .omitted, time: .shortened) : Date.FormatStyle().month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return "\(bar.start.formatted(style)) — \(bar.queries.formatted()) queries, \(bar.blocked.formatted()) blocked"
    }

    // MARK: Top lists

    struct TopRow: Equatable, Identifiable {
        /// Domain or client IP: the Query Log filter.
        let key: String
        let name: String
        let count: String
        let detail: String
        /// Bar length, 0...1, relative to the first row.
        let fraction: Double
        var id: String { key }
    }

    struct TopList: Equatable {
        let title: String
        let hint: String
        let rows: [TopRow]
    }

    static let topRowCount = 5

    /// Top blocked and Top queried: count, share of the total, and a bar.
    static func domainList(title: String, entries: [AdGuardStats.Entry], total: Int?) -> TopList {
        let top = Array(entries.prefix(topRowCount))
        let largest = Double(top.first?.count ?? 0)
        let rows = top.map { entry in
            TopRow(key: entry.name, name: entry.name, count: entry.count.formatted(),
                   detail: total.flatMap { $0 > 0 ? percent(Double(entry.count) / Double($0) * 100) : nil } ?? "",
                   fraction: largest > 0 ? Double(entry.count) / largest : 0)
        }
        return TopList(title: title, hint: total.map { "\($0.formatted()) total" } ?? "", rows: rows)
    }

    /// Top devices: the name from the client registry, else the IP with
    /// "Unnamed"; the count in compact form ("9.6K").
    static func deviceList(_ stats: AdGuardStats, name: (String) -> String?) -> TopList {
        let top = Array(stats.topClients.prefix(topRowCount))
        let largest = Double(top.first?.count ?? 0)
        let rows = top.map { entry in
            let resolved = name(entry.name)
            return TopRow(key: entry.name, name: resolved ?? entry.name,
                          count: entry.count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))),
                          detail: resolved == nil ? "Unnamed" : entry.name,
                          fraction: largest > 0 ? Double(entry.count) / largest : 0)
        }
        let count = stats.deviceCount
        let hint = count.atLeast ? "at least \(count.count) active" : "\(count.count) active"
        return TopList(title: "Top devices", hint: hint, rows: rows)
    }

    // MARK: Protection card

    static func title(_ feature: AdGuardFeature) -> String {
        switch feature {
        case .safeBrowsing: "Block malware and phishing"
        case .parental: "Block adult content"
        case .safeSearch: "Enforce safe search"
        }
    }

    /// "3 of 6 on · 581,421 rules".
    static func blocklistSummary(_ filtering: AdGuardFilteringStatus?) -> String {
        guard let filtering else { return "Unknown" }
        let on = filtering.enabledBlocklists.count
        var text = "\(on) of \(filtering.blocklists.count) on"
        if let rules = filtering.activeRuleCount { text += " · \(rules.formatted()) \(rules == 1 ? "rule" : "rules")" }
        return text
    }

    // MARK: Setting outcomes

    /// The line under the banner after a setting write. `nil` when the
    /// write did what was asked.
    static func settingOutcomeText(_ intent: AdGuardSettingIntent, _ outcome: MutationOutcome<AdGuardSettingState>) -> String? {
        switch outcome {
        case .verifiedSuccess, .verifiedRecovery:
            return nil
        case .verifiedMismatch:
            switch intent {
            case .protection(.enable): return "AdGuard Home did not turn protection on."
            case .protection(.disable): return "AdGuard Home did not turn protection off."
            case .protection(.pause): return "AdGuard Home did not pause protection."
            case .feature(let feature, _): return "AdGuard Home did not change “\(title(feature))”."
            }
        case .conflictingExternalEdit:
            return "Protection changed from somewhere else. Refresh to check."
        case .recoveryFailed, .unknownAfterDispatch:
            return "AdGuard Home did not answer in time. The change may have applied. Refresh to check."
        case .rejected(let rejection):
            switch rejection {
            case .gateBusy: return "Another change is still running."
            case .staleSession: return "The router changed during the operation. Refresh to check."
            case .capabilityUnavailable: return "AdGuard Home is not set up in Routewell."
            case .preconditionFailed("AdGuard Home refused the login"): return "AdGuard Home refused the sign-in. Nothing was changed."
            case .preconditionFailed("status unavailable"): return "AdGuard Home did not answer. Nothing was changed."
            case .preconditionFailed("credential unavailable"): return "The AdGuard Home password is not available. Nothing was changed."
            case .preconditionFailed(let reason), .invalidIntent(let reason): return reason
            }
        }
    }
}

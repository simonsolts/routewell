import Foundation
import RoutewellKit

// Router › Ports, Storage, and Logs (chunk 15): read over SSH, transcribed
// from design/router-screen.md.

extension RouterFormat {
    /// Decimal units with one decimal, as the Ports and Storage mockups show
    /// them: "0 B", "2.1 KB", "318.1 MB", "9.8 GB", "439 GB".
    static func decimalBytes(_ value: Int64?, locale: Locale = .current) -> String {
        guard let value, value >= 0 else { return dash }
        guard value >= 1000 else { return "\(value) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var scaled = Double(value) / 1000
        var index = 0
        while scaled >= 1000, index < units.count - 1 { scaled /= 1000; index += 1 }
        return "\(scaled.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))) \(units[index])"
    }

    /// "10 Gbps", "2.5 Gbps", "100 Mbps".
    static func linkSpeed(_ megabits: Int?, locale: Locale = .current) -> String {
        guard let megabits, megabits > 0 else { return dash }
        if megabits >= 1000 {
            return "\((Double(megabits) / 1000).formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))) Gbps"
        }
        return "\(megabits) Mbps"
    }

    /// `df -h` prints "7.2G"; the Storage mockup puts a space before the unit.
    static func humanSize(_ value: String) -> String {
        guard let match = value.firstMatch(of: /^([0-9.,]+)([A-Za-z]+)$/) else { return value }
        return "\(match.1) \(match.2)"
    }
}

// MARK: - Ports

struct RouterPortsModel: Equatable {
    static let columns = ["Interface", "Link", "Speed", "Duplex", "RX", "TX", "Errors / drops"]
    static let footnote = "Counters are cumulative since the router last booted. Errors and drops are shown as RX / TX."
    static let historyDetail = "Recorded while Routewell is running; unmonitored time is excluded."

    let strip: [MetricModel]
    let rows: [[RouterCell]]
    let history: RouterRowModel
    /// Newest first.
    let changes: [String]

    init(ports: RouterPortsStatus, changes log: LinkChangeLog, locale: Locale = .current) {
        let connected = ports.ports.filter { $0.link == .up }.map(\.name)
        let disconnected = ports.ports.filter { $0.link == .down }.map(\.name)
        strip = [
            MetricModel(title: "Interfaces", value: ports.ports.count.formatted(), detail: "Ethernet interfaces on the router"),
            MetricModel(title: "Connected", value: connected.count.formatted(), detail: connected.isEmpty ? "None" : connected.joined(separator: " · ")),
            MetricModel(title: "Disconnected", value: disconnected.count.formatted(), detail: disconnected.isEmpty ? "None" : disconnected.joined(separator: " · ")),
            MetricModel(title: "Link changes", value: log.changes.count.formatted(), detail: "This session"),
        ]
        rows = ports.ports.map { Self.row($0, locale: locale) }
        history = RouterRowModel(label: "Link changes observed", detail: Self.historyDetail,
                                 value: log.changes.isEmpty ? "None" : log.changes.count.formatted())
        changes = log.changes.reversed().map { change in
            "\(change.at.formatted(.dateTime.hour().minute().second().locale(locale))) · \(change.interface) · \(Self.linkText(change.from)) → \(Self.linkText(change.to))"
        }
    }

    static func linkText(_ link: LinkState) -> String {
        switch link { case .up: "Connected"; case .down: "Disconnected"; case .unknown: RouterFormat.unknown }
    }

    static func row(_ port: EthernetPortStatus, locale: Locale) -> [RouterCell] {
        let link: RouterCell = switch port.link {
        case .up: RouterCell(text: "Connected", tone: .healthy)
        case .down: RouterCell(text: "Disconnected", tone: .unknown)
        case .unknown: RouterCell(text: RouterFormat.unknown, tone: .unknown)
        }
        return [
            RouterCell(text: port.name, monospaced: true),
            link,
            RouterCell(text: RouterFormat.linkSpeed(port.speedMbps, locale: locale), monospaced: true),
            RouterCell(text: port.duplex.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? RouterFormat.dash),
            RouterCell(text: RouterFormat.decimalBytes(port.rxBytes, locale: locale), monospaced: true),
            RouterCell(text: RouterFormat.decimalBytes(port.txBytes, locale: locale), monospaced: true),
            RouterCell(text: "\(sum(port.rxErrors, port.rxDropped)) / \(sum(port.txErrors, port.txDropped))", monospaced: true),
        ]
    }

    /// Errors plus drops for one direction; unknown when either is missing.
    private static func sum(_ errors: Int64?, _ drops: Int64?) -> String {
        guard let errors, let drops else { return RouterFormat.dash }
        return (errors + drops).formatted()
    }

    func summary(hostname: String?) -> String {
        var lines = ["Ethernet interfaces — \(hostname ?? "router")"]
        for metric in strip { lines.append("\(metric.title): \(metric.value) (\(metric.detail))") }
        for row in rows { lines.append(zip(Self.columns, row).map { "\($0): \($1.text)" }.joined(separator: " · ")) }
        lines.append(Self.footnote)
        lines.append("\(history.label): \(history.value)")
        lines += changes
        return lines.joined(separator: "\n")
    }
}

// MARK: - Storage

struct RouterStorageModel: Equatable {
    struct Volume: Equatable {
        let mountPoint: String
        let type: String
        let fraction: Double?
        let usage: String
    }

    static let shareColumns = ["Share", "Storage", "Read-only", "Guest access"]
    static let footnote = "Read-only observations. No credentials, share paths or files are read; file browsing and storage changes are not available here."

    let rootStatus: RouterRowModel
    let rootFraction: Double?
    let rootUsage: String
    let rootRows: [RouterRowModel]
    let sharing: [RouterRowModel]
    let shares: [[RouterCell]]
    let mounted: RouterRowModel
    let volumes: [Volume]
    let externalAvailable: RouterRowModel?

    init(storage: StorageStatus, locale: Locale = .current) {
        switch storage.root {
        case .value(let root):
            rootStatus = RouterRowModel(label: "Status", value: "Available", tone: .healthy)
            rootFraction = root.usePercent.map { Double($0) / 100 }
            rootUsage = root.usePercent.map { "\($0) % used" } ?? RouterFormat.unknown
            rootRows = [
                RouterRowModel(label: "Used", value: RouterFormat.humanSize(root.used), monospaced: true),
                RouterRowModel(label: "Available", value: RouterFormat.humanSize(root.available), monospaced: true),
                RouterRowModel(label: "Capacity", value: RouterFormat.humanSize(root.size), monospaced: true),
            ]
        default:
            rootStatus = RouterRowModel(label: "Status", value: RouterFormat.unknown, tone: .unknown)
            rootFraction = nil
            rootUsage = RouterFormat.unknown
            rootRows = ["Used", "Available", "Capacity"].map { RouterRowModel(label: $0, value: RouterFormat.unknown) }
        }

        switch storage.samba {
        case .value(.configured(let list)) where !list.isEmpty:
            sharing = [RouterRowModel(label: "Status", value: "Configured", tone: .healthy),
                       RouterRowModel(label: "Configured shares", value: list.count.formatted())]
            shares = list.map { share in
                // The share's path is never read, so its storage stays unknown.
                [RouterCell(text: share.name), RouterCell(text: RouterFormat.unknown),
                 RouterCell(text: RouterFormat.yesNo(share.readOnly)), RouterCell(text: RouterFormat.yesNo(share.guestAccess))]
            }
        case .value(.configured):
            sharing = [RouterRowModel(label: "Status", value: "No shares", tone: .unknown),
                       RouterRowModel(label: "Configured shares", value: "0")]
            shares = []
        case .value(.notConfigured):
            sharing = [RouterRowModel(label: "Status", value: "Not configured", tone: .unknown)]
            shares = []
        default:
            sharing = [RouterRowModel(label: "Status", value: RouterFormat.unknown, tone: .unknown)]
            shares = []
        }

        switch storage.external {
        case .value(let list):
            mounted = RouterRowModel(label: "Mounted filesystems", value: list.count.formatted())
            volumes = list.map { volume in
                let fraction: Double? = if let used = volume.usedBytes, let total = volume.totalBytes, total > 0 { Double(used) / Double(total) } else { nil }
                return Volume(mountPoint: volume.mountPoint, type: volume.fileSystemType ?? "Type unknown", fraction: fraction,
                              usage: "\(RouterFormat.decimalBytes(volume.usedBytes, locale: locale)) of \(RouterFormat.decimalBytes(volume.totalBytes, locale: locale))")
            }
            let free = list.compactMap(\.availableBytes)
            externalAvailable = list.isEmpty ? nil
                : RouterRowModel(label: "Available", value: free.count == list.count ? RouterFormat.decimalBytes(free.reduce(0, +), locale: locale) : RouterFormat.unknown,
                                 monospaced: true)
        default:
            mounted = RouterRowModel(label: "Mounted filesystems", value: RouterFormat.unknown)
            volumes = []
            externalAvailable = nil
        }
    }
}

// MARK: - Logs

struct RouterLogsModel: Equatable {
    static let columns = ["Time", "Severity", "Category", "Source", "Message"]

    let entries: [RouterLogEntry]
    let status: String

    init(tail: RouterLogTail, severity: RouterLogSeverityFilter, category: RouterLogCategory?, search: String) {
        entries = tail.filtered(severity: severity, category: category, search: search)
        status = entries.count == tail.entries.count
            ? "Showing \(entries.count) most recent entries · newest first"
            : "Showing \(entries.count) of \(tail.entries.count) most recent entries · newest first"
    }

    static func time(_ entry: RouterLogEntry, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let time = entry.time else { return RouterFormat.dash }
        var style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(locale)
        style.timeZone = timeZone
        return time.formatted(style)
    }

    /// Error and worse red, warning yellow, notice blue, info and debug grey.
    static func tone(_ severity: RouterLogSeverity?) -> StatusTone {
        switch severity {
        case .emergency?, .alert?, .critical?, .error?: .error
        case .warning?: .attention
        case .notice?: .inProgress
        case .info?, .debug?, nil: .unknown
        }
    }

    /// "Mon 21 Sept 2026, 23:06:11 BST".
    static func detail(_ entry: RouterLogEntry, locale: Locale = .current, timeZone: TimeZone = .current) -> [RouterRowModel] {
        let timeText: String = if let time = entry.time {
            {
                var day = Date.FormatStyle.dateTime.weekday(.abbreviated).locale(locale)
                var date = Date.FormatStyle.dateTime.day().month(.abbreviated).year().locale(locale)
                var clock = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(locale)
                day.timeZone = timeZone
                date.timeZone = timeZone
                clock.timeZone = timeZone
                let zone = timeZone.abbreviation(for: time).map { " \($0)" } ?? ""
                return "\(time.formatted(day)) \(time.formatted(date)), \(time.formatted(clock))\(zone)"
            }()
        } else { RouterFormat.unknown }
        return [
            RouterRowModel(label: "Time", value: timeText, monospaced: true),
            RouterRowModel(label: "Facility · priority", value: entry.facilityPriority ?? RouterFormat.unknown, monospaced: true),
            RouterRowModel(label: "Source", value: entry.source, monospaced: true),
            RouterRowModel(label: "Message", value: entry.message, monospaced: true),
        ]
    }

    /// Raw lines, as on screen: time, then the router's own text.
    static func copyText(_ entries: [RouterLogEntry], locale: Locale = .current) -> String {
        entries.map { "\(time($0, locale: locale))  \($0.line)" }.joined(separator: "\n")
    }
}

// MARK: - SSH state

/// What an SSH-backed segment shows before its content.
enum RouterSSHState: Equatable {
    /// SSH is not set up for the profile.
    case notSetUp
    /// The probe is running.
    case checking
    /// The probe failed or timed out.
    case unavailable(title: String, message: String)
    case ready

    init(configured: Bool, probe: SSHProbeResult?) {
        guard configured else { self = .notSetUp; return }
        guard let probe else { self = .checking; return }
        switch probe.capability.state {
        case .supported: self = .ready
        case .unsupported:
            self = .unavailable(title: probe.failure == .hostKeyChanged ? "SSH host key changed" : "SSH is not working",
                                message: probe.failure?.message ?? "The router refused the SSH connection.")
        case .unknown:
            self = .unavailable(title: "SSH status unknown",
                                message: (probe.failure?.message ?? "The SSH check did not finish.") + " Check again when the router answers.")
        }
    }
}

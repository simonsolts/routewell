import Foundation
import RoutewellKit

/// The six sections in the details pane's source list.
enum ClientDetailsSection: String, CaseIterable, Identifiable {
    case overview, availability, dnsActivity, vpnRouting, personalise, forgetDevice

    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .availability: "Availability"
        case .dnsActivity: "DNS activity"
        case .vpnRouting: "VPN routing"
        case .personalise: "Personalise"
        case .forgetDevice: "Forget device"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "info.circle"
        case .availability: "clock"
        case .dnsActivity: "list.bullet"
        case .vpnRouting: "key"
        case .personalise: "pencil"
        case .forgetDevice: "trash"
        }
    }
}

/// What the details pane shows for the table selection. More than one
/// selected row disables the pane.
enum ClientsPaneContent: Equatable {
    case none
    case single(ClientListEntry)
    case multiple(Int)

    static func resolve(selection: Set<MACAddress>, entries: [ClientListEntry]) -> ClientsPaneContent {
        switch selection.count {
        case 0: return .none
        case 1:
            guard let mac = selection.first, let entry = entries.first(where: { $0.mac == mac }) else { return .none }
            return .single(entry)
        default: return .multiple(selection.count)
        }
    }
}

struct DetailRowModel: Equatable {
    let label: String
    let value: String
    var tone: StatusTone? = nil
    var monospaced = false
}

struct DetailGroupModel: Equatable {
    let title: String
    let rows: [DetailRowModel]
}

struct MetricModel: Equatable {
    let title: String
    let value: String
    let detail: String
    var tone: StatusTone? = nil
    var emphasised = false
    /// A small unit after the value ("%", "°C"), as in the Router mockups.
    var unit: String? = nil
    /// Values in 0…1 for a sparkline under the value; `nil` shows none.
    var history: [Double]? = nil
}

struct ReviewRowModel: Equatable, Identifiable {
    let mac: MACAddress
    let name: String
    let detail: String
    let firstObserved: String
    let symbol: String
    var id: MACAddress { mac }
}

/// Every string the Clients screen shows. Views stay thin; tests read these.
enum ClientsFormat {
    static let unknown = "Unknown"
    static let dash = "—"
    static let unknownDevice = "Unknown device"

    static func name(_ entry: ClientListEntry, mode: ClientNameMode) -> String {
        if let text = ClientNaming.name(mode, client: entry.client, record: entry.record).text { return text }
        return mode == .automatic ? unknownDevice : dash
    }

    static func connection(_ client: Client?) -> String? {
        guard let connection = client?.connection else { return nil }
        let parts: [String?]
        switch connection.medium {
        case .value(.wifi): parts = ["Wi-Fi", connection.band, connection.ssid]
        case .value(.wired): parts = ["Ethernet", connection.interface]
        case .unavailable, .unknown: parts = [connection.interface]
        }
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    /// Provisional signal bands until a documented threshold exists: good at
    /// −60 dBm or stronger, fair to −75 dBm, weak below.
    static func signal(_ client: Client?) -> (text: String, tone: StatusTone)? {
        guard case .value(let dBm)? = client?.signal else { return nil }
        let quality = dBm >= -60 ? "Good" : dBm >= -75 ? "Fair" : "Weak"
        return ("\(quality) \(dBm) dBm", dBm >= -60 ? .healthy : .degraded)
    }

    static func status(_ entry: ClientListEntry, now: Date) -> (text: String, tone: StatusTone) {
        switch entry.presence {
        case .online: return ("Online", .healthy)
        case .offline, .absent:
            guard let lastSeen = entry.record?.lastSeen else { return ("Offline", .unknown) }
            return ("Offline · \(relative(lastSeen, now: now))", .unknown)
        case .unknown: return (unknown, .unknown)
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "Just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    static func count(_ value: Observed<Int>) -> String {
        if case .value(let count) = value { return count.formatted(.number) }
        return dash
    }

    static func rate(_ value: Observed<Double>) -> String {
        switch value {
        case .value(let fraction): "\((fraction * 100).formatted(.number.precision(.fractionLength(1)))) %"
        case .unavailable: "–"
        case .unknown: dash
        }
    }

    static func vendor(_ vendor: ClientVendor) -> String {
        switch vendor {
        case .reported(let name): name
        case .randomised: "Not resolvable (randomised)"
        case .unknown: unknown
        }
    }

    static func category(_ category: DeviceCategory?) -> String? {
        switch category {
        case .phone: "Phone"
        case .desktop: "Desktop"
        case .laptop: "Laptop"
        case .smartHome: "Smart home"
        case .tv: "TV"
        case .server: "Server"
        case .printer: "Printer"
        case .watch: "Watch"
        case .tablet: "Tablet"
        case nil: nil
        }
    }

    static func symbol(_ category: DeviceCategory?) -> String {
        switch category {
        case .phone: "iphone"
        case .desktop: "desktopcomputer"
        case .laptop: "laptopcomputer"
        case .smartHome: "homepod"
        case .tv: "appletv"
        case .server: "server.rack"
        case .printer: "printer"
        case .watch: "applewatch"
        case .tablet: "ipad"
        case nil: "questionmark.circle"
        }
    }

    static func timestamp(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// The monospace subtitle under the pane header: IP · MAC · vendor.
    static func subtitle(_ entry: ClientListEntry) -> String {
        let ip = entry.client?.ip ?? dash
        let vendorText: String = switch entry.client?.vendor ?? .resolve(reported: nil, mac: entry.mac) {
        case .reported(let name): name
        case .randomised: "Randomised MAC"
        case .unknown: "Unknown vendor"
        }
        return [ip, entry.mac.colonSeparated, vendorText].joined(separator: " · ")
    }

    // MARK: Overview section

    static func overviewGroups(_ entry: ClientListEntry) -> [DetailGroupModel] {
        let client = entry.client
        let hostname = client?.hostname ?? (client == nil ? entry.record?.lastHostname : nil)
        let identity = DetailGroupModel(title: "Identity", rows: [
            DetailRowModel(label: "Hostname", value: hostname ?? unknown),
            DetailRowModel(label: "MAC address", value: entry.mac.colonSeparated, monospaced: true),
            DetailRowModel(label: "Vendor", value: vendor(client?.vendor ?? .resolve(reported: nil, mac: entry.mac))),
            DetailRowModel(label: "Category", value: category(entry.record?.category) ?? "Not set"),
        ])
        let signalValue = signal(client)
        let interface = client == nil ? "Not listed by the router" : (connection(client) ?? unknown)
        let connectionGroup = DetailGroupModel(title: "Connection", rows: [
            DetailRowModel(label: "Interface", value: interface),
            DetailRowModel(label: "Radio", value: unknown),
            DetailRowModel(label: "Channel · width", value: unknown),
            DetailRowModel(label: "Signal", value: signalValue?.text ?? unknown, tone: signalValue?.tone),
        ])
        let dhcp = DetailGroupModel(title: "DHCP", rows: [
            DetailRowModel(label: "Assignment", value: unknown),
            DetailRowModel(label: "Lease", value: unknown),
            DetailRowModel(label: "Address", value: unknown),
            DetailRowModel(label: "Remaining", value: unknown),
        ])
        return [identity, connectionGroup, dhcp]
    }

    static func overviewMetrics(_ entry: ClientListEntry, now: Date) -> [MetricModel] {
        let blocked = entry.blocked
        let lastSeen = entry.record?.lastSeen.map { "Last seen \(timestamp($0, now: now))" } ?? "Not seen online by Routewell"
        return [
            MetricModel(title: "Queries", value: countOrUnknown(entry.queries), detail: "Requests from this client"),
            MetricModel(title: "Blocked", value: countOrUnknown(blocked), detail: "Protection actions",
                        emphasised: { if case .value(let count) = blocked { return count > 0 } else { return false } }()),
            MetricModel(title: "Block rate", value: entry.blockRate == .unknown ? unknown : rate(entry.blockRate), detail: lastSeen),
            MetricModel(title: "VPN routing", value: unknown, detail: "Read when VPN support arrives", tone: .unknown),
        ]
    }

    private static func countOrUnknown(_ value: Observed<Int>) -> String {
        if case .value = value { return count(value) }
        return unknown
    }

    // MARK: Review sheet

    static func reviewRows(registry: DeviceRegistryState, clients: [Client], now: Date) -> [ReviewRowModel] {
        let byMAC = Dictionary(clients.map { ($0.mac, $0) }, uniquingKeysWith: { first, _ in first })
        return registry.awaitingReview.map { record in
            let client = byMAC[record.mac]
            let entry = ClientListEntry(mac: record.mac, client: client, record: record)
            let address = client?.ip ?? record.lastIP
            let detail = [address, record.mac.colonSeparated].compactMap { $0 }.joined(separator: " · ")
            let day = Calendar.current.isDate(record.firstSeen, inSameDayAs: now)
                ? "today, \(record.firstSeen.formatted(date: .omitted, time: .shortened))"
                : record.firstSeen.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            return ReviewRowModel(mac: record.mac, name: name(entry, mode: .automatic), detail: detail,
                                  firstObserved: "First observed \(day)", symbol: symbol(record.category))
        }
    }

    static func newDevicesText(_ count: Int) -> String {
        count == 1 ? "1 new device awaiting review" : "\(count) new devices awaiting review"
    }

    static func showingText(visible: Int, total: Int) -> String {
        "Showing \(visible) of \(total) \(total == 1 ? "client" : "clients")"
    }

    static func enrichmentNotice(_ enrichment: ClientEnrichment) -> String? {
        switch enrichment {
        case .joined: nil
        case .notConfigured: "AdGuard Home is not set up, so DNS counts are unknown."
        case .partial: "Some AdGuard Home data did not load; some names or DNS counts are unknown."
        case .failed: "AdGuard Home did not respond; names from it and DNS counts are unknown."
        }
    }
}

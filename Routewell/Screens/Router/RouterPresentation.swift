import Foundation
import RoutewellKit

/// The Router toolbar's ten segments, in the mockup's order.
enum RouterSegment: String, CaseIterable {
    case overview = "Overview", ports = "Ports", wifi = "Wi-Fi", multiWAN = "Multi-WAN", dns = "DNS"
    case sqm = "SQM", performance = "Performance", storage = "Storage", firmware = "Firmware", logs = "Logs"

    /// No RPC exists for these; they need SSH, which chunk 15 sets up.
    var requiresSSH: Bool { self == .ports || self == .storage || self == .logs }
}

/// One table cell: text, an optional status dot, and monospaced digits
/// for addresses and interface names.
struct RouterCell: Equatable {
    var text: String
    var tone: StatusTone? = nil
    var monospaced = false
}

struct RouterRowModel: Equatable {
    let label: String
    var detail: String? = nil
    let value: String
    var tone: StatusTone? = nil
    var monospaced = false
}

enum RouterFormat {
    static let unknown = "Unknown"
    static let dash = "—"

    private static func number(_ value: Double, fraction: ClosedRange<Int>, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(fraction)).grouping(.never).locale(locale))
    }

    /// IEC binary units, as the mockup shows memory: "787.94 MiB", "1.94 GiB".
    static func bytes(_ value: Int64?, fraction: ClosedRange<Int> = 0...2, locale: Locale = .current) -> String {
        guard let value, value >= 0 else { return unknown }
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var scaled = Double(value)
        var index = 0
        while scaled >= 1024, index < units.count - 1 { scaled /= 1024; index += 1 }
        return "\(number(scaled, fraction: index == 0 ? 0...0 : fraction, locale: locale)) \(units[index])"
    }

    static func storage(_ value: Int64?, locale: Locale = .current) -> String { bytes(value, fraction: 0...1, locale: locale) }

    static func percentNumber(_ fraction: Double, locale: Locale = .current) -> String {
        number(fraction * 100, fraction: 0...1, locale: locale)
    }

    static func percent(_ fraction: Double?, locale: Locale = .current) -> String {
        guard let fraction, fraction.isFinite else { return unknown }
        return "\(percentNumber(fraction, locale: locale)) %"
    }

    static func decimal(_ value: Double, locale: Locale = .current) -> String { number(value, fraction: 0...1, locale: locale) }

    static func celsius(_ value: Double?, locale: Locale = .current) -> String {
        guard let value else { return unknown }
        return "\(decimal(value, locale: locale)) °C"
    }

    static func loads(_ values: [Double], locale: Locale = .current) -> String? {
        guard values.count >= 3 else { return nil }
        return values.prefix(3).map { number($0, fraction: 2...2, locale: locale) }.joined(separator: " / ")
    }

    /// Display guidance from the Performance footnote, not a health verdict:
    /// Routewell does not score temperature (architecture 03).
    static func temperatureGuidance(_ celsius: Double?) -> String {
        guard let celsius else { return "Not reported by the router" }
        if celsius < 65 { return "Normal · below 65 °C" }
        if celsius < 80 { return "Elevated · 65–79 °C" }
        return "High · 80 °C or above"
    }

    /// "2 d 4 h 52 m".
    static func uptimeShort(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return unknown }
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) d \(hours) h \(minutes) m" }
        if hours > 0 { return "\(hours) h \(minutes) m" }
        return "\(minutes) m"
    }

    /// "2 days 4 hours 52 minutes".
    static func uptimeLong(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return unknown }
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        var parts: [String] = []
        if days > 0 { parts.append(unit(days, "day")) }
        if days > 0 || hours > 0 { parts.append(unit(hours, "hour")) }
        parts.append(unit(minutes, "minute"))
        return parts.joined(separator: " ")
    }

    /// "19 Sep, 18:17": the locale's day, month, and time, joined with a
    /// comma as in the mockups.
    static func dayTime(_ date: Date, locale: Locale = .current) -> String {
        "\(date.formatted(.dateTime.day().month(.abbreviated).locale(locale))), \(date.formatted(.dateTime.hour().minute().locale(locale)))"
    }

    /// "21 Sep 2026, 23:09".
    static func fullDate(_ date: Date, locale: Locale = .current) -> String {
        "\(date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))), \(date.formatted(.dateTime.hour().minute().locale(locale)))"
    }

    static func band(_ band: WirelessBand?) -> String {
        switch band {
        case .ghz2_4?: "2.4 GHz"
        case .ghz5?: "5 GHz"
        case .ghz6?: "6 GHz"
        case nil: "Unknown band"
        }
    }

    /// "2.4, 5 and 6 GHz".
    static func bandList(_ bands: [WirelessBand]) -> String? {
        let numbers = bands.sorted().map { band -> String in
            switch band { case .ghz2_4: "2.4"; case .ghz5: "5"; case .ghz6: "6" }
        }
        switch numbers.count {
        case 0: return nil
        case 1: return "\(numbers[0]) GHz"
        default: return "\(numbers.dropLast().joined(separator: ", ")) and \(numbers.last!) GHz"
        }
    }

    /// RFC 1918, carrier-grade NAT, loopback, and link-local addresses are
    /// not public, so a private WAN address is never shown as a public IP.
    static func isPublicIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _): return false
        case (100, 64...127), (169, 254), (172, 16...31), (192, 168): return false
        default: return true
        }
    }

    static func yesNo(_ value: Observed<Bool>) -> String {
        switch value { case .value(true): "Yes"; case .value(false): "No"; default: unknown }
    }
}

// MARK: - Overview

struct RouterOverviewModel: Equatable {
    let strip: [MetricModel]
    let identity: [RouterRowModel]
    let memory: [RouterRowModel]
    let network: [RouterRowModel]
    let services: [RouterRowModel]

    static let footnote = "Read-only telemetry reported by the router. Change settings in the router UI."

    init(snapshot: OverviewSnapshot, wireless: WirelessStatus?, locale: Locale = .current) {
        let router = snapshot.router
        strip = RouterOverviewModel.strip(router, locale: locale)
        identity = [
            RouterRowModel(label: "Model", value: router.model ?? RouterFormat.unknown),
            RouterRowModel(label: "Hostname", value: router.hostname ?? RouterFormat.unknown, monospaced: true),
            RouterRowModel(label: "Firmware", value: router.firmware ?? RouterFormat.unknown, monospaced: true),
            RouterRowModel(label: "OpenWrt", value: router.openWrtVersion ?? RouterFormat.unknown, monospaced: true),
            RouterRowModel(label: "Kernel", value: router.kernelVersion ?? RouterFormat.unknown, monospaced: true),
            RouterRowModel(label: "Architecture", value: router.architecture ?? RouterFormat.unknown, monospaced: true),
        ]
        memory = RouterOverviewModel.memoryRows(router, includeTotal: true, locale: locale)

        let internet = snapshot.internet
        let wan = internet.publicAddress
        let publicRow: RouterRowModel = if let wan, RouterFormat.isPublicIPv4(wan) {
            RouterRowModel(label: "Public IP", value: wan, monospaced: true)
        } else if let wan {
            RouterRowModel(label: "Public IP", detail: "The WAN address \(wan) is private", value: RouterFormat.unknown)
        } else {
            RouterRowModel(label: "Public IP", value: RouterFormat.unknown)
        }
        network = [
            RouterRowModel(label: "Internet", value: internet.reachability.label, tone: internet.reachability.tone),
            publicRow,
            RouterRowModel(label: "Gateway", value: internet.gateway ?? RouterFormat.unknown, monospaced: true),
            RouterRowModel(label: "DNS servers", value: internet.dnsServers.isEmpty ? RouterFormat.unknown : internet.dnsServers.joined(separator: ", "), monospaced: true),
        ]

        let adGuard = snapshot.adGuard
        let adGuardRow: RouterRowModel = switch (adGuard.reachability, adGuard.running) {
        case (.connected, .value(true)), (.connected, .unknown):
            RouterRowModel(label: "AdGuard Home", detail: "\(adGuard.version ?? "Version unknown") · process ID needs SSH", value: "Active", tone: .healthy)
        case (.connected, .value(false)):
            RouterRowModel(label: "AdGuard Home", detail: adGuard.version, value: "Stopped", tone: .unknown)
        default:
            RouterRowModel(label: "AdGuard Home", value: adGuard.reachability.label, tone: adGuard.reachability.tone)
        }
        let wifiClients = snapshot.clients.onlineByBand.map { $0.values.reduce(0, +) }
        let wifiValue: String = switch (wireless?.radios.count, wifiClients) {
        case let (radios?, clients?): "\(radios) radios · \(clients) clients"
        case let (radios?, nil): "\(radios) radios"
        case let (nil, clients?): "\(clients) clients"
        case (nil, nil): RouterFormat.unknown
        }
        let storageValue: String = if let used = router.storageUsedBytes, let total = router.storageTotalBytes, total > 0 {
            "\(Int((Double(used) / Double(total) * 100).rounded())) % used · \(RouterFormat.storage(router.storageFreeBytes, locale: locale)) available"
        } else { RouterFormat.unknown }
        services = [
            adGuardRow,
            RouterRowModel(label: "VPN", detail: "VPN status is read in a later update", value: RouterFormat.unknown, tone: .unknown),
            RouterRowModel(label: "Wi-Fi", detail: "Signal strength is not reported by the router", value: wifiValue),
            RouterRowModel(label: "Storage", value: storageValue),
        ]
    }

    static func strip(_ router: RouterStatus, locale: Locale) -> [MetricModel] {
        let cpu: MetricModel = if case .value(let percent) = router.cpuUtilizationPercent {
            MetricModel(title: "CPU", value: RouterFormat.decimal(percent, locale: locale), detail: loadDetail(router, locale: locale), unit: "%")
        } else {
            MetricModel(title: "CPU", value: RouterFormat.unknown, detail: loadDetail(router, locale: locale))
        }
        let memory: MetricModel = if let used = router.memoryUsedBytes, let total = router.memoryTotalBytes, total > 0 {
            MetricModel(title: "Memory", value: RouterFormat.percentNumber(Double(used) / Double(total), locale: locale),
                        detail: "\(RouterFormat.bytes(used, locale: locale)) of \(RouterFormat.bytes(total, locale: locale)) used", unit: "%")
        } else {
            MetricModel(title: "Memory", value: RouterFormat.unknown, detail: "Not reported by the router")
        }
        let degrees: Double? = if case .value(let value) = router.temperatureCelsius { value } else { nil }
        let temperature = MetricModel(title: "Temperature", value: degrees.map { RouterFormat.decimal($0, locale: locale) } ?? RouterFormat.unknown,
                                      detail: RouterFormat.temperatureGuidance(degrees), unit: degrees == nil ? nil : "°C")
        let uptime = MetricModel(title: "Uptime", value: RouterFormat.uptimeShort(router.uptimeSeconds),
                                 detail: router.lastBoot.map { "Last reboot \(RouterFormat.dayTime($0, locale: locale))" } ?? "Last reboot unknown")
        return [cpu, memory, temperature, uptime]
    }

    private static func loadDetail(_ router: RouterStatus, locale: Locale) -> String {
        RouterFormat.loads(router.loadAverages, locale: locale).map { "Load \($0)" } ?? "Load unknown"
    }

    /// The router reports buffers and cache as one value, so one row shows it.
    static func memoryRows(_ router: RouterStatus, includeTotal: Bool, locale: Locale) -> [RouterRowModel] {
        var rows: [RouterRowModel] = []
        if includeTotal { rows.append(RouterRowModel(label: "Total", value: RouterFormat.bytes(router.memoryTotalBytes, locale: locale), monospaced: true)) }
        rows.append(RouterRowModel(label: "Used", value: RouterFormat.bytes(router.memoryUsedBytes, locale: locale), monospaced: true))
        rows.append(RouterRowModel(label: "Available", detail: "Free memory plus buffers and cache", value: RouterFormat.bytes(router.memoryAvailableBytes, locale: locale), monospaced: true))
        rows.append(RouterRowModel(label: "Buffers and cache", detail: "Reported as one value", value: RouterFormat.bytes(router.memoryBuffersAndCacheBytes, locale: locale), monospaced: true))
        return rows
    }
}

// MARK: - Performance

struct RouterPerformanceModel: Equatable {
    let strip: [MetricModel]
    let memory: [RouterRowModel]
    let session: [RouterRowModel]
    let storage: [RouterRowModel]
    let storageFraction: Double?

    static let footnote = "Session values reflect Routewell observations only, not continuous monitoring. Temperature guidance: normal below 65 °C, elevated 65–79 °C, high at 80 °C or above."

    init(snapshot: OverviewSnapshot, history: TelemetryHistory, session summary: TelemetrySessionSummary, locale: Locale = .current) {
        let router = snapshot.router
        let total = router.memoryTotalBytes.map(Double.init)
        let memoryHistory = history.memoryUsedBytes.compactMap { point -> Double? in
            guard let total, total > 0 else { return nil }
            return point.value / total
        }
        let cpu: MetricModel = if case .value(let percent) = router.cpuUtilizationPercent {
            MetricModel(title: "CPU", value: RouterFormat.decimal(percent, locale: locale),
                        detail: summary.peakCPUPercent.map { "Peak this session \(RouterFormat.decimal($0, locale: locale)) %" } ?? "No peak yet",
                        unit: "%", history: history.cpuUtilizationPercent.map { $0.value / 100 })
        } else {
            MetricModel(title: "CPU", value: RouterFormat.unknown, detail: "Utilization is not reported by the router")
        }
        let load = MetricModel(title: "Load average", value: RouterFormat.loads(router.loadAverages, locale: locale) ?? RouterFormat.unknown,
                               detail: "1 · 5 · 15 min · not CPU percentages", history: Self.normalized(history.cpuLoad))
        let memory: MetricModel = if let used = router.memoryUsedBytes, let total = router.memoryTotalBytes, total > 0 {
            MetricModel(title: "Memory", value: RouterFormat.percentNumber(Double(used) / Double(total), locale: locale),
                        detail: "\(RouterFormat.bytes(used, locale: locale)) of \(RouterFormat.bytes(total, locale: locale))", unit: "%", history: memoryHistory)
        } else {
            MetricModel(title: "Memory", value: RouterFormat.unknown, detail: "Not reported by the router")
        }
        let degrees: Double? = if case .value(let value) = router.temperatureCelsius { value } else { nil }
        let temperature = MetricModel(title: "Temperature", value: degrees.map { RouterFormat.decimal($0, locale: locale) } ?? RouterFormat.unknown,
                                      detail: RouterFormat.temperatureGuidance(degrees), unit: degrees == nil ? nil : "°C",
                                      history: history.temperatureCelsius.map { min(max($0.value / 100, 0), 1) })
        strip = [cpu, load, memory, temperature]
        self.memory = RouterOverviewModel.memoryRows(router, includeTotal: false, locale: locale)
        session = [
            RouterRowModel(label: "Observations", detail: "Successful telemetry reads since launch", value: summary.observations.formatted()),
            RouterRowModel(label: "Peak CPU", value: summary.peakCPUPercent.map { "\(RouterFormat.decimal($0, locale: locale)) %" } ?? RouterFormat.unknown),
            RouterRowModel(label: "Peak memory", value: RouterFormat.percent(summary.peakMemoryFraction, locale: locale)),
            RouterRowModel(label: "Peak temperature", value: RouterFormat.celsius(summary.peakTemperatureCelsius, locale: locale)),
            RouterRowModel(label: "Router uptime", value: RouterFormat.uptimeLong(router.uptimeSeconds)),
        ]
        storage = [
            RouterRowModel(label: "Used", value: RouterFormat.storage(router.storageUsedBytes, locale: locale), monospaced: true),
            RouterRowModel(label: "Available", value: RouterFormat.storage(router.storageFreeBytes, locale: locale), monospaced: true),
            RouterRowModel(label: "Total", value: RouterFormat.storage(router.storageTotalBytes, locale: locale), monospaced: true),
        ]
        if let used = router.storageUsedBytes, let total = router.storageTotalBytes, total > 0 {
            storageFraction = Double(used) / Double(total)
        } else {
            storageFraction = nil
        }
    }

    /// Scales a ring to 0…1 against its own peak, for a sparkline shape only.
    static func normalized(_ points: [MetricPoint]) -> [Double] {
        guard let peak = points.map(\.value).max(), peak > 0 else { return points.map { _ in 0 } }
        return points.map { $0.value / peak }
    }

    func summary(hostname: String?) -> String {
        var lines = ["Router performance — \(hostname ?? "router")"]
        for metric in strip { lines.append("\(metric.title): \(metric.value)\(metric.unit.map { " \($0)" } ?? "") (\(metric.detail))") }
        for row in memory + session + storage { lines.append("\(row.label): \(row.value)") }
        lines.append("Storage usage: \(RouterFormat.percent(storageFraction))")
        lines.append(Self.footnote)
        return lines.joined(separator: "\n")
    }
}

// MARK: - DNS

struct RouterDNSModel: Equatable {
    let configuration: [RouterRowModel]
    let upstreams: [String]
    let services: [RouterRowModel]
    let path: String

    static let footnote = "Client DNS activity is visible only when it passes through AdGuard Home. VPN or direct encrypted DNS paths may not be observable."

    init(snapshot: OverviewSnapshot) {
        let dns = DNSConfiguration.derive(router: snapshot.router, internet: snapshot.internet, adGuard: snapshot.adGuard)
        upstreams = dns.upstreams
        configuration = [
            RouterRowModel(label: "Mode", detail: "Not reported over the router API", value: RouterFormat.unknown),
            RouterRowModel(label: "Encrypted DNS", detail: "Not reported over the router API", value: RouterFormat.unknown),
            RouterRowModel(label: "Advertised resolver", detail: "Router LAN address · DHCP option not read",
                           value: dns.advertisedResolver ?? RouterFormat.unknown, monospaced: true),
        ]
        let adGuard = snapshot.adGuard
        let running: RouterRowModel = switch dns.adGuardRunning {
        case .value(true):
            RouterRowModel(label: "AdGuard Home", detail: [adGuard.version, dns.adGuardPort.map { "port \($0)" }].compactMap { $0 }.joined(separator: " · "),
                           value: "Running", tone: .healthy)
        case .value(false): RouterRowModel(label: "AdGuard Home", value: "Stopped", tone: .unknown)
        default: RouterRowModel(label: "AdGuard Home", value: adGuard.reachability == .connected ? RouterFormat.unknown : adGuard.reachability.label, tone: .unknown)
        }
        let handles: RouterRowModel = switch dns.handlesClientRequests {
        case .value(true): RouterRowModel(label: "Handles client requests", value: "Yes", tone: .healthy)
        case .value(false): RouterRowModel(label: "Handles client requests", value: "No", tone: .unknown)
        default: RouterRowModel(label: "Handles client requests", value: RouterFormat.unknown, tone: .unknown)
        }
        services = [
            RouterRowModel(label: "DNS service", detail: "Not reported over the router API", value: RouterFormat.unknown),
            running,
            handles,
            RouterRowModel(label: "VPN DNS", value: RouterFormat.unknown, tone: .unknown),
        ]
        path = switch dns.resolutionPath {
        case .value(.throughAdGuard): "Client → Router → AdGuard Home → Upstream"
        case .value(.direct): "Client → Router → Upstream"
        default: RouterFormat.unknown
        }
    }
}

// MARK: - Wi-Fi

struct RouterWiFiModel: Equatable {
    struct Band: Equatable {
        let title: String
        let radio: String
        let rows: [[RouterCell]]
    }

    static let columns = ["SSID", "Interface", "State", "Band", "Channel", "Width", "Clients", "TX power"]
    let strip: [MetricModel]
    let bands: [Band]

    init(wireless: WirelessStatus, onlineByBand: [WirelessBand: Int]?, signals: [Int]?) {
        let networks = wireless.networks
        let enabled = wireless.enabledNetworkCount
        let disabled = networks.filter { $0.enabled == .value(false) }.count
        let clients = onlineByBand.map { $0.values.reduce(0, +) }
        let perBand = onlineByBand.map { counts in
            WirelessBand.allCases.compactMap { band in counts[band].flatMap { $0 > 0 ? "\($0) on \(RouterFormat.band(band))" : nil } }.joined(separator: " · ")
        }
        let weak = signals.map { $0.filter { $0 < -75 }.count }
        strip = [
            MetricModel(title: "Radios", value: wireless.radios.count.formatted(),
                        detail: RouterFormat.bandList(wireless.radios.compactMap(\.band)) ?? "Bands unknown"),
            MetricModel(title: "Networks", value: networks.count.formatted(), detail: "\(enabled) active · \(disabled) disabled"),
            MetricModel(title: "Associated clients", value: clients?.formatted() ?? RouterFormat.unknown,
                        detail: perBand.flatMap { $0.isEmpty ? nil : $0 } ?? (clients == 0 ? "No Wi-Fi clients online" : "Per-band counts unknown")),
            MetricModel(title: "Weak clients", value: weak?.formatted() ?? RouterFormat.unknown,
                        detail: weak == nil ? "Signal is not reported by the router" : "Below −75 dBm"),
        ]
        bands = wireless.radios.map { radio in
            Band(title: RouterFormat.band(radio.band), radio: radio.device ?? "", rows: radio.networks.map { network in
                Self.row(network, radio: radio, onlineByBand: onlineByBand)
            })
        }
    }

    static func row(_ network: WirelessNetwork, radio: WirelessRadio, onlineByBand: [WirelessBand: Int]?) -> [RouterCell] {
        let state: RouterCell = switch network.enabled {
        case .value(true): RouterCell(text: "Active", tone: .healthy)
        case .value(false): RouterCell(text: "Disabled", tone: .unknown)
        default: RouterCell(text: RouterFormat.unknown, tone: .unknown)
        }
        let configured = radio.configuredChannel.map { $0 == 0 ? "Auto" : String($0) }
        let channel = network.enabled == .value(true) ? radio.currentChannel.map(String.init) ?? configured : configured
        let width = radio.widthMHz.map { "\($0) MHz" } ?? radio.htmode ?? RouterFormat.unknown
        let clients = WirelessStatus.clients(for: network, on: radio, onlineByBand: onlineByBand).map(String.init) ?? RouterFormat.dash
        return [
            RouterCell(text: network.ssid ?? RouterFormat.unknown),
            RouterCell(text: network.interface ?? RouterFormat.unknown, monospaced: true),
            state,
            RouterCell(text: radio.band?.rawValue ?? RouterFormat.unknown, monospaced: true),
            RouterCell(text: channel ?? RouterFormat.unknown, monospaced: true),
            RouterCell(text: width, monospaced: true),
            RouterCell(text: clients, monospaced: true),
            RouterCell(text: radio.txPower ?? RouterFormat.unknown, monospaced: true),
        ]
    }

    func summary(hostname: String?) -> String {
        var lines = ["Wi-Fi — \(hostname ?? "router")"]
        for metric in strip { lines.append("\(metric.title): \(metric.value) (\(metric.detail))") }
        for band in bands {
            lines.append("")
            lines.append("\(band.title)\(band.radio.isEmpty ? "" : " · \(band.radio)")")
            for row in band.rows {
                lines.append(zip(Self.columns, row).map { "\($0): \($1.text)" }.joined(separator: " · "))
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Multi-WAN

struct RouterMultiWANModel: Equatable {
    static let columns = ["Interface", "State", "Connection type", "Address", "Active", "Default", "Metric"]
    static let footnote = "Observations only. Multi-WAN policy is configured in the router UI."
    let multiWAN: [RouterRowModel]
    let activePath: [RouterRowModel]
    let rows: [[RouterCell]]
    let history: RouterRowModel

    init(internet: InternetStatus, tracker: WANPathTracker, locale: Locale = .current) {
        let status = MultiWANStatus.derive(from: internet)
        multiWAN = [
            RouterRowModel(label: "Mode", value: RouterFormat.unknown, tone: .unknown),
            RouterRowModel(label: "Telemetry", detail: "Multi-WAN telemetry is not exposed by this firmware.", value: "Unavailable"),
            RouterRowModel(label: "Path changes", detail: "Observed this session", value: tracker.changes.count.formatted()),
        ]
        activePath = [
            RouterRowModel(label: "Default route", value: status.activePath.map { "\($0.interface) · \($0.gateway)" } ?? RouterFormat.unknown, monospaced: true),
            RouterRowModel(label: "Failover", value: "Not configured"),
        ]
        rows = status.interfaces.map { interface in
            let state: RouterCell = switch interface.up {
            case .value(true): RouterCell(text: "Up", tone: .healthy)
            case .value(false): RouterCell(text: "Down", tone: .unknown)
            default: RouterCell(text: RouterFormat.unknown, tone: .unknown)
            }
            return [
                RouterCell(text: interface.name, monospaced: true),
                state,
                RouterCell(text: interface.connection == .ethernet ? "Ethernet" : RouterFormat.unknown),
                RouterCell(text: interface.address ?? RouterFormat.dash, monospaced: true),
                RouterCell(text: Self.flag(interface.active)),
                RouterCell(text: Self.flag(interface.isDefault)),
                RouterCell(text: { if case .value(let metric) = interface.metric { String(metric) } else { RouterFormat.dash } }(), monospaced: true),
            ]
        }
        let last = tracker.changes.last.map { "Last \(RouterFormat.dayTime($0, locale: locale))" }
        history = RouterRowModel(label: "Path changes observed", detail: "Recorded while Routewell is running.",
                                 value: tracker.changes.isEmpty ? "None" : [tracker.changes.count.formatted(), last].compactMap { $0 }.joined(separator: " · "))
    }

    private static func flag(_ value: Observed<Bool>) -> String {
        switch value { case .value(true): "Yes"; case .value(false): "No"; default: RouterFormat.dash }
    }

    func summary(hostname: String?) -> String {
        var lines = ["Multi-WAN — \(hostname ?? "router")"]
        for row in multiWAN + activePath { lines.append("\(row.label): \(row.value)") }
        for row in rows { lines.append(zip(Self.columns, row).map { "\($0): \($1.text)" }.joined(separator: " · ")) }
        lines.append("\(history.label): \(history.value)")
        lines.append(Self.footnote)
        return lines.joined(separator: "\n")
    }
}

// MARK: - SQM

struct RouterSQMModel: Equatable {
    /// SQM writes arrive in chunk 27. Until then every control is read-only.
    static let writesAvailable = false
    static let queueDisciplines = ["cake", "fq_codel"]

    let switchOn: Bool
    let queueDiscipline: String
    let upload: String
    let download: String
    /// Every control (switch, queue discipline, upload, download) is disabled
    /// unless the native API answered and writes exist. A `-32601` reply
    /// therefore disables them, not just the status text.
    let controlsDisabled: Bool
    let status: [RouterRowModel]
    let footnote: String
    let statusFootnote: String?

    init(capability: Capability, configuration: SQMConfiguration?, failure: RefreshFailureCategory?,
         legacyEnabled: Observed<Bool>, writesAvailable: Bool = RouterSQMModel.writesAvailable) {
        let enabled: Observed<Bool> = capability.state == .unsupported ? legacyEnabled : configuration?.enabled ?? legacyEnabled
        switchOn = enabled == .value(true)
        queueDiscipline = configuration?.queueDiscipline ?? "cake"
        upload = configuration?.upload ?? ""
        download = configuration?.download ?? ""
        controlsDisabled = !(capability.state == .supported && writesAvailable)

        let configurationRow: RouterRowModel = switch capability.state {
        case .supported: RouterRowModel(label: "Router configuration", value: "Available", tone: .healthy)
        case .unsupported: RouterRowModel(label: "Router configuration", value: "Unavailable", tone: .degraded)
        case .unknown:
            failure == nil ? RouterRowModel(label: "Router configuration", value: RouterFormat.unknown, tone: .unknown)
                : RouterRowModel(label: "Router configuration", value: "Could not be read", tone: .degraded)
        }
        let applied: String = if configuration?.enabled == .value(true), let up = configuration?.upload, let down = configuration?.download {
            "↑ \(up) Mbps · ↓ \(down) Mbps"
        } else { RouterFormat.dash }
        status = [
            configurationRow,
            RouterRowModel(label: "Applied limits", value: applied),
            RouterRowModel(label: "Last applied", detail: "By Routewell", value: "Never"),
        ]
        footnote = switch capability.state {
        case .supported: "Read from the router's native SQM API. Change SQM in the router UI; editing here arrives in a later update."
        case .unsupported: "This router does not offer the native SQM API. The switch shows the router's status flag; nothing here can be changed."
        case .unknown: "SQM could not be read yet. The controls stay disabled until the router answers."
        }
        statusFootnote = switch capability.state {
        case .supported: nil
        case .unsupported: "SQM configuration could not be read from the router: the method is not available on this firmware."
        case .unknown: failure == nil ? nil : "SQM configuration could not be read from the router. The last known values stay shown."
        }
    }
}

// MARK: - Firmware

struct RouterFirmwareModel: Equatable {
    let identity: [RouterRowModel]
    let statusRow: RouterRowModel
    let latest: String
    let releaseNotesAvailable: Bool
    let checking: Bool

    static let footnote = "Firmware identity is read-only. Upgrades are performed in the GL.iNet administration interface."
    static let checkDetail = "Checks availability only; nothing is downloaded or installed."

    init(router: RouterStatus, state: RouterController.FirmwareState?, locale: Locale = .current) {
        let check = state?.check
        identity = [
            RouterRowModel(label: "Router model", value: router.model ?? RouterFormat.unknown),
            RouterRowModel(label: "Current firmware", value: router.firmware ?? RouterFormat.unknown, monospaced: true),
        ]
        checking = state?.checking == true
        let checked = check.map { "Last checked \(RouterFormat.fullDate($0.checkedAt, locale: locale))" }
        statusRow = if checking {
            RouterRowModel(label: "Update status", detail: checked, value: "Checking…", tone: .inProgress)
        } else {
            switch check?.status {
            case nil: RouterRowModel(label: "Update status", detail: "Never checked", value: "Not checked", tone: .unknown)
            case .upToDate?: RouterRowModel(label: "Update status", detail: checked, value: "Up to date", tone: .healthy)
            case .updateAvailable?: RouterRowModel(label: "Update status", detail: checked, value: "Update available", tone: .attention)
            case .unableToCheck(let failure)?:
                RouterRowModel(label: "Update status", detail: [checked, Self.reason(failure)].compactMap { $0 }.joined(separator: " · "),
                               value: "Unable to check", tone: .degraded)
            }
        }
        latest = if case .value(let version)? = check?.latest { version } else { RouterFormat.dash }
        releaseNotesAvailable = check?.releaseNotes != nil
    }

    private static func reason(_ failure: FirmwareCheckFailure) -> String {
        switch failure {
        case .notSupported: "This firmware has no online check"
        case .ambiguousReply: "The router's reply did not say"
        case .failed(let category): category.failureCategory.message
        }
    }

    struct Lifecycle: Equatable {
        let baselineValue: String
        let checkValue: String
        let runCheckEnabled: Bool
        let footnote: String
        let differences: [RouterRowModel]
    }

    static func lifecycle(baseline: UpgradeBaseline?, check: PostUpgradeCheck?, locale: Locale = .current) -> Lifecycle {
        let baselineValue = baseline.map { "Saved \(RouterFormat.dayTime($0.capturedAt, locale: locale))" } ?? "None saved"
        guard let check else {
            return Lifecycle(baselineValue: baselineValue, checkValue: "Not run", runCheckEnabled: baseline != nil,
                             footnote: "No firmware lifecycle check has been run.", differences: [])
        }
        let changes = check.differences.count
        let value = changes == 0 ? "No changes" : "\(changes) change\(changes == 1 ? "" : "s")"
        return Lifecycle(
            baselineValue: baselineValue, checkValue: value, runCheckEnabled: baseline != nil,
            footnote: "Last check \(RouterFormat.dayTime(check.ranAt, locale: locale)) compared \(check.comparedFields) observed values with the baseline from \(RouterFormat.dayTime(check.baselineCapturedAt, locale: locale)).",
            differences: check.differences.map { difference in
                RouterRowModel(label: fieldName(difference.field), value: "\(difference.before ?? "Not observed") → \(difference.after ?? "Not observed")")
            })
    }

    static func fieldName(_ field: BaselineField) -> String {
        switch field {
        case .model: "Model"
        case .hostname: "Hostname"
        case .firmware: "Firmware"
        case .openWrt: "OpenWrt"
        case .kernel: "Kernel"
        case .architecture: "Architecture"
        case .lanAddress: "LAN address"
        case .wanProtocol: "WAN protocol"
        case .internetConnected: "Internet connected"
        case .adGuardVersion: "AdGuard Home version"
        case .adGuardRunning: "AdGuard Home running"
        case .sqmEnabled: "SQM enabled"
        case .wifiRadios: "Wi-Fi radios"
        case .wifiNetworksEnabled: "Wi-Fi networks enabled"
        case .clientsOnline: "Clients online"
        }
    }
}

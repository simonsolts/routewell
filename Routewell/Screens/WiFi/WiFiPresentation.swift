import Foundation
import RoutewellKit

/// Texts and geometry for the Wi-Fi screen. Values the router does not
/// report show "—".
enum WiFiFormat {
    static let dash = "—"

    static func band(_ band: WirelessBand?) -> String { RouterFormat.band(band) }

    static func short(_ band: WirelessBand) -> String {
        switch band { case .ghz2_4: "2.4"; case .ghz5: "5"; case .ghz6: "6" }
    }

    static func generation(_ generation: WiFiGeneration?, band: WirelessBand?) -> String? {
        switch generation {
        case .wifi7?: "Wi-Fi 7"
        case .wifi6?: band == .ghz6 ? "Wi-Fi 6E" : "Wi-Fi 6"
        case .wifi5?: "Wi-Fi 5"
        case .wifi4?: "Wi-Fi 4"
        case .legacy?: "Older Wi-Fi"
        case nil: nil
        }
    }

    static func strength(_ strength: SignalStrength) -> String {
        switch strength { case .strong: "Strong"; case .good: "Good"; case .fair: "Fair"; case .weak: "Weak" }
    }

    static func security(_ security: WiFiSecurity?) -> String {
        switch security {
        case .none?: "Open"
        case .wpa2?: "WPA2"
        case .wpa2WPA1?: "WPA/WPA2"
        case .wpa3?: "WPA3"
        case .wpa2WPA3?: "WPA2/WPA3"
        case .other(let text)?: text
        case nil: dash
        }
    }

    static func power(_ level: TxPowerLevel?) -> String {
        switch level {
        case .max?: "Max"
        case .high?: "High"
        case .medium?: "Medium"
        case .low?: "Low"
        case .other(let text)?: text
        case nil: dash
        }
    }

    /// "Phone A", "Phone A and Phone B", "A, B and C", "A, B and 3 others".
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Devices"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }

    static func devices(_ count: Int) -> String { "\(count) \(count == 1 ? "device" : "devices")" }

    static func deviceName(_ device: WiFiDevice) -> String { device.name ?? "Unnamed device" }

    /// Channel width text: "80 MHz", or "Auto width".
    static func width(_ radio: WirelessRadio) -> String {
        if let width = radio.widthMHz { return "\(width) MHz" }
        return radio.htmode?.lowercased() == "auto" ? "Auto width" : dash
    }

    /// The channel in use, else the configured one.
    static func channel(_ radio: WirelessRadio) -> Int? {
        radio.currentChannel ?? radio.configuredChannel.flatMap { $0 > 0 ? $0 : nil }
    }

    static func mode(_ radio: WirelessRadio) -> String {
        switch radio.isAutoChannel { case true?: "Auto"; case false?: "Manual"; case nil: dash }
    }

    /// GL's `hwmode` tokens as Wi-Fi versions.
    static func versions(_ hwmode: String?, band: WirelessBand?) -> String {
        switch hwmode {
        case "11b/g/n/ax/be"?, "11a/n/ac/ax/be"?: "All (4 to 7)"
        case "11ac/ax/be"?: "Wi-Fi 5 to 7"
        case "11ax/be"?: band == .ghz6 ? "Wi-Fi 6E and 7" : "Wi-Fi 6 and 7"
        case let other?: other
        case nil: dash
        }
    }
}

// MARK: - Overview

struct WiFiOverviewPresentation {
    struct Sector: Equatable {
        let band: WirelessBand
        let count: Int
        var label: String { count == 0 ? "Not used" : "\(count)" }
    }

    struct Dot: Equatable, Identifiable {
        let device: WiFiDevice
        /// In the fan's 500 × 268 space.
        let x: Double
        let y: Double
        var id: MACAddress { device.mac }
    }

    struct NetworkCard: Equatable, Identifiable {
        let name: String
        let kind: WiFiNetworkKind
        let multiLink: Bool
        let secured: Bool
        let bands: [WirelessBand]
        let count: String
        var id: String { "\(kind)-\(multiLink)-\(name)" }
    }

    struct RadioTile: Equatable, Identifiable {
        let band: WirelessBand
        let now: String
        let mode: String
        /// Fractions of the strip's width.
        let block: ClosedRange<Double>?
        let dfs: ClosedRange<Double>?
        var id: WirelessBand { band }
    }

    struct SuggestionLine: Equatable, Identifiable {
        enum Action: Equatable { case radios, multiLink }
        let suggestion: WiFiSuggestion
        let title: String
        let action: (label: String, target: Action)?
        var id: WiFiSuggestion.Kind { suggestion.kind }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.suggestion == rhs.suggestion && lhs.title == rhs.title && lhs.action?.label == rhs.action?.label && lhs.action?.target == rhs.action?.target
        }
    }

    static let center = (x: 250.0, y: 248.0)
    /// Degrees from the fan's left edge, per band.
    static let sectors: [WirelessBand: (from: Double, to: Double)] = [.ghz2_4: (179, 121), .ghz5: (119, 61), .ghz6: (59, 1)]
    /// The radius for "unknown signal".
    static let unknownRadius = 120.0

    let deviceCount: Int
    /// "No weak signals", "2 weak signals", or `nil` without signal.
    let signalLine: String?
    let hasWeak: Bool
    let showsRings: Bool
    let sectorLabels: [Sector]
    let dots: [Dot]
    let cards: [NetworkCard]
    let addTiles: [WiFiOverview.Missing]
    let radios: [RadioTile]
    let suggestions: [SuggestionLine]

    init(overview: WiFiOverview, wireless: WirelessStatus, suggestions: [WiFiSuggestion]) {
        let devices = overview.devices
        deviceCount = devices.count
        showsRings = overview.hasStations
        let weak = devices.filter { $0.strength == .weak }.count
        hasWeak = weak > 0
        signalLine = overview.hasStations ? (weak == 0 ? "No weak signals" : "\(weak) weak \(weak == 1 ? "signal" : "signals")") : nil
        sectorLabels = WirelessBand.allCases.map { band in Sector(band: band, count: devices.filter { $0.band == band }.count) }
        dots = Self.layout(devices)

        var cards = overview.groups.map { group in
            NetworkCard(name: group.name, kind: group.kind, multiLink: false, secured: group.security?.isSecured ?? true, bands: group.bands,
                        count: group.deviceCount.map(String.init) ?? WiFiFormat.dash)
        }
        if let link = overview.multiLink {
            let members = devices.filter { $0.network == link.ssid && $0.kind == .main }.count
            let count = overview.hasStations ? String(members) : WiFiFormat.dash
            let card = NetworkCard(name: link.ssid ?? WiFiFormat.dash, kind: .main, multiLink: true,
                                   secured: link.encryption?.isSecured ?? true, bands: link.bands, count: count)
            let lastMain = cards.lastIndex { $0.kind == .main }
            cards.insert(card, at: lastMain.map { $0 + 1 } ?? 0)
        }
        self.cards = cards
        addTiles = overview.missing
        radios = wireless.radios.compactMap(Self.tile)

        let names = Dictionary(devices.map { ($0.mac, WiFiFormat.deviceName($0)) }, uniquingKeysWith: { first, _ in first })
        self.suggestions = suggestions.map { suggestion in
            let who = WiFiFormat.names(suggestion.devices.compactMap { names[$0] })
            return switch suggestion {
            case .fasterBand: SuggestionLine(suggestion: suggestion, title: "\(who) can use a faster band", action: nil)
            case .multiLinkReady(let macs):
                SuggestionLine(suggestion: suggestion, title: "Multi-link is ready for \(macs.count) Wi-Fi 7 \(macs.count == 1 ? "device" : "devices")",
                               action: ("Set Up…", .multiLink))
            case .ownNetwork(let macs):
                SuggestionLine(suggestion: suggestion, title: "\(who) can move to \(macs.count == 1 ? "its" : "their") own network", action: nil)
            case .dfsChannels: SuggestionLine(suggestion: suggestion, title: "5 GHz can use more channels with DFS", action: ("Review", .radios))
            }
        }
    }

    /// One dot per device: angle spreads the band's devices across its sector,
    /// radius grows as the signal weakens.
    static func layout(_ devices: [WiFiDevice]) -> [Dot] {
        var dots: [Dot] = []
        for band in WirelessBand.allCases {
            let members = devices.filter { $0.band == band }
            guard let sector = sectors[band] else { continue }
            for (index, device) in members.enumerated() {
                let degrees = sector.from - Double(index + 1) * (sector.from - sector.to) / Double(members.count + 1)
                let radius = device.signal.map(radius(dBm:)) ?? unknownRadius
                let angle = degrees * .pi / 180
                dots.append(Dot(device: device, x: center.x + radius * cos(angle), y: center.y - radius * sin(angle)))
            }
        }
        return dots
    }

    static func radius(dBm: Int) -> Double { min(240, max(30, 30 + Double(-dBm - 40) * 5.6)) }

    static func tooltip(_ device: WiFiDevice) -> String {
        let line1 = [device.network ?? WiFiFormat.dash, WiFiFormat.band(device.band), WiFiFormat.generation(device.generation, band: device.band)]
            .compactMap { $0 }.joined(separator: " · ")
        var line2 = device.signal.map { dBm in "\(WiFiFormat.strength(SignalStrength(dBm: dBm))) signal (\(dBm) dBm)" } ?? "Signal \(WiFiFormat.dash)"
        if device.canUseFasterBand { line2 += " · can use a faster band" }
        return [WiFiFormat.deviceName(device), line1, line2].joined(separator: "\n")
    }

    static func accessibilityLabel(_ device: WiFiDevice) -> String {
        [WiFiFormat.deviceName(device), WiFiFormat.band(device.band), device.signal.map { "\($0) dBm" } ?? "signal unknown"].joined(separator: ", ")
    }

    static func tile(_ radio: WirelessRadio) -> RadioTile? {
        guard let band = radio.band else { return nil }
        let channel = WiFiFormat.channel(radio)
        let now = "\(channel.map { "Ch \($0)" } ?? "Ch \(WiFiFormat.dash)") · \(WiFiFormat.width(radio))"
        let lane = WiFiLane(radio: radio, autoSkips: nil)
        return RadioTile(band: band, now: now, mode: WiFiFormat.mode(radio), block: lane.blockFraction, dfs: lane.dfsFraction)
    }
}

// MARK: - Radios

/// One Radios lane: the channel ruler, the block for the channel in use and
/// its width, the DFS area, and the channels Auto skips.
struct WiFiLane: Equatable {
    let band: WirelessBand?
    let channels: [WirelessChannel]
    let block: [Int]?
    let autoSkips: Set<Int>
    let isAuto: Bool

    init(radio: WirelessRadio, autoSkips: [Int]?) {
        band = radio.band
        channels = radio.channels
        isAuto = radio.isAutoChannel ?? false
        self.autoSkips = Set(autoSkips ?? [])
        block = WiFiFormat.channel(radio).flatMap { Self.block(band: radio.band, channel: $0, width: radio.widthMHz ?? 20, channels: radio.channels.map(\.number)) }
    }

    /// The channels a width covers around `channel`, as GL's bonding groups
    /// them; `nil` when the block does not fit the channel list.
    static func block(band: WirelessBand?, channel: Int, width: Int, channels: [Int]) -> [Int]? {
        guard channels.contains(channel) else { return nil }
        if band == .ghz2_4 {
            let low = width == 40 ? (channel >= 5 ? channel - 6 : channel - 2) : channel - 2
            let high = width == 40 ? (channel >= 5 ? channel + 2 : channel + 6) : channel + 2
            let covered = channels.filter { $0 >= low && $0 <= high }
            return covered.isEmpty ? nil : covered
        }
        let size = max(1, width / 20)
        guard let index = channels.firstIndex(of: channel) else { return nil }
        // 5 GHz has a gap between 64 and 100; groups never cross it.
        let segment: [Int] = band == .ghz5 && channel >= 100 ? channels.filter { $0 >= 100 } : band == .ghz5 ? channels.filter { $0 < 100 } : channels
        let position = segment.firstIndex(of: channel) ?? index
        let start = (position / size) * size
        guard start + size <= segment.count else { return [channel] }
        return Array(segment[start ..< start + size])
    }

    func fraction(_ numbers: [Int]) -> ClosedRange<Double>? {
        let all = channels.map(\.number)
        guard let first = numbers.first.flatMap(all.firstIndex(of:)), let last = numbers.last.flatMap(all.firstIndex(of:)), !all.isEmpty else { return nil }
        return Double(first) / Double(all.count) ... Double(last + 1) / Double(all.count)
    }

    var blockFraction: ClosedRange<Double>? { block.flatMap(fraction) }
    var dfsFraction: ClosedRange<Double>? {
        let dfs = channels.filter(\.dfs).map(\.number)
        return dfs.isEmpty ? nil : fraction(dfs)
    }

    func skipped(_ channel: Int) -> Bool { isAuto && autoSkips.contains(channel) }
}

struct WiFiRadioInspector: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        var help: String? = nil
    }

    let band: WirelessBand
    let deviceLine: String
    let rows: [Row]
    let advanced: [Row]
    /// Devices on the band by signal, 0 (strong) to 1 (weak); `nil` without signal.
    let ruler: [(name: String, position: Double, weak: Bool)]?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.band == rhs.band && lhs.deviceLine == rhs.deviceLine && lhs.rows == rhs.rows && lhs.advanced == rhs.advanced
            && lhs.ruler?.map(\.name) == rhs.ruler?.map(\.name) && lhs.ruler?.map(\.position) == rhs.ruler?.map(\.position)
    }

    init(radio: WirelessRadio, band: WirelessBand, devices: [WiFiDevice], air: WiFiAir?) {
        self.band = band
        let onBand = devices.filter { $0.band == band }
        deviceLine = onBand.isEmpty ? "No devices" : WiFiFormat.devices(onBand.count)
        let channel = WiFiFormat.channel(radio).map(String.init) ?? WiFiFormat.dash
        var rows = [
            Row(label: "Channel", value: radio.isAutoChannel == true ? "Auto · \(channel)" : channel,
                help: "Auto picks the channel when the radio starts. Grey numbers are channels that Auto does not use."),
            Row(label: "Width", value: WiFiFormat.width(radio)),
        ]
        if band == .ghz5 {
            let dfs = radio.channels.filter(\.dfs).map(\.number)
            let value: String = if let skips = air?.autoSkips(device: radio.device) {
                dfs.allSatisfy(skips.contains) ? "Off" : "On"
            } else { WiFiFormat.dash }
            rows.append(Row(label: "DFS channels", value: value,
                            help: "Shared with weather radar. If radar shows up, the router moves to another channel."))
        }
        if band == .ghz6 {
            let value = radio.pscOnly.map { $0 ? "On" : "Off" } ?? WiFiFormat.dash
            rows.append(Row(label: "Preferred channels only", value: value,
                            help: "Devices find the network faster on preferred scanning channels (5, 21, 37, 53, 69, 85)."))
        }
        rows.append(Row(label: "Power", value: WiFiFormat.power(radio.txPowerLevel),
                        help: "Lower power covers a smaller area. The dots show each device's signal now."))
        self.rows = rows
        advanced = [Row(label: "Wi-Fi versions", value: WiFiFormat.versions(radio.hwmode, band: band))]

        let measured = onBand.compactMap { device in device.signal.map { (WiFiFormat.deviceName(device), $0) } }
        if measured.isEmpty, onBand.contains(where: { $0.signal == nil }) {
            ruler = nil
        } else {
            ruler = measured.map { name, dBm in
                let position = min(0.98, max(0.02, Double(-dBm - 40) / 45))
                return (name: name, position: position, weak: dBm < -70)
            }
        }
    }
}

// MARK: - Multi-link

struct WiFiMultiLinkPresentation: Equatable {
    struct Card: Equatable, Identifiable {
        let mac: MACAddress
        let name: String
        let sub: String
        /// Gbit/s, one decimal.
        let rate: String
        let band: WirelessBand?
        let fraction: Double
        let legend: String
        var id: MACAddress { mac }
    }

    /// The scale of the bars, in Mbit/s.
    static let scale = 4_400.0

    let isOn: Bool
    let name: String?
    let bands: [WirelessBand]
    let cards: [Card]
    let others: Int
    let subtitle: String
    let linkMode: String

    init(mlo: MLOConfiguration, devices: [WiFiDevice], air: WiFiAir?) {
        let network = mlo.main
        let on = network?.isOn == true
        isOn = on
        name = network?.ssid
        let bands = network?.bands ?? []
        self.bands = bands
        let wifi7 = devices.filter { $0.generation == .wifi7 }
        let members = on ? devices.filter { $0.network == network?.ssid && $0.kind == .main } : wifi7
        cards = members.map { device in
            let megabits = device.rate?.megabitsPerSecond
            let rate = megabits.map { String(format: "%.1f", $0 / 1000) } ?? WiFiFormat.dash
            let signal = device.strength.map(WiFiFormat.strength) ?? WiFiFormat.dash
            return Card(mac: device.mac, name: WiFiFormat.deviceName(device),
                        sub: on ? WiFiFormat.band(device.band) : "Wi-Fi 7 · one band now", rate: rate, band: device.band,
                        fraction: min(1, (megabits ?? 0) / Self.scale),
                        legend: "\(WiFiFormat.band(device.band)) · \(rate) Gbps · \(signal)")
        }
        others = max(0, devices.count - members.count)
        let count = members.count
        subtitle = on
            ? "Multi-link on \(bands.map(WiFiFormat.band).joined(separator: " + ")) · \(WiFiFormat.devices(count))"
            : (count == 0 ? "No device uses Wi-Fi 7 now." : "\(count) of your devices can use two bands at the same time.")
        let interfaceModes = air?.sections?.compactMap(\.emlMode) ?? []
        linkMode = interfaceModes.first.map { $0.uppercased() } ?? WiFiFormat.dash
    }
}

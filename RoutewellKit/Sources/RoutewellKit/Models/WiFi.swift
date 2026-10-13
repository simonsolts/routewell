import Foundation

// MARK: - Bands and radios

public enum WirelessBand: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Comparable {
    case ghz2_4 = "2g", ghz5 = "5g", ghz6 = "6g"

    /// `wifi get_status` `band` is `2g`, `5g`, or `6g`;
    /// `clients get_list` `iface` is `2.4G`, `5G`, or `6G`.
    /// Anything else stays unknown.
    public static func parse(_ token: String?) -> WirelessBand? {
        switch token?.lowercased() {
        case "2g", "2.4g": .ghz2_4
        case "5g": .ghz5
        case "6g": .ghz6
        default: nil
        }
    }

    /// The band of a centre frequency in MHz.
    public static func from(megahertz: Int) -> WirelessBand? {
        switch megahertz {
        case 2400..<2500: .ghz2_4
        case 4900..<5925: .ghz5
        case 5925..<7200: .ghz6
        default: nil
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One channel a radio offers, from `wifi get_config` `channels[]`.
public struct WirelessChannel: Sendable, Equatable, Hashable {
    public var number: Int
    public var dfs: Bool
    /// A 6 GHz preferred scanning channel.
    public var psc: Bool

    public init(_ number: Int, dfs: Bool = false, psc: Bool = false) {
        self.number = number
        self.dfs = dfs
        self.psc = psc
    }
}

/// `txpower` as GL shows it. Anything else stays verbatim.
public enum TxPowerLevel: Sendable, Equatable {
    case max, high, medium, low
    case other(String)

    public static func parse(_ text: String?) -> TxPowerLevel? {
        guard let text, !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "max": return .max
        case "high": return .high
        case "medium": return .medium
        case "low": return .low
        default: return .other(text)
        }
    }

    /// The likely loss against Max in dB, for the signal ruler.
    public var decibelsBelowMax: Double? {
        switch self {
        case .max: 0
        case .high: -1.2
        case .medium: -3
        case .low: -6
        case .other: nil
        }
    }
}

/// `wifi get_status` `state`.
public enum RadioState: Sendable, Equatable {
    case starting, cac, conflict, ready
    case other(String)

    public static func parse(_ text: String?) -> RadioState? {
        guard let text, !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "starting": return .starting
        case "cac": return .cac
        case "conflict": return .conflict
        case "ready": return .ready
        default: return .other(text)
        }
    }
}

/// `encryption`. GL offers `none`, `psk2`, `psk-mixed`, `sae`, `sae-mixed`.
public enum WiFiSecurity: Sendable, Equatable, Hashable {
    case none, wpa2, wpa2WPA1, wpa3, wpa2WPA3
    case other(String)

    public static func parse(_ text: String?) -> WiFiSecurity? {
        guard let text, !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "none": return WiFiSecurity.none
        case "psk2": return .wpa2
        case "psk-mixed": return .wpa2WPA1
        case "sae": return .wpa3
        case "sae-mixed": return .wpa2WPA3
        default: return .other(text)
        }
    }

    public var isSecured: Bool { self != .none }
}

/// A network key from `get_config` or `get_mlo_config`. It is never
/// encoded, logged, or printed: every text form is redacted.
public struct WiFiPassword: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) { self.value = value }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum WiFiNetworkKind: Sendable, Equatable, Hashable {
    case main, guest, iot
}

/// One network slot on a radio, from `wifi get_config` `res[].ifaces[]`.
public struct WirelessNetwork: Sendable, Equatable {
    public var interface: String?
    public var ssid: String?
    public var enabled: Observed<Bool>
    public var guest: Bool?
    public var iot: Bool?
    public var encryption: WiFiSecurity?
    public var hidden: Bool?
    public var randomBSSID: Bool?
    /// `init`: the slot was set up once.
    public var initialised: Bool?
    public var password: WiFiPassword?

    public init(interface: String? = nil, ssid: String? = nil, enabled: Observed<Bool> = .unknown, guest: Bool? = nil, iot: Bool? = nil,
                encryption: WiFiSecurity? = nil, hidden: Bool? = nil, randomBSSID: Bool? = nil, initialised: Bool? = nil,
                password: WiFiPassword? = nil) {
        self.interface = interface
        self.ssid = ssid
        self.enabled = enabled
        self.guest = guest
        self.iot = iot
        self.encryption = encryption
        self.hidden = hidden
        self.randomBSSID = randomBSSID
        self.initialised = initialised
        self.password = password
    }

    /// `nil` when the router reported neither flag.
    public var kind: WiFiNetworkKind? {
        if iot == true { return .iot }
        if guest == true { return .guest }
        return guest == nil && iot == nil ? nil : .main
    }

    public var isOn: Bool { enabled == .value(true) }
}

/// One radio from `wifi get_config` `res[]`, joined by band with
/// `wifi get_status` `res[]`.
public struct WirelessRadio: Sendable, Equatable {
    public var device: String?
    public var band: WirelessBand?
    /// The configured channel; `0` means automatic selection.
    public var configuredChannel: Int?
    /// The channel `wifi get_status` reports for this band.
    public var currentChannel: Int?
    /// Verbatim: `auto`, `80`, or `160` on 4.9.2.
    public var htmode: String?
    /// Verbatim (`Max`); never converted.
    public var txPower: String?
    public var networks: [WirelessNetwork]
    public var channels: [WirelessChannel]
    /// The widths in MHz the current Wi-Fi standard allows, smallest first.
    public var widthOptions: [Int]
    /// `htmodes.auto`: the radio offers Auto width.
    public var autoWidth: Bool?
    public var hwmode: String?
    public var hwmodeOptions: [String]
    public var securityOptions: [WiFiSecurity]
    /// `chan_6g_only_psc`.
    public var pscOnly: Bool?
    public var state: RadioState?

    public init(device: String? = nil, band: WirelessBand? = nil, configuredChannel: Int? = nil, currentChannel: Int? = nil,
                htmode: String? = nil, txPower: String? = nil, networks: [WirelessNetwork] = [], channels: [WirelessChannel] = [],
                widthOptions: [Int] = [], autoWidth: Bool? = nil, hwmode: String? = nil, hwmodeOptions: [String] = [],
                securityOptions: [WiFiSecurity] = [], pscOnly: Bool? = nil, state: RadioState? = nil) {
        self.device = device
        self.band = band
        self.configuredChannel = configuredChannel
        self.currentChannel = currentChannel
        self.htmode = htmode
        self.txPower = txPower
        self.networks = networks
        self.channels = channels
        self.widthOptions = widthOptions
        self.autoWidth = autoWidth
        self.hwmode = hwmode
        self.hwmodeOptions = hwmodeOptions
        self.securityOptions = securityOptions
        self.pscOnly = pscOnly
        self.state = state
    }

    /// Channel width in MHz from the digits at the end of `htmode`
    /// (`80` on 4.9.2, `VHT80` elsewhere). `nil` for `auto`.
    public var widthMHz: Int? {
        guard let htmode, let digits = htmode.firstMatch(of: /(\d+)$/)?.1 else { return nil }
        return Int(digits)
    }

    public var isAutoChannel: Bool? { configuredChannel.map { $0 == 0 } }
    public var txPowerLevel: TxPowerLevel? { TxPowerLevel.parse(txPower) }
    /// The band's main network: the slot that is neither guest nor IoT.
    public var mainNetwork: WirelessNetwork? { networks.first { $0.kind == .main } }
}

public struct WirelessStatus: Sendable, Equatable {
    public var radios: [WirelessRadio]
    /// `dfs_support`.
    public var dfsSupport: Bool?

    public init(radios: [WirelessRadio] = [], dfsSupport: Bool? = nil) {
        self.radios = radios
        self.dfsSupport = dfsSupport
    }

    public var networks: [WirelessNetwork] { radios.flatMap(\.networks) }
    public var enabledNetworkCount: Int { networks.filter(\.isOn).count }

    public func radio(_ band: WirelessBand) -> WirelessRadio? { radios.first { $0.band == band } }

    /// A band's online client count belongs to one SSID only when exactly
    /// one SSID on that band is enabled; the router reports no per-SSID count.
    public static func clients(for network: WirelessNetwork, on radio: WirelessRadio, onlineByBand: [WirelessBand: Int]?) -> Int? {
        guard let band = radio.band, let count = onlineByBand?[band] else { return nil }
        guard network.isOn else { return network.enabled == .value(false) ? 0 : nil }
        let enabled = radio.networks.filter(\.isOn)
        return enabled.count == 1 ? count : nil
    }
}

// MARK: - Multi-link and subnets

/// `wifi get_mlo_config`.
public struct MLOConfiguration: Sendable, Equatable {
    public var supportedBands: [WirelessBand]
    public var networks: [MLONetwork]

    public init(supportedBands: [WirelessBand] = [], networks: [MLONetwork] = []) {
        self.supportedBands = supportedBands
        self.networks = networks
    }

    /// The main (not guest) multi-link network.
    public var main: MLONetwork? { networks.first { $0.guest != true } }
}

public struct MLONetwork: Sendable, Equatable {
    /// `mld0` and so on.
    public var name: String?
    public var enabled: Observed<Bool>
    public var bands: [WirelessBand]
    public var ssid: String?
    public var encryption: WiFiSecurity?
    public var hidden: Bool?
    public var randomBSSID: Bool?
    public var guest: Bool?
    public var initialised: Bool?
    public var password: WiFiPassword?

    public init(name: String? = nil, enabled: Observed<Bool> = .unknown, bands: [WirelessBand] = [], ssid: String? = nil,
                encryption: WiFiSecurity? = nil, hidden: Bool? = nil, randomBSSID: Bool? = nil, guest: Bool? = nil,
                initialised: Bool? = nil, password: WiFiPassword? = nil) {
        self.name = name
        self.enabled = enabled
        self.bands = bands
        self.ssid = ssid
        self.encryption = encryption
        self.hidden = hidden
        self.randomBSSID = randomBSSID
        self.guest = guest
        self.initialised = initialised
        self.password = password
    }

    /// Set up and switched on.
    public var isOn: Bool { enabled == .value(true) && initialised != false }
}

/// `wan_access_mode` of a guest or IoT subnet.
public enum WANAccessMode: Sendable, Equatable {
    case unrestricted, blockWANSubnet, blockInternet
    case other(Int)

    public static func parse(_ value: Int?) -> WANAccessMode? {
        switch value {
        case 0?: .unrestricted
        case 1?: .blockWANSubnet
        case 2?: .blockInternet
        case let value?: .other(value)
        case nil: nil
        }
    }
}

/// One fixed subnet from `vlan_subnet get_subnets`. Every field the router
/// sent stays in `fields`, so a later write can send it back.
public struct SubnetPolicy: Sendable, Equatable {
    /// `main`, `guest`, or `iot` from `display_name`, lower case.
    public var name: String?
    public var enabled: Observed<Bool>
    public var isolate: Bool?
    public var wanAccess: WANAccessMode?
    public var address: String?
    public var netmask: String?
    public var fields: [String: JSONValue]

    public init(name: String? = nil, enabled: Observed<Bool> = .unknown, isolate: Bool? = nil, wanAccess: WANAccessMode? = nil,
                address: String? = nil, netmask: String? = nil, fields: [String: JSONValue] = [:]) {
        self.name = name
        self.enabled = enabled
        self.isolate = isolate
        self.wanAccess = wanAccess
        self.address = address
        self.netmask = netmask
        self.fields = fields
    }
}

/// One Wi-Fi read over RPC. A failed part fails only that part.
public struct WiFiSnapshot: Sendable, Equatable {
    public var wireless: Result<WirelessStatus, RefreshFailureCategory>
    public var mlo: Result<MLOConfiguration, RefreshFailureCategory>
    public var subnets: Result<[SubnetPolicy], RefreshFailureCategory>

    public init(wireless: Result<WirelessStatus, RefreshFailureCategory>,
                mlo: Result<MLOConfiguration, RefreshFailureCategory> = .failure(.unavailable),
                subnets: Result<[SubnetPolicy], RefreshFailureCategory> = .failure(.unavailable)) {
        self.wireless = wireless
        self.mlo = mlo
        self.subnets = subnets
    }
}

/// One `WiFiService.snapshot()`. `capability` is unsupported only after
/// `-32601` on `wifi get_config`.
public struct WiFiSnapshotResult: Sendable {
    public var area: AreaRefreshResult<WiFiSnapshot>
    public var capability: Capability

    public init(area: AreaRefreshResult<WiFiSnapshot>, capability: Capability) {
        self.area = area
        self.capability = capability
    }
}

// MARK: - Stations (SSH)

/// The Wi-Fi standard a link uses now, from the `tx bitrate` tokens. It is
/// not what the device can do.
public enum WiFiGeneration: Int, Sendable, Equatable, Comparable {
    case legacy = 3, wifi4, wifi5, wifi6, wifi7

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One `tx bitrate` or `rx bitrate` line of `iw station dump`.
public struct WiFiRate: Sendable, Equatable {
    public var megabitsPerSecond: Double?
    public var widthMHz: Int?
    public var mcs: Int?
    public var spatialStreams: Int?
    public var generation: WiFiGeneration?

    public init(megabitsPerSecond: Double? = nil, widthMHz: Int? = nil, mcs: Int? = nil, spatialStreams: Int? = nil,
                generation: WiFiGeneration? = nil) {
        self.megabitsPerSecond = megabitsPerSecond
        self.widthMHz = widthMHz
        self.mcs = mcs
        self.spatialStreams = spatialStreams
        self.generation = generation
    }
}

public struct WiFiStation: Sendable, Equatable {
    public var interface: String
    public var band: WirelessBand?
    public var mac: MACAddress
    /// dBm.
    public var signal: Int?
    public var txRate: WiFiRate?
    public var rxRate: WiFiRate?
    public var connectedSeconds: Int?
    public var inactiveMilliseconds: Int?

    public init(interface: String, band: WirelessBand? = nil, mac: MACAddress, signal: Int? = nil, txRate: WiFiRate? = nil,
                rxRate: WiFiRate? = nil, connectedSeconds: Int? = nil, inactiveMilliseconds: Int? = nil) {
        self.interface = interface
        self.band = band
        self.mac = mac
        self.signal = signal
        self.txRate = txRate
        self.rxRate = rxRate
        self.connectedSeconds = connectedSeconds
        self.inactiveMilliseconds = inactiveMilliseconds
    }

    public var generation: WiFiGeneration? { txRate?.generation ?? rxRate?.generation }
}

/// One access point interface from `iw dev`.
public struct WiFiInterface: Sendable, Equatable {
    public var name: WiFiInterfaceName
    public var band: WirelessBand?
    public var channel: Int?

    public init(name: WiFiInterfaceName, band: WirelessBand? = nil, channel: Int? = nil) {
        self.name = name
        self.band = band
        self.channel = channel
    }
}

/// The options of one `wireless` UCI section that no RPC reports.
public struct WirelessSectionOptions: Sendable, Equatable {
    public var section: String
    /// `wifi-device` or `wifi-iface`.
    public var type: String?
    public var ifname: String?
    /// Channels Auto does not use (`acs_skiplist`).
    public var autoSkips: [Int]?
    public var dfsEnabled: Bool?
    public var emlMode: String?
    public var ieee80211k: Bool?
    public var bssTransition: Bool?
    public var ieee80211r: Bool?

    public init(section: String, type: String? = nil, ifname: String? = nil, autoSkips: [Int]? = nil, dfsEnabled: Bool? = nil,
                emlMode: String? = nil, ieee80211k: Bool? = nil, bssTransition: Bool? = nil, ieee80211r: Bool? = nil) {
        self.section = section
        self.type = type
        self.ifname = ifname
        self.autoSkips = autoSkips
        self.dfsEnabled = dfsEnabled
        self.emlMode = emlMode
        self.ieee80211k = ieee80211k
        self.bssTransition = bssTransition
        self.ieee80211r = ieee80211r
    }
}

/// One Wi-Fi read over SSH. Each part is `nil` when its read failed.
public struct WiFiAir: Sendable, Equatable {
    public var interfaces: [WiFiInterface]?
    public var stations: [WiFiStation]?
    public var sections: [WirelessSectionOptions]?

    public init(interfaces: [WiFiInterface]? = nil, stations: [WiFiStation]? = nil, sections: [WirelessSectionOptions]? = nil) {
        self.interfaces = interfaces
        self.stations = stations
        self.sections = sections
    }

    /// Auto's skipped channels for the radio section `device`.
    public func autoSkips(device: String?) -> [Int]? {
        guard let device else { return nil }
        return sections?.first { $0.section == device }?.autoSkips
    }
}

import Foundation

// MARK: - Wi-Fi

public enum WirelessBand: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Comparable {
    case ghz2_4 = "2g", ghz5 = "5g", ghz6 = "6g"

    /// `wifi get_status` `band` is `2g`, `5g`, or `6g` `[verified live]`;
    /// `clients get_list` `iface` is `2.4G`, `5G`, or `6G` `[verified live]`.
    /// Anything else stays unknown.
    public static func parse(_ token: String?) -> WirelessBand? {
        switch token?.lowercased() {
        case "2g", "2.4g": .ghz2_4
        case "5g": .ghz5
        case "6g": .ghz6
        default: nil
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One SSID on a radio, from `wifi get_config` `res[].ifaces[]`: `name`,
/// `ssid`, `enabled`, `guest`, `iot`, `hidden` `[verified live]` keys.
public struct WirelessNetwork: Sendable, Equatable {
    public var interface: String?
    public var ssid: String?
    public var enabled: Observed<Bool>
    public var guest: Bool?
    public var iot: Bool?

    public init(interface: String? = nil, ssid: String? = nil, enabled: Observed<Bool> = .unknown, guest: Bool? = nil, iot: Bool? = nil) {
        self.interface = interface
        self.ssid = ssid
        self.enabled = enabled
        self.guest = guest
        self.iot = iot
    }
}

/// One radio from `wifi get_config` `res[]` (`device`, `band`, `channel`,
/// `htmode`, `txpower`, `ifaces` `[verified live]` keys), joined by band
/// with `wifi get_status` `res[].channel` `[verified live]`.
public struct WirelessRadio: Sendable, Equatable {
    public var device: String?
    public var band: WirelessBand?
    /// The configured channel; `0` means automatic selection `[assumed]`.
    public var configuredChannel: Int?
    /// The channel `wifi get_status` reports for this band.
    public var currentChannel: Int?
    /// Verbatim: `auto`, `80`, or `160` on 4.9.1 `[verified live]`.
    public var htmode: String?
    /// Verbatim (`Max` on 4.9.1 `[verified live]`); never converted.
    public var txPower: String?
    public var networks: [WirelessNetwork]

    public init(device: String? = nil, band: WirelessBand? = nil, configuredChannel: Int? = nil, currentChannel: Int? = nil,
                htmode: String? = nil, txPower: String? = nil, networks: [WirelessNetwork] = []) {
        self.device = device
        self.band = band
        self.configuredChannel = configuredChannel
        self.currentChannel = currentChannel
        self.htmode = htmode
        self.txPower = txPower
        self.networks = networks
    }

    /// Channel width in MHz from the digits at the end of `htmode`
    /// (`80` on 4.9.1, `VHT80` elsewhere). `nil` for `auto`.
    public var widthMHz: Int? {
        guard let htmode, let digits = htmode.firstMatch(of: /(\d+)$/)?.1 else { return nil }
        return Int(digits)
    }
}

public struct WirelessStatus: Sendable, Equatable {
    public var radios: [WirelessRadio]

    public init(radios: [WirelessRadio] = []) { self.radios = radios }

    public var networks: [WirelessNetwork] { radios.flatMap(\.networks) }
    public var enabledNetworkCount: Int { networks.filter { $0.enabled == .value(true) }.count }

    /// A band's online client count belongs to one SSID only when exactly
    /// one SSID on that band is enabled; the router reports no per-SSID count.
    public static func clients(for network: WirelessNetwork, on radio: WirelessRadio, onlineByBand: [WirelessBand: Int]?) -> Int? {
        guard let band = radio.band, let count = onlineByBand?[band] else { return nil }
        guard network.enabled == .value(true) else { return network.enabled == .value(false) ? 0 : nil }
        let enabled = radio.networks.filter { $0.enabled == .value(true) }
        return enabled.count == 1 ? count : nil
    }
}

// MARK: - SQM

/// `sqm get_config`: `enable`, `qdisc`, `upload`, `download` `[verified live]`
/// keys. On 4.9.1 `upload` and `download` are strings, empty when unset;
/// they stay verbatim because their unit is `[assumed]`.
public struct SQMConfiguration: Sendable, Equatable {
    public var enabled: Observed<Bool>
    public var queueDiscipline: String?
    public var upload: String?
    public var download: String?

    public init(enabled: Observed<Bool> = .unknown, queueDiscipline: String? = nil, upload: String? = nil, download: String? = nil) {
        self.enabled = enabled
        self.queueDiscipline = queueDiscipline
        self.upload = upload
        self.download = download
    }
}

// MARK: - Firmware

public enum FirmwareCheckFailure: Sendable, Equatable {
    /// `-32601`: this firmware has no online check.
    case notSupported
    /// The reply said neither "available" nor "current". Never read as up to date.
    case ambiguousReply
    case failed(RefreshFailureCategory)
}

public enum FirmwareUpdateStatus: Sendable, Equatable {
    case upToDate, updateAvailable
    case unableToCheck(FirmwareCheckFailure)
}

/// One `upgrade check_firmware_online` result. `current_version` is
/// `[verified live]`; `new_firmware_version`, `update_available`, and
/// `release_note(s)` are `[verified in source]`: 4.9.1 with no update
/// did not send them.
public struct FirmwareCheck: Sendable, Equatable {
    public var current: Observed<String>
    public var latest: Observed<String>
    public var status: FirmwareUpdateStatus
    public var releaseNotes: String?
    public var checkedAt: Date

    public init(current: Observed<String> = .unknown, latest: Observed<String> = .unknown, status: FirmwareUpdateStatus,
                releaseNotes: String? = nil, checkedAt: Date) {
        self.current = current
        self.latest = latest
        self.status = status
        self.releaseNotes = releaseNotes
        self.checkedAt = checkedAt
    }
}

// MARK: - Multi-WAN

public enum WANConnectionType: Sendable, Equatable {
    /// The interface `cable get_status` describes (`wan`).
    case ethernet
    case unknown
}

public struct WANInterfaceStatus: Sendable, Equatable {
    public var name: String
    /// `network[].up`; its meaning is `[assumed]`.
    public var up: Observed<Bool>
    public var connection: WANConnectionType
    public var address: String?
    /// No RPC field reports these; they stay unknown.
    public var active: Observed<Bool> = .unknown
    public var isDefault: Observed<Bool> = .unknown
    public var metric: Observed<Int> = .unknown
}

public struct WANPath: Sendable, Equatable {
    public var interface: String
    public var gateway: String
}

/// Honest Multi-WAN state. RouterPilot hardcodes mode and capability as
/// unknown too; no RPC reports Multi-WAN mode, policy, or failover.
public struct MultiWANStatus: Sendable, Equatable {
    public var interfaces: [WANInterfaceStatus]
    /// The `wan` interface and its gateway, only when `cable get_status`
    /// gave a gateway and `wan` is the one interface reported up.
    public var activePath: WANPath?

    public static func derive(from internet: InternetStatus) -> MultiWANStatus {
        let interfaces = internet.uplinks.map { uplink in
            let isCable = uplink.name == "wan"
            return WANInterfaceStatus(name: uplink.name, up: uplink.up,
                                      connection: isCable ? .ethernet : .unknown,
                                      address: isCable ? internet.publicAddress : nil)
        }
        let upNames = internet.uplinks.filter { $0.up == .value(true) }.map(\.name)
        var path: WANPath?
        if upNames == ["wan"], let gateway = internet.gateway { path = WANPath(interface: "wan", gateway: gateway) }
        return MultiWANStatus(interfaces: interfaces, activePath: path)
    }
}

/// Counts changes of the active path while Routewell runs. Session-only:
/// the first observation, or one after an unknown path, is not a change.
public struct WANPathTracker: Sendable, Equatable {
    public private(set) var changes: [Date] = []
    private var last: WANPath?

    public init() {}

    public mutating func observe(_ status: MultiWANStatus, at date: Date) {
        guard let path = status.activePath else { return }
        if let last, last != path { changes.append(date) }
        last = path
        if changes.count > 100 { changes.removeFirst(changes.count - 100) }
    }
}

// MARK: - DNS

/// Where client DNS goes, from what the router and AdGuard Home report.
/// Mode and encrypted DNS are not reported over RPC and stay unknown.
public struct DNSConfiguration: Sendable, Equatable {
    public enum Path: Sendable, Equatable { case throughAdGuard, direct }

    public var upstreams: [String]
    public var advertisedResolver: String?
    public var adGuardRunning: Observed<Bool>
    public var adGuardPort: Int?
    public var handlesClientRequests: Observed<Bool>
    public var resolutionPath: Observed<Path>

    public static func derive(router: RouterStatus, internet: InternetStatus, adGuard: AdGuardStatus) -> DNSConfiguration {
        let path: Observed<Path> = switch (adGuard.handlesClientRequests, adGuard.running) {
        case (.value(true), .value(true)): .value(.throughAdGuard)
        case (.value(false), _): .value(.direct)
        default: .unknown
        }
        return DNSConfiguration(upstreams: internet.dnsServers, advertisedResolver: router.lanAddress,
                                adGuardRunning: adGuard.running, adGuardPort: adGuard.dnsPort,
                                handlesClientRequests: adGuard.handlesClientRequests, resolutionPath: path)
    }
}

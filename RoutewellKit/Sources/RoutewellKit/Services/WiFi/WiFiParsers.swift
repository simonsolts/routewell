import Foundation

/// `wifi get_config` joined with `wifi get_status`. `get_config` `band` is
/// `2G`/`5G`/`6G` and `get_status` `band` is `2g`/`5g`/`6g`, so the join
/// ignores case. `key` goes only into `WiFiPassword`.
public enum WirelessParser {
    /// `nil` when `get_config` has no `res` array (a malformed reply).
    public static func parse(config: JSONValue, status: JSONValue?) -> WirelessStatus? {
        guard let radios = config["res"]?.array else { return nil }
        var live: [WirelessBand: (channel: Int?, state: RadioState?)] = [:]
        for radio in status?["res"]?.array ?? [] {
            guard let band = WirelessBand.parse(radio["band"]?.string), live[band] == nil else { continue }
            live[band] = (radio["channel"]?.int.flatMap { $0 > 0 ? $0 : nil }, RadioState.parse(radio["state"]?.string))
        }
        return WirelessStatus(radios: radios.map { radio in
            let band = WirelessBand.parse(radio["band"]?.string)
            let hwmode = WiFiJSON.text(radio["hwmode"])
            let htmodes = radio["htmodes"]?.object ?? [:]
            let maxWidth = hwmode.flatMap { htmodes[$0]?.int }
            return WirelessRadio(
                device: WiFiJSON.text(radio["device"]),
                band: band,
                configuredChannel: radio["channel"]?.int,
                currentChannel: band.flatMap { live[$0]?.channel },
                htmode: WiFiJSON.text(radio["htmode"]),
                txPower: WiFiJSON.text(radio["txpower"]) ?? radio["txpower"]?.double.map { $0.formatted() },
                networks: (radio["ifaces"]?.array ?? []).map(network),
                channels: (radio["channels"]?.array ?? []).compactMap { channel in
                    guard let number = channel["channel"]?.int, number > 0 else { return nil }
                    return WirelessChannel(number, dfs: WiFiJSON.flag(channel["dfs"]) ?? false, psc: WiFiJSON.flag(channel["psc"]) ?? false)
                },
                widthOptions: maxWidth.map { max in [20, 40, 80, 160, 320].filter { $0 <= max } } ?? [],
                autoWidth: WiFiJSON.flag(htmodes["auto"]),
                hwmode: hwmode,
                hwmodeOptions: (radio["hwmodes"]?.array ?? []).compactMap(WiFiJSON.text),
                securityOptions: (radio["encryptions"]?.array ?? []).compactMap { WiFiSecurity.parse($0.string) },
                pscOnly: WiFiJSON.flag(radio["chan_6g_only_psc"]),
                state: band.flatMap { live[$0]?.state }
            )
        }, dfsSupport: WiFiJSON.flag(config["dfs_support"]))
    }

    static func network(_ iface: JSONValue) -> WirelessNetwork {
        WirelessNetwork(
            interface: WiFiJSON.text(iface["name"]), ssid: WiFiJSON.text(iface["ssid"]),
            enabled: WiFiJSON.flag(iface["enabled"]).map(Observed.value) ?? .unknown,
            guest: WiFiJSON.flag(iface["guest"]), iot: WiFiJSON.flag(iface["iot"]),
            encryption: WiFiSecurity.parse(iface["encryption"]?.string), hidden: WiFiJSON.flag(iface["hidden"]),
            randomBSSID: WiFiJSON.flag(iface["random_bssid"]), initialised: WiFiJSON.flag(iface["init"]),
            password: iface["key"]?.string.map(WiFiPassword.init), bssid: iface["bssid"]?.string)
    }
}

/// `wifi get_mlo_config`: `mlo_bandsupport`, `ifaces[]` with `name`,
/// `mlo_enable`, `mlo_band`, `ssid`, `encryption`, `key`, `hidden`,
/// `random_bssid`, `guest`, `init`.
public enum MLOParser {
    /// `nil` when the reply is not an object.
    public static func parse(_ result: JSONValue) -> MLOConfiguration? {
        guard result.object != nil else { return nil }
        return MLOConfiguration(supportedBands: bands(result["mlo_bandsupport"]), networks: (result["ifaces"]?.array ?? []).map { iface in
            MLONetwork(
                name: WiFiJSON.text(iface["name"]),
                enabled: WiFiJSON.flag(iface["mlo_enable"]).map(Observed.value) ?? .unknown,
                bands: bands(iface["mlo_band"]), ssid: WiFiJSON.text(iface["ssid"]),
                encryption: WiFiSecurity.parse(iface["encryption"]?.string), hidden: WiFiJSON.flag(iface["hidden"]),
                randomBSSID: WiFiJSON.flag(iface["random_bssid"]), guest: WiFiJSON.flag(iface["guest"]),
                initialised: WiFiJSON.flag(iface["init"]), password: iface["key"]?.string.map(WiFiPassword.init))
        })
    }

    /// An array of band tokens, or one string of them split by spaces or commas.
    static func bands(_ value: JSONValue?) -> [WirelessBand] {
        let tokens: [String] = switch value {
        case .array(let items)?: items.compactMap(\.string)
        case .string(let text)?: text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }).map(String.init)
        default: []
        }
        return Array(Set(tokens.compactMap(WirelessBand.parse))).sorted()
    }
}

/// `vlan_subnet get_subnets`: `subnets[]`.
public enum SubnetParser {
    /// `nil` when the reply has no `subnets` array.
    public static func parse(_ result: JSONValue) -> [SubnetPolicy]? {
        guard let subnets = result["subnets"]?.array else { return nil }
        return subnets.compactMap { subnet in
            guard let fields = subnet.object else { return nil }
            return SubnetPolicy(
                name: WiFiJSON.text(subnet["display_name"])?.lowercased(),
                enabled: WiFiJSON.flag(subnet["enabled"]).map(Observed.value) ?? .unknown,
                isolate: WiFiJSON.flag(subnet["isolate"]),
                wanAccess: WANAccessMode.parse(subnet["wan_access_mode"]?.int),
                address: WiFiJSON.text(subnet["ip"]) ?? WiFiJSON.text(subnet["gateway"]),
                netmask: WiFiJSON.text(subnet["netmask"]),
                fields: fields)
        }
    }
}

enum WiFiJSON {
    static func text(_ value: JSONValue?) -> String? {
        guard let raw = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// GL mixes `true`, `1`, and `"1"`.
    static func flag(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag)?: flag
        case .number(let number)? where number == 0 || number == 1: number == 1
        case .string(let text)? where text == "0" || text == "1": text == "1"
        default: nil
        }
    }
}

/// The `wifiInterfaces` output: `name type channel megahertz` per
/// interface, `-` for a missing value. Only access points are kept, and only
/// names that are valid `WiFiInterfaceName`s.
public enum WiFiInterfaceParser {
    public static func parse(_ text: String) -> [WiFiInterface] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 4, fields[1] == "AP", let name = WiFiInterfaceName(fields[0]) else { return nil }
            let megahertz = Int(fields[3])
            return WiFiInterface(name: name, band: megahertz.flatMap(WirelessBand.from(megahertz:)), channel: Int(fields[2]))
        }
    }
}

/// The `wifiStations` output: `== <interface>` before each interface's
/// `iw dev <interface> station dump`.
public enum StationDumpParser {
    public static func parse(_ text: String, interfaces: [WiFiInterface] = []) -> [WiFiStation] {
        let bands = Dictionary(interfaces.map { ($0.name.description, $0.band) }, uniquingKeysWith: { first, _ in first })
        var stations: [WiFiStation] = []
        var interface: String?
        var current: WiFiStation?
        func flush() {
            if let current { stations.append(current) }
            current = nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("== ") {
                flush()
                interface = String(line.dropFirst(3))
                continue
            }
            if line.hasPrefix("Station ") {
                flush()
                let address = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                guard let interface, address.count == 17, let mac = MACAddress(address) else { continue }
                current = WiFiStation(interface: interface, band: bands[interface] ?? nil, mac: mac)
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "signal": current?.signal = value.firstMatch(of: /^(-?\d+)/).flatMap { Int($0.1) }
            case "tx bitrate": current?.txRate = rate(value)
            case "rx bitrate": current?.rxRate = rate(value)
            case "connected time": current?.connectedSeconds = value.firstMatch(of: /^(\d+)/).flatMap { Int($0.1) }
            case "inactive time": current?.inactiveMilliseconds = value.firstMatch(of: /^(\d+)/).flatMap { Int($0.1) }
            default: break
            }
        }
        flush()
        return stations
    }

    /// `2161.3 MBit/s 160MHz EHT-MCS 10 EHT-NSS 2 EHT-GI 0`, `HE-MCS`,
    /// `VHT-MCS`, `MCS 7` (Wi-Fi 4), or the rate alone (legacy).
    public static func rate(_ text: String) -> WiFiRate? {
        guard let speed = text.firstMatch(of: /^(\d+(?:\.\d+)?)\s*MBit\/s/) else { return nil }
        var rate = WiFiRate(megabitsPerSecond: Double(speed.1))
        rate.widthMHz = text.firstMatch(of: /(\d+)\s*MHz/).flatMap { Int($0.1) }
        if let mcs = text.firstMatch(of: /\b(EHT|HE|VHT)-MCS (\d+)/) {
            rate.generation = switch mcs.1 { case "EHT": .wifi7; case "HE": .wifi6; default: .wifi5 }
            rate.mcs = Int(mcs.2)
            rate.spatialStreams = text.firstMatch(of: /\b(EHT|HE|VHT)-NSS (\d+)/).flatMap { $0.1 == mcs.1 ? Int($0.2) : nil }
            return rate
        }
        if let mcs = text.firstMatch(of: /(?:^|\s)MCS (\d+)/) {
            rate.generation = .wifi4
            rate.mcs = Int(mcs.1)
        } else {
            rate.generation = .legacy
        }
        return rate
    }
}

/// The filtered `uci -q show wireless` lines of `wifiRadioOptions`.
public enum WirelessOptionsParser {
    public static func parse(_ text: String) -> [WirelessSectionOptions] {
        var sections: [String: WirelessSectionOptions] = [:]
        var order: [String] = []
        func update(_ name: String, _ change: (inout WirelessSectionOptions) -> Void) {
            if sections[name] == nil { sections[name] = WirelessSectionOptions(section: name); order.append(name) }
            change(&sections[name]!)
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = line.firstMatch(of: /^wireless\.([^.=]+)=([A-Za-z-]+)$/) {
                update(String(match.1)) { $0.type = String(match.2) }
            } else if let match = line.firstMatch(of: /^wireless\.([^.=]+)\.([a-z0-9_]+)='?([^']*)'?$/) {
                let value = String(match.3)
                let flag: Bool? = value == "1" ? true : value == "0" ? false : nil
                update(String(match.1)) { options in
                    switch match.2 {
                    case "ifname": options.ifname = value.isEmpty ? nil : value
                    case "acs_skiplist": options.autoSkips = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                    case "dfs_enable": options.dfsEnabled = flag
                    case "eml_mode": options.emlMode = value.isEmpty ? nil : value
                    case "ieee80211k": options.ieee80211k = flag
                    case "bss_transition": options.bssTransition = flag
                    case "ieee80211r": options.ieee80211r = flag
                    case "country":
                        let code = value.uppercased()
                        options.country = (1...3).contains(code.count) && code.allSatisfy { $0.isASCII && $0.isLetter } ? code : nil
                    default: break
                    }
                }
            }
        }
        return order.compactMap { sections[$0] }
    }
}

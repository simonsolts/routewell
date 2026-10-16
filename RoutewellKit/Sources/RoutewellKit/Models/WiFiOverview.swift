import Foundation

/// One client from `clients get_list`, as the Wi-Fi screen needs it.
public struct WiFiClientInfo: Sendable, Equatable {
    public var mac: MACAddress
    public var name: String?
    public var band: WirelessBand?
    public var online: Bool
    /// On the multi-link network: on Wi-Fi with no one band.
    public var multiLink: Bool
    public var ip: String?

    public init(mac: MACAddress, name: String? = nil, band: WirelessBand? = nil, online: Bool = true, multiLink: Bool = false, ip: String? = nil) {
        self.mac = mac
        self.name = name
        self.band = band
        self.online = online
        self.multiLink = multiLink
        self.ip = ip
    }

    /// The band from the list's `iface` token (`2.4 GHz`, `5 GHz`, `6 GHz`).
    public init(client: Client, name: String?) {
        let band: WirelessBand? = switch client.connection.band {
        case "2.4 GHz"?: .ghz2_4
        case "5 GHz"?: .ghz5
        case "6 GHz"?: .ghz6
        default: nil
        }
        self.init(mac: client.mac, name: name, band: band, online: client.online == .value(true),
                  multiLink: client.connection.band == ClientConnection.multiLink, ip: client.ip)
    }

    /// The devices of `macs` that have joined a network: listed online with
    /// an address in its subnet.
    public static func joined(_ macs: [MACAddress], clients: [WiFiClientInfo]?, subnet: SubnetPolicy?) -> Set<MACAddress> {
        guard let subnet else { return [] }
        return Set((clients ?? []).filter { $0.online && macs.contains($0.mac) && subnet.contains(ip: $0.ip) }.map(\.mac))
    }
}

/// Strong (−50 dBm and up), Good (−60), Fair (−70), Weak (below −70).
public enum SignalStrength: Int, Sendable, Equatable, CaseIterable, Comparable {
    case strong, good, fair, weak

    public init(dBm: Int) {
        self = switch dBm {
        case (-50)...: .strong
        case -60 ..< -50: .good
        case -70 ..< -60: .fair
        default: .weak
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One device on the air map.
public struct WiFiDevice: Sendable, Equatable, Identifiable {
    public var mac: MACAddress
    public var name: String?
    public var band: WirelessBand?
    public var interface: String?
    /// The network name the device uses, when the router says.
    public var network: String?
    public var kind: WiFiNetworkKind?
    /// True when the device uses the multi-link network.
    public var viaLink = false
    /// dBm; `nil` without SSH.
    public var signal: Int?
    public var rate: WiFiRate?
    public var canUseFasterBand = false

    public var id: MACAddress { mac }
    public var generation: WiFiGeneration? { rate?.generation }
    public var strength: SignalStrength? { signal.map(SignalStrength.init(dBm:)) }

    public init(mac: MACAddress, name: String? = nil, band: WirelessBand? = nil, interface: String? = nil, network: String? = nil,
                kind: WiFiNetworkKind? = nil, viaLink: Bool = false, signal: Int? = nil, rate: WiFiRate? = nil, canUseFasterBand: Bool = false) {
        self.mac = mac
        self.name = name
        self.band = band
        self.interface = interface
        self.network = network
        self.kind = kind
        self.viaLink = viaLink
        self.signal = signal
        self.rate = rate
        self.canUseFasterBand = canUseFasterBand
    }
}

/// The networks that are on, grouped by name. The router keeps one slot per
/// band; a group joins the slots that share a name.
public struct WiFiNetworkGroup: Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: WiFiNetworkKind
    public var bands: [WirelessBand]
    public var security: WiFiSecurity?
    public var interfaces: [String]
    /// `nil` when no source gives a count for every band.
    public var deviceCount: Int?

    public var id: String { "\(kind)-\(name)" }

    public init(name: String, kind: WiFiNetworkKind, bands: [WirelessBand], security: WiFiSecurity? = nil, interfaces: [String] = [],
                deviceCount: Int? = nil) {
        self.name = name
        self.kind = kind
        self.bands = bands
        self.security = security
        self.interfaces = interfaces
        self.deviceCount = deviceCount
    }
}

public enum WiFiSuggestion: Sendable, Equatable, Hashable, Identifiable {
    /// Devices on 2.4 GHz that use Wi-Fi 5 or newer while a faster band
    /// has another name.
    case fasterBand([MACAddress])
    /// Wi-Fi 7 devices while multi-link is off.
    case multiLinkReady([MACAddress])
    /// Wi-Fi 4 and older devices on 2.4 GHz while no IoT network is on.
    case ownNetwork([MACAddress])
    /// 5 GHz Auto skips every DFS channel.
    case dfsChannels

    public enum Kind: String, Sendable, Hashable { case fasterBand, multiLinkReady, ownNetwork, dfsChannels }

    public var kind: Kind {
        switch self {
        case .fasterBand: .fasterBand
        case .multiLinkReady: .multiLinkReady
        case .ownNetwork: .ownNetwork
        case .dfsChannels: .dfsChannels
        }
    }

    public var id: Kind { kind }

    public var devices: [MACAddress] {
        switch self {
        case .fasterBand(let devices), .multiLinkReady(let devices), .ownNetwork(let devices): devices
        case .dfsChannels: []
        }
    }
}

/// The derived Overview: devices, network groups, the networks not set up,
/// and suggestions. Values the reads do not give stay `nil`.
public struct WiFiOverview: Sendable, Equatable {
    public enum Missing: Sendable, Equatable, Hashable { case guest, iot, multiLink }

    public var devices: [WiFiDevice]
    public var groups: [WiFiNetworkGroup]
    public var multiLink: MLONetwork?
    public var missing: [Missing]
    public var suggestions: [WiFiSuggestion]
    /// True when signal and Wi-Fi version come from the stations.
    public var hasStations: Bool

    public init(wireless: WirelessStatus, mlo: MLOConfiguration?, air: WiFiAir?, clients: [WiFiClientInfo]?) {
        var slots: [String: (band: WirelessBand?, network: WirelessNetwork)] = [:]
        for radio in wireless.radios {
            for network in radio.networks {
                if let interface = network.interface { slots[interface] = (radio.band, network) }
            }
        }
        let names = Dictionary((clients ?? []).map { ($0.mac, $0.name) }, uniquingKeysWith: { first, _ in first })
        let bandNetworks = Dictionary(grouping: wireless.radios.flatMap { radio in radio.networks.filter(\.isOn).map { (radio.band, $0) } },
                                      by: { $0.0 })

        var devices: [WiFiDevice]
        if let stations = air?.stations {
            hasStations = true
            // An interface outside `get_config` belongs to the multi-link network when it is on.
            let linked = mlo?.main.flatMap { $0.isOn ? $0 : nil }
            devices = stations.map { station in
                let slot = slots[station.interface]
                let band = station.band ?? slot?.band
                let viaLink = slot == nil && band.map { linked?.bands.contains($0) == true } == true
                return WiFiDevice(mac: station.mac, name: names[station.mac] ?? nil, band: band, interface: station.interface,
                                  network: viaLink ? linked?.ssid : slot?.network.ssid, kind: viaLink ? .main : slot?.network.kind,
                                  viaLink: viaLink, signal: station.signal, rate: station.txRate ?? station.rxRate)
            }
        } else {
            hasStations = false
            let linked = mlo?.main.flatMap { $0.isOn ? $0 : nil }
            devices = (clients ?? []).filter { $0.online && ($0.band != nil || $0.multiLink) }.map { client in
                if client.multiLink {
                    return WiFiDevice(mac: client.mac, name: client.name, network: linked?.ssid, kind: .main, viaLink: true)
                }
                // The band's network is known only when one network is on there.
                let only = bandNetworks[client.band].flatMap { $0.count == 1 ? $0[0].1 : nil }
                return WiFiDevice(mac: client.mac, name: client.name, band: client.band, network: only?.ssid, kind: only?.kind)
            }
        }

        let fastNames = Set(wireless.radios.filter { $0.band == .ghz5 || $0.band == .ghz6 }
            .flatMap { $0.networks.filter { $0.kind == .main && $0.isOn }.compactMap(\.ssid) })
        for index in devices.indices where devices[index].band == .ghz2_4 {
            let device = devices[index]
            guard let generation = device.generation, generation >= .wifi5 else { continue }
            devices[index].canUseFasterBand = fastNames.contains { $0 != device.network }
        }
        self.devices = devices.sorted { ($0.band ?? .ghz6, -($0.signal ?? -200)) < ($1.band ?? .ghz6, -($1.signal ?? -200)) }

        var groups: [WiFiNetworkGroup] = []
        for kind in [WiFiNetworkKind.main, .guest, .iot] {
            var order: [String] = []
            var members: [String: [(WirelessBand?, WirelessNetwork)]] = [:]
            for radio in wireless.radios {
                for network in radio.networks where network.kind == kind && network.isOn {
                    let name = network.ssid ?? network.interface ?? "—"
                    if members[name] == nil { order.append(name) }
                    members[name, default: []].append((radio.band, network))
                }
            }
            for name in order {
                let slots = members[name] ?? []
                let interfaces = slots.compactMap(\.1.interface)
                let bands = Array(Set(slots.compactMap(\.0))).sorted()
                let count: Int?
                if hasStations {
                    count = devices.filter { $0.interface.map(interfaces.contains) ?? false }.count
                } else if clients != nil, slots.allSatisfy({ bandNetworks[$0.0]?.count == 1 }) {
                    count = devices.filter { $0.band.map(bands.contains) ?? false }.count
                } else {
                    count = nil
                }
                groups.append(WiFiNetworkGroup(name: name, kind: kind, bands: bands, security: slots.first?.1.encryption,
                                               interfaces: interfaces, deviceCount: count))
            }
        }
        self.groups = groups

        multiLink = mlo?.main.flatMap { $0.isOn ? $0 : nil }
        var missing: [Missing] = []
        if !groups.contains(where: { $0.kind == .guest }) { missing.append(.guest) }
        if !groups.contains(where: { $0.kind == .iot }) { missing.append(.iot) }
        if let mlo, mlo.supportedBands.count >= 2, multiLink == nil { missing.append(.multiLink) }
        self.missing = missing

        var suggestions: [WiFiSuggestion] = []
        if hasStations {
            let faster = self.devices.filter(\.canUseFasterBand).map(\.mac)
            if !faster.isEmpty { suggestions.append(.fasterBand(faster)) }
            let wifi7 = self.devices.filter { $0.generation == .wifi7 }.map(\.mac)
            if missing.contains(.multiLink), !wifi7.isEmpty { suggestions.append(.multiLinkReady(wifi7)) }
            let simple = self.devices.filter { device in
                device.band == .ghz2_4 && device.kind == .main && device.generation.map { $0 <= .wifi4 } == true
            }.map(\.mac)
            if missing.contains(.iot), !simple.isEmpty { suggestions.append(.ownNetwork(simple)) }
        }
        if let radio = wireless.radio(.ghz5), radio.isAutoChannel == true, radio.mainNetwork?.isOn == true {
            let dfs = radio.channels.filter(\.dfs).map(\.number)
            if let skips = air?.autoSkips(device: radio.device), !dfs.isEmpty, Set(dfs).isSubset(of: skips) {
                suggestions.append(.dfsChannels)
            }
        }
        self.suggestions = suggestions
    }
}

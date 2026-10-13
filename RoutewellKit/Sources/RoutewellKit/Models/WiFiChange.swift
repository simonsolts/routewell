import Foundation

// MARK: - Change set

/// The edit of one main network name from the network sheet or Use One Name.
/// `interfaces` are the slots the network had when the sheet opened; `bands`
/// are the bands it should have. A band another name holds moves to this one.
public struct WiFiNetworkEdit: Sendable, Equatable {
    public var interfaces: [String]
    public var name: String
    public var password: WiFiPassword?
    public var security: WiFiSecurity
    public var hidden: Bool
    public var randomBSSID: Bool
    public var bands: [WirelessBand]

    public init(interfaces: [String], name: String, password: WiFiPassword?, security: WiFiSecurity, hidden: Bool,
                randomBSSID: Bool, bands: [WirelessBand]) {
        self.interfaces = interfaces
        self.name = name
        self.password = password
        self.security = security
        self.hidden = hidden
        self.randomBSSID = randomBSSID
        self.bands = bands
    }
}

/// What the person staged. `isolate` is the main subnet's AP isolation; it
/// covers every main network name at once.
public struct WiFiChangeSet: Sendable, Equatable {
    public var networks: [WiFiNetworkEdit]
    public var isolate: Bool?

    public init(networks: [WiFiNetworkEdit] = [], isolate: Bool? = nil) {
        self.networks = networks
        self.isolate = isolate
    }
}

/// Why a staged network edit cannot be sent.
public enum WiFiEditProblem: Sendable, Equatable {
    case emptyName, nameTooLong, passwordLength, noBand, wpa3With6GHz
}

public extension WiFiNetworkEdit {
    /// GL's limits: a name of 1 to 32 bytes, a password of 8 to 63
    /// characters (or 64 hex digits), and WPA3 only while 6 GHz is on.
    var problems: [WiFiEditProblem] {
        var problems: [WiFiEditProblem] = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { problems.append(.emptyName) }
        if name.utf8.count > 32 { problems.append(.nameTooLong) }
        if security.isSecured, !Self.validPassword(password?.value ?? "") { problems.append(.passwordLength) }
        if bands.isEmpty { problems.append(.noBand) }
        if bands.contains(.ghz6), security != .wpa3 { problems.append(.wpa3With6GHz) }
        return problems
    }

    static func validPassword(_ text: String) -> Bool {
        if (8...63).contains(text.count) { return true }
        return text.count == 64 && text.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Calls

/// One network slot as the router holds it: the fields a `set_config`
/// sends and verify compares.
public struct WiFiSlotState: Sendable, Equatable {
    public var interface: String
    public var band: WirelessBand?
    public var ssid: String?
    public var security: WiFiSecurity?
    public var password: WiFiPassword?
    public var hidden: Bool?
    public var randomBSSID: Bool?
    public var enabled: Bool?

    public init(interface: String, band: WirelessBand? = nil, ssid: String? = nil, security: WiFiSecurity? = nil,
                password: WiFiPassword? = nil, hidden: Bool? = nil, randomBSSID: Bool? = nil, enabled: Bool? = nil) {
        self.interface = interface
        self.band = band
        self.ssid = ssid
        self.security = security
        self.password = password
        self.hidden = hidden
        self.randomBSSID = randomBSSID
        self.enabled = enabled
    }

    init(_ network: WirelessNetwork, band: WirelessBand?) {
        self.init(interface: network.interface ?? "", band: band, ssid: network.ssid, security: network.encryption,
                  password: network.password, hidden: network.hidden, randomBSSID: network.randomBSSID,
                  enabled: { if case .value(let on) = network.enabled { on } else { nil } }())
    }

    /// The slots of a `get_config` read, by interface.
    static func slots(_ wireless: WirelessStatus) -> [String: WiFiSlotState] {
        var slots: [String: WiFiSlotState] = [:]
        for radio in wireless.radios {
            for network in radio.networks {
                guard let interface = network.interface else { continue }
                slots[interface] = WiFiSlotState(network, band: radio.band)
            }
        }
        return slots
    }
}

/// What restarts when a call applies (`wifi reload` on this driver).
public enum WiFiRestartScope: Sendable, Equatable, Hashable {
    /// Name, password, security, on/off, or MAC address: only that interface.
    case network(WirelessBand)
    /// Any other change on the radio: the whole band.
    case radio(WirelessBand)
    /// The main subnet's settings reload.
    case subnet

    public var band: WirelessBand? {
        switch self {
        case .network(let band), .radio(let band): band
        case .subnet: nil
        }
    }
}

/// One RPC write of the plan. It holds a key, so it is never logged or
/// encoded: its text forms name the interface only.
public enum WiFiCall: Sendable, Equatable, CustomStringConvertible {
    /// `wifi set_config` with the whole state of one network.
    case network(WiFiSlotState, initialised: Bool)
    /// `vlan_subnet set_fixed_subnet` with every field as read and `isolate`
    /// changed.
    case subnet(SubnetPolicy, isolate: Bool)

    public var description: String {
        switch self {
        case .network(let slot, _): "wifi set_config \(slot.interface)"
        case .subnet(let subnet, _): "vlan_subnet set_fixed_subnet \(subnet.name ?? "—")"
        }
    }

    /// The `set_config` params. `key` is always sent, also when only another
    /// field changes and when security is `none`.
    var params: JSONValue {
        switch self {
        case .network(let slot, let initialised):
            var params: [String: JSONValue] = [
                "init": .bool(initialised),
                "iface_name": .string(slot.interface),
                "ssid": .string(slot.ssid ?? ""),
                "encryption": .string(slot.security.map(WiFiSecurity.wire) ?? "none"),
                "key": .string(slot.password?.value ?? ""),
                "hidden": .bool(slot.hidden ?? false),
                "random_bssid": .bool(slot.randomBSSID ?? false),
            ]
            if let enabled = slot.enabled { params["enabled"] = .bool(enabled) }
            return .object(params)
        case .subnet(let subnet, let isolate):
            var params = subnet.fields.filter { Self.subnetKeys.contains($0.key) || (subnet.name != "main" && Self.vlanKeys.contains($0.key)) }
            // The value keeps the type the router sent.
            params["isolate"] = if case .number? = subnet.fields["isolate"] { .number(isolate ? 1 : 0) } else { .bool(isolate) }
            return .object(params)
        }
    }

    static let subnetKeys: Set<String> = ["display_name", "ip", "gateway", "netmask", "dhcp_enable", "leasetime", "isolate", "dns", "lpr",
                                          "dhcp_start_ip", "dhcp_end_ip"]
    static let vlanKeys: Set<String> = ["enabled", "vlan_id", "transfer_enable", "wan_access_mode"]
}

extension WiFiSecurity {
    /// The `encryption` token GL reads and writes.
    static func wire(_ security: WiFiSecurity) -> String {
        switch security {
        case .none: "none"
        case .wpa2: "psk2"
        case .wpa2WPA1: "psk-mixed"
        case .wpa3: "sae"
        case .wpa2WPA3: "sae-mixed"
        case .other(let text): text
        }
    }
}

// MARK: - This Mac

/// How this Mac reaches the router.
public enum ThisMacLink: Sendable, Equatable {
    case ethernet
    /// The band from `clients get_list`; the interface from the stations
    /// when SSH gives them.
    case wifi(band: WirelessBand, interface: String?)
    case unknown

    /// `onWiFi` is whether the path to the router uses Wi-Fi; `wifiMAC` is
    /// the Mac's current Wi-Fi address, found in the client list.
    public static func resolve(onWiFi: Bool?, wifiMAC: MACAddress?, clients: [WiFiClientInfo]?, devices: [WiFiDevice]) -> ThisMacLink {
        switch onWiFi {
        case false?: return .ethernet
        case nil: return .unknown
        case true?:
            guard let wifiMAC else { return .unknown }
            if let device = devices.first(where: { $0.mac == wifiMAC }), let band = device.band {
                return .wifi(band: band, interface: device.interface)
            }
            if let band = clients?.first(where: { $0.mac == wifiMAC && $0.online })?.band { return .wifi(band: band, interface: nil) }
            return .unknown
        }
    }
}

/// What the apply does to this Mac.
public enum ThisMacImpact: Sendable, Equatable {
    case staysOnEthernet
    /// On Wi-Fi, and nothing it uses restarts.
    case staysConnected
    case dropsThenJoins(String)
    /// The name changes: the Mac must join the new name by hand.
    case mustJoin(String)
    /// The password or security changes: the Mac must enter the password.
    case mustEnterPassword(String)
    case unknown

    /// The Mac loses the router for a while.
    public var drops: Bool {
        switch self {
        case .staysOnEthernet, .staysConnected: false
        case .dropsThenJoins, .mustJoin, .mustEnterPassword, .unknown: true
        }
    }
}

// MARK: - Plan

/// The ordered calls, the restart scope of each, the devices that drop, and
/// this Mac. Built from the change set and a `get_config` read.
public struct WiFiApplyPlan: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var call: WiFiCall
        public var scope: WiFiRestartScope
        /// The slot as the sheet showed it; `nil` for the subnet.
        public var before: WiFiSlotState?
    }

    public var steps: [Step]
    /// The main subnet as read, when the plan changes isolation.
    public var subnetBefore: SubnetPolicy?
    /// Devices that must join again by hand: their network's name, password,
    /// or security changes.
    public var mustJoin: [MACAddress]
    /// Devices that drop and come back by themselves.
    public var reconnect: [MACAddress]
    public var thisMac: ThisMacImpact

    public var isEmpty: Bool { steps.isEmpty }
    public var calls: [WiFiCall] { steps.map(\.call) }

    /// The restart scopes, one per band, a radio restart over a network one.
    public var restarts: [WiFiRestartScope] {
        var byBand: [WirelessBand: WiFiRestartScope] = [:]
        var subnet = false
        for step in steps {
            guard let band = step.scope.band else { subnet = true; continue }
            if case .radio = byBand[band] { continue }
            byBand[band] = step.scope
        }
        return byBand.keys.sorted().compactMap { byBand[$0] } + (subnet ? [.subnet] : [])
    }

    public init(change: WiFiChangeSet, wireless: WirelessStatus, subnets: [SubnetPolicy]?, devices: [WiFiDevice], thisMac: ThisMacLink) {
        let slots = WiFiSlotState.slots(wireless)
        var steps: [Step] = []
        var mustJoin: Set<MACAddress> = []
        var reconnect: Set<MACAddress> = []
        var macImpact: ThisMacImpact?
        let mac = thisMac

        func onSlot(_ interface: String, band: WirelessBand?) -> [WiFiDevice] {
            devices.filter { device in
                if let own = device.interface { return own == interface }
                // Without stations a band's devices belong to its one network on.
                return device.band == band && band.flatMap { wireless.radio($0) }?.networks.filter(\.isOn).count == 1
            }
        }
        func macOn(_ interface: String, band: WirelessBand?) -> Bool {
            guard case .wifi(let macBand, let macInterface) = mac else { return false }
            if let macInterface { return macInterface == interface }
            return macBand == band && band.flatMap { wireless.radio($0) }?.mainNetwork?.interface == interface
        }

        if let isolate = change.isolate, let main = subnets?.first(where: { $0.name == "main" }), main.isolate != isolate {
            steps.append(Step(call: .subnet(main, isolate: isolate), scope: .subnet, before: nil))
            subnetBefore = main
        } else {
            subnetBefore = nil
        }

        for edit in change.networks {
            var targets: [(WiFiSlotState, Bool)] = []
            for band in edit.bands.sorted() {
                guard let radio = wireless.radio(band), let network = radio.mainNetwork, let interface = network.interface,
                      let before = slots[interface] else { continue }
                var after = before
                after.ssid = edit.name
                after.security = edit.security
                after.password = edit.password ?? before.password
                after.hidden = edit.hidden
                after.randomBSSID = edit.randomBSSID
                after.enabled = true
                targets.append((after, network.initialised ?? true))
            }
            for interface in edit.interfaces where !targets.contains(where: { $0.0.interface == interface }) {
                guard var after = slots[interface] else { continue }
                after.enabled = false
                targets.append((after, wireless.networks.first { $0.interface == interface }?.initialised ?? true))
            }
            for (after, initialised) in targets {
                guard let before = slots[after.interface], before != after else { continue }
                let renamed = before.ssid != after.ssid || before.password != after.password || before.security != after.security
                let quick = renamed || before.enabled != after.enabled || before.randomBSSID != after.randomBSSID
                let radioWide = before.hidden != after.hidden
                let band = after.band ?? before.band ?? .ghz2_4
                let scope: WiFiRestartScope = radioWide || !quick ? .radio(band) : .network(band)
                steps.append(Step(call: .network(after, initialised: initialised), scope: scope, before: before))

                let affected = scope == .radio(band) ? devices.filter { $0.band == band } : onSlot(after.interface, band: band)
                for device in onSlot(after.interface, band: band) where renamed && before.enabled == true && after.enabled == true {
                    mustJoin.insert(device.mac)
                }
                for device in affected where !mustJoin.contains(device.mac) { reconnect.insert(device.mac) }

                let macHere = macOn(after.interface, band: band) || (scope == .radio(band) && { if case .wifi(band, _) = mac { true } else { false } }())
                guard macHere, before.enabled == true else { continue }
                let name = after.ssid ?? edit.name
                let impact: ThisMacImpact
                if after.enabled == false {
                    let stays = wireless.radios.contains { $0.band != band && $0.mainNetwork?.ssid == before.ssid && $0.mainNetwork?.isOn == true }
                        || edit.bands.contains { $0 != band } && edit.name == before.ssid
                    impact = stays ? .dropsThenJoins(before.ssid ?? name) : .unknown
                } else if before.ssid != after.ssid {
                    impact = .mustJoin(name)
                } else if before.password != after.password || before.security != after.security {
                    impact = .mustEnterPassword(name)
                } else {
                    impact = .dropsThenJoins(name)
                }
                macImpact = Self.stronger(macImpact, impact)
            }
        }
        // Subnet first, then networks.
        self.steps = steps
        self.mustJoin = Array(mustJoin).sorted { $0.description < $1.description }
        self.reconnect = Array(reconnect.subtracting(mustJoin)).sorted { $0.description < $1.description }
        switch thisMac {
        case .ethernet: self.thisMac = .staysOnEthernet
        case .unknown: self.thisMac = steps.isEmpty ? .staysConnected : .unknown
        case .wifi: self.thisMac = macImpact ?? .staysConnected
        }
    }

    private static func stronger(_ lhs: ThisMacImpact?, _ rhs: ThisMacImpact) -> ThisMacImpact {
        func rank(_ impact: ThisMacImpact) -> Int {
            switch impact {
            case .staysOnEthernet, .staysConnected: 0
            case .dropsThenJoins: 1
            case .unknown: 2
            case .mustEnterPassword: 3
            case .mustJoin: 4
            }
        }
        guard let lhs else { return rhs }
        return rank(rhs) > rank(lhs) ? rhs : lhs
    }
}

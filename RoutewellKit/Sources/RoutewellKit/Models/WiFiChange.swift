import Foundation

// MARK: - Change set

/// The edit of one network name from the network sheet, Use One Name, or the
/// guest and IoT sheets. `interfaces` are the slots the network had when the
/// sheet opened; `bands` are the bands it should have. A main band another
/// name holds moves to this one. A guest or IoT edit with no band turns the
/// network off.
public struct WiFiNetworkEdit: Sendable, Equatable {
    public var kind: WiFiNetworkKind
    public var interfaces: [String]
    public var name: String
    public var password: WiFiPassword?
    public var security: WiFiSecurity
    public var hidden: Bool
    public var randomBSSID: Bool
    public var bands: [WirelessBand]
    /// Use One Name: every band gets this password and security, also the
    /// network's own bands that had others.
    public var sameOnEveryBand: Bool

    public init(kind: WiFiNetworkKind = .main, interfaces: [String], name: String, password: WiFiPassword?, security: WiFiSecurity,
                hidden: Bool, randomBSSID: Bool, bands: [WirelessBand], sameOnEveryBand: Bool = false) {
        self.kind = kind
        self.interfaces = interfaces
        self.name = name
        self.password = password
        self.security = security
        self.hidden = hidden
        self.randomBSSID = randomBSSID
        self.bands = bands
        self.sameOnEveryBand = sameOnEveryBand
    }
}

/// The radio fields `set_config` sends with a band's main network. They
/// apply to every network on the band.
public struct WiFiRadioSettings: Sendable, Equatable {
    public var device: String
    public var band: WirelessBand
    /// `0` is Auto.
    public var channel: Int
    /// MHz; `nil` is Auto width.
    public var width: Int?
    public var hwmode: String
    public var txPower: TxPowerLevel
    /// `chan_6g_only_psc`, 6 GHz only.
    public var pscOnly: Bool?

    public init(device: String, band: WirelessBand, channel: Int, width: Int?, hwmode: String, txPower: TxPowerLevel, pscOnly: Bool? = nil) {
        self.device = device
        self.band = band
        self.channel = channel
        self.width = width
        self.hwmode = hwmode
        self.txPower = txPower
        self.pscOnly = pscOnly
    }

    /// `nil` when the read lacks a field `set_config` needs.
    public init?(_ radio: WirelessRadio) {
        guard let device = radio.device, let band = radio.band, let channel = radio.configuredChannel, let hwmode = radio.hwmode,
              let txPower = radio.txPowerLevel, let htmode = radio.htmode else { return nil }
        let width = radio.widthMHz
        guard width != nil || htmode.lowercased() == "auto" else { return nil }
        self.init(device: device, band: band, channel: channel, width: width, hwmode: hwmode, txPower: txPower,
                  pscOnly: band == .ghz6 ? radio.pscOnly : nil)
    }

    public var isAutoChannel: Bool { channel == 0 }

    var params: [String: JSONValue] {
        var params: [String: JSONValue] = [
            "device": .string(device),
            "channel": .number(Double(channel)),
            "htmode": .string(width.map(String.init) ?? "auto"),
            "hwmode": .string(hwmode),
            "txpower": .string(txPower.wire),
        ]
        if let pscOnly { params["chan_6g_only_psc"] = .bool(pscOnly) }
        return params
    }
}

/// A `wireless` option no RPC writes, set over SSH.
public enum WiFiOptionSetting: Sendable, Equatable, Hashable {
    /// `ieee80211k` and `bss_transition` (802.11k/v) together.
    case roamingHelp(Bool)
    /// `ieee80211r`.
    case fastRoaming(Bool)
    /// `acs_skiplist`: the channels Auto does not use.
    case autoSkips([Int])

    /// The same kind of setting with the value a section holds. A missing
    /// flag is off, a missing list is empty.
    public static func read(like setting: Self, from options: WirelessSectionOptions?) -> Self {
        switch setting {
        case .roamingHelp: .roamingHelp((options?.ieee80211k ?? false) && (options?.bssTransition ?? false))
        case .fastRoaming: .fastRoaming(options?.ieee80211r ?? false)
        case .autoSkips: .autoSkips((options?.autoSkips ?? []).sorted())
        }
    }

    var normalized: Self {
        if case .autoSkips(let channels) = self { return .autoSkips(Array(Set(channels)).sorted()) }
        return self
    }
}

/// One staged SSH option, by the section name as read.
public struct WiFiOptionEdit: Sendable, Equatable, Hashable {
    public var section: String
    public var band: WirelessBand
    public var setting: WiFiOptionSetting

    public init(section: String, band: WirelessBand, setting: WiFiOptionSetting) {
        self.section = section
        self.band = band
        self.setting = setting
    }
}

/// One option write with a validated section name.
public struct WiFiOptionWrite: Sendable, Equatable, Hashable {
    public var section: UCISectionName
    public var band: WirelessBand
    public var setting: WiFiOptionSetting

    public init(section: UCISectionName, band: WirelessBand, setting: WiFiOptionSetting) {
        self.section = section
        self.band = band
        self.setting = setting
    }
}

/// The "can reach" rules of the guest or IoT subnet that can change. `nil`
/// is unknown or unchanged.
public struct WiFiSubnetRules: Sendable, Equatable {
    public var kind: WiFiNetworkKind
    /// AP isolation off.
    public var eachOther: Bool?
    /// `wan_access_mode` 0 (on) or 1 (off). Routewell never sends 2, which
    /// blocks the internet.
    public var reachesModem: Bool?

    public init(kind: WiFiNetworkKind, eachOther: Bool?, reachesModem: Bool?) {
        self.kind = kind
        self.eachOther = eachOther
        self.reachesModem = reachesModem
    }

    /// The rules a subnet has now.
    public init(kind: WiFiNetworkKind, subnet: SubnetPolicy?) {
        let modem: Bool? = switch subnet?.wanAccess {
        case .unrestricted?: true
        case .blockWANSubnet?: false
        default: nil
        }
        self.init(kind: kind, eachOther: subnet?.isolate.map { !$0 }, reachesModem: modem)
    }

    /// `display_name` of the subnet.
    public static func subnetName(_ kind: WiFiNetworkKind) -> String {
        switch kind {
        case .main: "main"
        case .guest: "guest"
        case .iot: "iot"
        }
    }
}

/// What the person staged. `isolate` is the main subnet's AP isolation; it
/// covers every main network name at once. `rules` are the guest and IoT
/// subnets' rules. `radios` hold each changed band's whole radio state.
/// `mlo` is the multi-link network as it should be.
public struct WiFiChangeSet: Sendable, Equatable {
    public var networks: [WiFiNetworkEdit]
    public var isolate: Bool?
    public var rules: [WiFiSubnetRules]
    public var radios: [WiFiRadioSettings]
    public var options: [WiFiOptionEdit]
    public var mlo: MLONetwork?

    public init(networks: [WiFiNetworkEdit] = [], isolate: Bool? = nil, rules: [WiFiSubnetRules] = [], radios: [WiFiRadioSettings] = [],
                options: [WiFiOptionEdit] = [], mlo: MLONetwork? = nil) {
        self.networks = networks
        self.isolate = isolate
        self.rules = rules
        self.radios = radios
        self.options = options
        self.mlo = mlo
    }
}

public extension SubnetPolicy {
    /// True when `ip` is an IPv4 address in this subnet.
    func contains(ip: String?) -> Bool {
        func value(_ text: String?) -> UInt32? {
            let parts = text?.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) } ?? []
            guard parts.count == 4 else { return nil }
            return parts.reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard let ip = value(ip), let address = value(address), let mask = value(netmask) else { return false }
        return ip & mask == address & mask
    }

    /// "192.168.9.1/24".
    var range: String? {
        guard let address, let netmask else { return nil }
        let bits = netmask.split(separator: ".").compactMap { UInt8($0) }.map(\.nonzeroBitCount).reduce(0, +)
        return "\(address)/\(bits)"
    }
}

/// Why a staged network edit cannot be sent.
public enum WiFiEditProblem: Sendable, Equatable {
    case emptyName, nameTooLong, passwordLength, noBand, wpa3With6GHz
    /// Multi-link needs two bands or more.
    case oneBand
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

public extension MLONetwork {
    /// GL's limits for a network, and two bands or more. The plan sends
    /// WPA3 with 6 GHz.
    var problems: [WiFiEditProblem] {
        let security = bands.contains(.ghz6) ? .wpa3 : encryption ?? .wpa3
        var edit = WiFiNetworkEdit(interfaces: [], name: ssid ?? "", password: password, security: security, hidden: hidden ?? false,
                                   randomBSSID: randomBSSID ?? true, bands: bands)
        if !isOn { edit.bands = [.ghz2_4] }
        var problems = edit.problems
        if isOn, bands.count == 1 { problems.append(.oneBand) }
        return problems
    }

    /// The fields `set_mlo_config` sends and verify compares.
    var sent: MLONetwork {
        MLONetwork(name: name, enabled: enabled, bands: bands.sorted(), ssid: ssid, encryption: encryption, hidden: hidden,
                   randomBSSID: randomBSSID, initialised: initialised != false, password: password)
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
    /// Sent only when a guest or IoT network is added. The driver can give a
    /// new one, so it is not compared.
    public var bssid: String?

    public init(interface: String, band: WirelessBand? = nil, ssid: String? = nil, security: WiFiSecurity? = nil,
                password: WiFiPassword? = nil, hidden: Bool? = nil, randomBSSID: Bool? = nil, enabled: Bool? = nil, bssid: String? = nil) {
        self.interface = interface
        self.band = band
        self.ssid = ssid
        self.security = security
        self.password = password
        self.hidden = hidden
        self.randomBSSID = randomBSSID
        self.enabled = enabled
        self.bssid = bssid
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.interface == rhs.interface && lhs.band == rhs.band && lhs.ssid == rhs.ssid && lhs.security == rhs.security
            && lhs.password == rhs.password && lhs.hidden == rhs.hidden && lhs.randomBSSID == rhs.randomBSSID && lhs.enabled == rhs.enabled
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
    /// A guest or IoT network starts on the band; the others stay up.
    case added(WirelessBand)
    /// The main subnet's settings reload.
    case subnet
    /// The guest or IoT subnet's settings reload while its network is on.
    case rules(WiFiNetworkKind)

    public var band: WirelessBand? {
        switch self {
        case .network(let band), .radio(let band), .added(let band): band
        case .subnet, .rules: nil
        }
    }
}

/// One write of the plan. It holds a key, so it is never logged or
/// encoded: its text forms name the interface or section only.
public enum WiFiCall: Sendable, Equatable, CustomStringConvertible {
    /// `wifi set_config` with the whole state of one network, and the
    /// band's radio fields when they change.
    case network(WiFiSlotState, initialised: Bool, radio: WiFiRadioSettings?)
    /// `vlan_subnet set_fixed_subnet` with every field as read and `isolate`
    /// changed.
    case subnet(SubnetPolicy, isolate: Bool)
    /// `vlan_subnet set_fixed_subnet` for the guest or IoT subnet, every
    /// field as read and the rules changed.
    case rules(SubnetPolicy, WiFiSubnetRules)
    /// One SSH command: `uci set` per option, `uci commit`, `wifi reload`.
    case options([WiFiOptionWrite])
    /// `wifi set_mlo_config` with the whole state of the multi-link network.
    case mlo(MLONetwork)

    public var description: String {
        switch self {
        case .network(let slot, _, let radio): "wifi set_config \(slot.interface)\(radio == nil ? "" : " with radio")"
        case .subnet(let subnet, _), .rules(let subnet, _): "vlan_subnet set_fixed_subnet \(subnet.name ?? "—")"
        case .options(let writes): "uci wireless \(Set(writes.map(\.section.description)).sorted().joined(separator: " "))"
        case .mlo(let network): "wifi set_mlo_config \(network.name ?? "—")"
        }
    }

    /// The RPC params. `key` is always sent, also when only another field
    /// changes and when security is `none`. `nil` for the SSH command.
    var params: JSONValue? {
        switch self {
        case .network(let slot, let initialised, let radio):
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
            if let bssid = slot.bssid { params["bssid"] = .string(bssid) }
            if let radio { params.merge(radio.params) { _, new in new } }
            return .object(params)
        case .subnet(let subnet, let isolate):
            return .object(Self.subnetParams(subnet, isolate: isolate))
        case .rules(let subnet, let rules):
            var params = Self.subnetParams(subnet, isolate: rules.eachOther.map { !$0 } ?? subnet.isolate ?? true)
            if let modem = rules.reachesModem { params["wan_access_mode"] = .number(modem ? 0 : 1) }
            return .object(params)
        case .options:
            return nil
        case .mlo(let network):
            let bands = network.bands.sorted()
            return .object([
                "init": .bool(network.initialised ?? true),
                "name": .string(network.name ?? ""),
                "mlo_enable": .bool(network.enabled == .value(true)),
                "mlo_band": .array(bands.map { .string($0.rawValue) }),
                "ssid": .string(network.ssid ?? ""),
                // 6 GHz allows only WPA3.
                "encryption": .string(bands.contains(.ghz6) ? "sae" : network.encryption.map(WiFiSecurity.wire) ?? "sae"),
                "key": .string(network.password?.value ?? ""),
                "hidden": .bool(network.hidden ?? false),
                "random_bssid": .bool(network.randomBSSID ?? false),
            ])
        }
    }

    private static func subnetParams(_ subnet: SubnetPolicy, isolate: Bool) -> [String: JSONValue] {
        var params = subnet.fields.filter { subnetKeys.contains($0.key) || (subnet.name != "main" && vlanKeys.contains($0.key)) }
        // The value keeps the type the router sent.
        params["isolate"] = if case .number? = subnet.fields["isolate"] { .number(isolate ? 1 : 0) } else { .bool(isolate) }
        return params
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

/// The radar check a manual DFS channel needs before its band comes up.
/// Its length depends on the channel and the router's rules; the apply waits
/// while `get_status` says `cac`.
public struct WiFiRadarCheck: Sendable, Equatable {
    public var band: WirelessBand
    public var channel: Int

    public init(band: WirelessBand, channel: Int) {
        self.band = band
        self.channel = channel
    }
}

/// The ordered calls, the restart scope of each, the devices that drop, and
/// this Mac. Built from the change set and a `get_config` read.
public struct WiFiApplyPlan: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var call: WiFiCall
        public var scopes: [WiFiRestartScope]
        /// The slot as the sheet showed it; `nil` for the subnet and options.
        public var before: WiFiSlotState?
        /// The band's radio fields as the sheet showed them, when the call
        /// changes them.
        public var radioBefore: WiFiRadioSettings?
        /// The sections the options call writes, as the sheet showed them.
        public var optionsBefore: [WirelessSectionOptions]
        /// The multi-link network as the sheet showed it.
        public var mloBefore: MLONetwork?

        public init(call: WiFiCall, scopes: [WiFiRestartScope], before: WiFiSlotState? = nil, radioBefore: WiFiRadioSettings? = nil,
                    optionsBefore: [WirelessSectionOptions] = [], mloBefore: MLONetwork? = nil) {
            self.call = call
            self.scopes = scopes
            self.before = before
            self.radioBefore = radioBefore
            self.optionsBefore = optionsBefore
            self.mloBefore = mloBefore
        }
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
    public var radarCheck: WiFiRadarCheck?

    public var isEmpty: Bool { steps.isEmpty }
    public var calls: [WiFiCall] { steps.map(\.call) }

    /// The restart scopes, one per band (a radio restart over a new network
    /// over a network one), then the subnet reloads.
    public var restarts: [WiFiRestartScope] {
        func rank(_ scope: WiFiRestartScope) -> Int {
            switch scope {
            case .radio: 2
            case .added: 1
            default: 0
            }
        }
        var byBand: [WirelessBand: WiFiRestartScope] = [:]
        var others: [WiFiRestartScope] = []
        for scope in steps.flatMap(\.scopes) {
            guard let band = scope.band else {
                if !others.contains(scope) { others.append(scope) }
                continue
            }
            if let kept = byBand[band], rank(kept) >= rank(scope) { continue }
            byBand[band] = scope
        }
        return byBand.keys.sorted().compactMap { byBand[$0] } + others
    }

    /// `options` are the `wireless` sections read over SSH; `mlo` is the
    /// `get_mlo_config` read.
    public init(change: WiFiChangeSet, wireless: WirelessStatus, subnets: [SubnetPolicy]?, options: [WirelessSectionOptions]? = nil,
                mlo: MLOConfiguration? = nil, devices: [WiFiDevice], thisMac: ThisMacLink) {
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
        func macOnRadio(_ band: WirelessBand) -> Bool {
            if case .wifi(band, _) = mac { true } else { false }
        }
        /// The Mac is on another network of a radio that restarts: its settings stay.
        var macStays: ThisMacImpact {
            let macSSID: String? = if case .wifi(_, let interface?) = mac { slots[interface]?.ssid } else { nil }
            return macSSID.map(ThisMacImpact.dropsThenJoins) ?? .unknown
        }

        if let isolate = change.isolate, let main = subnets?.first(where: { $0.name == "main" }), main.isolate != isolate {
            steps.append(Step(call: .subnet(main, isolate: isolate), scopes: [.subnet]))
            subnetBefore = main
        } else {
            subnetBefore = nil
        }
        for rule in change.rules {
            guard let subnet = subnets?.first(where: { $0.name == WiFiSubnetRules.subnetName(rule.kind) }) else { continue }
            let now = WiFiSubnetRules(kind: rule.kind, subnet: subnet)
            let after = WiFiSubnetRules(kind: rule.kind, eachOther: rule.eachOther ?? now.eachOther, reachesModem: rule.reachesModem ?? now.reachesModem)
            guard after != now else { continue }
            // An off network's subnet is not active, so nothing reloads.
            let on = wireless.radios.contains { $0.network(rule.kind)?.isOn == true }
            steps.append(Step(call: .rules(subnet, after), scopes: on ? [.rules(rule.kind)] : []))
        }

        var radios: [WirelessBand: (after: WiFiRadioSettings, before: WiFiRadioSettings)] = [:]
        for radio in change.radios {
            guard let read = wireless.radio(radio.band).flatMap(WiFiRadioSettings.init), read != radio else { continue }
            radios[radio.band] = (radio, read)
        }

        var targets: [(slot: WiFiSlotState, initialised: Bool, name: String, kind: WiFiNetworkKind, turnsOff: Bool)] = []
        for edit in change.networks {
            // The edit's fields come from its first slot. Its other slots can
            // differ; they keep each field the edit leaves as that slot had it.
            let read = edit.interfaces.first.flatMap { slots[$0] }
            for band in edit.bands.sorted() {
                guard let radio = wireless.radio(band), let network = radio.network(edit.kind), let interface = network.interface,
                      let before = slots[interface] else { continue }
                let own = edit.interfaces.contains(interface) ? read : nil
                let key = edit.sameOnEveryBand ? nil : own
                var after = before
                after.ssid = edit.name
                if key == nil || key?.security != edit.security { after.security = edit.security }
                if let password = edit.password, key == nil || key?.password != password { after.password = password }
                if own == nil || own?.hidden != edit.hidden { after.hidden = edit.hidden }
                if own == nil || own?.randomBSSID != edit.randomBSSID { after.randomBSSID = edit.randomBSSID }
                after.enabled = true
                // A guest or IoT network that is off is added: `init` true and the BSSID as read.
                let adds = edit.kind != .main && before.enabled != true
                if adds { after.bssid = network.bssid }
                targets.append((after, adds || (network.initialised ?? true), edit.name, edit.kind, false))
            }
            for interface in edit.interfaces where !targets.contains(where: { $0.slot.interface == interface }) {
                guard var after = slots[interface] else { continue }
                after.enabled = false
                targets.append((after, wireless.networks.first { $0.interface == interface }?.initialised ?? true, edit.name, edit.kind,
                                edit.kind != .main && edit.bands.isEmpty))
            }
        }
        // Radio fields ride on the band's main network call.
        for band in radios.keys.sorted() {
            guard let network = wireless.radio(band)?.mainNetwork, let interface = network.interface, let slot = slots[interface],
                  !targets.contains(where: { $0.slot.interface == interface }) else { continue }
            targets.append((slot, network.initialised ?? true, slot.ssid ?? "", .main, false))
        }

        var radioSent: Set<WirelessBand> = []
        for (after, initialised, editName, kind, turnsOff) in targets {
            guard let before = slots[after.interface] else { continue }
            let band = after.band ?? before.band ?? .ghz2_4
            let radio = wireless.radio(band)?.mainNetwork?.interface == after.interface ? radios[band] : nil
            guard before != after || radio != nil else { continue }
            if radio != nil { radioSent.insert(band) }
            let renamed = before.ssid != after.ssid || before.password != after.password || before.security != after.security
            let quick = renamed || before.enabled != after.enabled || before.randomBSSID != after.randomBSSID
            let radioWide = before.hidden != after.hidden || radio != nil
            let added = kind != .main && before.enabled != true && after.enabled == true
            let scope: WiFiRestartScope = radioWide || !quick ? .radio(band) : added ? .added(band) : .network(band)
            steps.append(Step(call: .network(after, initialised: initialised, radio: radio?.after), scopes: [scope], before: before,
                              radioBefore: radio?.before))

            let affected = scope == .radio(band) ? devices.filter { $0.band == band } : onSlot(after.interface, band: band)
            // A guest or IoT network that turns off leaves its devices to join another network.
            for device in onSlot(after.interface, band: band) where before.enabled == true && (renamed && after.enabled == true || turnsOff) {
                mustJoin.insert(device.mac)
            }
            for device in affected where !mustJoin.contains(device.mac) { reconnect.insert(device.mac) }

            let onThisSlot = macOn(after.interface, band: band)
            let onThisRadio = scope == .radio(band) && macOnRadio(band)
            guard onThisSlot || onThisRadio, before.enabled == true else { continue }
            let name = after.ssid ?? editName
            let impact: ThisMacImpact
            if !onThisSlot {
                impact = macStays
            } else if after.enabled == false {
                let stays = wireless.radios.contains { $0.band != band && $0.mainNetwork?.ssid == before.ssid && $0.mainNetwork?.isOn == true }
                    || change.networks.contains { edit in edit.bands.contains { $0 != band } && edit.name == before.ssid }
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

        radarCheck = radios.keys.sorted().lazy.compactMap { band -> WiFiRadarCheck? in
            guard radioSent.contains(band), let after = radios[band]?.after, !after.isAutoChannel,
                  wireless.radio(band)?.channels.first(where: { $0.number == after.channel })?.dfs == true else { return nil }
            return WiFiRadarCheck(band: band, channel: after.channel)
        }.first

        if var after = change.mlo, let before = mlo?.networks.first(where: { $0.name == after.name && after.name != nil }) {
            after.bands.sort()
            if after.bands.contains(.ghz6) { after.encryption = .wpa3 }
            after.initialised = after.enabled == .value(true) ? true : before.initialised
            if after.sent != before.sent {
                let wasOn = before.isOn
                let isOn = after.enabled == .value(true)
                let renamed = before.ssid != after.ssid || before.password != after.password || before.encryption != after.encryption
                let radioWide = wasOn && isOn && before.hidden != after.hidden
                let bands = Set(wasOn ? before.bands : []).union(isOn ? after.bands : []).sorted()
                let scopes = bands.map { band -> WiFiRestartScope in
                    if radioWide { return .radio(band) }
                    return isOn && !(wasOn && before.bands.contains(band)) ? .added(band) : .network(band)
                }
                steps.append(Step(call: .mlo(after), scopes: scopes, mloBefore: before))

                let members = devices.filter(\.viaLink)
                if wasOn {
                    for device in members {
                        if renamed || !isOn { mustJoin.insert(device.mac) } else { reconnect.insert(device.mac) }
                    }
                }
                if radioWide {
                    for device in devices where device.band.map(bands.contains) == true && !mustJoin.contains(device.mac) { reconnect.insert(device.mac) }
                }
                let macDevice: WiFiDevice? = if case .wifi(_, let interface?) = mac { devices.first { $0.interface == interface } } else { nil }
                if wasOn, macDevice?.viaLink == true {
                    let name = after.ssid ?? before.ssid ?? ""
                    let impact: ThisMacImpact = if !isOn { .unknown }
                        else if before.ssid != after.ssid { .mustJoin(name) }
                        else if renamed { .mustEnterPassword(name) }
                        else { .dropsThenJoins(name) }
                    macImpact = Self.stronger(macImpact, impact)
                } else if radioWide, case .wifi(let band, _) = mac, bands.contains(band) {
                    macImpact = Self.stronger(macImpact, macStays)
                }
            }
        }

        var writes: [WiFiOptionWrite] = []
        var optionsBefore: [WirelessSectionOptions] = []
        for edit in change.options {
            let setting = edit.setting.normalized
            guard let name = UCISectionName(edit.section), let before = options?.first(where: { $0.section == edit.section }),
                  WiFiOptionSetting.read(like: setting, from: before) != setting,
                  !writes.contains(where: { $0.section == name && $0.setting == setting }) else { continue }
            writes.append(WiFiOptionWrite(section: name, band: edit.band, setting: setting))
            if !optionsBefore.contains(before) { optionsBefore.append(before) }
        }
        if !writes.isEmpty {
            let bands = Array(Set(writes.map(\.band))).sorted()
            steps.append(Step(call: .options(writes), scopes: bands.map(WiFiRestartScope.radio), optionsBefore: optionsBefore))
            for band in bands {
                for device in devices where device.band == band && !mustJoin.contains(device.mac) { reconnect.insert(device.mac) }
                if macOnRadio(band) {
                    let own: String? = if case .wifi(_, let interface?) = mac { slots[interface]?.ssid } else { wireless.radio(band)?.mainNetwork?.ssid }
                    macImpact = Self.stronger(macImpact, own.map(ThisMacImpact.dropsThenJoins) ?? .unknown)
                }
            }
        }

        // Subnet first, then networks and radios, then multi-link, then the SSH options.
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

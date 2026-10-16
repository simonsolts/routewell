import Foundation
import Synchronization
import RoutewellKit

/// Synthetic Wi-Fi with the neutral names "Flint Home" (2.4 GHz) and
/// "Flint Home Fast" (5 + 6 GHz). The stations use the MAC addresses of the
/// mock client list's Wi-Fi devices, so the screen shows their names. The
/// scenario is readable without `await`, so `MockRouterBackend.ssh` can
/// answer `nil` for "SSH off".
public final class MockWiFiService: WiFiService, WiFiApplyTransport {
    public enum Scenario: String, CaseIterable, Sendable {
        case today
        /// One name on all bands, and multi-link on as "Flint Home 7".
        case afterSuggestions
        case guestAndIoT
        case multiLinkOn
        /// SSH is not set up: the backend has no SSH service.
        case sshOff
        /// `get_mlo_config` times out; the rest works.
        case multiLinkFails
        /// `-32601` on `wifi get_config`.
        case methodNotFound
        /// 2.4 GHz on manual channel 6, 5 GHz on manual channel 100 (DFS).
        case manualChannel
    }

    /// How a network edit goes. The Mac is the MacBook Air on "Flint Home
    /// Fast" (6 GHz), except on Ethernet.
    public enum ApplyScenario: String, CaseIterable, Sendable {
        case success
        /// The reply is lost; the change applied.
        case replyLost
        /// The router does not answer again after the restart.
        case macNotBack
        /// The router answers but keeps the old values.
        case mismatch
        /// The first call comes back with an `err_code`.
        case refused
        case macOnEthernet
        /// A manual DFS channel finds radar during its check.
        case radarFound
    }

    private struct Edits {
        var wireless: WirelessStatus?
        var subnets: [SubnetPolicy]?
        var sections: [WirelessSectionOptions]?
        /// The band whose radar check runs, and when it ends.
        var radarCheck: (band: WirelessBand, until: Date)?
        var radar: WirelessBand?
    }

    /// How long a mock radar check takes.
    static let radarCheckTime: TimeInterval = 3

    private let selected = Mutex<Scenario>(.today)
    private let applySelected = Mutex<ApplyScenario>(.success)
    private let edits = Mutex(Edits())

    public init() {}

    public var scenario: Scenario { selected.withLock { $0 } }
    public func setScenario(_ value: Scenario) {
        selected.withLock { $0 = value }
        edits.withLock { $0 = Edits() }
    }

    public var applyScenario: ApplyScenario { applySelected.withLock { $0 } }
    public func setApplyScenario(_ value: ApplyScenario) { applySelected.withLock { $0 = value } }

    /// This Mac's Wi-Fi address in the mock: the MacBook Air's.
    public static let thisMac = MACAddress("a4:83:e7:12:9c:01")!
    public var thisMacOnWiFi: Bool { applyScenario != .macOnEthernet }

    private func currentWireless(_ scenario: Scenario) -> WirelessStatus {
        let (stored, check, radar) = edits.withLock { ($0.wireless, $0.radarCheck, $0.radar) }
        var wireless = stored ?? Self.wireless(scenario)
        for index in wireless.radios.indices {
            guard let band = wireless.radios[index].band else { continue }
            if band == radar {
                wireless.radios[index].state = .conflict
            } else if let check, check.band == band, Date() < check.until {
                wireless.radios[index].state = .cac
            }
        }
        return wireless
    }

    private func currentSections(_ scenario: Scenario) -> [WirelessSectionOptions] {
        edits.withLock { $0.sections } ?? Self.air(scenario).sections ?? []
    }

    private func currentSubnets(_ scenario: Scenario) -> [SubnetPolicy] {
        edits.withLock { $0.subnets } ?? Self.subnets(scenario)
    }

    // MARK: - Apply

    public func readWireless() async throws -> WirelessStatus {
        try Task.checkCancellation()
        return currentWireless(scenario)
    }

    public func readSubnets() async throws -> [SubnetPolicy] {
        try Task.checkCancellation()
        return currentSubnets(scenario)
    }

    public func readRadioStates() async throws -> [WirelessBand: RadioState] {
        if applyScenario == .macNotBack { throw GLiNetRPCError.transport(.unreachable(code: -1004)) }
        return Dictionary(currentWireless(scenario).radios.compactMap { radio in radio.band.map { ($0, radio.state ?? .ready) } },
                          uniquingKeysWith: { first, _ in first })
    }

    public func readOptions() async throws -> [WirelessSectionOptions] {
        try Task.checkCancellation()
        guard scenario != .sshOff else { throw GLiNetRPCError.transport(.unreachable(code: -1004)) }
        return currentSections(scenario)
    }

    public func send(_ call: WiFiCall) async throws -> Int? {
        try await Task.sleep(for: .milliseconds(300))
        let apply = applyScenario
        if apply == .refused { return -1 }
        if apply != .mismatch { store(call) }
        if apply == .replyLost { throw GLiNetRPCError.transport(.timedOut) }
        return nil
    }

    private func store(_ call: WiFiCall) {
        let scenario = scenario
        var wireless = edits.withLock { $0.wireless } ?? Self.wireless(scenario)
        var subnets = currentSubnets(scenario)
        var sections = currentSections(scenario)
        var radarCheck = edits.withLock { $0.radarCheck }
        var radar = edits.withLock { $0.radar }
        switch call {
        case .network(let slot, _, let settings):
            if let settings, let index = wireless.radios.firstIndex(where: { $0.band == settings.band }) {
                var radio = wireless.radios[index]
                radio.configuredChannel = settings.channel
                if !settings.isAutoChannel { radio.currentChannel = settings.channel }
                radio.htmode = settings.width.map(String.init) ?? "auto"
                radio.hwmode = settings.hwmode
                radio.txPower = settings.txPower.wire
                if settings.pscOnly != nil { radio.pscOnly = settings.pscOnly }
                wireless.radios[index] = radio
                if !settings.isAutoChannel, radio.channels.first(where: { $0.number == settings.channel })?.dfs == true {
                    if applyScenario == .radarFound { radar = settings.band } else { radarCheck = (settings.band, Date().addingTimeInterval(Self.radarCheckTime)) }
                }
            }
            for radio in wireless.radios.indices {
                for index in wireless.radios[radio].networks.indices where wireless.radios[radio].networks[index].interface == slot.interface {
                    var network = wireless.radios[radio].networks[index]
                    network.ssid = slot.ssid
                    network.encryption = slot.security
                    network.password = slot.password
                    network.hidden = slot.hidden
                    network.randomBSSID = slot.randomBSSID
                    if let enabled = slot.enabled { network.enabled = .value(enabled) }
                    wireless.radios[radio].networks[index] = network
                }
            }
        case .subnet(let subnet, let isolate):
            for index in subnets.indices where subnets[index].name == subnet.name { subnets[index].isolate = isolate }
        case .options(let writes):
            for write in writes {
                guard let index = sections.firstIndex(where: { $0.section == write.section.description }) else { continue }
                switch write.setting {
                case .roamingHelp(let on):
                    sections[index].ieee80211k = on
                    sections[index].bssTransition = on
                case .fastRoaming(let on): sections[index].ieee80211r = on
                case .autoSkips(let channels): sections[index].autoSkips = channels
                }
            }
        }
        edits.withLock { $0 = Edits(wireless: wireless, subnets: subnets, sections: sections, radarCheck: radarCheck, radar: radar) }
    }

    public func probe() async -> Capability {
        scenario == .methodNotFound
            ? Capability(.unsupported, evidence: .methodNotFound(method: "wifi.get_config"), observedAt: .now)
            : Capability(.supported, evidence: .mockScenario("wifi"), observedAt: .now)
    }

    public func snapshot() async throws -> WiFiSnapshotResult {
        try Task.checkCancellation()
        let now = Date()
        let scenario = scenario
        guard scenario != .methodNotFound else {
            return WiFiSnapshotResult(area: .failure(.unavailable, attemptedAt: now),
                                      capability: Capability(.unsupported, evidence: .methodNotFound(method: "wifi.get_config"), observedAt: now))
        }
        let snapshot = WiFiSnapshot(
            wireless: .success(currentWireless(scenario)),
            mlo: scenario == .multiLinkFails ? .failure(.timeout) : .success(Self.mlo(scenario)),
            subnets: .success(currentSubnets(scenario)))
        return WiFiSnapshotResult(area: .success(snapshot, observedAt: now, source: .mock),
                                  capability: Capability(.supported, evidence: .mockScenario(scenario.rawValue), observedAt: now))
    }

    public func air() async throws -> AreaRefreshResult<WiFiAir> {
        try Task.checkCancellation()
        let scenario = scenario
        guard scenario != .sshOff, scenario != .methodNotFound else { return .failure(.unavailable, attemptedAt: Date()) }
        var air = Self.air(scenario)
        air.sections = currentSections(scenario)
        return .success(air, observedAt: Date(), source: .mock)
    }

    // MARK: - Data

    public static let home = "Flint Home"
    public static let fast = "Flint Home Fast"
    public static let multiLink = "Flint Home 7"
    public static let guest = "Flint Home Guest"
    public static let iot = "Flint Home IoT"

    private static let securityOptions: [WiFiSecurity] = [.none, .wpa2, .wpa2WPA1, .wpa3, .wpa2WPA3]

    private static func slot(_ interface: String, _ ssid: String, on: Bool, guest: Bool = false, iot: Bool = false,
                             security: WiFiSecurity = .wpa2WPA3) -> WirelessNetwork {
        WirelessNetwork(interface: interface, ssid: ssid, enabled: .value(on), guest: guest, iot: iot, encryption: security,
                        hidden: false, randomBSSID: true, initialised: on || !(guest || iot), password: WiFiPassword("example-password"))
    }

    public static func wireless(_ scenario: Scenario) -> WirelessStatus {
        let oneName = scenario == .afterSuggestions
        let guestOn = scenario == .guestAndIoT
        let fastName = oneName ? home : fast
        let manual = scenario == .manualChannel
        return WirelessStatus(radios: [
            WirelessRadio(device: "MT7990_1_1", band: .ghz2_4, configuredChannel: manual ? 6 : 0, currentChannel: manual ? 6 : 9,
                          htmode: manual ? "20" : "auto", txPower: "Max",
                          networks: [
                              slot("ra0", home, on: true),
                              slot("ra1", guest, on: guestOn, guest: true),
                              slot("ra3", iot, on: guestOn, iot: true, security: .wpa2),
                          ],
                          channels: (1...13).map { WirelessChannel($0) }, widthOptions: [20, 40], autoWidth: true,
                          hwmode: "11b/g/n/ax/be", hwmodeOptions: ["11b/g/n/ax/be", "11ax/be"], securityOptions: securityOptions, state: .ready),
            WirelessRadio(device: "MT7990_1_2", band: .ghz5, configuredChannel: manual ? 100 : 0, currentChannel: oneName || manual ? 100 : 44,
                          htmode: oneName ? "160" : "80", txPower: "Max",
                          networks: [
                              slot("rai0", fastName, on: true, security: oneName ? .wpa2WPA3 : .wpa3),
                              slot("rai1", guest, on: guestOn, guest: true),
                              slot("rai3", iot, on: false, iot: true, security: .wpa2),
                          ],
                          channels: ([36, 40, 44, 48] + [52, 56, 60, 64] + Array(stride(from: 100, through: 140, by: 4))).map { WirelessChannel($0, dfs: $0 >= 52) },
                          widthOptions: [20, 40, 80, 160], autoWidth: false,
                          hwmode: "11a/n/ac/ax/be", hwmodeOptions: ["11a/n/ac/ax/be", "11ac/ax/be", "11ax/be"], securityOptions: securityOptions, state: .ready),
            WirelessRadio(device: "MT7990_1_3", band: .ghz6, configuredChannel: 0, currentChannel: 37, htmode: "160", txPower: "Max",
                          networks: [
                              slot("rax0", fastName, on: true, security: .wpa3),
                              slot("rax1", guest, on: false, guest: true, security: .wpa3),
                          ],
                          channels: stride(from: 1, through: 93, by: 4).map { WirelessChannel($0, psc: [5, 21, 37, 53, 69, 85].contains($0)) },
                          widthOptions: [20, 40, 80, 160, 320], autoWidth: false,
                          hwmode: "11ax/be", hwmodeOptions: ["11ax/be"], securityOptions: [.wpa3], pscOnly: true, state: .ready),
        ], dfsSupport: true)
    }

    public static func mlo(_ scenario: Scenario) -> MLOConfiguration {
        let on = scenario == .afterSuggestions || scenario == .multiLinkOn
        return MLOConfiguration(supportedBands: [.ghz2_4, .ghz5, .ghz6], networks: [
            MLONetwork(name: "mld0", enabled: .value(on), bands: [.ghz5, .ghz6], ssid: on ? multiLink : fast, encryption: .wpa3,
                       hidden: false, randomBSSID: true, guest: false, initialised: true, password: WiFiPassword("example-password")),
        ])
    }

    public static func subnets(_ scenario: Scenario) -> [SubnetPolicy] {
        let on = scenario == .guestAndIoT
        return [
            SubnetPolicy(name: "main", enabled: .value(true), isolate: false, address: "192.168.8.1", netmask: "255.255.255.0"),
            SubnetPolicy(name: "guest", enabled: .value(on), isolate: true, wanAccess: .blockWANSubnet, address: "192.168.9.1", netmask: "255.255.255.0"),
            SubnetPolicy(name: "iot", enabled: .value(on), isolate: true, wanAccess: .blockWANSubnet, address: "192.168.10.1", netmask: "255.255.255.0"),
        ]
    }

    private static func mac(_ text: String) -> MACAddress { MACAddress(text)! }

    public static func air(_ scenario: Scenario) -> WiFiAir {
        let he = WiFiRate(megabitsPerSecond: 286.8, widthMHz: 20, mcs: 11, spatialStreams: 2, generation: .wifi6)
        let eht24 = WiFiRate(megabitsPerSecond: 344.1, widthMHz: 20, mcs: 13, spatialStreams: 2, generation: .wifi7)
        let ht = WiFiRate(megabitsPerSecond: 65, widthMHz: 20, mcs: 7, generation: .wifi4)
        let eht6 = WiFiRate(megabitsPerSecond: 2161.3, widthMHz: 160, mcs: 10, spatialStreams: 2, generation: .wifi7)
        let he6 = WiFiRate(megabitsPerSecond: 1200.9, widthMHz: 160, mcs: 11, spatialStreams: 1, generation: .wifi6)
        let he5 = WiFiRate(megabitsPerSecond: 1201, widthMHz: 80, mcs: 11, spatialStreams: 2, generation: .wifi6)
        let after = scenario == .afterSuggestions
        let multiLinkOn = after || scenario == .multiLinkOn
        let stations = [
            WiFiStation(interface: after ? "rai0" : "ra0", band: after ? .ghz5 : .ghz2_4, mac: mac("66:29:ea:33:fb:78"), signal: after ? -58 : -61,
                        txRate: after ? he5 : he, connectedSeconds: 7_200, inactiveMilliseconds: 40),
            WiFiStation(interface: multiLinkOn ? "rax2" : "ra0", band: multiLinkOn ? .ghz6 : .ghz2_4, mac: mac("ba:4d:21:07:3e:91"),
                        signal: multiLinkOn ? -64 : -47, txRate: multiLinkOn ? eht6 : eht24, connectedSeconds: 3_600, inactiveMilliseconds: 10),
            WiFiStation(interface: multiLinkOn ? "rax2" : "rax0", band: .ghz6, mac: mac("0e:e5:7b:da:22:c7"), signal: -66,
                        txRate: eht6, connectedSeconds: 9_000, inactiveMilliseconds: 120),
            WiFiStation(interface: "rax0", band: .ghz6, mac: mac("a4:83:e7:12:9c:01"), signal: -59, txRate: he6,
                        connectedSeconds: 12_000, inactiveMilliseconds: 300),
            WiFiStation(interface: scenario == .guestAndIoT ? "ra3" : "ra0", band: .ghz2_4, mac: mac("d8:1c:79:aa:04:53"), signal: -46,
                        txRate: ht, connectedSeconds: 50_000, inactiveMilliseconds: 900),
        ]
        let names = ["ra0", "ra1", "ra3", "rai0", "rai1", "rax0", "rax2"]
        let interfaces = names.compactMap { name -> WiFiInterface? in
            guard let valid = WiFiInterfaceName(name) else { return nil }
            let band: WirelessBand = name.hasPrefix("rax") ? .ghz6 : name.hasPrefix("rai") ? .ghz5 : .ghz2_4
            return WiFiInterface(name: valid, band: band, channel: band == .ghz6 ? 37 : band == .ghz5 ? 44 : 9)
        }
        let sections = [
            WirelessSectionOptions(section: "MT7990_1_1", type: "wifi-device", autoSkips: [12, 13]),
            WirelessSectionOptions(section: "MT7990_1_2", type: "wifi-device",
                                   autoSkips: after ? [149, 153, 157, 161, 165] : [52, 56, 60, 64] + Array(stride(from: 100, through: 165, by: 4)),
                                   dfsEnabled: true),
            WirelessSectionOptions(section: "MT7990_1_3", type: "wifi-device"),
            WirelessSectionOptions(section: "wifi2g", type: "wifi-iface", ifname: "ra0", emlMode: "emlsr", ieee80211k: true, bssTransition: true, ieee80211r: false),
            WirelessSectionOptions(section: "wifi5g", type: "wifi-iface", ifname: "rai0", emlMode: "emlsr", ieee80211k: true, bssTransition: true, ieee80211r: false),
            WirelessSectionOptions(section: "wifi6g", type: "wifi-iface", ifname: "rax0", emlMode: "emlsr", ieee80211k: true, bssTransition: true, ieee80211r: false),
        ]
        return WiFiAir(interfaces: interfaces, stations: stations, sections: sections)
    }
}

extension WiFiApplyPolicy {
    /// Short waits, so each step of the trail shows for a moment.
    static var mock: WiFiApplyPolicy {
        var policy = WiFiApplyPolicy()
        policy.settle = .seconds(1)
        policy.pollInterval = .milliseconds(500)
        policy.reconnectWindow = .seconds(4)
        policy.verifyDeadline = .seconds(3)
        return policy
    }
}

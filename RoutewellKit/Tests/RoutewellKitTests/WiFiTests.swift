import Foundation
import Testing
@testable import RoutewellKit
import RoutewellMock

// The Wi-Fi fixtures have the shapes of the 4.9.2 recordings and GL's web UI
// code, with the neutral names "Flint Home" and "Flint Home Fast".
private func wifiFixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/glinet/wifi"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

private func sshWiFiFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/ssh/wifi"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// Answers each SSH command with a fixture and records the commands.
private actor WiFiSSHRunner: SSHCommandRunning {
    private let replies: [String: (Int32, String)]
    private(set) var commands: [SSHCommand] = []

    init(_ replies: [String: (Int32, String)]) { self.replies = replies }

    func run(_ command: SSHCommand, limits: ProcessLimits) async throws -> ProcessResult {
        commands.append(command)
        let key = switch command {
        case .wifiInterfaces: "interfaces"
        case .wifiStations: "stations"
        case .wifiRadioOptions: "options"
        default: "other"
        }
        guard let (status, text) = replies[key] else { throw SSHFailure.timedOut }
        return ProcessResult(exitStatus: status, stdout: Data(text.utf8), stderr: Data(), stdoutTruncated: false, stderrTruncated: false)
    }
}

private enum WiFiStub {
    enum Answer: Sendable { case fixture(String), rpcError(Int), transport(TransportError) }

    static func service(_ answers: [String: Answer], runner: (any SSHCommandRunning)? = nil) -> LiveWiFiService {
        let endpoint = try! RouterEndpoint(scheme: .https, host: "192.0.2.20", port: 443)
        let transport = StubHTTPTransport { request in
            let url = request.url!
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            let id = body["id"]?.int ?? 0
            func envelope(_ payload: [String: JSONValue]) throws -> (Data, HTTPURLResponse) {
                var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .number(Double(id))]
                object.merge(payload) { $1 }
                return (try JSONEncoder().encode(JSONValue.object(object)), StubHTTPTransport.response(200, url: url))
            }
            switch body["method"]?.string {
            case "challenge": return try envelope(["result": .object(["alg": .number(1), "salt": .string("saltsalt12"), "nonce": .string("nonceabcdef")])])
            case "login": return try envelope(["result": .object(["sid": .string("SID")])])
            default: break
            }
            let key = "\(body["params"]?[1]?.string ?? "").\(body["params"]?[2]?.string ?? "")"
            switch answers[key] ?? .rpcError(-32601) {
            case .fixture(let name): return try envelope(["result": try wifiFixture(name)])
            case .transport(let error): throw error
            case .rpcError(let code): return try envelope(["error": .object(["code": .number(Double(code)), "message": .string("err")])])
            }
        }
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: "admin", password: { "pw" }, transport: transport)
        return LiveWiFiService(rpc: rpc, runner: runner, clock: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    static let all: [String: Answer] = [
        "wifi.get_config": .fixture("wifi-get-config"), "wifi.get_status": .fixture("wifi-get-status"),
        "wifi.get_mlo_config": .fixture("wifi-get-mlo-config"), "vlan_subnet.get_subnets": .fixture("vlan_subnet-get-subnets"),
    ]
}

@Suite struct WiFiParserTests {
    @Test func configAndStatusGiveRadiosChannelsAndNetworks() throws {
        let status = try #require(WirelessParser.parse(config: try wifiFixture("wifi-get-config"), status: try wifiFixture("wifi-get-status")))
        #expect(status.dfsSupport == true)
        let low = try #require(status.radio(.ghz2_4))
        #expect(low.isAutoChannel == true)
        #expect(low.currentChannel == 9)
        #expect(low.channels.map(\.number) == Array(1...13))
        #expect(low.widthOptions == [20, 40])
        #expect(low.autoWidth == true)
        #expect(low.hwmodeOptions == ["11b/g/n/ax/be", "11ax/be"])
        #expect(low.securityOptions == [.none, .wpa2, .wpa2WPA1, .wpa3, .wpa2WPA3])
        #expect(low.txPowerLevel == .max)
        #expect(low.state == .ready)
        #expect(low.mainNetwork?.ssid == "Flint Home")
        #expect(low.networks.map(\.kind) == [.main, .guest, .iot])
        let mid = try #require(status.radio(.ghz5))
        #expect(mid.widthMHz == 80)
        #expect(mid.widthOptions == [20, 40, 80, 160])
        #expect(mid.channels.filter(\.dfs).first?.number == 52)
        let high = try #require(status.radio(.ghz6))
        #expect(high.pscOnly == true)
        #expect(high.channels.filter(\.psc).map(\.number) == [5, 21, 37, 53, 69, 85])
        #expect(high.widthOptions == [20, 40, 80, 160, 320])
        #expect(high.state == .cac)
        #expect(high.mainNetwork?.encryption == .wpa3)
    }

    @Test func missingFieldsStayUnknown() throws {
        let config: JSONValue = .object(["res": .array([.object(["band": .string("5G"), "htmodes": .object(["auto": .number(1)]),
                                                                  "ifaces": .array([.object(["name": .string("rai0")])])])])])
        let radio = try #require(WirelessParser.parse(config: config, status: nil)?.radios.first)
        #expect(radio.device == nil)
        #expect(radio.channels.isEmpty)
        #expect(radio.widthOptions.isEmpty)
        #expect(radio.autoWidth == true)
        #expect(radio.state == nil)
        #expect(radio.txPowerLevel == nil)
        let network = try #require(radio.networks.first)
        #expect(network.enabled == .unknown)
        #expect(network.kind == nil)
        #expect(network.encryption == nil)
        #expect(network.password == nil)
        #expect(WirelessParser.parse(config: .object(["other": .null]), status: nil) == nil)
    }

    @Test func multiLinkAndSubnets() throws {
        let mlo = try #require(MLOParser.parse(try wifiFixture("wifi-get-mlo-config")))
        #expect(mlo.supportedBands == [.ghz2_4, .ghz5, .ghz6])
        let main = try #require(mlo.main)
        #expect(main.bands == [.ghz5, .ghz6])
        #expect(main.enabled == .value(false))
        #expect(!main.isOn)
        #expect(main.encryption == .wpa3)
        #expect(MLOParser.bands(.string("6g, 5g")) == [.ghz5, .ghz6])
        #expect(MLOParser.parse(.string("x")) == nil)

        let subnets = try #require(SubnetParser.parse(try wifiFixture("vlan_subnet-get-subnets")))
        #expect(subnets.map(\.name) == ["main", "guest", "iot"])
        #expect(subnets[1].isolate == true)
        #expect(subnets[1].wanAccess == .blockWANSubnet)
        #expect(subnets[1].enabled == .value(false))
        #expect(subnets[2].address == "192.168.10.1")
        #expect(subnets[2].fields["vlan_id"]?.int == 10)
        #expect(SubnetParser.parse(.object([:])) == nil)
    }

    @Test func interfacesKeepOnlyAccessPoints() throws {
        let interfaces = WiFiInterfaceParser.parse(try sshWiFiFixture("iw-dev"))
        #expect(interfaces.map(\.name.description) == ["ra0", "ra1", "rai0", "rax0", "ra15"])
        #expect(interfaces.map(\.band) == [.ghz2_4, nil, .ghz5, .ghz6, .ghz2_4])
        #expect(interfaces[1].channel == nil)
        #expect(WiFiInterfaceParser.parse("bad;name AP 1 2412\n").isEmpty)
    }

    @Test func stationDumpReadsEachGeneration() throws {
        let interfaces = WiFiInterfaceParser.parse(try sshWiFiFixture("iw-dev"))
        let stations = StationDumpParser.parse(try sshWiFiFixture("station-dump"), interfaces: interfaces)
        #expect(stations.count == 6)
        #expect(stations.map(\.interface) == ["ra0", "ra0", "ra0", "rai0", "rax0", "rax0"])
        #expect(stations.map(\.generation) == [.wifi4, .wifi6, .legacy, .wifi5, .wifi7, .wifi6])
        let wifi7 = stations[4]
        #expect(wifi7.band == .ghz6)
        #expect(wifi7.signal == -61)
        #expect(wifi7.txRate == WiFiRate(megabitsPerSecond: 2161.3, widthMHz: 160, mcs: 10, spatialStreams: 2, generation: .wifi7))
        #expect(wifi7.rxRate?.mcs == 8)
        #expect(wifi7.connectedSeconds == 9_000)
        #expect(wifi7.inactiveMilliseconds == 120)
        #expect(stations[3].txRate == WiFiRate(megabitsPerSecond: 866.7, widthMHz: 80, mcs: 9, spatialStreams: 2, generation: .wifi5))
        #expect(stations[0].txRate?.mcs == 7)
        #expect(stations[0].txRate?.spatialStreams == nil)
        #expect(stations[0].rxRate?.generation == .legacy)
        // Missing lines stay unknown.
        #expect(stations[5].signal == nil)
        #expect(stations[5].connectedSeconds == nil)
        #expect(stations[2].inactiveMilliseconds == nil)
        #expect(StationDumpParser.rate("unknown") == nil)
    }

    @Test func radioOptionsBySection() throws {
        let sections = WirelessOptionsParser.parse(try sshWiFiFixture("uci-wireless-options"))
        let air = WiFiAir(sections: sections)
        #expect(air.autoSkips(device: "MT7990_1_1") == [12, 13])
        #expect(air.autoSkips(device: "MT7990_1_2")?.first == 52)
        #expect(air.autoSkips(device: "MT7990_1_3") == nil)
        let mid = try #require(sections.first { $0.section == "MT7990_1_2" })
        #expect(mid.dfsEnabled == true)
        #expect(mid.type == "wifi-device")
        let main = try #require(sections.first { $0.ifname == "ra0" })
        #expect(main.ieee80211k == true)
        #expect(main.bssTransition == true)
        #expect(main.ieee80211r == false)
        #expect(sections.first { $0.section == "wlanmld5g" }?.emlMode == "emlsr")
    }

    @Test func passwordIsNeverPrinted() {
        let password = WiFiPassword("example-password")
        #expect(password.description == "<redacted>")
        #expect(String(describing: password) == "<redacted>")
        #expect(String(reflecting: password) == "<redacted>")
        var dumped = ""
        dump(WirelessNetwork(ssid: "Flint Home", password: password), to: &dumped)
        #expect(!dumped.contains("example-password"))
        #expect(!"\(WirelessNetwork(ssid: "Flint Home", password: password))".contains("example-password"))
    }
}

@Suite struct WiFiServiceTests {
    @Test func snapshotReadsEveryPart() async throws {
        let result = try await WiFiStub.service(WiFiStub.all).snapshot()
        #expect(result.capability.state == .supported)
        guard case .success(let snapshot, _, let source) = result.area else { Issue.record("expected a snapshot"); return }
        #expect(source == .routerRPC)
        #expect(try snapshot.wireless.get().radios.count == 3)
        #expect(try snapshot.mlo.get().main?.name == "mld0")
        #expect(try snapshot.subnets.get().count == 3)
    }

    @Test func aFailedPartFailsOnlyThatPart() async throws {
        var answers = WiFiStub.all
        answers["wifi.get_mlo_config"] = .transport(.timedOut)
        answers["vlan_subnet.get_subnets"] = .rpcError(-32601)
        answers["wifi.get_status"] = .rpcError(-32000)
        let result = try await WiFiStub.service(answers).snapshot()
        guard case .success(let snapshot, _, _) = result.area else { Issue.record("expected a snapshot"); return }
        #expect(snapshot.mlo == .failure(.timeout))
        #expect(snapshot.subnets == .failure(.unavailable))
        #expect(try snapshot.wireless.get().radios.allSatisfy { $0.currentChannel == nil && $0.state == nil })
    }

    @Test func onlyMethodNotFoundOnGetConfigIsUnsupported() async throws {
        let missing = try await WiFiStub.service([:]).snapshot()
        #expect(missing.capability.state == .unsupported)
        #expect(missing.capability.evidence == .methodNotFound(method: "wifi.get_config"))
        let failing = try await WiFiStub.service(["wifi.get_config": .transport(.unreachable(code: -1004))]).snapshot()
        #expect(failing.capability.state == .unknown)
        guard case .failure(.network, _) = failing.area else { Issue.record("expected a network failure"); return }
    }

    @Test func airReadsInterfacesThenStationsThenOptions() async throws {
        let runner = WiFiSSHRunner(["interfaces": (0, try sshWiFiFixture("iw-dev")), "stations": (0, try sshWiFiFixture("station-dump")),
                                    "options": (0, try sshWiFiFixture("uci-wireless-options"))])
        let result = try await WiFiStub.service([:], runner: runner).air()
        guard case .success(let air, _, let source) = result else { Issue.record("expected air"); return }
        #expect(source == .routerSSH)
        #expect(air.stations?.count == 6)
        #expect(air.sections?.isEmpty == false)
        let commands = await runner.commands
        #expect(commands.count == 3)
        guard case .wifiStations(let names) = commands[1] else { Issue.record("expected the station read"); return }
        #expect(names.map(\.description) == ["ra0", "ra1", "rai0", "rax0", "ra15"])
    }

    @Test func airWithoutSSHOrInterfacesFails() async throws {
        guard case .failure(.unavailable, _) = try await WiFiStub.service([:]).air() else { Issue.record("expected unavailable"); return }
        let runner = WiFiSSHRunner(["options": (0, "")])
        guard case .failure(.timeout, _) = try await WiFiStub.service([:], runner: runner).air() else { Issue.record("expected a timeout"); return }
        // A failed station read keeps the bands without signal.
        let partial = WiFiSSHRunner(["interfaces": (0, "ra0 AP 9 2452\n"), "stations": (1, ""), "options": (0, "")])
        guard case .success(let air, _, _) = try await WiFiStub.service([:], runner: partial).air() else { Issue.record("expected air"); return }
        #expect(air.stations == nil)
        #expect(air.interfaces?.count == 1)
        // A failed interface read never becomes "no devices".
        let noInterfaces = WiFiSSHRunner(["interfaces": (1, ""), "options": (0, "")])
        guard case .failure = try await WiFiStub.service([:], runner: noInterfaces).air() else { Issue.record("expected a failure"); return }
    }

    @Test func commandsRenderOnlyValidatedNames() throws {
        let names = try ["ra0", "rax0"].map { try #require(WiFiInterfaceName($0)) }
        #expect(SSHCommand.wifiStations(names).rendered
            == "r=0; for i in ra0 rax0; do echo \"== $i\"; iw dev \"$i\" station dump || r=1; done; exit $r")
        #expect(SSHCommand.wifiInterfaces.rendered.hasPrefix("o=$(iw dev) || exit; "))
        #expect(WiFiInterfaceName("ra0;reboot") == nil)
        #expect(!SSHCommand.wifiRadioOptions.rendered.contains("key"))
        #expect(!SSHCommand.wifiRadioOptions.rendered.contains("ssid"))
        #expect(!SSHCommand.wifiInterfaces.takesInput)
    }

    @Test func recorderPlanHasTheWiFiReads() {
        let plan = FixtureRecordingPlan.calls
        for method in ["get_config", "get_status", "get_mlo_config"] {
            #expect(plan.contains { $0.object == "wifi" && $0.method == method })
        }
        #expect(plan.contains { $0.object == "vlan_subnet" && $0.method == "get_subnets" })
        #expect(FixtureRecordingPlan.sshReads["wifi-interfaces"] == .wifiInterfaces)
        #expect(FixtureRecordingPlan.sshReads["wifi-radio-options"] == .wifiRadioOptions)
        #expect(plan.allSatisfy(FixtureRecordingPlan.isReadOnly))
        // The key never passes the redactor.
        let redacted = RecordedFixtureRedactor.redact(.object(["key": .string("secret-value"), "encryption": .string("sae-mixed")]))
        #expect(redacted["key"]?.string != "secret-value")
        #expect(redacted["encryption"]?.string == "sae-mixed")
    }
}

@Suite struct WiFiOverviewTests {
    private static let names: [String: String] = [
        "66:29:ea:33:fb:78": "Phone A", "ba:4d:21:07:3e:91": "Phone B", "0e:e5:7b:da:22:c7": "Laptop",
        "a4:83:e7:12:9c:01": "Tablet", "d8:1c:79:aa:04:53": "Plug",
    ]

    private func clients(bands: [String: WirelessBand] = [:]) -> [WiFiClientInfo] {
        Self.names.map { mac, name in WiFiClientInfo(mac: MACAddress(mac)!, name: name, band: bands[mac] ?? .ghz2_4) }
    }

    private func overview(_ scenario: MockWiFiService.Scenario, ssh: Bool = true, clients: [WiFiClientInfo]? = nil) -> WiFiOverview {
        WiFiOverview(wireless: MockWiFiService.wireless(scenario), mlo: MockWiFiService.mlo(scenario),
                     air: ssh ? MockWiFiService.air(scenario) : nil, clients: clients ?? self.clients())
    }

    @Test func networksAreGroupedByName() {
        let today = overview(.today)
        #expect(today.groups.map(\.name) == ["Flint Home", "Flint Home Fast"])
        #expect(today.groups.map(\.bands) == [[.ghz2_4], [.ghz5, .ghz6]])
        #expect(today.groups.map(\.deviceCount) == [3, 2])
        #expect(today.missing == [.guest, .iot, .multiLink])
        #expect(today.multiLink == nil)

        let oneName = overview(.afterSuggestions)
        #expect(oneName.groups.map(\.name) == ["Flint Home"])
        #expect(oneName.groups.first?.bands == [.ghz2_4, .ghz5, .ghz6])
        #expect(oneName.multiLink?.ssid == "Flint Home 7")
        #expect(oneName.missing == [.guest, .iot])
        // Stations outside `get_config` belong to the multi-link network.
        #expect(oneName.devices.filter { $0.network == "Flint Home 7" }.count == 2)

        let guests = overview(.guestAndIoT)
        #expect(guests.groups.map(\.kind) == [.main, .main, .guest, .iot])
        #expect(guests.groups[2].bands == [.ghz2_4, .ghz5])
        #expect(guests.groups[3].deviceCount == 1)
        #expect(guests.missing == [.multiLink])
    }

    @Test func onlyLinkStationsUseMultiLinkWhenTheNamesMatch() {
        var mlo = MockWiFiService.mlo(.multiLinkOn)
        mlo.networks[0].ssid = "Flint Home Fast"
        #expect(mlo.main?.isOn == true)
        let view = WiFiOverview(wireless: MockWiFiService.wireless(.today), mlo: mlo, air: MockWiFiService.air(.today), clients: clients())
        #expect(view.devices.filter { $0.network == "Flint Home Fast" }.count == 2)
        #expect(view.devices.filter(\.viaLink).isEmpty)
        #expect(overview(.multiLinkOn).devices.filter(\.viaLink).count == 2)
    }

    @Test func withoutSSHDevicesComeFromTheClientListWithoutSignal() {
        let bands: [String: WirelessBand] = ["0e:e5:7b:da:22:c7": .ghz6, "a4:83:e7:12:9c:01": .ghz6]
        let view = overview(.today, ssh: false, clients: clients(bands: bands) + [WiFiClientInfo(mac: MACAddress("02:00:00:00:00:09")!, band: .ghz5, online: false)])
        #expect(!view.hasStations)
        #expect(view.devices.count == 5)
        #expect(view.devices.allSatisfy { $0.signal == nil && $0.generation == nil })
        #expect(view.devices.first { $0.band == .ghz6 }?.network == "Flint Home Fast")
        // One network per band holds the count; nothing needs signal.
        #expect(view.groups.map(\.deviceCount) == [3, 2])
        #expect(view.suggestions.isEmpty)
        // No client list: no counts.
        #expect(WiFiOverview(wireless: MockWiFiService.wireless(.today), mlo: nil, air: nil, clients: nil).groups.allSatisfy { $0.deviceCount == nil })
    }

    @Test func generationAndFasterBandRules() {
        let today = overview(.today)
        let phoneA = today.devices.first { $0.mac == MACAddress("66:29:ea:33:fb:78") }
        #expect(phoneA?.generation == .wifi6)
        #expect(phoneA?.canUseFasterBand == true)
        #expect(phoneA?.strength == .fair)
        let plug = today.devices.first { $0.mac == MACAddress("d8:1c:79:aa:04:53") }
        #expect(plug?.generation == .wifi4)
        #expect(plug?.canUseFasterBand == false)
        // One name on every band: no faster band under another name.
        #expect(overview(.afterSuggestions).devices.allSatisfy { !$0.canUseFasterBand })
        #expect(SignalStrength(dBm: -50) == .strong)
        #expect(SignalStrength(dBm: -51) == .good)
        #expect(SignalStrength(dBm: -70) == .fair)
        #expect(SignalStrength(dBm: -71) == .weak)
    }

    @Test func suggestionRules() {
        let today = overview(.today)
        #expect(today.suggestions.map(\.kind) == [.fasterBand, .multiLinkReady, .ownNetwork, .dfsChannels])
        #expect(today.suggestions[0].devices.count == 2)
        #expect(today.suggestions[1].devices.count == 2)
        #expect(today.suggestions[2].devices == [MACAddress("d8:1c:79:aa:04:53")!])
        // One name and multi-link leave only the IoT suggestion.
        #expect(overview(.afterSuggestions).suggestions.map(\.kind) == [.ownNetwork])
        // The IoT network is on: no "own network" suggestion.
        #expect(!overview(.guestAndIoT).suggestions.map(\.kind).contains(.ownNetwork))
        // Without SSH only the rules that need no SSH data can apply, and DFS needs the skip list.
        #expect(overview(.today, ssh: false).suggestions.isEmpty)
        // A failed multi-link read hides the multi-link tile and its suggestion.
        let noLink = WiFiOverview(wireless: MockWiFiService.wireless(.today), mlo: nil, air: MockWiFiService.air(.today), clients: clients())
        #expect(!noLink.missing.contains(.multiLink))
        #expect(!noLink.suggestions.map(\.kind).contains(.multiLinkReady))
    }

    @Test func mockScenariosCoverTheCapabilityStates() async throws {
        let service = MockWiFiService()
        service.setScenario(.methodNotFound)
        #expect(try await service.snapshot().capability.state == .unsupported)
        service.setScenario(.multiLinkFails)
        guard case .success(let snapshot, _, _) = try await service.snapshot().area else { Issue.record("expected a snapshot"); return }
        #expect(snapshot.mlo == .failure(.timeout))
        service.setScenario(.sshOff)
        guard case .failure(.unavailable, _) = try await service.air() else { Issue.record("expected no air"); return }
        let backend = MockRouterBackend()
        #expect(backend.ssh != nil)
        backend.mockWiFi.setScenario(.sshOff)
        #expect(backend.ssh == nil)
    }
}

@Suite struct WiFiMultiLinkClientTests {
    @Test func multiLinkClientCountsAsWiFi() throws {
        let url = try #require(Bundle.module.url(forResource: "clients-get_list-mld", withExtension: "json", subdirectory: "Fixtures/glinet/clients"))
        let list = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let status = GLiNetStatusParser.clientStatus(getStatus: nil, clientList: list)
        #expect(status.onlineByBand == [.ghz2_4: 1])
        #expect(status.onlineMultiLink == 1)
        #expect(status.onlineWiFi == 2)

        let connection = GLiNetClientListParser.connection(interface: "mld")
        #expect(connection.medium == .value(.wifi) && connection.band == ClientConnection.multiLink)

        // Without SSH the client is a multi-link device with no band.
        let clients = [
            WiFiClientInfo(mac: MACAddress("02:00:00:00:01:01")!, band: .ghz2_4),
            WiFiClientInfo(mac: MACAddress("02:00:00:00:01:02")!, multiLink: true),
        ]
        let overview = WiFiOverview(wireless: MockWiFiService.wireless(.today), mlo: MockWiFiService.mlo(.multiLinkOn), air: nil, clients: clients)
        #expect(overview.devices.count == 2)
        let linked = try #require(overview.devices.first { $0.viaLink })
        #expect(linked.band == nil && linked.network == MockWiFiService.multiLink)
    }
}

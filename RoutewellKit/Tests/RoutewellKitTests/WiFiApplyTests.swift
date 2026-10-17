import Foundation
import Synchronization
import Testing
@testable import RoutewellKit
import RoutewellMock

private final class ApplyClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_790_000_000))

    func now() -> Date { current.withLock { $0 } }

    func sleep(_ duration: Duration) async throws {
        current.withLock { $0 = $0.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) }
        try Task.checkCancellation()
    }
}

/// A router in memory. `apply` decides what a write does to it.
private actor FakeRouter: WiFiApplyTransport {
    enum Send { case apply, applyThenLose, applyThenCloseSSH, ignore, errCode(Int), throwError(GLiNetRPCError) }

    var wireless: WirelessStatus
    var subnets: [SubnetPolicy]
    var sections: [WirelessSectionOptions]
    var sends: [Send]
    /// Radio states after the first write, read in turn; the last one stays.
    var states: [[WirelessBand: RadioState]] = []
    /// Reads after the first write that fail before the router answers again.
    var unreachableReads = 0
    /// Reads that still show the old values.
    var staleReads = 0
    private(set) var sent: [WiFiCall] = []
    private var stale: WirelessStatus?

    init(wireless: WirelessStatus = MockWiFiService.wireless(.today), subnets: [SubnetPolicy] = MockWiFiService.subnets(.today),
         sections: [WirelessSectionOptions] = MockWiFiService.air(.today).sections ?? [], sends: [Send] = [.apply]) {
        self.wireless = wireless
        self.subnets = subnets
        self.sections = sections
        self.sends = sends
    }

    func set(states: [[WirelessBand: RadioState]]) { self.states = states }

    func set(unreachable: Int = 0, stale: Int = 0) {
        unreachableReads = unreachable
        staleReads = stale
    }

    func edit(_ change: (inout WirelessStatus) -> Void) { change(&wireless) }

    func readWireless() async throws -> WirelessStatus {
        if !sent.isEmpty, unreachableReads > 0 { unreachableReads -= 1; throw GLiNetRPCError.transport(.timedOut) }
        if staleReads > 0, let stale { staleReads -= 1; return stale }
        guard !sent.isEmpty, let next = states.first else { return wireless }
        if states.count > 1 { states.removeFirst() }
        var read = wireless
        for index in read.radios.indices { if let band = read.radios[index].band, let state = next[band] { read.radios[index].state = state } }
        return read
    }

    func readSubnets() async throws -> [SubnetPolicy] { subnets }

    var mlo = MockWiFiService.mlo(.today)
    func readMLO() async throws -> MLOConfiguration { mlo }
    func editMLO(_ change: (inout MLOConfiguration) -> Void) { change(&mlo) }

    func readOptions() async throws -> [WirelessSectionOptions] { sections }

    func editSections(_ change: (inout [WirelessSectionOptions]) -> Void) { change(&sections) }

    func readRadioStates() async throws -> [WirelessBand: RadioState] {
        if !sent.isEmpty, unreachableReads > 0 { unreachableReads -= 1; throw GLiNetRPCError.transport(.unreachable(code: -1004)) }
        return [.ghz2_4: .ready, .ghz5: .ready, .ghz6: .ready]
    }

    func send(_ call: WiFiCall) async throws -> Int? {
        sent.append(call)
        let next = sends.count > 1 ? sends.removeFirst() : sends[0]
        if stale == nil { stale = wireless }
        switch next {
        case .apply: store(call); return nil
        case .applyThenLose: store(call); throw GLiNetRPCError.transport(.timedOut)
        case .applyThenCloseSSH: store(call); throw SSHFailure.connectionFailed
        case .ignore: return nil
        case .errCode(let code): return code
        case .throwError(let error): throw error
        }
    }

    private func store(_ call: WiFiCall) {
        switch call {
        case .network(let slot, _, let settings):
            if let settings, let index = wireless.radios.firstIndex(where: { $0.band == settings.band }) {
                wireless.radios[index].configuredChannel = settings.channel
                wireless.radios[index].htmode = settings.width.map(String.init) ?? "auto"
                wireless.radios[index].hwmode = settings.hwmode
                wireless.radios[index].txPower = settings.txPower.wire
                if settings.pscOnly != nil { wireless.radios[index].pscOnly = settings.pscOnly }
            }
            for radio in wireless.radios.indices {
                for index in wireless.radios[radio].networks.indices where wireless.radios[radio].networks[index].interface == slot.interface {
                    wireless.radios[radio].networks[index].ssid = slot.ssid
                    wireless.radios[radio].networks[index].encryption = slot.security
                    wireless.radios[radio].networks[index].password = slot.password
                    wireless.radios[radio].networks[index].hidden = slot.hidden
                    wireless.radios[radio].networks[index].randomBSSID = slot.randomBSSID
                    if let enabled = slot.enabled { wireless.radios[radio].networks[index].enabled = .value(enabled) }
                }
            }
        case .subnet(let subnet, let isolate):
            for index in subnets.indices where subnets[index].name == subnet.name { subnets[index].isolate = isolate }
        case .rules(let subnet, let rules):
            for index in subnets.indices where subnets[index].name == subnet.name {
                if let eachOther = rules.eachOther { subnets[index].isolate = !eachOther }
                if let modem = rules.reachesModem { subnets[index].wanAccess = modem ? .unrestricted : .blockWANSubnet }
            }
        case .mlo(let network):
            for index in mlo.networks.indices where mlo.networks[index].name == network.name { mlo.networks[index] = network }
        case .options(let writes):
            for write in writes {
                guard let index = sections.firstIndex(where: { $0.section == write.section.description }) else { continue }
                switch write.setting {
                case .roamingHelp(let on): sections[index].ieee80211k = on; sections[index].bssTransition = on
                case .fastRoaming(let on): sections[index].ieee80211r = on
                case .autoSkips(let channels): sections[index].autoSkips = channels
                }
            }
        }
    }
}

private enum Sample {
    static let wireless = MockWiFiService.wireless(.today)
    static let devices = WiFiOverview(wireless: wireless, mlo: MockWiFiService.mlo(.today), air: MockWiFiService.air(.today), clients: nil).devices
    static let password = WiFiPassword("example-password")
    /// The MacBook Air on "Flint Home Fast", 6 GHz.
    static let macOnFast = ThisMacLink.wifi(band: .ghz6, interface: "rax0")

    static func home(_ change: (inout WiFiNetworkEdit) -> Void = { _ in }) -> WiFiNetworkEdit {
        var edit = WiFiNetworkEdit(interfaces: ["ra0"], name: MockWiFiService.home, password: password, security: .wpa2WPA3, hidden: false,
                                   randomBSSID: true, bands: [.ghz2_4])
        change(&edit)
        return edit
    }

    static func fast(_ change: (inout WiFiNetworkEdit) -> Void = { _ in }) -> WiFiNetworkEdit {
        var edit = WiFiNetworkEdit(interfaces: ["rai0", "rax0"], name: MockWiFiService.fast, password: password, security: .wpa3,
                                   hidden: false, randomBSSID: true, bands: [.ghz5, .ghz6])
        change(&edit)
        return edit
    }

    static func plan(_ change: WiFiChangeSet, mac: ThisMacLink = macOnFast) -> WiFiApplyPlan {
        WiFiApplyPlan(change: change, wireless: wireless, subnets: MockWiFiService.subnets(.today), devices: devices, thisMac: mac)
    }

    static func radio(_ band: WirelessBand, _ change: (inout WiFiRadioSettings) -> Void = { _ in }) -> WiFiRadioSettings {
        var settings = WiFiRadioSettings(wireless.radio(band)!)!
        change(&settings)
        return settings
    }

    static func planWithOptions(_ change: WiFiChangeSet, mac: ThisMacLink = macOnFast) -> WiFiApplyPlan {
        WiFiApplyPlan(change: change, wireless: wireless, subnets: nil, options: MockWiFiService.air(.today).sections, devices: devices, thisMac: mac)
    }

    static func executor(_ router: FakeRouter, gate: MutationGate = MutationGate(), clock: ApplyClock = ApplyClock(),
                         log: SessionEventLog? = nil) -> WiFiApplyExecutor {
        WiFiApplyExecutor(transport: router, gate: gate, clock: clock.now, sleep: clock.sleep, log: log)
    }
}


@Suite struct WiFiApplyPlanTests {
    @Test func noChangeSendsNothing() {
        #expect(Sample.plan(WiFiChangeSet(networks: [Sample.home(), Sample.fast()])).isEmpty)
    }

    @Test func visibleRestartsTheRadio() throws {
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.home { $0.hidden = true }]))
        #expect(plan.steps.count == 1)
        let step = try #require(plan.steps.first)
        #expect(step.scopes == [.radio(.ghz2_4)])
        guard case .network(let slot, _, _) = step.call else { Issue.record("not a network call"); return }
        #expect(slot.interface == "ra0" && slot.hidden == true && slot.password == Sample.password)
        #expect(plan.mustJoin.isEmpty)
        #expect(Set(plan.reconnect) == [MACAddress("66:29:ea:33:fb:78")!, MACAddress("ba:4d:21:07:3e:91")!, MACAddress("d8:1c:79:aa:04:53")!])
        #expect(plan.thisMac == .staysConnected)
        #expect(plan.restarts == [.radio(.ghz2_4)])
    }

    @Test func passwordRestartsTheNetworkAndDevicesJoinAgain() {
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.fast { $0.password = WiFiPassword("another-password") }]))
        #expect(plan.steps.map(\.scopes) == [[.network(.ghz5)], [.network(.ghz6)]])
        #expect(Set(plan.mustJoin) == [MACAddress("0e:e5:7b:da:22:c7")!, MACAddress("a4:83:e7:12:9c:01")!])
        #expect(plan.reconnect.isEmpty)
        #expect(plan.thisMac == .mustEnterPassword(MockWiFiService.fast))
    }

    @Test func newNameMeansTheMacJoinsByHand() {
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.fast { $0.name = "Flint Home Up" }]))
        #expect(plan.thisMac == .mustJoin("Flint Home Up"))
        #expect(plan.thisMac.drops)
    }

    @Test func macPredictionPerLink() {
        let visible = WiFiChangeSet(networks: [Sample.fast { $0.hidden = true }])
        #expect(Sample.plan(visible).thisMac == .dropsThenJoins(MockWiFiService.fast))
        #expect(Sample.plan(visible, mac: .ethernet).thisMac == .staysOnEthernet)
        #expect(Sample.plan(visible, mac: .wifi(band: .ghz2_4, interface: "ra0")).thisMac == .staysConnected)
        #expect(Sample.plan(visible, mac: .unknown).thisMac == .unknown)
        // Without stations the band names the slot.
        #expect(Sample.plan(visible, mac: .wifi(band: .ghz6, interface: nil)).thisMac == .dropsThenJoins(MockWiFiService.fast))
    }

    @Test func macOnAnotherNetworkOfTheRadioRejoinsItsOwn() {
        let guest = WiFiChangeSet(networks: [Sample.home { $0.hidden = true; $0.name = "Flint Home Up"; $0.password = WiFiPassword("another-password") }])
        let wireless = MockWiFiService.wireless(.guestAndIoT)
        let plan = WiFiApplyPlan(change: guest, wireless: wireless, subnets: nil, devices: [], thisMac: .wifi(band: .ghz2_4, interface: "ra1"))
        #expect(plan.thisMac == .dropsThenJoins(MockWiFiService.guest))
    }

    @Test func otherBandsKeepFieldsTheEditLeaves() throws {
        var wireless = Sample.wireless
        let other = WiFiPassword("second-password")
        for radio in wireless.radios.indices {
            for index in wireless.radios[radio].networks.indices where wireless.radios[radio].networks[index].interface == "rax0" {
                wireless.radios[radio].networks[index].password = other
            }
        }
        let plan = WiFiApplyPlan(change: WiFiChangeSet(networks: [Sample.fast { $0.hidden = true }]), wireless: wireless,
                                 subnets: nil, devices: Sample.devices, thisMac: .ethernet)
        let slots = plan.calls.compactMap { call -> WiFiSlotState? in if case .network(let slot, _, _) = call { slot } else { nil } }
        #expect(slots.map(\.interface) == ["rai0", "rax0"])
        #expect(slots.allSatisfy { $0.hidden == true })
        #expect(slots.map(\.password) == [Sample.password, other])

        // Use One Name makes the password the same on every band.
        let one = WiFiApplyPlan(change: WiFiChangeSet(networks: [Sample.fast { $0.sameOnEveryBand = true }]), wireless: wireless,
                                subnets: nil, devices: Sample.devices, thisMac: .ethernet)
        let unified = one.calls.compactMap { call -> WiFiSlotState? in if case .network(let slot, _, _) = call { slot } else { nil } }
        #expect(unified.map(\.interface) == ["rax0"])
        #expect(unified.map(\.password) == [Sample.password])
    }

    @Test func useOneNameMovesTheBands() {
        // "Flint Home" on every band: with 6 GHz it must be WPA3.
        let edit = Sample.home { $0.bands = [.ghz2_4, .ghz5, .ghz6]; $0.security = .wpa3 }
        #expect(edit.problems.isEmpty)
        let plan = Sample.plan(WiFiChangeSet(networks: [edit]))
        let slots = plan.calls.compactMap { call -> WiFiSlotState? in if case .network(let slot, _, _) = call { slot } else { nil } }
        #expect(slots.map(\.interface) == ["ra0", "rai0", "rax0"])
        #expect(slots.allSatisfy { $0.ssid == MockWiFiService.home && $0.security == .wpa3 && $0.enabled == true })
        // Both names change for someone: all five devices join again.
        #expect(plan.mustJoin.count == 5)
        #expect(plan.thisMac == .mustJoin(MockWiFiService.home))
    }

    @Test func takingABandAwayTurnsItsSlotOff() throws {
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.fast { $0.bands = [.ghz5] }]))
        #expect(plan.steps.count == 1)
        guard case .network(let slot, _, _) = try #require(plan.calls.first) else { Issue.record("not a network call"); return }
        #expect(slot.interface == "rax0" && slot.enabled == false)
        #expect(plan.steps.first?.scopes == [.network(.ghz6)])
        #expect(plan.mustJoin.isEmpty)
        #expect(Set(plan.reconnect) == [MACAddress("0e:e5:7b:da:22:c7")!, MACAddress("a4:83:e7:12:9c:01")!])
        // The Mac moves to 5 GHz, which keeps the name.
        #expect(plan.thisMac == .dropsThenJoins(MockWiFiService.fast))
    }

    @Test func isolationComesFirstAndKeepsTheOtherFields() throws {
        let main = SubnetPolicy(name: "main", enabled: .value(true), isolate: false, address: "192.168.8.1",
                                fields: ["display_name": .string("Main"), "ip": .string("192.168.8.1"), "isolate": .number(0),
                                         "leasetime": .string("12h"), "vlan_id": .number(1), "unknown_field": .string("x")])
        let change = WiFiChangeSet(networks: [Sample.home { $0.hidden = true }], isolate: true)
        let plan = WiFiApplyPlan(change: change, wireless: Sample.wireless, subnets: [main], devices: Sample.devices, thisMac: .ethernet)
        #expect(plan.steps.map(\.scopes) == [[.subnet], [.radio(.ghz2_4)]])
        let params = try #require(plan.calls.first?.params?.object)
        #expect(params["isolate"] == .number(1))
        #expect(params["leasetime"] == .string("12h"))
        #expect(params["vlan_id"] == nil && params["unknown_field"] == nil)
    }

    @Test func editProblems() {
        #expect(Sample.home { $0.name = " " }.problems == [.emptyName])
        #expect(Sample.home { $0.name = String(repeating: "é", count: 17) }.problems == [.nameTooLong])
        #expect(Sample.home { $0.password = WiFiPassword("short") }.problems == [.passwordLength])
        #expect(Sample.home { $0.password = WiFiPassword(String(repeating: "a", count: 64)) }.problems.isEmpty)
        #expect(Sample.home { $0.security = .none; $0.password = nil }.problems.isEmpty)
        #expect(Sample.home { $0.bands = [] }.problems == [.noBand])
        #expect(Sample.home { $0.bands = [.ghz6] }.problems == [.wpa3With6GHz])
    }

    @Test func keyIsAlwaysSentAndNeverPrinted() throws {
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.home { $0.hidden = true }]))
        let call = try #require(plan.calls.first)
        #expect(call.params?["key"] == .string("example-password"))
        #expect(!call.description.contains("example-password"))
        #expect(!String(describing: plan).contains("example-password"))
        #expect(!String(reflecting: plan).contains("example-password"))
        // An open network still sends the key it read.
        let open = WiFiCall.network(WiFiSlotState(interface: "ra0", security: WiFiSecurity.none, password: Sample.password), initialised: true, radio: nil)
        #expect(open.params?["key"] == .string("example-password") && open.params?["encryption"] == .string("none"))
    }
}

@Suite struct WiFiApplyExecutorTests {
    private var visible: WiFiApplyPlan { Sample.plan(WiFiChangeSet(networks: [Sample.home { $0.hidden = true }])) }

    @Test func appliesAndVerifies() async {
        let router = FakeRouter()
        let gate = MutationGate()
        let steps = StepLog()
        let report = await Sample.executor(router, gate: gate).apply(visible) { await steps.add($0) }
        guard case .verifiedSuccess(let state) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(state.slots.first?.hidden == true)
        #expect(report.dispatched)
        #expect(await router.sent.count == 1)
        #expect(await steps.all == [.sending, .restarting, .checking])
        #expect(await gate.isHeld == false)
    }

    @Test func concurrentAppliesRunOneAtATime() async throws {
        let router = FakeRouter()
        let gate = MutationGate()
        let held = try await gate.acquire()
        let executor = Sample.executor(router, gate: gate)
        let plan = visible
        let waiting = Task { await executor.apply(plan) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await router.sent.isEmpty)
        await gate.release(held)
        guard case .verifiedSuccess = await waiting.value.outcome else { Issue.record("not applied"); return }
        #expect(await router.sent.count == 1)
    }

    @Test func cancelWhileQueuedSendsNothing() async throws {
        let router = FakeRouter()
        let gate = MutationGate()
        let held = try await gate.acquire()
        let executor = Sample.executor(router, gate: gate)
        let plan = visible
        let waiting = Task { await executor.apply(plan) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        let report = await waiting.value
        #expect(report.outcome == .rejected(.preconditionFailed("Cancelled before dispatch")))
        #expect(!report.dispatched)
        #expect(await router.sent.isEmpty)
        await gate.release(held)
    }

    @Test func lostReplyWaitsForTheRouterThenVerifies() async {
        let router = FakeRouter(sends: [.applyThenLose])
        await router.set(unreachable: 3)
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.home { $0.name = "Flint Home Up" }]))
        let steps = StepLog()
        let report = await Sample.executor(router).apply(plan) { await steps.add($0) }
        guard case .verifiedSuccess = report.outcome else { Issue.record("\(report.outcome)"); return }
        // Nothing is sent after a lost reply.
        #expect(await router.sent.count == 1)
        #expect(await steps.all == [.sending, .restarting, .reconnecting, .checking])
    }

    @Test func lostReplyStopsTheRestAndReportsAMismatch() async {
        let router = FakeRouter(sends: [.applyThenLose])
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.fast { $0.name = "Flint Home Up" }]))
        let report = await Sample.executor(router).apply(plan)
        guard case .verifiedMismatch(_, let actual) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(actual.slots.map(\.ssid) == ["Flint Home Up", MockWiFiService.fast])
        #expect(await router.sent.count == 1)
    }

    @Test func eventualConsistency() async {
        let router = FakeRouter()
        await router.set(stale: 2)
        guard case .verifiedSuccess = await Sample.executor(router).apply(visible).outcome else { Issue.record("not verified"); return }
    }

    @Test func externalEditSendsNothing() async {
        let router = FakeRouter()
        await router.edit { $0.radios[0].networks[0].ssid = "Renamed Elsewhere" }
        let report = await Sample.executor(router).apply(visible)
        guard case .conflictingExternalEdit(let actual) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(actual.slots.first?.ssid == "Renamed Elsewhere")
        #expect(!report.dispatched)
        #expect(await router.sent.isEmpty)
    }

    @Test func missingRadioStateIsNotSuccess() async {
        let router = FakeRouter()
        await router.edit { wireless in
            for index in wireless.radios.indices { wireless.radios[index].state = nil }
        }
        let report = await Sample.executor(router).apply(visible)
        guard case .verifiedMismatch = report.outcome else { Issue.record("\(report.outcome)"); return }
    }

    @Test func mismatchIsNotSentAgain() async {
        let router = FakeRouter(sends: [.ignore])
        let report = await Sample.executor(router).apply(visible)
        guard case .verifiedMismatch(let expected, let actual) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(expected.slots.first?.hidden == true && actual.slots.first?.hidden == false)
        #expect(await router.sent.count == 1)
    }

    @Test func errorCodeOnTheFirstCallIsRejected() async {
        let router = FakeRouter(sends: [.errCode(-1)])
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.fast { $0.hidden = true }]))
        let report = await Sample.executor(router).apply(plan)
        #expect(report.outcome == .rejected(.preconditionFailed(WiFiApplyExecutor.refusedMessage(-1))))
        #expect(report.dispatched)
        #expect(await router.sent.count == 1)
    }

    @Test func invalidParametersBeforeAnyCallIsRejected() async {
        let router = FakeRouter(sends: [.throwError(.invalidParameters)])
        let report = await Sample.executor(router).apply(visible)
        guard case .rejected = report.outcome else { Issue.record("\(report.outcome)"); return }
    }

    @Test func macNotBackIsUnknown() async {
        let router = FakeRouter()
        await router.set(unreachable: 1000)
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.fast { $0.hidden = true }]))
        let report = await Sample.executor(router).apply(plan)
        #expect(report.outcome == .unknownAfterDispatch)
        #expect(report.dispatched)
    }

    @Test func isolationVerifies() async {
        let router = FakeRouter()
        let plan = Sample.plan(WiFiChangeSet(isolate: true), mac: .ethernet)
        guard case .verifiedSuccess(let state) = await Sample.executor(router).apply(plan).outcome else { Issue.record("not verified"); return }
        #expect(state.isolate == true)
    }

    @Test func logNeverHoldsTheKey() async {
        let log = SessionEventLog()
        let router = FakeRouter(sends: [.errCode(5)])
        _ = await Sample.executor(router, log: log).apply(Sample.plan(WiFiChangeSet(networks: [Sample.home { $0.hidden = true }])))
        let text = await log.events().map { "\($0)" }.joined()
        #expect(!text.isEmpty)
        #expect(!text.contains("example-password"))
    }

    @Test func liveTransportSendsGLShapes() async throws {
        let bodies = BodyLog()
        let endpoint = try RouterEndpoint(scheme: .https, host: "192.0.2.20", port: 443)
        let transport = StubHTTPTransport { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            let result: JSONValue = switch body["method"]?.string {
            case "challenge": .object(["alg": .number(1), "salt": .string("saltsalt12"), "nonce": .string("nonceabcdef")])
            case "login": .object(["sid": .string("SID")])
            default: .object([:])
            }
            await bodies.add(body)
            let envelope = JSONValue.object(["jsonrpc": .string("2.0"), "id": body["id"] ?? .number(0), "result": result])
            return (try JSONEncoder().encode(envelope), StubHTTPTransport.response(200, url: request.url!))
        }
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: "admin", password: { "pw" }, transport: transport)
        let call = try #require(visible.calls.first)
        #expect(try await LiveWiFiApplyTransport(rpc: rpc).send(call) == nil)
        let sent = try #require(await bodies.all.last)
        #expect(sent["params"]?[1] == .string("wifi") && sent["params"]?[2] == .string("set_config"))
        let params = try #require(sent["params"]?[3]?.object)
        #expect(Set(params.keys) == ["init", "iface_name", "ssid", "encryption", "key", "hidden", "random_bssid", "enabled"])
        #expect(params["key"] == .string("example-password") && params["encryption"] == .string("sae-mixed"))
    }

    @Test func mockAppliesThroughTheRealExecutor() async throws {
        let wifi = MockWiFiService()
        let clock = ApplyClock()
        let executor = WiFiApplyExecutor(transport: wifi, gate: MutationGate(), clock: clock.now, sleep: clock.sleep)
        let plan = visible
        guard case .verifiedSuccess = await executor.apply(plan).outcome else { Issue.record("not verified"); return }
        guard case .success(let snapshot, _, _) = try? await wifi.snapshot().area else { Issue.record("no snapshot"); return }
        #expect((try? snapshot.wireless.get())?.radio(.ghz2_4)?.mainNetwork?.hidden == true)
        wifi.setScenario(.today)
        #expect(try await wifi.readWireless().radio(.ghz2_4)?.mainNetwork?.hidden == false)
    }
}

@Suite struct WiFiRadioPlanTests {
    @Test func radioFieldsRideOnTheMainNetworkCall() throws {
        let plan = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.txPower = .medium }]))
        #expect(plan.steps.count == 1)
        let step = try #require(plan.steps.first)
        #expect(step.scopes == [.radio(.ghz5)])
        #expect(step.radioBefore == Sample.radio(.ghz5))
        let params = try #require(step.call.params?.object)
        #expect(params["iface_name"] == .string("rai0") && params["key"] == .string("example-password"))
        #expect(params["device"] == .string("MT7990_1_2") && params["txpower"] == .string("Medium"))
        #expect(params["channel"] == .number(0) && params["htmode"] == .string("80") && params["hwmode"] == .string("11a/n/ac/ax/be"))
        #expect(params["chan_6g_only_psc"] == nil)
        // The Mac is on 6 GHz.
        #expect(plan.thisMac == .staysConnected)
        #expect(plan.radarCheck == nil)
    }

    @Test func unchangedRadioSendsNothing() {
        #expect(Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5), Sample.radio(.ghz6)])).isEmpty)
    }

    @Test func htmodeChannelAndPSCStrings() throws {
        let manual = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz2_4) { $0.channel = 6; $0.width = 20 }]))
        let params = try #require(manual.calls.first?.params?.object)
        #expect(params["channel"] == .number(6) && params["htmode"] == .string("20"))
        let auto = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.width = nil }]))
        #expect(auto.calls.first?.params?["htmode"] == .string("auto"))
        let six = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz6) { $0.pscOnly = false; $0.width = 320 }]))
        #expect(six.calls.first?.params?["chan_6g_only_psc"] == .bool(false) && six.calls.first?.params?["htmode"] == .string("320"))
        // The Mac is on 6 GHz: the radio restart drops it.
        #expect(six.thisMac == .dropsThenJoins(MockWiFiService.fast))
        #expect(Set(six.reconnect) == [MACAddress("0e:e5:7b:da:22:c7")!, MACAddress("a4:83:e7:12:9c:01")!])
    }

    @Test func powerWords() {
        #expect(TxPowerLevel.levels.map(\.wire) == ["Low", "Medium", "High", "Max"])
    }

    @Test func networkAndRadioOnOneBandAreOneCall() throws {
        let change = WiFiChangeSet(networks: [Sample.home { $0.hidden = true }], radios: [Sample.radio(.ghz2_4) { $0.channel = 11 }])
        let plan = Sample.plan(change)
        #expect(plan.steps.count == 1)
        let params = try #require(plan.calls.first?.params?.object)
        #expect(params["hidden"] == .bool(true) && params["channel"] == .number(11))
    }

    @Test func manualDFSChannelNeedsARadarCheck() {
        #expect(Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.channel = 100 }])).radarCheck == WiFiRadarCheck(band: .ghz5, channel: 100))
        #expect(Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.channel = 36 }])).radarCheck == nil)
    }

    @Test func optionsAreOneSSHCommand() throws {
        let change = WiFiChangeSet(options: [
            WiFiOptionEdit(section: "wifi2g", band: .ghz2_4, setting: .fastRoaming(true)),
            WiFiOptionEdit(section: "wifi5g", band: .ghz5, setting: .roamingHelp(false)),
            // Already as the router has it.
            WiFiOptionEdit(section: "wifi6g", band: .ghz6, setting: .roamingHelp(true)),
        ])
        let plan = Sample.planWithOptions(change)
        #expect(plan.steps.count == 1)
        let step = try #require(plan.steps.first)
        #expect(step.scopes == [.radio(.ghz2_4), .radio(.ghz5)])
        #expect(step.optionsBefore.map(\.section) == ["wifi2g", "wifi5g"])
        guard case .options(let writes) = step.call else { Issue.record("not options"); return }
        #expect(SSHCommand.setWiFiOptions(writes).rendered ==
            "uci set wireless.wifi2g.ieee80211r='1' && uci set wireless.wifi5g.ieee80211k='0' && uci set wireless.wifi5g.bss_transition='0' "
            + "&& uci commit wireless && wifi reload")
        #expect(step.call.params == nil)
        #expect(plan.thisMac == .staysConnected)
    }

    @Test func autoSkipListsAreChannelNumbersOnly() throws {
        let section = try #require(UCISectionName("MT7990_1_2"))
        #expect(SSHCommand.setWiFiOptions([WiFiOptionWrite(section: section, band: .ghz5, setting: .autoSkips([149, 153, -1, 999]))]).rendered
            == "uci set wireless.MT7990_1_2.acs_skiplist='149;153' && uci commit wireless && wifi reload")
        #expect(SSHCommand.setWiFiOptions([WiFiOptionWrite(section: section, band: .ghz5, setting: .autoSkips([]))]).rendered
            == "{ uci -q delete wireless.MT7990_1_2.acs_skiplist || true; } && uci commit wireless && wifi reload")
        let plan = Sample.planWithOptions(WiFiChangeSet(options: [WiFiOptionEdit(section: "MT7990_1_2", band: .ghz5, setting: .autoSkips([165, 149]))]))
        guard case .options(let writes)? = plan.calls.first else { Issue.record("no options"); return }
        #expect(writes.first?.setting == .autoSkips([149, 165]))
    }

    @Test func sectionNamesAreValidated() {
        #expect(UCISectionName("wifi2g") != nil && UCISectionName("MT7990_1_1") != nil)
        for bad in ["@wifi-iface[0]", "a b", "a;reboot", "", "x.y", "a'b", String(repeating: "a", count: 65)] { #expect(UCISectionName(bad) == nil) }
        let anonymous = WiFiOptionEdit(section: "@wifi-iface[0]", band: .ghz2_4, setting: .fastRoaming(true))
        #expect(Sample.planWithOptions(WiFiChangeSet(options: [anonymous])).isEmpty)
        // A section the read does not have is not written.
        #expect(Sample.planWithOptions(WiFiChangeSet(options: [WiFiOptionEdit(section: "wifi9g", band: .ghz2_4, setting: .fastRoaming(true))])).isEmpty)
    }
}

@Suite struct WiFiRadioApplyTests {
    @Test func radioChangeVerifies() async {
        let router = FakeRouter()
        let plan = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.txPower = .medium; $0.width = 160 }]), mac: .ethernet)
        guard case .verifiedSuccess(let state) = await Sample.executor(router).apply(plan).outcome else { Issue.record("not verified"); return }
        #expect(state.radios.map(\.txPower) == [.medium])
        #expect(state.radios.map(\.width) == [160])
    }

    @Test func radarCheckWaitsUntilReady() async {
        let router = FakeRouter()
        await router.set(states: [[.ghz5: .cac], [.ghz5: .cac], [.ghz5: .ready]])
        let plan = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.channel = 100 }]), mac: .ethernet)
        let steps = StepLog()
        let report = await Sample.executor(router).apply(plan) { await steps.add($0) }
        guard case .verifiedSuccess = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(await steps.all == [.sending, .restarting, .checking, .radarCheck])
    }

    @Test func radarCheckOutlastsTheNormalDeadline() async {
        let router = FakeRouter()
        // 300 polls of 2 s: past the 30 s verify deadline, within the 11 minute limit.
        await router.set(states: Array(repeating: [.ghz5: .cac], count: 300) + [[.ghz5: .ready]])
        let plan = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.channel = 100 }]), mac: .ethernet)
        guard case .verifiedSuccess = await Sample.executor(router).apply(plan).outcome else { Issue.record("not verified"); return }
    }

    @Test func radarCheckGivesUpAfterTheLimit() async {
        let router = FakeRouter()
        await router.set(states: [[.ghz5: .cac]])
        let plan = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.channel = 100 }]), mac: .ethernet)
        let clock = ApplyClock()
        let start = clock.now()
        guard case .verifiedMismatch = await Sample.executor(router, clock: clock).apply(plan).outcome else { Issue.record("not a mismatch"); return }
        #expect(clock.now().timeIntervalSince(start) > 660 && clock.now().timeIntervalSince(start) < 700)
    }

    @Test func autoLandingOnADFSChannelIsWaitedFor() async {
        let router = FakeRouter()
        await router.set(states: [[.ghz5: .cac], [.ghz5: .ready]])
        let plan = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.txPower = .high }]), mac: .ethernet)
        #expect(plan.radarCheck == nil)
        let steps = StepLog()
        guard case .verifiedSuccess = await Sample.executor(router).apply(plan, progress: { await steps.add($0) }).outcome else {
            Issue.record("not verified"); return
        }
        #expect(await steps.all.contains(.radarCheck))
    }

    @Test func radarConflictEndsTheWait() async {
        let router = FakeRouter()
        await router.set(states: [[.ghz5: .cac], [.ghz5: .conflict]])
        let plan = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.channel = 100 }]), mac: .ethernet)
        guard case .verifiedMismatch(let expected, let actual) = await Sample.executor(router).apply(plan).outcome else {
            Issue.record("not a mismatch"); return
        }
        #expect(expected.radar.isEmpty && actual.radar == [.ghz5])
    }

    @Test func externalRadioEditSendsNothing() async {
        let router = FakeRouter()
        await router.edit { $0.radios[1].configuredChannel = 44 }
        let plan = Sample.plan(WiFiChangeSet(radios: [Sample.radio(.ghz5) { $0.txPower = .low }]), mac: .ethernet)
        let report = await Sample.executor(router).apply(plan)
        guard case .conflictingExternalEdit = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(await router.sent.isEmpty)
    }

    @Test func optionsVerifyOverSSH() async {
        let router = FakeRouter()
        let plan = Sample.planWithOptions(WiFiChangeSet(options: [WiFiOptionEdit(section: "wifi2g", band: .ghz2_4, setting: .fastRoaming(true))]),
                                          mac: .ethernet)
        guard case .verifiedSuccess(let state) = await Sample.executor(router).apply(plan).outcome else { Issue.record("not verified"); return }
        #expect(state.options.map(\.setting) == [.fastRoaming(true)])
    }

    @Test func optionsWaitForTheRadarCheck() async {
        let router = FakeRouter()
        await router.set(states: [[.ghz5: .cac], [.ghz5: .ready]])
        let plan = Sample.planWithOptions(WiFiChangeSet(options: [WiFiOptionEdit(section: "MT7990_1_2", band: .ghz5, setting: .autoSkips([]))]),
                                          mac: .ethernet)
        let steps = StepLog()
        guard case .verifiedSuccess = await Sample.executor(router).apply(plan, progress: { await steps.add($0) }).outcome else {
            Issue.record("not verified"); return
        }
        #expect(await steps.all.contains(.radarCheck))
        let radar = FakeRouter()
        await radar.set(states: [[.ghz5: .conflict]])
        guard case .verifiedMismatch(_, let actual) = await Sample.executor(radar).apply(plan).outcome else { Issue.record("no radar"); return }
        #expect(actual.radar == [.ghz5])
    }

    @Test func closedSSHAfterOptionsIsReadBack() async {
        let router = FakeRouter(sends: [.applyThenCloseSSH])
        let plan = Sample.planWithOptions(WiFiChangeSet(options: [WiFiOptionEdit(section: "wifi2g", band: .ghz2_4, setting: .fastRoaming(true))]),
                                          mac: .ethernet)
        let report = await Sample.executor(router).apply(plan)
        guard case .verifiedSuccess = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(report.dispatched)
    }

    @Test func externalOptionEditSendsNothing() async {
        let router = FakeRouter()
        await router.editSections { $0[3].ieee80211r = true }
        let plan = Sample.planWithOptions(WiFiChangeSet(options: [WiFiOptionEdit(section: "wifi2g", band: .ghz2_4, setting: .roamingHelp(false))]),
                                          mac: .ethernet)
        guard case .conflictingExternalEdit = await Sample.executor(router).apply(plan).outcome else { Issue.record("no conflict"); return }
        #expect(await router.sent.isEmpty)
    }

    @Test func liveOptionsRunOneSSHCommand() async throws {
        let runner = RecordingRunner()
        let endpoint = try RouterEndpoint(scheme: .https, host: "192.0.2.20", port: 443)
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: "admin", password: { "pw" }, transport: StubHTTPTransport { _ in throw URLError(.notConnectedToInternet) })
        let section = try #require(UCISectionName("wifi2g"))
        let call = WiFiCall.options([WiFiOptionWrite(section: section, band: .ghz2_4, setting: .fastRoaming(false))])
        #expect(try await LiveWiFiApplyTransport(rpc: rpc, runner: runner).send(call) == nil)
        #expect(await runner.commands == [.setWiFiOptions([WiFiOptionWrite(section: section, band: .ghz2_4, setting: .fastRoaming(false))])])
        // Without SSH the options cannot be sent.
        await #expect(throws: SSHFailure.configurationFailed) { try await LiveWiFiApplyTransport(rpc: rpc).send(call) }
    }

    @Test func mockRadarCheckRunsThenReady() async throws {
        let wifi = MockWiFiService()
        var policy = WiFiApplyPolicy()
        policy.settle = .zero
        policy.pollInterval = .milliseconds(200)
        // Real time: the mock's radar check ends after a few seconds.
        let executor = WiFiApplyExecutor(transport: wifi, gate: MutationGate(), policy: policy)
        let settings = WiFiRadioSettings(MockWiFiService.wireless(.today).radio(.ghz5)!)!
        var manual = settings
        manual.channel = 100
        let plan = WiFiApplyPlan(change: WiFiChangeSet(radios: [manual]), wireless: MockWiFiService.wireless(.today), subnets: nil, devices: [], thisMac: .ethernet)
        let steps = StepLog()
        guard case .verifiedSuccess = await executor.apply(plan, progress: { await steps.add($0) }).outcome else { Issue.record("not verified"); return }
        #expect(await steps.all.contains(.radarCheck))
        wifi.setApplyScenario(.radarFound)
        wifi.setScenario(.today)
        guard case .verifiedMismatch(_, let actual) = await executor.apply(plan).outcome else { Issue.record("no radar"); return }
        #expect(actual.radar == [.ghz5])
        // Auto clears the radar.
        let now = try await wifi.readWireless()
        var auto = try #require(now.radio(.ghz5).flatMap(WiFiRadioSettings.init))
        auto.channel = 0
        let recover = WiFiApplyPlan(change: WiFiChangeSet(radios: [auto]), wireless: now, subnets: nil, devices: [], thisMac: .ethernet)
        guard case .verifiedSuccess(let state) = await executor.apply(recover).outcome else { Issue.record("radar stays"); return }
        #expect(state.radar.isEmpty)
    }
}

private actor RecordingRunner: SSHCommandRunning {
    private(set) var commands: [SSHCommand] = []
    func run(_ command: SSHCommand, limits: ProcessLimits) async throws -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitStatus: 0, stdout: Data(), stderr: Data())
    }
}

private actor StepLog {
    private(set) var all: [WiFiApplyStep] = []
    func add(_ step: WiFiApplyStep) { all.append(step) }
}

private actor BodyLog {
    private(set) var all: [JSONValue] = []
    func add(_ body: JSONValue) { all.append(body) }
}

@Suite struct WiFiGuestIoTTests {
    private static func subnets() throws -> [SubnetPolicy] {
        let url = try #require(Bundle.module.url(forResource: "vlan_subnet-get-subnets", withExtension: "json", subdirectory: "Fixtures/glinet/wifi"))
        return try #require(SubnetParser.parse(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))))
    }

    private static func turnOn(_ kind: WiFiNetworkKind, bands: [WirelessBand], security: WiFiSecurity = .wpa2WPA3) -> WiFiNetworkEdit {
        WiFiNetworkEdit(kind: kind, interfaces: [], name: kind == .guest ? "Flint Guest" : "Flint IoT", password: WiFiPassword("new-guest-key"),
                        security: security, hidden: false, randomBSSID: true, bands: bands)
    }

    private static func plan(_ change: WiFiChangeSet, wireless: WirelessStatus = Sample.wireless, subnets: [SubnetPolicy]) -> WiFiApplyPlan {
        WiFiApplyPlan(change: change, wireless: wireless, subnets: subnets, devices: Sample.devices, thisMac: Sample.macOnFast)
    }

    private static func slots(_ plan: WiFiApplyPlan) -> [WiFiSlotState] {
        plan.calls.compactMap { call in if case .network(let slot, _, _) = call { slot } else { nil } }
    }

    @Test func turnOnAddsOneNetworkPerBand() throws {
        var wireless = Sample.wireless
        for radio in wireless.radios.indices {
            for index in wireless.radios[radio].networks.indices { wireless.radios[radio].networks[index].bssid = "" }
        }
        let rules = WiFiSubnetRules(kind: .guest, eachOther: false, reachesModem: false)
        let plan = Self.plan(WiFiChangeSet(networks: [Self.turnOn(.guest, bands: [.ghz2_4, .ghz5])], rules: [rules]), wireless: wireless,
                             subnets: try Self.subnets())
        // The fixture already isolates guests and blocks the modem: no subnet call.
        #expect(Self.slots(plan).map(\.interface) == ["ra1", "rai1"])
        #expect(plan.steps.map(\.scopes) == [[.added(.ghz2_4)], [.added(.ghz5)]])
        #expect(plan.restarts == [.added(.ghz2_4), .added(.ghz5)])
        for call in plan.calls {
            let params = try #require(call.params?.object)
            #expect(Set(params.keys) == ["init", "iface_name", "ssid", "encryption", "key", "hidden", "random_bssid", "enabled", "bssid"])
            #expect(params["init"] == .bool(true) && params["enabled"] == .bool(true) && params["ssid"] == .string("Flint Guest"))
            #expect(params["encryption"] == .string("sae-mixed") && params["key"] == .string("new-guest-key"))
        }
        #expect(plan.mustJoin.isEmpty && plan.reconnect.isEmpty)
        #expect(plan.thisMac == .staysConnected)

        let six = Self.plan(WiFiChangeSet(networks: [Self.turnOn(.guest, bands: [.ghz2_4, .ghz5, .ghz6], security: .wpa3)]), subnets: try Self.subnets())
        #expect(Self.slots(six).map(\.interface) == ["ra1", "rai1", "rax1"])
        #expect(Self.slots(six).allSatisfy { $0.security == .wpa3 })
        #expect(Self.turnOn(.guest, bands: [.ghz6]).problems == [.wpa3With6GHz])
    }

    @Test func iotRulesGoFirstWithTheOtherFieldsAsRead() throws {
        let subnets = try Self.subnets()
        let iot = try #require(subnets.first { $0.name == "iot" })
        let rules = WiFiSubnetRules(kind: .iot, eachOther: true, reachesModem: false)
        let plan = Self.plan(WiFiChangeSet(networks: [Self.turnOn(.iot, bands: [.ghz2_4], security: .wpa2)], rules: [rules]), subnets: subnets)
        guard case .rules(_, let sent) = try #require(plan.calls.first) else { Issue.record("not the subnet call"); return }
        #expect(sent == rules)
        // The subnet is off until its Wi-Fi is on, so nothing reloads.
        #expect(plan.steps.map(\.scopes) == [[], [.added(.ghz2_4)]])
        #expect(Self.slots(plan).map(\.interface) == ["ra3"])
        let params = try #require(plan.calls.first?.params?.object)
        var expected = iot.fields
        expected["isolate"] = .bool(false)
        #expect(params == expected)
        #expect(params["wan_access_mode"] == .number(1) && params["enabled"] == .bool(false) && params["vlan_id"] == .number(10))
        // The IoT network has no 6 GHz slot.
        #expect(Self.slots(Self.plan(WiFiChangeSet(networks: [Self.turnOn(.iot, bands: [.ghz2_4, .ghz6])]), subnets: subnets)).map(\.interface) == ["ra3"])
    }

    @Test func modemAccessIsNeverTwo() throws {
        var subnets = try Self.subnets()
        let index = try #require(subnets.firstIndex { $0.name == "guest" })
        subnets[index].wanAccess = .blockInternet
        subnets[index].fields["wan_access_mode"] = .number(2)
        for modem in [true, false] {
            for eachOther in [true, false] {
                let plan = Self.plan(WiFiChangeSet(rules: [WiFiSubnetRules(kind: .guest, eachOther: eachOther, reachesModem: modem)]), subnets: subnets)
                let params = try #require(plan.calls.first?.params?.object)
                #expect(params["wan_access_mode"] == .number(modem ? 0 : 1))
            }
        }
        // A rule left unknown keeps the value as read and sends no call for it.
        #expect(Self.plan(WiFiChangeSet(rules: [WiFiSubnetRules(kind: .guest, eachOther: nil, reachesModem: nil)]), subnets: subnets).isEmpty)
    }

    @Test func rulesOfAnOnNetworkReloadItsSubnet() throws {
        let subnets = try Self.subnets()
        let plan = Self.plan(WiFiChangeSet(rules: [WiFiSubnetRules(kind: .guest, eachOther: true, reachesModem: false)]),
                             wireless: MockWiFiService.wireless(.guestAndIoT), subnets: subnets)
        #expect(plan.steps.map(\.scopes) == [[.rules(.guest)]])
        #expect(plan.restarts == [.rules(.guest)])
        #expect(plan.mustJoin.isEmpty && plan.reconnect.isEmpty)
    }

    @Test func turnOffSendsEnabledFalsePerBandAndItsDevicesJoinAnother() throws {
        let wireless = MockWiFiService.wireless(.guestAndIoT)
        let devices = WiFiOverview(wireless: wireless, mlo: nil, air: MockWiFiService.air(.guestAndIoT), clients: nil).devices
        let off = WiFiNetworkEdit(kind: .iot, interfaces: ["ra3"], name: MockWiFiService.iot, password: Sample.password, security: .wpa2,
                                  hidden: false, randomBSSID: true, bands: [])
        let plan = WiFiApplyPlan(change: WiFiChangeSet(networks: [off]), wireless: wireless, subnets: try Self.subnets(), devices: devices,
                                 thisMac: .ethernet)
        let slots = Self.slots(plan)
        #expect(slots.map(\.interface) == ["ra3"] && slots.allSatisfy { $0.enabled == false })
        guard case .network(_, let initialised, _) = try #require(plan.calls.first) else { return }
        #expect(initialised)
        #expect(plan.mustJoin == [MACAddress("d8:1c:79:aa:04:53")!])
        // The main networks are not touched.
        #expect(!slots.contains { ["ra0", "rai0", "rax0"].contains($0.interface) })
    }

    @Test func subnetCodesHaveTheirOwnText() throws {
        let rules = WiFiCall.rules(try #require(try Self.subnets().first { $0.name == "guest" }), WiFiSubnetRules(kind: .guest, eachOther: true, reachesModem: false))
        #expect(WiFiApplyExecutor.refusedMessage(-9, call: rules).contains("overlaps another network"))
        #expect(WiFiApplyExecutor.refusedMessage(-11, call: rules).contains("overlaps another network"))
        #expect(WiFiApplyExecutor.refusedMessage(20_016_008, call: rules).contains("TAP site-to-site"))
        #expect(WiFiApplyExecutor.refusedMessage(1003, call: rules).contains("address settings (code 1003)"))
        let network = WiFiCall.network(WiFiSlotState(interface: "ra1"), initialised: true, radio: nil)
        #expect(WiFiApplyExecutor.refusedMessage(-9, call: network) == WiFiApplyExecutor.refusedMessage(-9))
    }

    @Test func refusedSubnetCallSendsNothingElse() async throws {
        let router = FakeRouter(subnets: try Self.subnets(), sends: [.errCode(-9)])
        let plan = Self.plan(WiFiChangeSet(networks: [Self.turnOn(.iot, bands: [.ghz2_4])], rules: [WiFiSubnetRules(kind: .iot, eachOther: true, reachesModem: false)]),
                             subnets: try Self.subnets())
        let report = await Sample.executor(router).apply(plan)
        guard case .rejected(.preconditionFailed(let message)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(message.contains("overlaps another network"))
        #expect(await router.sent.count == 1)
    }

    @Test func turnOnVerifiesTheRulesAndTheNewNetworks() async throws {
        let subnets = try Self.subnets()
        let router = FakeRouter(subnets: subnets, sends: [.apply, .apply])
        let log = SessionEventLog()
        let plan = Self.plan(WiFiChangeSet(networks: [Self.turnOn(.iot, bands: [.ghz2_4])], rules: [WiFiSubnetRules(kind: .iot, eachOther: true, reachesModem: true)]),
                             subnets: subnets)
        let report = await Sample.executor(router, log: log).apply(plan)
        guard case .verifiedSuccess(let state) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(state.rules == [WiFiSubnetRules(kind: .iot, eachOther: true, reachesModem: true)])
        #expect(state.slots.map(\.enabled) == [true])
        let text = await log.events().map { "\($0)" }.joined() + plan.calls.map(\.description).joined() + String(reflecting: plan)
        #expect(!text.contains("new-guest-key"))
    }

    @Test func joinedMeansOnlineInTheSubnet() throws {
        let iot = try #require(try Self.subnets().first { $0.name == "iot" })
        #expect(iot.range == "192.168.10.1/24")
        let plug = MACAddress("00:17:88:4a:1e:2f")!, thermostat = MACAddress("d8:1c:79:aa:04:53")!, printer = MACAddress("3c:52:82:7a:0d:91")!
        let clients = [
            WiFiClientInfo(mac: plug, ip: "192.168.10.120"),
            WiFiClientInfo(mac: thermostat, ip: "192.168.8.116"),
            WiFiClientInfo(mac: printer, online: false, ip: "192.168.10.31"),
        ]
        #expect(WiFiClientInfo.joined([plug, thermostat, printer], clients: clients, subnet: iot) == [plug])
        #expect(WiFiClientInfo.joined([plug], clients: clients, subnet: nil).isEmpty)
    }
}

@Suite struct WiFiMultiLinkPlanTests {
    static func turnOn(name: String = "Flint Home Link", bands: [WirelessBand] = [.ghz6, .ghz5]) -> MLONetwork {
        var network = MockWiFiService.mlo(.today).main!
        network.enabled = .value(true)
        network.ssid = name
        network.bands = bands
        network.encryption = .wpa2WPA3
        return network
    }

    static func plan(_ network: MLONetwork, mlo: MLOConfiguration = MockWiFiService.mlo(.today), devices: [WiFiDevice] = Sample.devices,
                     mac: ThisMacLink = Sample.macOnFast) -> WiFiApplyPlan {
        WiFiApplyPlan(change: WiFiChangeSet(mlo: network), wireless: Sample.wireless, subnets: nil, mlo: mlo, devices: devices, thisMac: mac)
    }

    @Test func turnOnSendsSortedBandsAndWPA3With6GHz() throws {
        let plan = Self.plan(Self.turnOn())
        let call = try #require(plan.calls.first)
        let rpc = try #require(LiveWiFiApplyTransport.rpcCall(call))
        #expect(rpc.object == "wifi" && rpc.method == "set_mlo_config")
        let params = try #require(call.params)
        #expect(params["mlo_band"]?.array?.compactMap(\.string) == ["5g", "6g"])
        #expect(params["encryption"]?.string == "sae")
        #expect(params["mlo_enable"] == .bool(true) && params["init"] == .bool(true))
        #expect(params["name"]?.string == "mld0" && params["ssid"]?.string == "Flint Home Link")
        #expect(!call.description.contains("example-password"))
    }

    @Test func turnOnStartsNewNetworksAndDropsNothing() {
        let plan = Self.plan(Self.turnOn())
        #expect(plan.restarts == [.added(.ghz5), .added(.ghz6)])
        #expect(plan.mustJoin.isEmpty && plan.reconnect.isEmpty)
        #expect(plan.thisMac == .staysConnected)
    }

    @Test func bothNameChoicesAreSent() throws {
        for name in ["Flint Home Link", MockWiFiService.fast] {
            let params = try #require(Self.plan(Self.turnOn(name: name)).calls.first?.params)
            #expect(params["ssid"]?.string == name)
        }
    }

    @Test func oneBandIsAProblem() {
        #expect(Self.turnOn(bands: [.ghz6]).problems == [.oneBand])
        #expect(Self.turnOn().problems.isEmpty)
        var off = Self.turnOn(bands: [.ghz6])
        off.enabled = .value(false)
        #expect(off.problems.isEmpty)
    }

    @Test func turningOffMakesItsDevicesJoinAgain() {
        let mlo = MockWiFiService.mlo(.multiLinkOn)
        let devices = WiFiOverview(wireless: Sample.wireless, mlo: mlo, air: MockWiFiService.air(.multiLinkOn), clients: nil).devices
        var off = mlo.main!
        off.enabled = .value(false)
        let plan = Self.plan(off, mlo: mlo, devices: devices)
        #expect(plan.restarts == [.network(.ghz5), .network(.ghz6)])
        #expect(Set(plan.mustJoin) == Set(devices.filter(\.viaLink).map(\.mac)) && plan.mustJoin.count == 2)
        guard case .mlo(let sent)? = plan.calls.first else { Issue.record("no call"); return }
        #expect(sent.initialised == true && sent.enabled == .value(false))
    }

    @Test func unchangedNetworkSendsNothing() {
        #expect(Self.plan(MockWiFiService.mlo(.today).main!).isEmpty)
    }

    @Test func applyVerifiesTheMultiLinkNetwork() async {
        let router = FakeRouter()
        let report = await Sample.executor(router).apply(Self.plan(Self.turnOn()))
        guard case .verifiedSuccess(let state) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(state.mlo?.ssid == "Flint Home Link" && state.mlo?.encryption == .wpa3)
    }

    @Test func outsideChangeSendsNothing() async {
        let router = FakeRouter()
        await router.editMLO { $0.networks[0].ssid = "Flint Home Other" }
        let report = await Sample.executor(router).apply(Self.plan(Self.turnOn()))
        guard case .conflictingExternalEdit = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(await router.sent.isEmpty)
    }
}

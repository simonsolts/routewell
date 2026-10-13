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
    enum Send { case apply, applyThenLose, ignore, errCode(Int), throwError(GLiNetRPCError) }

    var wireless: WirelessStatus
    var subnets: [SubnetPolicy]
    var sends: [Send]
    /// Reads after the first write that fail before the router answers again.
    var unreachableReads = 0
    /// Reads that still show the old values.
    var staleReads = 0
    private(set) var sent: [WiFiCall] = []
    private var stale: WirelessStatus?

    init(wireless: WirelessStatus = MockWiFiService.wireless(.today), subnets: [SubnetPolicy] = MockWiFiService.subnets(.today),
         sends: [Send] = [.apply]) {
        self.wireless = wireless
        self.subnets = subnets
        self.sends = sends
    }

    func set(unreachable: Int = 0, stale: Int = 0) {
        unreachableReads = unreachable
        staleReads = stale
    }

    func edit(_ change: (inout WirelessStatus) -> Void) { change(&wireless) }

    func readWireless() async throws -> WirelessStatus {
        if !sent.isEmpty, unreachableReads > 0 { unreachableReads -= 1; throw GLiNetRPCError.transport(.timedOut) }
        if staleReads > 0, let stale { staleReads -= 1; return stale }
        return wireless
    }

    func readSubnets() async throws -> [SubnetPolicy] { subnets }

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
        case .ignore: return nil
        case .errCode(let code): return code
        case .throwError(let error): throw error
        }
    }

    private func store(_ call: WiFiCall) {
        switch call {
        case .network(let slot, _):
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
        #expect(step.scope == .radio(.ghz2_4))
        guard case .network(let slot, _) = step.call else { Issue.record("not a network call"); return }
        #expect(slot.interface == "ra0" && slot.hidden == true && slot.password == Sample.password)
        #expect(plan.mustJoin.isEmpty)
        #expect(Set(plan.reconnect) == [MACAddress("66:29:ea:33:fb:78")!, MACAddress("ba:4d:21:07:3e:91")!, MACAddress("d8:1c:79:aa:04:53")!])
        #expect(plan.thisMac == .staysConnected)
        #expect(plan.restarts == [.radio(.ghz2_4)])
    }

    @Test func passwordRestartsTheNetworkAndDevicesJoinAgain() {
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.fast { $0.password = WiFiPassword("another-password") }]))
        #expect(plan.steps.map(\.scope) == [.network(.ghz5), .network(.ghz6)])
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

    @Test func useOneNameMovesTheBands() {
        // "Flint Home" on every band: with 6 GHz it must be WPA3.
        let edit = Sample.home { $0.bands = [.ghz2_4, .ghz5, .ghz6]; $0.security = .wpa3 }
        #expect(edit.problems.isEmpty)
        let plan = Sample.plan(WiFiChangeSet(networks: [edit]))
        let slots = plan.calls.compactMap { call -> WiFiSlotState? in if case .network(let slot, _) = call { slot } else { nil } }
        #expect(slots.map(\.interface) == ["ra0", "rai0", "rax0"])
        #expect(slots.allSatisfy { $0.ssid == MockWiFiService.home && $0.security == .wpa3 && $0.enabled == true })
        // Both names change for someone: all five devices join again.
        #expect(plan.mustJoin.count == 5)
        #expect(plan.thisMac == .mustJoin(MockWiFiService.home))
    }

    @Test func takingABandAwayTurnsItsSlotOff() throws {
        let plan = Sample.plan(WiFiChangeSet(networks: [Sample.fast { $0.bands = [.ghz5] }]))
        #expect(plan.steps.count == 1)
        guard case .network(let slot, _) = try #require(plan.calls.first) else { Issue.record("not a network call"); return }
        #expect(slot.interface == "rax0" && slot.enabled == false)
        #expect(plan.steps.first?.scope == .network(.ghz6))
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
        #expect(plan.steps.map(\.scope) == [.subnet, .radio(.ghz2_4)])
        let params = try #require(plan.calls.first?.params.object)
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
        #expect(call.params["key"] == .string("example-password"))
        #expect(!call.description.contains("example-password"))
        #expect(!String(describing: plan).contains("example-password"))
        #expect(!String(reflecting: plan).contains("example-password"))
        // An open network still sends the key it read.
        let open = WiFiCall.network(WiFiSlotState(interface: "ra0", security: WiFiSecurity.none, password: Sample.password), initialised: true)
        #expect(open.params["key"] == .string("example-password") && open.params["encryption"] == .string("none"))
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

private actor StepLog {
    private(set) var all: [WiFiApplyStep] = []
    func add(_ step: WiFiApplyStep) { all.append(step) }
}

private actor BodyLog {
    private(set) var all: [JSONValue] = []
    func add(_ body: JSONValue) { all.append(body) }
}

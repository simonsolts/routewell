import Foundation
import Testing
@testable import RoutewellKit
import RoutewellMock

/// Anonymized copies of the 4.9.1 recordings (keys and types as recorded,
/// example values in place of redacted text). The `upgrade-*` files are
/// source-informed only: no recording of that call exists yet.
private func routerFixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/glinet/router"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

/// Serves the login handshake and answers each `call` by `object.method`.
private enum RouterStub {
    static let endpoint = try! RouterEndpoint(scheme: .https, host: "192.0.2.20", port: 443)

    enum Answer: Sendable { case fixture(String), rpcError(Int), transport(TransportError), body(JSONValue) }

    static func service(_ answers: [String: Answer]) -> (LiveRouterService, StubHTTPTransport) {
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
            case .fixture(let name): return try envelope(["result": try routerFixture(name)])
            case .body(let value): return try envelope(["result": value])
            case .transport(let error): throw error
            case .rpcError(let code): return try envelope(["error": .object(["code": .number(Double(code)), "message": .string("err")])])
            }
        }
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: "admin", password: { "pw" }, transport: transport)
        return (LiveRouterService(rpc: rpc, clock: { Date(timeIntervalSince1970: 1_790_109_457) }), transport)
    }
}

@Suite struct RouterOverviewParsingTests {
    @Test func identityMemoryStorageAndClockComeFromTheRecordedShape() throws {
        let router = GLiNetStatusParser.routerStatus(getStatus: try routerFixture("system-get-status"), getInfo: try routerFixture("system-get-info"))
        #expect(router.model == "GL.iNet GL-BE14000")
        #expect(router.hostname == "GL-BE14000")
        #expect(router.firmware == "4.9.1")
        #expect(router.kernelVersion == "5.4.281")
        #expect(router.architecture == "mediatek/mt7988")
        #expect(router.memoryTotalBytes == 2_082_811_904)
        #expect(router.memoryFreeBytes == 889_991_168)
        #expect(router.memoryBuffersAndCacheBytes == 364_122_112)
        // Buffers and cache are not "used".
        #expect(router.memoryUsedBytes == Int64(828_698_624)) // total − free − buffers and cache
        #expect(router.memoryAvailableBytes == Int64(1_254_113_280))
        #expect(router.storageTotalBytes == 62_176_428_032)
        #expect(router.storageUsedBytes == Int64(1_437_868_032)) // equals the recorded flash_app
        #expect(router.routerTime == Date(timeIntervalSince1970: 1_790_109_457))
        #expect(router.uptimeSeconds == nil || router.lastBoot != nil)
        #expect(router.sqmEnabled == .value(false))
        #expect(router.temperatureCelsius == .value(57))
        // No RPC field reports CPU utilization.
        #expect(router.cpuUtilizationPercent == .unknown)
    }

    @Test func withoutBuffersTheOldMemoryRuleHolds() {
        let status: JSONValue = .object(["system": .object(["memory_total": .number(100), "memory_free": .number(40)])])
        let router = GLiNetStatusParser.routerStatus(getStatus: status, getInfo: nil)
        #expect(router.memoryUsedBytes == 60)
        #expect(router.memoryBuffersAndCacheBytes == nil)
        #expect(router.storageTotalBytes == nil)
        #expect(router.lastBoot == nil)
        #expect(router.sqmEnabled == .unknown)
    }

    @Test func uplinksAndWANProtocolComeFromStatusAndCable() throws {
        let internet = GLiNetStatusParser.internetStatus(getStatus: try routerFixture("system-get-status"), cableStatus: try routerFixture("cable-get-status"))
        #expect(internet.uplinks.count == 8)
        #expect(internet.uplinks.first { $0.name == "wan" }?.up == .value(true))
        #expect(internet.uplinks.filter { $0.up == .value(true) }.count == 1)
        #expect(internet.wanProtocol == "dhcp")
        #expect(internet.gateway == "198.51.100.7")
        #expect(internet.dnsServers == ["198.51.100.5", "198.51.100.6"])
    }

    @Test func onlineWiFiClientsAreCountedPerBand() throws {
        let url = try #require(Bundle.module.url(forResource: "clients-get_list-4.9.1", withExtension: "json", subdirectory: "Fixtures/glinet/clients"))
        let list = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let status = GLiNetStatusParser.clientStatus(getStatus: nil, clientList: list)
        let byBand = try #require(status.onlineByBand)
        let online = list["clients"]?.array?.filter { $0["online"]?.bool == true } ?? []
        let wireless = online.filter { ["2.4G", "5G", "6G"].contains($0["iface"]?.string ?? "") }
        #expect(byBand.values.reduce(0, +) == wireless.count)
        #expect(GLiNetStatusParser.clientStatus(getStatus: try routerFixture("system-get-status"), clientList: nil).onlineByBand == nil)
    }

    @Test func adGuardReportsItsDNSPort() throws {
        let url = try #require(Bundle.module.url(forResource: "control-status-4.9.1", withExtension: "json", subdirectory: "Fixtures/adguard"))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        #expect(json["dns_port"]?.int == 3053)
        let status = AdGuardClient.adGuardStatus(status: AdGuardStatusResponse(version: "v0.107.73", running: true), stats: nil, now: .now)
        #expect(status.running == .value(true))
        #expect(AdGuardClient.adGuardStatus(status: nil, stats: nil, now: .now).running == .unknown)
    }
}

@Suite struct MultiWANTests {
    @Test func honestUnknownWhenTheRouterReportsNoState() {
        var internet = InternetStatus()
        internet.uplinks = [UplinkInterface(name: "wan"), UplinkInterface(name: "wwan")]
        internet.publicAddress = "172.16.10.5"
        internet.gateway = "172.16.10.72"
        let status = MultiWANStatus.derive(from: internet)
        #expect(status.interfaces.map(\.name) == ["wan", "wwan"])
        #expect(status.interfaces.allSatisfy { $0.up == .unknown && $0.active == .unknown && $0.isDefault == .unknown && $0.metric == .unknown })
        #expect(status.interfaces[0].connection == .ethernet)
        #expect(status.interfaces[0].address == "172.16.10.5")
        #expect(status.interfaces[1].connection == .unknown)
        #expect(status.interfaces[1].address == nil)
        // No up state, so no claim about the default route.
        #expect(status.activePath == nil)
    }

    @Test func activePathNeedsTheWANUpAndAGateway() throws {
        let internet = GLiNetStatusParser.internetStatus(getStatus: try routerFixture("system-get-status"), cableStatus: try routerFixture("cable-get-status"))
        #expect(MultiWANStatus.derive(from: internet).activePath == WANPath(interface: "wan", gateway: "198.51.100.7"))
        var noGateway = internet
        noGateway.gateway = nil
        #expect(MultiWANStatus.derive(from: noGateway).activePath == nil)
        #expect(MultiWANStatus.derive(from: InternetStatus()).interfaces.isEmpty)
    }

    @Test func pathTrackerCountsOnlyRealChanges() {
        var tracker = WANPathTracker()
        let wan = MultiWANStatus(interfaces: [], activePath: WANPath(interface: "wan", gateway: "192.0.2.1"))
        let wwan = MultiWANStatus(interfaces: [], activePath: WANPath(interface: "wwan", gateway: "192.0.2.9"))
        let unknown = MultiWANStatus(interfaces: [], activePath: nil)
        tracker.observe(wan, at: Date(timeIntervalSince1970: 1))
        tracker.observe(unknown, at: Date(timeIntervalSince1970: 2))
        tracker.observe(wan, at: Date(timeIntervalSince1970: 3))
        #expect(tracker.changes.isEmpty)
        tracker.observe(wwan, at: Date(timeIntervalSince1970: 4))
        #expect(tracker.changes == [Date(timeIntervalSince1970: 4)])
    }
}

@Suite struct WirelessTests {
    @Test func radiosJoinTheirCurrentChannelByBand() throws {
        let status = try #require(WirelessParser.parse(config: try routerFixture("wifi-get-config"), status: try routerFixture("wifi-get-status")))
        #expect(status.radios.map(\.band) == [.ghz2_4, .ghz5, .ghz6])
        #expect(status.radios.map(\.currentChannel) == [9, 44, 37])
        #expect(status.radios.map(\.configuredChannel) == [0, 0, 0])
        #expect(status.radios.map(\.widthMHz) == [40, 160, 320])
        #expect(status.radios.map(\.device) == ["mt7990_1_1", "mt7990_1_2", "mt7990_1_3"])
        #expect(status.radios.allSatisfy { $0.txPower == "max" })
        #expect(status.networks.count == 8)
        #expect(status.enabledNetworkCount == 3)
        #expect(status.radios[0].networks[1].guest == true)
        #expect(status.radios[0].networks[2].iot == true)
    }

    @Test func missingFieldsStayUnknown() {
        let config: JSONValue = .object(["res": .array([.object(["ifaces": .array([.object(["ssid": .string("A")])])])])])
        let status = WirelessParser.parse(config: config, status: nil)
        let radio = try? #require(status?.radios.first)
        #expect(radio?.band == nil)
        #expect(radio?.txPower == nil)
        #expect(radio?.widthMHz == nil)
        #expect(radio?.currentChannel == nil)
        #expect(radio?.networks.first?.enabled == .unknown)
        #expect(WirelessParser.parse(config: .object(["other": .null]), status: nil) == nil)
    }

    @Test func aBandCountBelongsToAnSSIDOnlyWhenItIsTheOnlyOneEnabled() {
        let one = WirelessRadio(band: .ghz2_4, networks: [
            WirelessNetwork(ssid: "Home", enabled: .value(true)), WirelessNetwork(ssid: "Guest", enabled: .value(false))])
        let two = WirelessRadio(band: .ghz5, networks: [
            WirelessNetwork(ssid: "Home", enabled: .value(true)), WirelessNetwork(ssid: "Guest", enabled: .value(true))])
        let counts: [WirelessBand: Int] = [.ghz2_4: 5, .ghz5: 3]
        #expect(WirelessStatus.clients(for: one.networks[0], on: one, onlineByBand: counts) == 5)
        #expect(WirelessStatus.clients(for: one.networks[1], on: one, onlineByBand: counts) == 0)
        #expect(WirelessStatus.clients(for: two.networks[0], on: two, onlineByBand: counts) == nil)
        #expect(WirelessStatus.clients(for: one.networks[0], on: one, onlineByBand: nil) == nil)
    }
}

@Suite struct RouterServiceTests {
    @Test func sqmAvailableOn491() async throws {
        let (service, _) = RouterStub.service(["wifi.get_config": .fixture("wifi-get-config"), "wifi.get_status": .fixture("wifi-get-status"),
                                               "sqm.get_config": .fixture("sqm-get-config")])
        let result = try await service.details()
        #expect(result.sqmCapability.state == .supported)
        guard case .success(let sqm, _, let source) = result.sqm else { Issue.record("expected SQM"); return }
        #expect(source == .routerRPC)
        #expect(sqm == SQMConfiguration(enabled: .value(false), queueDiscipline: "cake", upload: nil, download: nil))
        guard case .success(let wireless, _, _) = result.wireless else { Issue.record("expected Wi-Fi"); return }
        #expect(wireless.radios.count == 3)
    }

    @Test func methodNotFoundIsTheOnlyUnsupportedSignalForSQM() async throws {
        let (missing, _) = RouterStub.service(["wifi.get_config": .fixture("wifi-get-config"), "sqm.get_config": .rpcError(-32601)])
        let unsupported = try await missing.details()
        #expect(unsupported.sqmCapability.state == .unsupported)
        #expect(unsupported.sqmCapability.evidence == .methodNotFound(method: "sqm.get_config"))
        guard case .failure(.unavailable, _) = unsupported.sqm else { Issue.record("expected unavailable"); return }
        // A failed wifi.get_status loses only the current channel.
        guard case .success(let wireless, _, _) = unsupported.wireless else { Issue.record("expected Wi-Fi"); return }
        #expect(wireless.radios.allSatisfy { $0.currentChannel == nil })

        for answer: RouterStub.Answer in [.transport(.timedOut), .rpcError(-32602), .rpcError(-32000), .body(.string("x"))] {
            let (service, _) = RouterStub.service(["sqm.get_config": answer])
            let result = try await service.details()
            #expect(result.sqmCapability.state == .unknown)
            guard case .failure = result.sqm else { Issue.record("expected failure"); continue }
        }
    }

    @Test func wifiFailureFailsOnlyTheWiFiPart() async throws {
        let (service, _) = RouterStub.service(["wifi.get_config": .transport(.unreachable(code: -1004)), "sqm.get_config": .fixture("sqm-get-config")])
        let result = try await service.details()
        guard case .failure(.network, _) = result.wireless else { Issue.record("expected network failure"); return }
        #expect(result.sqmCapability.state == .supported)
    }

    @Test func firmwareCheckOutcomes() async throws {
        let (available, transport) = RouterStub.service(["upgrade.check_firmware_online": .fixture("upgrade-check-firmware-online")])
        let check = try await available.checkFirmware()
        #expect(check.status == .updateAvailable)
        #expect(check.current == .value("4.9.1"))
        #expect(check.latest == .value("4.9.2"))
        #expect(check.releaseNotes?.contains("line 2") == true)
        #expect(check.checkedAt == Date(timeIntervalSince1970: 1_790_109_457))
        // The check is the only call sent: nothing is downloaded or installed.
        let methods = await transport.recorded().compactMap { record -> String? in
            guard let body = try? JSONDecoder().decode(JSONValue.self, from: record.body ?? Data()), body["method"]?.string == "call" else { return nil }
            return "\(body["params"]?[1]?.string ?? "").\(body["params"]?[2]?.string ?? "")"
        }
        #expect(methods == ["upgrade.check_firmware_online"])

        let (current, _) = RouterStub.service(["upgrade.check_firmware_online": .fixture("upgrade-check-firmware-online-current")])
        let upToDate = try await current.checkFirmware()
        #expect(upToDate.status == .upToDate)
        #expect(upToDate.latest == .value("4.9.1"))

        let (ambiguous, _) = RouterStub.service(["upgrade.check_firmware_online": .fixture("upgrade-check-firmware-online-ambiguous")])
        #expect(try await ambiguous.checkFirmware().status == .unableToCheck(.ambiguousReply))

        let (missing, _) = RouterStub.service([:])
        #expect(try await missing.checkFirmware().status == .unableToCheck(.notSupported))

        let (offline, _) = RouterStub.service(["upgrade.check_firmware_online": .transport(.timedOut)])
        #expect(try await offline.checkFirmware().status == .unableToCheck(.failed(.timeout)))
    }

    @Test func firmwareParserNeverAssumesUpToDate() {
        let now = Date(timeIntervalSince1970: 1)
        #expect(FirmwareCheckParser.parse(.object([:]), at: now).status == .unableToCheck(.ambiguousReply))
        #expect(FirmwareCheckParser.parse(.object(["current_version": .string("4.9.1"), "new_firmware_version": .string("4.9.1")]), at: now).status == .upToDate)
        #expect(FirmwareCheckParser.parse(.object(["current_version": .string("4.9.1"), "new_firmware_version": .string("4.9.2")]), at: now).status == .updateAvailable)
        #expect(FirmwareCheckParser.parse(.object(["update_available": .number(1)]), at: now).status == .updateAvailable)
        let notes = FirmwareCheckParser.parse(.object(["update_available": .bool(true), "release_notes": .array([.string("a"), .string(" "), .string("b")])]), at: now)
        #expect(notes.releaseNotes == "a\nb")
        #expect(notes.latest == .unknown)
    }

    @Test func routerReadsAreSessionFenced() async throws {
        let backend = MockRouterBackend()
        let session = RouterSession()
        let old = SessionToken(profileID: "home", revision: 1)
        let lease = SessionLease(token: old, backend: backend)
        try await session.beginRevision(old)
        try await session.installLease(lease)
        #expect(try await session.routerDetails(using: lease) != nil)
        try await session.beginRevision(SessionToken(profileID: "home", revision: 2))
        await #expect(throws: SessionError.stale) { try await session.routerDetails(using: lease) }
        await #expect(throws: SessionError.stale) { try await session.checkFirmware(using: lease) }
    }

    @Test func mockCoversEverySQMAndFirmwareScenario() async throws {
        let mock = MockRouterService()
        #expect(try await mock.details().sqmCapability.state == .unsupported)
        await mock.setSQMBehavior(.available)
        #expect(try await mock.details().sqmCapability.state == .supported)
        await mock.setSQMBehavior(.failing)
        #expect(try await mock.details().sqmCapability.state == .unknown)
        #expect(try await mock.checkFirmware().status == .unableToCheck(.failed(.network)))
        await mock.setFirmwareBehavior(.updateAvailable)
        #expect(try await mock.checkFirmware().status == .updateAvailable)
        await mock.setFirmwareBehavior(.upToDate)
        #expect(try await mock.checkFirmware().status == .upToDate)
        guard case .success(let wireless, _, _) = try await mock.details().wireless else { Issue.record("expected Wi-Fi"); return }
        #expect(wireless.radios.map(\.band) == [.ghz2_4, .ghz5, .ghz6])
    }

    @Test func theRouterScreenRequestsTheRouterArea() {
        let plan = ScreenRefreshPlan.resolve(destination: "router", segment: "Overview")
        #expect(plan.contains { $0.area == .routerDetail && $0.interval == .seconds(30) })
        #expect(!plan.contains { $0.area == .network })
    }
}

@Suite struct DNSConfigurationTests {
    @Test func pathFollowsHandleClientRequests() {
        var adGuard = AdGuardStatus()
        adGuard.running = .value(true)
        adGuard.dnsPort = 3053
        adGuard.handlesClientRequests = .value(true)
        var router = RouterStatus()
        router.lanAddress = "192.168.8.1"
        var internet = InternetStatus()
        internet.dnsServers = ["192.0.2.53"]
        let through = DNSConfiguration.derive(router: router, internet: internet, adGuard: adGuard)
        #expect(through.resolutionPath == .value(.throughAdGuard))
        #expect(through.adGuardPort == 3053)
        #expect(through.upstreams == ["192.0.2.53"])
        #expect(through.advertisedResolver == "192.168.8.1")
        adGuard.handlesClientRequests = .value(false)
        #expect(DNSConfiguration.derive(router: router, internet: internet, adGuard: adGuard).resolutionPath == .value(.direct))
        adGuard.handlesClientRequests = .unknown
        #expect(DNSConfiguration.derive(router: router, internet: internet, adGuard: adGuard).resolutionPath == .unknown)
    }
}

@Suite struct TelemetrySessionTests {
    @Test func ringsAndSessionPeaksFollowEachSample() async {
        let sampler = TelemetrySampler(overviewLimit: 2)
        let start = Date(timeIntervalSince1970: 100)
        _ = await sampler.append(TelemetrySample(capturedAt: start, cpuLoad: .value(2.3), cpuUtilizationPercent: .value(13.3),
                                                 memoryUsedBytes: .value(40), memoryTotalBytes: .value(100), temperatureCelsius: .value(54.2)))
        _ = await sampler.append(TelemetrySample(capturedAt: start.addingTimeInterval(30), cpuLoad: .value(2.1), cpuUtilizationPercent: .value(3),
                                                 memoryUsedBytes: .value(30), memoryTotalBytes: .value(100), temperatureCelsius: .value(50)))
        let history = await sampler.append(TelemetrySample(capturedAt: start.addingTimeInterval(60), cpuLoad: .value(1.9)))
        #expect(history.cpuLoad.map(\.value) == [2.1, 1.9])
        #expect(history.cpuUtilizationPercent.map(\.value) == [13.3, 3])
        let session = await sampler.session()
        #expect(session.observations == 3)
        #expect(session.since == start)
        #expect(session.peakCPUPercent == 13.3)
        #expect(session.peakMemoryFraction == 0.4)
        #expect(session.peakTemperatureCelsius == 54.2)

        let reset = await sampler.resetSession(at: start.addingTimeInterval(90))
        #expect(reset.observations == 0 && reset.peakCPUPercent == nil && reset.since == start.addingTimeInterval(90))
        // The rings keep their history after a reset.
        #expect(await sampler.history().cpuLoad.count == 2)
    }

    @Test func unknownReadingsAddNoPeak() async {
        let sampler = TelemetrySampler()
        _ = await sampler.append(TelemetrySample(capturedAt: .now))
        let session = await sampler.session()
        #expect(session.observations == 1)
        #expect(session.peakCPUPercent == nil && session.peakMemoryFraction == nil && session.peakTemperatureCelsius == nil)
    }
}

@Suite struct UpgradeBaselineTests {
    private func summary(firmware: String?, clients: Int?) -> RouterStateSummary {
        var state = RouterStateSummary()
        state.model = "GL-BE14000"
        state.firmware = firmware
        state.kernel = "5.4.281"
        state.clientsOnline = clients
        return state
    }

    @Test func comparisonListsEveryChangedField() {
        let baseline = UpgradeBaseline(capturedAt: Date(timeIntervalSince1970: 1), state: summary(firmware: "4.9.1", clients: 12))
        let check = PostUpgradeCheck.compare(baseline, current: summary(firmware: "4.9.2", clients: nil), at: Date(timeIntervalSince1970: 2))
        #expect(check.baselineCapturedAt == Date(timeIntervalSince1970: 1))
        #expect(check.comparedFields == 3)
        #expect(check.differences == [
            BaselineDifference(field: .firmware, before: "4.9.1", after: "4.9.2"),
            BaselineDifference(field: .clientsOnline, before: "12", after: nil),
        ])
        #expect(PostUpgradeCheck.compare(baseline, current: baseline.state, at: .now).differences.isEmpty)
    }

    @Test func captureTakesOnlyObservedValues() {
        var snapshot = MockRouterBackend.snapshot(at: Date(timeIntervalSince1970: 1))
        snapshot.adGuard.running = .unknown
        let state = RouterStateSummary.capture(snapshot, wireless: MockRouterService.wireless)
        #expect(state.firmware == "4.9.1")
        #expect(state.adGuardRunning == nil)
        #expect(state.wifiRadios == 3)
        #expect(state.wifiNetworksEnabled == 3)
        #expect(RouterStateSummary.capture(OverviewSnapshot(observedAt: .now), wireless: nil) == RouterStateSummary())
    }

    @Test func storeRoundTripsAndKeepsMemoryOnAFailedWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = UpgradeBaseline(capturedAt: Date(timeIntervalSince1970: 10), state: summary(firmware: "4.9.1", clients: 3))
        let store = UpgradeBaselineStore(store: AtomicJSONStore(directory: directory))
        #expect(await store.load() == .empty)
        #expect(await store.saveBaseline(baseline, for: "Home") == nil)
        let check = PostUpgradeCheck.compare(baseline, current: baseline.state, at: Date(timeIntervalSince1970: 20))
        #expect(await store.recordCheck(check, for: "Home") == nil)

        let reloaded = UpgradeBaselineStore(store: AtomicJSONStore(directory: directory))
        #expect(await reloaded.load() == .loaded)
        #expect(await reloaded.snapshot().baselines["Home"] == baseline)
        #expect(await reloaded.snapshot().checks["Home"] == check)
        // A new baseline clears the check that compared the old one.
        #expect(await reloaded.saveBaseline(baseline, for: "Home") == nil)
        #expect(await reloaded.snapshot().checks["Home"] == nil)

        struct Refused: Error {}
        let failing = UpgradeBaselineStore(store: AtomicJSONStore(directory: directory, beforeCommit: { throw Refused() }))
        #expect(await failing.saveBaseline(baseline, for: "Other") == .writeFailed)
        #expect(await failing.snapshot().baselines["Other"] == nil)
    }
}

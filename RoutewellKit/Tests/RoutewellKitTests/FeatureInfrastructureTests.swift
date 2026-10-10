import Foundation
import Testing
@testable import RoutewellKit

@Test func telemetryRingsEvictOldestAndIgnoreUnknown() async {
    let sampler = TelemetrySampler(overviewLimit: 2, throughputLimit: 3)
    for index in 0..<4 {
        _ = await sampler.append(TelemetrySample(
            capturedAt: Date(timeIntervalSince1970: Double(index)),
            cpuLoad: .value(Double(index)), memoryUsedBytes: .value(Double(index * 10)),
            wanRxBytesPerSecond: .value(Double(index))
        ))
    }
    _ = await sampler.append(TelemetrySample(capturedAt: .now))
    let history = await sampler.history()
    #expect(history.cpuLoad.map(\.value) == [2, 3])
    #expect(history.memoryUsedBytes.map(\.value) == [20, 30])
    #expect(history.wanRxBytesPerSecond.map(\.value) == [1, 2, 3])
    await sampler.clear()
    #expect(await sampler.history().memoryUsedBytes.isEmpty)
}

@Test func screenPlanKeepsOverviewAndUsesAreaCadence() {
    let analytics = ScreenRefreshPlan.resolve(destination: "analytics", segment: "Overview")
    #expect(Set(analytics.map(\.area)).isSuperset(of: ScreenRefreshPlan.overviewAreas))
    #expect(analytics.first(where: { $0.area == .telemetry })?.interval == .seconds(2))
    let adGuard = ScreenRefreshPlan.resolve(destination: "adGuard", segment: "Instance")
    #expect(Set(adGuard.map(\.area)) == ScreenRefreshPlan.overviewAreas.union([.adGuardOverview, .ssh]))
    let network = ScreenRefreshPlan.resolve(destination: "network", segment: "Overview")
    #expect(network.first(where: { $0.area == .publicIP })?.interval == .seconds(600))
    #expect(network.first(where: { $0.area == .network })?.interval == .seconds(30))
    let other = ScreenRefreshPlan.resolve(destination: "overview")
    #expect(Set(other.map(\.area)) == ScreenRefreshPlan.overviewAreas)
}

@Test func fixturePlanIsReadOnlyAndRedactsCanaries() async throws {
    #expect(FixtureRecordingPlan.calls.allSatisfy(FixtureRecordingPlan.isReadOnly))
    #expect(Set(FixtureRecordingPlan.calls.map(\.fileName)).count == FixtureRecordingPlan.calls.count)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = FixtureBackend()
    let session = RouterSession()
    let token = SessionToken(profileID: "synthetic", revision: 1)
    let lease = SessionLease(token: token, backend: backend)
    try await session.beginRevision(token)
    try await session.installLease(lease)
    let count = try await FixtureRecorder().record(session: session, lease: lease, to: directory)
    // This backend has no SSH, so the SSH calls are skipped, not written.
    let recorded = FixtureRecordingPlan.calls.filter { $0.transport != .ssh }
    #expect(count == recorded.count)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ssh-logread-250.txt").path))
    for call in recorded {
        let data = try Data(contentsOf: directory.appendingPathComponent(call.fileName))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("CANARY-PASSWORD"))
        #expect(!text.contains("secret-wifi"))
        #expect(!text.contains("192.168.8.22"))
        #expect(!text.contains("AA:BB:CC:DD:EE:FF"))
        // The first Query Log page has no entries here, so the reads that
        // take a value from it say so instead of calling.
        #expect(text.contains(call.method.contains("{") ? "no value" : "-32601"))
    }
    let manifestData = try Data(contentsOf: directory.appendingPathComponent("_recording-manifest.json"))
    let manifest = try JSONDecoder().decode(FixtureRecordingManifest.self, from: manifestData)
    #expect(manifest.source == "synthetic-test-backend")
    #expect(manifest.files.count == count)
    #expect(manifest.privacy.contains("privacy aliases"))
}

private struct FixtureBackend: RouterBackend, FixtureRecordableBackend {
    func overview() async throws -> OverviewRefreshResult { throw CancellationError() }
    func recordFixture(_ call: FixtureCall) async -> JSONValue {
        .object([
            "error": .object(["code": .number(-32601), "message": .string("Method not found")]),
            "password": .string("CANARY-PASSWORD"), "ssid": .string("secret-wifi"),
            "client_ip": .string("192.168.8.22"), "mac": .string("AA:BB:CC:DD:EE:FF")
        ])
    }
}

/// The older page and both searches take their values from the
/// first Query Log page, and only checked values are sent.
@Test func fixturePlanFillsQueryLogValuesFromTheFirstPage() async throws {
    let page: JSONValue = .object([
        "oldest": .string("2026-01-02T03:04:05.123456789+01:00"),
        "data": .array([.object(["client": .string("192.0.2.10"), "question": .object(["name": .string("example.com")])])]),
    ])
    let calls = FixtureRecordingPlan.calls.filter { $0.method.hasPrefix("control/querylog?") }
    #expect(calls.count == 5)
    let methods = calls.compactMap { FixtureRecordingPlan.resolve($0, firstPage: page)?.method }
    #expect(methods == [
        "control/querylog?limit=500",
        "control/querylog?limit=500&older_than=2026-01-02T03:04:05.123456789+01:00",
        "control/querylog?limit=500&search=192.0.2.10",
        "control/querylog?limit=500&search=example.com",
        "control/querylog?limit=500&response_status=blocked",
    ])
    let unsafe: JSONValue = .object([
        "oldest": .string("yesterday&limit=1"),
        "data": .array([.object(["client": .string("192.0.2.10/24"), "question": .object(["name": .string("a b.example")])])]),
    ])
    #expect(calls.compactMap { FixtureRecordingPlan.resolve($0, firstPage: unsafe) }.count == 2)
    #expect(FixtureRecordingPlan.isSafeQueryValue(name: "search", value: "2001:db8::1"))
    #expect(!FixtureRecordingPlan.isSafeQueryValue(name: "search", value: "example.com/path"))
    #expect(!FixtureRecordingPlan.isSafeQueryValue(name: "limit", value: "5-00"))
    #expect(calls.allSatisfy(FixtureRecordingPlan.isReadOnly))
}

@Test func recorderKeepsTechnicalEvidenceButHidesPersonalText() throws {
    let payload: JSONValue = .object([
        "clients": .array([.object([
            "mac": .string("AA:BB:CC:DD:EE:01"), "ip": .string("192.168.8.40"),
            "name": .string(""), "alias": .string("Kitchen iPad"),
            "iface": .string("ra0"), "class": .string("Simons iPhone"),
            "total_rx": .string("123456"), "online_time": .number(1_789_000_000)
        ])]),
        "top_clients": .array([.object(["192.168.8.40": .number(12)])]),
        "data": .array([.object([
            "client": .string("192.168.8.40"), "reason": .string("FilteredBlackList"),
            "time": .string("2026-09-22T21:14:11.123456+01:00"), "key": .string("12345678")
        ])])
    ])
    var aliases = FixtureAliases()
    RecordedFixtureRedactor.collectAliases(payload, into: &aliases)
    let redacted = RecordedFixtureRedactor.redact(payload, aliases: aliases)
    let client = try #require(redacted["clients"]?.array?.first)
    let ipAlias = try #require(client["ip"]?.string)
    #expect(ipAlias.hasPrefix("198.51."))
    #expect(client["mac"]?.string?.hasPrefix("02:00:00:00:") == true)
    #expect(client["name"]?.string == "")
    #expect(client["alias"]?.string?.hasPrefix("Example") == true)
    #expect(client["iface"]?.string == "ra0")
    #expect(client["class"]?.string == "[REDACTED TEXT]")
    #expect(client["total_rx"]?.string == "123456")
    #expect(redacted["top_clients"]?.array?.first?[ipAlias]?.int == 12)
    let entry = try #require(redacted["data"]?.array?.first)
    #expect(entry["client"]?.string == ipAlias)
    #expect(entry["reason"]?.string == "FilteredBlackList")
    #expect(entry["time"]?.string == "2026-09-22T21:14:11.123456+01:00")
    #expect(entry["key"]?.string == "[REDACTED TEXT]")
    let text = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
    #expect(!text.contains("192.168.8.40"))
    #expect(!text.contains("Kitchen iPad"))
    #expect(!text.contains("Simons iPhone"))
}

@Test func recorderAllowsTheNamedFirmwareCheckOnly() {
    #expect(FixtureRecordingPlan.calls.contains { $0.object == "upgrade" && $0.method == "check_firmware_online" })
    #expect(FixtureRecordingPlan.isReadOnly(.init(.rpc, object: "upgrade", method: "check_firmware_online", fileName: "a.json")))
    #expect(!FixtureRecordingPlan.isReadOnly(.init(.rpc, object: "system", method: "check_firmware_online", fileName: "b.json")))
    #expect(!FixtureRecordingPlan.isReadOnly(.init(.rpc, object: "upgrade", method: "upgrade_online", fileName: "c.json")))
    #expect(!FixtureRecordingPlan.isReadOnly(.init(.rpc, object: "sqm", method: "set_config", fileName: "d.json")))
    #expect(!FixtureRecordingPlan.isReadOnly(.init(.rpc, method: "check_firmware_online", fileName: "e.json")))
}

@Test func recorderKeepsVersionAndRadioTokens() {
    let payload: JSONValue = .object([
        "firmware_version": .string("4.9.1"), "new_firmware_version": .string("4.9.2"),
        "board_info": .object(["kernel_version": .string("5.4.281"), "architecture": .string("mediatek/mt7988"),
                               "hostname": .string("Simons router")]),
        "txpower": .string("max"), "htmode": .string("EHT160"), "upload": .string("100"),
        "release_note": .string("Fixes for Simon's home")
    ])
    let redacted = RecordedFixtureRedactor.redact(payload)
    #expect(redacted["firmware_version"]?.string == "4.9.1")
    #expect(redacted["new_firmware_version"]?.string == "4.9.2")
    #expect(redacted["board_info"]?["kernel_version"]?.string == "5.4.281")
    #expect(redacted["board_info"]?["architecture"]?.string == "mediatek/mt7988")
    #expect(redacted["board_info"]?["hostname"]?.string == "Example")
    #expect(redacted["txpower"]?.string == "max")
    #expect(redacted["htmode"]?.string == "EHT160")
    #expect(redacted["upload"]?.string == "100")
    #expect(redacted["release_note"]?.string == "[REDACTED TEXT]")
}

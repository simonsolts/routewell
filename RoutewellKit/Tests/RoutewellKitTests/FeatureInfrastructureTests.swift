import Foundation
import Testing
@testable import RoutewellKit
import RoutewellMock

@Test func defaultFeatureServicesAreAbsent() {
    let backend: any RouterBackend = NoFeaturesBackend()
    for area in [DataArea.clients, .queryLog, .network, .maintenance, .vpn, .plugins, .telemetry] {
        #expect(backend.service(for: area) == nil)
    }
}

@Test func mockCapabilityTransitionsAreIndependent() async throws {
    let backend = MockRouterBackend()
    let clients = try #require(backend.clients)
    let vpn = try #require(backend.vpn)
    #expect(await clients.probe().state == .unknown)
    await backend.setFeatureBehavior(.supported, for: .clients)
    let supported = await clients.probe()
    #expect(supported.state == .supported)
    #expect(supported.observedAt != nil)
    #expect(await vpn.probe().state == .unknown)
    await backend.setFeatureBehavior(.unsupported, for: .clients)
    #expect(await clients.probe().state == .unsupported)
    await backend.setFeatureBehavior(.failing, for: .clients)
    #expect(await clients.probe().state == .unknown)
}

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
    let schedules = ScreenRefreshPlan.resolve(destination: "protection", segment: "Schedules")
    #expect(schedules.first(where: { $0.area == .schedules })?.interval == .seconds(60))
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
    #expect(count == FixtureRecordingPlan.calls.count)
    for call in FixtureRecordingPlan.calls {
        let data = try Data(contentsOf: directory.appendingPathComponent(call.fileName))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("CANARY-PASSWORD"))
        #expect(!text.contains("secret-wifi"))
        #expect(!text.contains("192.168.8.22"))
        #expect(!text.contains("AA:BB:CC:DD:EE:FF"))
        #expect(text.contains("-32601"))
    }
    let manifestData = try Data(contentsOf: directory.appendingPathComponent("_recording-manifest.json"))
    let manifest = try JSONDecoder().decode(FixtureRecordingManifest.self, from: manifestData)
    #expect(manifest.source == "synthetic-test-backend")
    #expect(manifest.files.count == count)
    #expect(manifest.privacy.contains("privacy aliases"))
}

private struct NoFeaturesBackend: RouterBackend {
    var protection: (any ProtectionService)? { nil }
    func overview() async throws -> OverviewRefreshResult { throw CancellationError() }
}

private struct FixtureBackend: RouterBackend, FixtureRecordableBackend {
    var protection: (any ProtectionService)? { nil }
    func overview() async throws -> OverviewRefreshResult { throw CancellationError() }
    func recordFixture(_ call: FixtureCall) async -> JSONValue {
        .object([
            "error": .object(["code": .number(-32601), "message": .string("Method not found")]),
            "password": .string("CANARY-PASSWORD"), "ssid": .string("secret-wifi"),
            "client_ip": .string("192.168.8.22"), "mac": .string("AA:BB:CC:DD:EE:FF")
        ])
    }
}

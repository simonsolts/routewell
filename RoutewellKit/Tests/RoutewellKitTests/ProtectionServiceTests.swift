import Foundation
import Testing
@testable import RoutewellKit

/// Records POST start/end markers so tests can prove two calls never
/// interleave their writes on the wire.
private actor OrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Holds the AdGuard mock "server" state so a `control/protection` write is
/// reflected by the very next `control/status` read, the way the real
/// AdGuard Home API behaves.
private actor MockAdGuardState {
    private var enabled = true
    private var durationMs = 0
    func apply(enabled: Bool, durationMs: Int) {
        self.enabled = enabled
        self.durationMs = durationMs
    }
    func snapshot() -> (enabled: Bool, durationMs: Int) { (enabled, durationMs) }
}

private func statusBody(enabled: Bool, durationMs: Int) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "protection_enabled": enabled,
        "protection_disabled_duration": durationMs,
    ])
}

@Suite struct ProtectionServiceTests {
    /// The plan's Task 10.2 requirement: `LiveRouterBackend` builds one
    /// `ProtectionMutationExecutor` backed by one `MutationGate` per backend
    /// instance, so two separate reads of `.protection` still serialize
    /// through the same gate rather than each getting its own.
    @Test func liveBackendSharesOneGateAcrossProtectionAccesses() async throws {
        let recorder = OrderRecorder()
        let state = MockAdGuardState()
        let transport = StubHTTPTransport { request in
            let url = request.url!
            if request.httpMethod == "POST" {
                await recorder.record("start-write")
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    let enabled = json["enabled"] as? Bool ?? true
                    let durationMs = json["duration"] as? Int ?? 0
                    await state.apply(enabled: enabled, durationMs: durationMs)
                }
                try await Task.sleep(for: .milliseconds(20))
                await recorder.record("end-write")
                return (Data(), StubHTTPTransport.response(200, url: url))
            }
            let snapshot = await state.snapshot()
            return (statusBody(enabled: snapshot.enabled, durationMs: snapshot.durationMs), StubHTTPTransport.response(200, url: url))
        }
        let backend = Self.makeBackend(transport: transport, adGuard: Self.makeAdGuardClient(transport))

        let serviceA = backend.protection
        let serviceB = backend.protection
        #expect(serviceA != nil)
        #expect(serviceB != nil)

        async let reportA = serviceA!.setProtection(.enable, allowRecovery: false)
        async let reportB = serviceB!.setProtection(.disable, allowRecovery: false)
        let (a, b) = await (reportA, reportB)

        #expect(a.outcome == .verifiedSuccess(.enabled) || b.outcome == .verifiedSuccess(.enabled))

        let events = await recorder.events
        #expect(events == ["start-write", "end-write", "start-write", "end-write"])
    }

    @Test func liveBackendProtectionIsNilWithoutAdGuard() throws {
        let transport = StubHTTPTransport { request in (Data(), StubHTTPTransport.response(200, url: request.url!)) }
        let backend = Self.makeBackend(transport: transport, adGuard: nil)
        #expect(backend.protection == nil)
    }

    @Test func sessionRejectsWithCapabilityUnavailableWhenBackendHasNoAdGuard() async throws {
        let transport = StubHTTPTransport { request in (Data(), StubHTTPTransport.response(200, url: request.url!)) }
        let backend = Self.makeBackend(transport: transport, adGuard: nil)
        let session = RouterSession()
        let token = SessionToken(profileID: "no-adguard", revision: 1)
        let lease = SessionLease(token: token, backend: backend)
        try await session.beginRevision(token)
        try await session.installLease(lease)

        let report = try await session.setProtection(using: lease, intent: .enable, allowRecovery: false)
        #expect(report.outcome == .rejected(.capabilityUnavailable))
        #expect(report.dispatched == false)
    }

    private static func makeAdGuardClient(_ transport: StubHTTPTransport) -> AdGuardClient {
        AdGuardClient(
            baseURL: URL(string: "http://192.0.2.40:3000/")!,
            credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }),
            transport: transport
        )
    }

    private static func makeBackend(transport: StubHTTPTransport, adGuard: AdGuardClient?) -> LiveRouterBackend {
        let endpoint = try! RouterEndpoint(scheme: .https, host: "192.0.2.40", port: 443)
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: "root", password: { "correct horse" }, transport: transport)
        let configuration = LiveBackendConfiguration(
            routerEndpoint: endpoint,
            adGuard: adGuard == nil ? nil : AdGuardSettings(port: 3000, useRouterCredentials: false),
            adGuardBaseURL: adGuard == nil ? nil : URL(string: "http://192.0.2.40:3000/")
        )
        return LiveRouterBackend(
            configuration: configuration,
            rpc: rpc,
            adGuard: adGuard,
            trustStore: InMemoryEndpointTrustStore(),
            trustPrompt: DenyAllTrustPromptHandler()
        )
    }
}

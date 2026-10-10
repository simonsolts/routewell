import Foundation
import Testing
@testable import RoutewellKit

/// Finding the router without a password. Neutral values only:
/// documentation addresses and generated fingerprints.
private enum Discovery {
    static let gateway = "192.0.2.1"
    static let consoleAddress = "10.0.0.1"
    static let fingerprint = try! CertificateFingerprint(sha256: Data(repeating: 0xA5, count: 32))
    static let otherFingerprint = try! CertificateFingerprint(sha256: Data(repeating: 0x5A, count: 32))

    /// Long limits for tests where a fake answers. The run ends at the answer,
    /// so the limits cost nothing, and a slow CI runner cannot pass them.
    static let timing = RouterDiscovery.Timing(attempt: .seconds(2), firstRow: .seconds(4), total: .seconds(6),
                                               retryPause: .milliseconds(20), gatewayGrace: .seconds(2))

    /// Short limits, but the real proportions, for tests that wait until the time is up.
    static let short = RouterDiscovery.Timing(attempt: .milliseconds(150), firstRow: .milliseconds(400), total: .milliseconds(800),
                                              retryPause: .milliseconds(20), gatewayGrace: .milliseconds(150))

    static func make(_ prober: FakeProber, gateway: String? = Discovery.gateway, console: [String] = [],
                     denied: Bool = false, timing: RouterDiscovery.Timing = Discovery.timing) -> RouterDiscovery {
        RouterDiscovery(prober: prober, gateway: FakeGateway(address: gateway), resolver: FakeResolver(addresses: console),
                        localNetwork: FakeLocalNetwork(denied: denied), timing: timing)
    }
}

/// A scripted prober: each host maps to an outcome, an answer delay, or a hang.
private actor FakeProber: RouterChallengeProbing {
    enum Script: Sendable {
        case answer(ChallengeProbeOutcome, after: Duration = .zero)
        case hang
    }

    private let scripts: [String: Script]
    private(set) var calls: [String] = []
    private(set) var starts: [String: [ContinuousClock.Instant]] = [:]
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0

    init(_ scripts: [String: Script]) { self.scripts = scripts }

    func probe(_ endpoint: RouterEndpoint) async -> ChallengeProbeOutcome {
        calls.append(endpoint.host)
        starts[endpoint.host, default: []].append(.now)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        switch scripts[endpoint.host] ?? .answer(.noAnswer) {
        case .answer(let outcome, let delay):
            if delay > .zero { try? await Task.sleep(for: delay) }
            return outcome
        case .hang:
            try? await Task.sleep(for: .seconds(60))
            return .noAnswer
        }
    }

    func count(_ host: String) -> Int { calls.filter { $0 == host }.count }
}

private struct FakeGateway: GatewayLocating {
    let address: String?
    func gatewayAddress() async -> String? { address }
}

private struct FakeResolver: HostResolving {
    let addresses: [String]
    func ipv4Addresses(for host: String) async -> [String] {
        host == RouterDiscovery.consoleHost ? addresses : []
    }
}

private struct FakeLocalNetwork: LocalNetworkAccessChecking {
    let denied: Bool
    func isDenied(host: String) async -> Bool { denied }
}

private actor Flag {
    private(set) var count = 0
    func set() { count += 1 }
}

// MARK: - Order

@Test func gatewayThatAnswersIsFoundFirstWithItsFingerprint() async {
    let prober = FakeProber([Discovery.gateway: .answer(.glinet(fingerprint: Discovery.fingerprint))])
    let fallback = Flag()
    let result = await Discovery.make(prober).run { await fallback.set() }
    #expect(result == .found(DiscoveredRouter(endpoint: RouterDiscovery.endpoint(Discovery.gateway)!, source: .gateway,
                                              fingerprint: Discovery.fingerprint)))
    #expect(await fallback.count == 0)
    #expect(await prober.count(RouterDiscovery.fallbackHost) == 0)
}

@Test func gatewayAndConsoleRunTogether() async {
    let prober = FakeProber([
        Discovery.gateway: .answer(.notGLiNet, after: .milliseconds(300)),
        Discovery.consoleAddress: .answer(.glinet(fingerprint: Discovery.fingerprint), after: .milliseconds(300)),
    ])
    let result = await Discovery.make(prober, console: [Discovery.consoleAddress]).run()
    #expect(result == .found(DiscoveredRouter(endpoint: RouterDiscovery.endpoint(Discovery.consoleAddress)!, source: .console,
                                              fingerprint: Discovery.fingerprint)))
    #expect(await prober.maxInFlight == 2)
}

@Test func gatewayWinsWhenBothAnswer() async {
    let prober = FakeProber([
        Discovery.gateway: .answer(.glinet(fingerprint: Discovery.fingerprint), after: .milliseconds(60)),
        Discovery.consoleAddress: .answer(.glinet(fingerprint: Discovery.otherFingerprint)),
    ])
    let result = await Discovery.make(prober, console: [Discovery.consoleAddress]).run()
    guard case .found(let router) = result else { Issue.record("expected a router"); return }
    #expect(router.source == .gateway)
    #expect(router.fingerprint == Discovery.fingerprint)
}

@Test func consoleWinsAfterTheGatewayGraceRunsOut() async {
    let prober = FakeProber([
        Discovery.gateway: .hang,
        Discovery.consoleAddress: .answer(.glinet(fingerprint: Discovery.fingerprint)),
    ])
    let timing = RouterDiscovery.Timing(attempt: .seconds(2), firstRow: .seconds(60), total: .seconds(60),
                                        retryPause: .milliseconds(20), gatewayGrace: .milliseconds(150))
    let clock = ContinuousClock()
    let start = clock.now
    let result = await Discovery.make(prober, console: [Discovery.consoleAddress], timing: timing).run()
    guard case .found(let router) = result else { Issue.record("expected a router"); return }
    #expect(router.source == .console)
    // Grace (150 ms), not the whole first row (60 s), with room for a slow runner.
    #expect(clock.now - start < .seconds(20))
}

@Test func aPublicConsoleAddressIsNeverTried() async {
    let prober = FakeProber(["203.0.113.5": .answer(.glinet(fingerprint: Discovery.fingerprint))])
    let result = await Discovery.make(prober, gateway: nil, console: ["203.0.113.5"], timing: Discovery.short).run()
    #expect(result == .notFound)
    #expect(await prober.count("203.0.113.5") == 0)
}

@Test func fallbackRunsAfterTheFirstRowFails() async {
    let prober = FakeProber([
        Discovery.gateway: .answer(.notGLiNet),
        RouterDiscovery.fallbackHost: .answer(.glinet(fingerprint: Discovery.fingerprint)),
    ])
    let fallback = Flag()
    let result = await Discovery.make(prober).run { await fallback.set() }
    #expect(result == .found(DiscoveredRouter(endpoint: RouterDiscovery.endpoint(RouterDiscovery.fallbackHost)!, source: .fallback,
                                              fingerprint: Discovery.fingerprint)))
    #expect(await fallback.count == 1)
    #expect(await prober.calls.first == Discovery.gateway)
}

// MARK: - Timeouts

@Test func eachAttemptHasItsOwnDeadlineAndIsRetried() async throws {
    let prober = FakeProber([Discovery.gateway: .hang])
    let timing = RouterDiscovery.Timing(attempt: .milliseconds(100), firstRow: .seconds(30), total: .seconds(30),
                                        retryPause: .milliseconds(20), gatewayGrace: .milliseconds(100))
    let run = Task { await Discovery.make(prober, timing: timing).run() }
    // Without its own deadline the first attempt hangs for 60 s, so a second
    // attempt within 10 s shows the cut-off. Waiting for it, not for a fixed
    // time, keeps a slow runner from failing the test.
    let clock = ContinuousClock()
    let waitEnd = clock.now.advanced(by: .seconds(10))
    while await prober.count(Discovery.gateway) < 2, clock.now < waitEnd {
        try? await Task.sleep(for: .milliseconds(10))
    }
    run.cancel()
    _ = await run.value
    let starts = await prober.starts[Discovery.gateway] ?? []
    try #require(starts.count >= 2)
    // The cut-off is not early: 100 ms attempt plus 20 ms pause.
    #expect(starts[1] - starts[0] >= .milliseconds(120))
}

@Test func theWholeSearchStaysWithinTheTotal() async {
    let prober = FakeProber([Discovery.gateway: .hang, RouterDiscovery.fallbackHost: .hang, Discovery.consoleAddress: .hang])
    let clock = ContinuousClock()
    let start = clock.now
    let result = await Discovery.make(prober, console: [Discovery.consoleAddress], timing: Discovery.short).run()
    #expect(result == .notFound)
    // 800 ms total, with room for a slow runner. A probe that is never cut off hangs for 60 s.
    #expect(clock.now - start < .seconds(5))
    #expect(clock.now - start >= .milliseconds(700))
}

@Test func defaultTimingMatchesThePlan() {
    let timing = RouterDiscovery.Timing()
    #expect(timing.attempt == .milliseconds(1500))
    #expect(timing.total == .seconds(6))
}

// MARK: - What counts as a router

@Test func aNonGLiNetAnswerIsRejectedAndNotRetried() async {
    let prober = FakeProber([Discovery.gateway: .answer(.notGLiNet), RouterDiscovery.fallbackHost: .answer(.notGLiNet)])
    let result = await Discovery.make(prober).run()
    #expect(result == .notFound)
    #expect(await prober.count(Discovery.gateway) == 1)
    #expect(await prober.count(RouterDiscovery.fallbackHost) == 1)
}

@Test func noAnswerAnywhereWithDeniedLocalNetworkIsDenied() async {
    let prober = FakeProber([:])
    let result = await Discovery.make(prober, denied: true, timing: Discovery.short).run()
    #expect(result == .localNetworkDenied)
}

@Test func manualAddressIsProbedOnce() async throws {
    let endpoint = try RouterEndpoint.parse("192.0.2.20:8443")
    let found = await Discovery.make(FakeProber(["192.0.2.20": .answer(.glinet(fingerprint: Discovery.fingerprint))])).probe(manual: endpoint)
    #expect(found == .found(DiscoveredRouter(endpoint: endpoint, source: .manual, fingerprint: Discovery.fingerprint)))
    #expect(await Discovery.make(FakeProber(["192.0.2.20": .answer(.notGLiNet)])).probe(manual: endpoint) == .notGLiNet)
    #expect(await Discovery.make(FakeProber([:]), denied: true, timing: Discovery.short).probe(manual: endpoint) == .localNetworkDenied)
}

@Test func onlyPrivateIPv4CountsForTheConsoleName() {
    #expect(RouterDiscovery.isPrivateIPv4("192.168.8.1"))
    #expect(RouterDiscovery.isPrivateIPv4("10.1.2.3"))
    #expect(RouterDiscovery.isPrivateIPv4("172.20.0.1"))
    #expect(!RouterDiscovery.isPrivateIPv4("172.32.0.1"))
    #expect(!RouterDiscovery.isPrivateIPv4("203.0.113.5"))
    #expect(!RouterDiscovery.isPrivateIPv4("console.gl-inet.com"))
    #expect(RouterDiscovery.ipv4Literal("fe80::1") == nil)
}

// MARK: - No secret before trust

@Test func theChallengeRequestCarriesNoSecret() throws {
    let endpoint = try RouterEndpoint.parse("192.0.2.1")
    let request = LiveRouterChallengeProbe.challengeRequest(for: endpoint)
    #expect(request.url?.absoluteString == "https://192.0.2.1/rpc")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.httpShouldHandleCookies == false)
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody))
    #expect(body["method"]?.string == "challenge")
    #expect(body["params"] == .object(["username": .string("root")]))
    let keys: Set<String> = if case .object(let object) = body { Set(object.keys) } else { [] }
    #expect(keys == ["jsonrpc", "id", "method", "params"])
}

@Test func aChallengeReplyNeedsSaltAndNonce() throws {
    let good = Data(#"{"jsonrpc":"2.0","id":1,"result":{"alg":1,"salt":"saltsalt12","nonce":"nonceabcdef"}}"#.utf8)
    #expect(LiveRouterChallengeProbe.isGLiNetChallenge(good, statusCode: 200))
    #expect(!LiveRouterChallengeProbe.isGLiNetChallenge(good, statusCode: 404))
    let noNonce = Data(#"{"jsonrpc":"2.0","id":1,"result":{"alg":1,"salt":"saltsalt12"}}"#.utf8)
    #expect(!LiveRouterChallengeProbe.isGLiNetChallenge(noNonce, statusCode: 200))
    let error = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Access denied"}}"#.utf8)
    #expect(!LiveRouterChallengeProbe.isGLiNetChallenge(error, statusCode: 200))
    #expect(!LiveRouterChallengeProbe.isGLiNetChallenge(Data("<html>login</html>".utf8), statusCode: 200))
}

// MARK: - Finish rows

@Test func finishRowsComeFromTheProbeResults() {
    let probe = RouterProbe(model: "GL-EXAMPLE", firmware: "4.0.0", hostname: "example-router")
    let all = OnboardingSummary(name: "Home", address: "192.0.2.1", probe: probe, ssh: .connected(keyName: "id_example"),
                                adGuardEnabled: .value(true))
    #expect(all.router == .init(title: "Home", detail: "GL-EXAMPLE · 192.0.2.1", state: "Connected", tone: .connected))
    #expect(all.ssh == .init(title: "SSH", detail: "Signed in with id_example", state: "Connected", tone: .connected))
    #expect(all.adGuard.state == "Active")

    let none = OnboardingSummary(name: "  ", address: "192.0.2.1", probe: RouterProbe(), ssh: .off, adGuardEnabled: .value(false))
    #expect(none.router.title == "router")
    #expect(none.router.detail == "Model unknown · 192.0.2.1")
    #expect(none.ssh.state == "Off")
    #expect(none.ssh.detail == "Not set up. Turn it on any time in Settings › Router.")
    #expect(none.adGuard == .init(title: "AdGuard Home", detail: "Off on your router. Protection stats appear when it’s on.",
                                  state: "Off", tone: .off))
    #expect(OnboardingSummary(name: "x", address: "a", probe: nil, ssh: .off, adGuardEnabled: .unknown).adGuard.tone == .unknown)
}

@Test func adGuardHomeEnabledReadsTheConfigFlag() {
    #expect(LiveRouterBackend.adGuardHomeEnabled(config: .object(["enabled": .bool(true)])) == .value(true))
    #expect(LiveRouterBackend.adGuardHomeEnabled(config: .object(["enabled": .bool(false)])) == .value(false))
    #expect(LiveRouterBackend.adGuardHomeEnabled(config: .object([:])) == .unknown)
}

// MARK: - Persistence

@Test func profilesSavedBeforeOnboardingReadAsComplete() throws {
    let id = UUID()
    let endpoint = try RouterEndpoint.parse("192.0.2.1")
    var profile = RouterProfile(id: id, name: "router", liveEndpoint: endpoint, setupComplete: false)
    let encoded = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(RouterProfile.self, from: encoded).setupComplete == false)

    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "setupComplete")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(RouterProfile.self, from: legacy).setupComplete == true)
    profile.setupComplete = true
    #expect(profile.setupComplete)
}

@Test func peekReadsWithoutSideEffects() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(AtomicJSONStore.peek(AppSettings.self, from: .settings, in: directory) == nil)
    let store = AtomicJSONStore(directory: directory)
    var settings = AppSettings()
    settings.refreshIntervalSeconds = 60
    try await store.save(settings, to: .settings, revision: 1)
    #expect(AtomicJSONStore.peek(AppSettings.self, from: .settings, in: directory)?.refreshIntervalSeconds == 60)
    try Data("not json".utf8).write(to: directory.appendingPathComponent("profiles.json"))
    #expect(AtomicJSONStore.peek(ProfileSettings.self, from: .profiles, in: directory) == nil)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("profiles.json").path))
}

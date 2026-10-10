import Foundation
import Testing
@testable import RoutewellKit

private func dnsFixture() throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "dns-info", withExtension: "json", subdirectory: "Fixtures/adguard/dns"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

private func json(_ text: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
}

/// `dns-info.json` is built from the AdGuard Home 0.107 schema with neutral
/// values; no recording of `dns_info` exists yet.
struct AdGuardDNSParsingTests {
    @Test func fixtureParsesEveryShownField() throws {
        let settings = try #require(AdGuardDNSSettings.parse(try dnsFixture()))
        #expect(settings.upstreams?.count == 7)
        #expect(settings.upstreamMode == .loadBalance)
        #expect(settings.fallback == [])
        #expect(settings.bootstrap == ["192.0.2.10", "198.51.100.10:53"])
        #expect(settings.blockingMode == .customIP)
        #expect(settings.blockingIPv4 == "192.0.2.99")
        #expect(settings.blockingIPv6 == "2001:db8::99")
        #expect(settings.blockedResponseTTL == 10)
        #expect(settings.cacheEnabled == true)
        #expect(settings.cacheOptimistic == false)
        #expect(settings.cacheSize == 4_194_304)
        #expect(settings.cacheTTLMin == 0)
        #expect(settings.cacheTTLMax == 86_400)
        #expect(settings.dnssecEnabled == true)
        #expect(settings.ednsClientSubnet == false)
        #expect(settings.resolvesIPv6 == true)
        #expect(settings.rateLimit == 20)
    }

    @Test func unknownFieldsAreKeptAndNeverSentAsChanges() throws {
        let loaded = try #require(AdGuardDNSSettings.parse(try dnsFixture()))
        #expect(loaded.fields["upstream_timeout"] == .number(10))
        #expect(loaded.fields["default_local_ptr_upstreams"] == .array([.string("192.0.2.1")]))
        var staged = loaded
        staged.cacheSize = 16_777_216
        staged.resolvesIPv6 = false
        #expect(staged.changes(from: loaded) == ["cache_size": .number(16_777_216), "disable_ipv6": .bool(true)])
        #expect(staged.fields["upstream_timeout"] == .number(10))
        #expect(loaded.changes(from: loaded).isEmpty)
    }

    @Test func missingOrOddFieldsAreUnknown() throws {
        let settings = try #require(AdGuardDNSSettings.parse(json(#"{"upstream_mode":"other","blocking_mode":7,"cache_size":"big"}"#)))
        #expect(settings.upstreams == nil)
        #expect(settings.upstreamMode == nil)
        #expect(settings.blockingMode == nil)
        #expect(settings.cacheSize == nil)
        #expect(settings.resolvesIPv6 == nil)
        #expect(AdGuardDNSSettings.parse(.array([])) == nil)
    }

    /// The older empty mode and `load_balance` are the same setting.
    @Test func emptyUpstreamModeMatchesLoadBalance() {
        let old = AdGuardDNSSettings(fields: ["upstream_mode": .string("")])
        #expect(old.contains(["upstream_mode": .string("load_balance")]))
        #expect(!old.contains(["upstream_mode": .string("parallel")]))
    }

    @Test func upstreamLinesAndProtocols() throws {
        let lines = try #require(AdGuardDNSSettings.parse(try dnsFixture())?.upstreams).map(UpstreamLine.init)
        #expect(lines.map(\.kind) == [.server, .server, .server, .server, .server, .comment, .domainSpecific])
        #expect(lines.compactMap(\.address).map { UpstreamProtocol(address: $0) } == [.doh, .dot, .doq, .plain, .plain])
        #expect(UpstreamProtocol(address: "h3://dns.example.net/dns-query") == .doh)
        #expect(UpstreamProtocol(address: "tcp://192.0.2.53") == .plain)
        #expect(UpstreamProtocol(address: "sdns://AQcAAAAAAAAA") == .dnsCrypt)
        #expect(UpstreamProtocol(address: "ftp://dns.example.net") == .other)
    }

    @Test func problemsBlockApply() {
        var settings = AdGuardDNSSettings(fields: ["upstream_dns": .array([.string("# only a comment")])])
        #expect(settings.problem == "Add at least one upstream server.")
        #expect(settings.applying(["upstream_dns_file": .string("/etc/upstreams.txt")]).problem == nil)
        settings.upstreams = ["192.0.2.53"]
        settings.blockingMode = .customIP
        #expect(settings.problem == "Enter a custom IPv4 or IPv6 address.")
        settings.blockingIPv4 = "192.0.2.300"
        #expect(settings.problem == "The custom IPv4 address is not valid.")
        settings.blockingIPv4 = "192.0.2.99"
        settings.blockingIPv6 = "192.0.2.99"
        #expect(settings.problem == "The custom IPv6 address is not valid.")
        settings.blockingIPv6 = ""
        settings.cacheTTLMin = 600
        settings.cacheTTLMax = 60
        #expect(settings.problem == "The cache minimum is longer than the maximum.")
        settings.cacheTTLMax = 0
        #expect(settings.problem == nil)
    }
}

struct UpstreamStatsJoinTests {
    /// The stats name upstreams with their port; the settings may leave
    /// it out. Neutral addresses in the recorded shapes.
    @Test func keysJoinAcrossDefaultPorts() {
        #expect(UpstreamAddress.key("https://dns.example.net/dns-query") == UpstreamAddress.key("https://dns.example.net:443/dns-query"))
        #expect(UpstreamAddress.key("quic://dns.example.com") == UpstreamAddress.key("quic://dns.example.com:853"))
        #expect(UpstreamAddress.key("tls://DNS.example.org") == UpstreamAddress.key("tls://dns.example.org:853"))
        #expect(UpstreamAddress.key("192.0.2.53") == UpstreamAddress.key("192.0.2.53:53"))
        #expect(UpstreamAddress.key("udp://192.0.2.53") == UpstreamAddress.key("192.0.2.53:53"))
        #expect(UpstreamAddress.key("2001:db8::53") == UpstreamAddress.key("[2001:db8::53]:53"))
        #expect(UpstreamAddress.key("https://dns.example.net/dns-query") != UpstreamAddress.key("https://dns.example.net/other"))
        #expect(UpstreamAddress.key("192.0.2.53:5353") != UpstreamAddress.key("192.0.2.53"))
        #expect(UpstreamAddress.key("tls://dns.example.org") != UpstreamAddress.key("quic://dns.example.org"))
    }

    @Test func recordedKeyShapesGiveShareAndTime() {
        let stats = AdGuardStats.parse(json(#"""
        {"top_upstreams_responses":[{"https://dns.example.net:443/dns-query":60},{"quic://dns.example.com:853":30},{"192.0.2.53:53":10}],
         "top_upstreams_avg_time":[{"quic://dns.example.com:853":1.5279144999999998},{"https://dns.example.net:443/dns-query":0.0195},{"192.0.2.53:53":0.004}]}
        """#))
        let doh = stats.usage(of: "https://dns.example.net/dns-query")
        #expect(doh.sharePercent == 60)
        #expect(abs((doh.averageMilliseconds ?? 0) - 19.5) < 0.001)
        #expect(!doh.isSlow)
        let doq = stats.usage(of: "quic://dns.example.com")
        #expect(doq.sharePercent == 30)
        #expect(doq.isSlow)
        #expect(stats.usage(of: "192.0.2.53").sharePercent == 10)
        let missing = stats.usage(of: "tls://dns.example.org")
        #expect(missing == UpstreamUsage())
        #expect(!missing.isSlow)
    }

    /// The anonymised recorded stats: the slowest upstream is over 0.5 s.
    @Test func fixtureStatsTimesParseInSeconds() throws {
        let url = try #require(Bundle.module.url(forResource: "stats-24h", withExtension: "json", subdirectory: "Fixtures/adguard/overview"))
        let stats = AdGuardStats.parse(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)))
        #expect(stats.topUpstreamTimes?.count == 5)
        #expect(stats.usage(of: "https://dns-1.example/dns-query").isSlow)
        #expect(!stats.usage(of: "https://dns-2.example/dns-query").isSlow)
        let share = try #require(stats.usage(of: "https://dns-1.example/dns-query").sharePercent)
        #expect(abs(share - 1995.0 / 3087.0 * 100) < 0.001)
    }

    /// An archive saved before the times existed still loads.
    @Test func olderSavedStatsLoadWithoutTimes() throws {
        var stats = AdGuardStats()
        stats.topUpstreams = [.init(name: "192.0.2.53:53", count: 1)]
        var object = try #require(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(stats)).object)
        object["topUpstreamTimes"] = nil
        let decoded = try JSONDecoder().decode(AdGuardStats.self, from: JSONEncoder().encode(JSONValue.object(object)))
        #expect(decoded.topUpstreamTimes == nil)
        #expect(decoded.usage(of: "192.0.2.53").sharePercent == 100)
    }
}

struct UpstreamTestResultTests {
    @Test func okAndErrorsMapPerAddress() {
        let result = UpstreamTestResult.parse(json(#"""
        {"https://dns.example.net/dns-query":"OK","192.0.2.53:5353":"couldn't communicate with upstream: i/o timeout\n","tls://dns.example.org":3}
        """#))
        #expect(result.status(of: "https://dns.example.net/dns-query") == .ok)
        #expect(result.status(of: "https://dns.example.net:443/dns-query") == .ok)
        #expect(result.status(of: "192.0.2.53:5353") == .failed("couldn't communicate with upstream: i/o timeout"))
        #expect(result.status(of: "tls://dns.example.org") == nil)
        #expect(UpstreamTestResult.parse(nil).statuses.isEmpty)
    }
}

// MARK: Executor

private final class DNSClock: Sendable {
    private nonisolated(unsafe) var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let lock = NSLock()

    func now() -> Date { lock.withLock { current } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { current = current.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) }
    }
}

/// AdGuard Home's DNS settings over HTTP. `ignored` fields are accepted and
/// not changed; with `readsFailAfterWrite`, every read after a write fails.
private final class DNSServer: Sendable {
    private nonisolated(unsafe) var settings: [String: JSONValue]
    private nonisolated(unsafe) var ignored: Set<String> = []
    private nonisolated(unsafe) var readsFailAfterWrite = false
    private nonisolated(unsafe) var written = false
    private nonisolated(unsafe) var writeStatus = 200
    private let lock = NSLock()
    let transport: StubHTTPTransport

    init(_ settings: [String: JSONValue]) {
        self.settings = settings
        let box = Box()
        transport = StubHTTPTransport { request in try box.server!.answer(request) }
        box.server = self
    }

    private final class Box: @unchecked Sendable {
        weak var server: DNSServer?
    }

    func set(ignored: Set<String> = [], readsFailAfterWrite: Bool = false, writeStatus: Int = 200) {
        lock.withLock {
            self.ignored = ignored
            self.readsFailAfterWrite = readsFailAfterWrite
            self.writeStatus = writeStatus
        }
    }

    var current: [String: JSONValue] { lock.withLock { settings } }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let reply: (Int, JSONValue?) = lock.withLock {
            switch (request.httpMethod, url.path) {
            case ("GET", "/control/dns_info"):
                return readsFailAfterWrite && written ? (500, nil) : (200, .object(settings))
            case ("POST", "/control/dns_config"):
                written = true
                let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                for (key, value) in body?.object ?? [:] where !ignored.contains(key) { settings[key] = value }
                return (writeStatus, nil)
            case ("POST", "/control/cache_clear"):
                return (writeStatus, nil)
            case ("POST", "/control/test_upstream_dns"):
                let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                let addresses = (body?["upstream_dns"]?.array ?? []).compactMap(\.string)
                return (200, .object(Dictionary(uniqueKeysWithValues: addresses.map {
                    ($0, JSONValue.string($0.contains("bad") ? "upstream does not answer" : "OK"))
                })))
            default:
                return (404, nil)
            }
        }
        let data = try reply.1.map { try JSONEncoder().encode($0) } ?? Data()
        return (data, StubHTTPTransport.response(reply.0, url: url))
    }
}

private func executor(_ server: DNSServer, gate: MutationGate = MutationGate(), clock: DNSClock = DNSClock()) -> AdGuardSettingExecutor {
    let client = AdGuardClient(baseURL: URL(string: "http://192.0.2.1:3000/")!,
                               credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }),
                               transport: server.transport)
    return AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: client), gate: gate,
                                  clock: { clock.now() }, sleep: { try await clock.sleep($0) })
}

struct AdGuardDNSApplyTests {
    private static let loaded: [String: JSONValue] = [
        "upstream_dns": .array([.string("192.0.2.53")]), "cache_size": .number(4_194_304),
        "ratelimit": .number(20), "protection_enabled": .bool(true), "upstream_timeout": .number(10),
    ]

    @Test func applySendsOnlyTheChangedFieldsAndVerifies() async throws {
        let server = DNSServer(Self.loaded)
        let changes: [String: JSONValue] = ["cache_size": .number(16_777_216), "upstream_dns": .array([.string("tls://dns.example.org")])]
        let report = await executor(server).run(.dns(changes: changes), availability: .running)
        guard case .verifiedSuccess(.dns(let settings)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(settings.cacheSize == 16_777_216)
        #expect(report.dispatched)
        let recorded = await server.transport.recorded()
        #expect(recorded.map { "\($0.request.httpMethod!) \($0.request.url!.path)" }
            == ["GET /control/dns_info", "POST /control/dns_config", "GET /control/dns_info"])
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(recorded[1].body))
        #expect(body == .object(changes))
    }

    @Test func nothingIsSentWhenAdGuardHomeAlreadyHasTheValues() async throws {
        let server = DNSServer(Self.loaded)
        let report = await executor(server).run(.dns(changes: ["ratelimit": .number(20)]), availability: .running)
        #expect(!report.dispatched)
        #expect(await server.transport.recorded().count == 1)
    }

    /// `resync`: the outcome reports AdGuard Home's values and nothing is
    /// sent again.
    @Test func ignoredFieldIsMismatchWithOneWrite() async throws {
        let server = DNSServer(Self.loaded)
        server.set(ignored: ["cache_size"])
        let report = await executor(server).run(.dns(changes: ["cache_size": .number(1_048_576)]), availability: .running)
        guard case .verifiedMismatch(.dns(let expected), .dns(let actual)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(expected.cacheSize == 1_048_576)
        #expect(actual.cacheSize == 4_194_304)
        #expect(await server.transport.recorded().filter { $0.request.httpMethod == "POST" }.count == 1)
    }

    @Test func lostVerificationIsUnknownAfterDispatch() async throws {
        let server = DNSServer(Self.loaded)
        server.set(readsFailAfterWrite: true)
        let report = await executor(server).run(.dns(changes: ["ratelimit": .number(0)]), availability: .running)
        #expect(report.outcome == .unknownAfterDispatch)
        #expect(report.dispatched)
    }

    @Test func applyIsRejectedUnlessRunningOrWithoutChanges() async throws {
        let server = DNSServer(Self.loaded)
        let run = executor(server)
        for availability in [AdGuardAvailability.cached, .off, .unknown] {
            let report = await run.run(.dns(changes: ["ratelimit": .number(5)]), availability: availability)
            #expect(report.outcome == .rejected(.preconditionFailed("AdGuard Home is not running.")))
        }
        #expect(await run.run(.dns(changes: [:]), availability: .running).outcome == .rejected(.invalidIntent("No DNS changes")))
        #expect(await server.transport.recorded().isEmpty)
    }

    @Test func clearCacheIsOneCallAndALostReplyIsUnknown() async throws {
        let server = DNSServer(Self.loaded)
        let run = executor(server)
        #expect(await run.run(.clearDNSCache, availability: .running).outcome == .verifiedSuccess(.cacheCleared))
        server.set(writeStatus: 500)
        let failed = await run.run(.clearDNSCache, availability: .running)
        #expect(failed.outcome == .unknownAfterDispatch)
        #expect(failed.dispatched)
        #expect(await server.transport.recorded().map { $0.request.url!.path } == ["/control/cache_clear", "/control/cache_clear"])
    }

    /// A check, not a change: it runs while a write holds the gate.
    @Test func testUpstreamsDoesNotWaitForTheGate() async throws {
        let server = DNSServer(Self.loaded)
        let gate = MutationGate()
        let token = try await gate.acquire()
        let request = UpstreamTestRequest(upstreams: ["https://dns.example.net/dns-query", "bad.example"], bootstrap: ["192.0.2.10"], fallback: [])
        let result = try await executor(server, gate: gate).testUpstreams(request, availability: .running).get()
        await gate.release(token)
        #expect(result.status(of: "https://dns.example.net/dns-query") == .ok)
        #expect(result.status(of: "bad.example") == .failed("upstream does not answer"))
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(await server.transport.recorded().first?.body))
        #expect(body == .object(["upstream_dns": .array([.string("https://dns.example.net/dns-query"), .string("bad.example")]),
                                 "bootstrap_dns": .array([.string("192.0.2.10")]), "fallback_dns": .array([])]))
        #expect(await executor(server).testUpstreams(request, availability: .cached) == .failure(.unavailable))
    }
}

struct AdGuardDNSArchiveTests {
    /// The DNS tab shows the Overview read's `dns_info` and upstream stats.
    @Test func dnsTabRunsTheOverviewRead() {
        let areas = ScreenRefreshPlan.resolve(destination: "adGuard", segment: "DNS", defaultInterval: .seconds(30)).map(\.area)
        #expect(areas.contains(.adGuardOverview))
    }

    @Test func overviewReadSavesTheDNSSection() async throws {
        let store = AdGuardArchiveStore(root: nil)
        let profile = UUID()
        let settings = AdGuardDNSSettings(fields: ["ratelimit": .number(20)])
        let reading = AdGuardOverviewReading(range: .day, stats: .failure(.timeout), statsConfig: .failure(.timeout),
                                             protection: .failure(.timeout), filtering: .failure(.timeout),
                                             dns: .success(settings), observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        await store.save(reading, for: profile)
        let archive = try #require(await store.archive(for: profile))
        #expect(archive.dns?.value == settings)
        #expect(archive.savedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func recordingPlanReadsDNSInfo() {
        let call = FixtureRecordingPlan.calls.first { $0.method == "control/dns_info" }
        #expect(call?.fileName == "adguard-dns-info.json")
        #expect(call.map(FixtureRecordingPlan.isReadOnly) == true)
        let redacted = RecordedFixtureRedactor.redact(.object(["upstream_mode": .string("load_balance"), "blocking_mode": .string("custom_ip"),
                                                               "upstream_dns": .array([.string("https://private.example/abc")])]))
        #expect(redacted["upstream_mode"] == .string("load_balance"))
        #expect(redacted["blocking_mode"] == .string("custom_ip"))
        #expect(redacted["upstream_dns"]?[0]?.string != "https://private.example/abc")
    }
}

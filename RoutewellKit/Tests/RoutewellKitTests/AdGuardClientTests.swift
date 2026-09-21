import Foundation
import Testing
@testable import RoutewellKit

private func fixtureData(_ name: String, subdirectory: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory)!
    return try! Data(contentsOf: url)
}

/// A minimal `RouterSessionTokenProvider` test double. `GLiNetRPCClient` is
/// implemented on another branch (task 5); this stub only needs to satisfy
/// the protocol `AdGuardClientTests` depends on.
private actor StubSessionProvider: RouterSessionTokenProvider {
    private(set) var invalidateCount = 0
    private var sid: String

    init(sid: String) { self.sid = sid }

    func sessionID() async throws -> String { sid }
    func invalidateSession() async { invalidateCount += 1 }
}

@Suite struct AdGuardClientTests {
    private static let baseURL = URL(string: "http://192.168.8.1:3000/")!

    @Test func statusParsesFixture() async throws {
        let body = fixtureData("control-status", subdirectory: "Fixtures/adguard")
        let transport = StubHTTPTransport { request in
            (body, StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }), transport: transport)
        let status = try await client.status()
        #expect(status.version == "v0.107.43")
        #expect(status.running == true)
        #expect(status.protectionEnabled == true)
        #expect(status.protectionDisabledDurationMilliseconds == 0)
        #expect(status.dnsAddresses == ["192.168.8.1:53"])
    }

    @Test func statsParsesFixture() async throws {
        let body = fixtureData("control-stats", subdirectory: "Fixtures/adguard")
        let transport = StubHTTPTransport { request in
            (body, StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }), transport: transport)
        let stats = try await client.stats()
        #expect(stats.queries == 1234)
        #expect(stats.blocked == 56)
        #expect(stats.timeUnits == "days")
    }

    @Test func adGuardStatusPausedMapping() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let status = AdGuardStatusResponse(protectionEnabled: false, protectionDisabledDurationMilliseconds: 60_000)
        let result = AdGuardClient.adGuardStatus(status: status, stats: nil, now: now)
        #expect(result.reachability == .connected)
        if case .paused(let until) = result.protection {
            #expect(until == now.addingTimeInterval(60))
        } else {
            Issue.record("expected .paused, got \(result.protection)")
        }
    }

    @Test func adGuardStatusDisabledMapping() {
        let status = AdGuardStatusResponse(protectionEnabled: false, protectionDisabledDurationMilliseconds: 0)
        let result = AdGuardClient.adGuardStatus(status: status, stats: nil, now: .now)
        #expect(result.protection == .disabled)
    }

    @Test func adGuardStatusEnabledMapping() {
        let status = AdGuardStatusResponse(protectionEnabled: true)
        let result = AdGuardClient.adGuardStatus(status: status, stats: nil, now: .now)
        #expect(result.protection == .enabled)
    }

    @Test func adGuardStatusUnknownWhenNil() {
        let result = AdGuardClient.adGuardStatus(status: nil, stats: nil, now: .now)
        #expect(result.protection == .unknown)
        #expect(result.reachability == .unknown)
    }

    @Test func adGuardStatusIncludesStatsCounts() {
        let stats = AdGuardStatsResponse(queries: 10, blocked: 2, timeUnits: "days")
        let result = AdGuardClient.adGuardStatus(status: nil, stats: stats, now: .now)
        #expect(result.queriesToday == 10)
        #expect(result.blockedToday == 2)
    }

    @Test func basicCredentialsSendExactAuthorizationHeader() async throws {
        let body = fixtureData("control-status", subdirectory: "Fixtures/adguard")
        let transport = StubHTTPTransport { request in
            (body, StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "hunter2" }), transport: transport)
        _ = try await client.status()
        let recorded = await transport.recorded()
        #expect(recorded.count == 1)
        let expected = "Basic " + Data("admin:hunter2".utf8).base64EncodedString()
        #expect(recorded[0].request.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test func routerTokenCredentialsSendCookieHeader() async throws {
        let body = fixtureData("control-status", subdirectory: "Fixtures/adguard")
        let transport = StubHTTPTransport { request in
            (body, StubHTTPTransport.response(200, url: request.url!))
        }
        let session = StubSessionProvider(sid: "abc123")
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: RouterTokenAdGuardCredentials(session: session), transport: transport)
        _ = try await client.status()
        let recorded = await transport.recorded()
        #expect(recorded[0].request.value(forHTTPHeaderField: "Cookie") == "Admin-Token=abc123")
    }

    @Test func routerTokenRetriesOnceAfter401ThenSucceeds() async throws {
        let body = fixtureData("control-status", subdirectory: "Fixtures/adguard")
        let counter = Counter()
        let transport = StubHTTPTransport { request in
            let attempt = await counter.increment()
            if attempt == 1 {
                return (Data(), StubHTTPTransport.response(401, url: request.url!))
            }
            return (body, StubHTTPTransport.response(200, url: request.url!))
        }
        let session = StubSessionProvider(sid: "abc123")
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: RouterTokenAdGuardCredentials(session: session), transport: transport)
        let status = try await client.status()
        #expect(status.version == "v0.107.43")
        let recorded = await transport.recorded()
        #expect(recorded.count == 2)
        let invalidated = await session.invalidateCount
        #expect(invalidated == 1)
    }

    @Test func basicCredentials403IsNotRetried() async throws {
        let transport = StubHTTPTransport { request in
            (Data(), StubHTTPTransport.response(403, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "hunter2" }), transport: transport)
        await #expect(throws: AdGuardClientError.unauthorized(403)) {
            _ = try await client.status()
        }
        let recorded = await transport.recorded()
        #expect(recorded.count == 1)
    }

    @Test func httpStatusErrorSurfacesForNon200NonAuthResponses() async throws {
        let transport = StubHTTPTransport { request in
            (Data(), StubHTTPTransport.response(500, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "hunter2" }), transport: transport)
        await #expect(throws: AdGuardClientError.httpStatus(500)) {
            _ = try await client.status()
        }
    }

    @Test func malformedBodyThrows() async throws {
        let transport = StubHTTPTransport { request in
            (Data("not json".utf8), StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "hunter2" }), transport: transport)
        await #expect(throws: AdGuardClientError.malformedResponse) {
            _ = try await client.status()
        }
    }

    @Test func credentialFailureSurfacesAsCredentialUnavailable() async throws {
        let transport = StubHTTPTransport { request in
            (Data(), StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(
            baseURL: Self.baseURL,
            credentials: BasicAdGuardCredentials(username: "admin", password: { throw CredentialError.missing }),
            transport: transport
        )
        await #expect(throws: AdGuardClientError.credentialUnavailable) {
            _ = try await client.status()
        }
        let recorded = await transport.recorded()
        #expect(recorded.isEmpty)
    }

    @Test func setProtectionSendsSortedJSONBodyAndCorrectMethod() async throws {
        let transport = StubHTTPTransport { request in
            (Data(), StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "hunter2" }), transport: transport)
        try await client.setProtection(enabled: false, durationMilliseconds: 60_000)
        let recorded = await transport.recorded()
        #expect(recorded.count == 1)
        #expect(recorded[0].request.httpMethod == "POST")
        #expect(recorded[0].request.url?.path == "/control/protection")
        #expect(recorded[0].request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = recorded[0].body.map { String(data: $0, encoding: .utf8) } ?? nil
        #expect(body == "{\"duration\":60000,\"enabled\":false}")
    }

    @Test func setProtectionRetriesOnceAfter401ThenSucceeds() async throws {
        let counter = Counter()
        let transport = StubHTTPTransport { request in
            let attempt = await counter.increment()
            if attempt == 1 {
                return (Data(), StubHTTPTransport.response(401, url: request.url!))
            }
            return (Data(), StubHTTPTransport.response(200, url: request.url!))
        }
        let session = StubSessionProvider(sid: "abc123")
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: RouterTokenAdGuardCredentials(session: session), transport: transport)
        try await client.setProtection(enabled: true, durationMilliseconds: 0)
        let recorded = await transport.recorded()
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0.request.httpMethod == "POST" })
        let invalidated = await session.invalidateCount
        #expect(invalidated == 1)
    }

    @Test func setProtection403WithoutRetrySupportThrowsAfterOnePOST() async throws {
        let transport = StubHTTPTransport { request in
            (Data(), StubHTTPTransport.response(403, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "hunter2" }), transport: transport)
        await #expect(throws: AdGuardClientError.unauthorized(403)) {
            try await client.setProtection(enabled: true, durationMilliseconds: 0)
        }
        let recorded = await transport.recorded()
        #expect(recorded.count == 1)
    }

    @Test func requestsStayPinnedToBaseURLHostAndPort() async throws {
        let body = fixtureData("control-status", subdirectory: "Fixtures/adguard")
        let transport = StubHTTPTransport { request in
            (body, StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(baseURL: Self.baseURL, credentials: BasicAdGuardCredentials(username: "admin", password: { "hunter2" }), transport: transport)
        _ = try await client.status()
        let recorded = await transport.recorded()
        #expect(recorded[0].request.url?.host == "192.168.8.1")
        #expect(recorded[0].request.url?.port == 3000)
        #expect(recorded[0].request.url?.path == "/control/status")
    }
}

private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

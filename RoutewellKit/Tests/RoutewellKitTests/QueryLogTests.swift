import Foundation
import Testing
@testable import RoutewellKit
import RoutewellMock

private func queryLogFixture() throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: "control-querylog-4.9.1", withExtension: "json", subdirectory: "Fixtures/adguard/querylog")!)
}

private struct NoCredentials: AdGuardCredentialProvider {
    func authorizationHeaders() async throws -> [String: String] { [:] }
    func handleUnauthorized() async -> Bool { false }
}

private let adGuardURL = URL(string: "http://192.0.2.20:3000/")!

@Suite struct QueryLogTests {
    @Test func parsesTheRecordedPage() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: queryLogFixture())
        let page = try #require(QueryLogParser.parse(json, limit: 500))
        #expect(page.entries.count == 211)
        #expect(!page.isFull)
        #expect(page.oldest == QueryLogParser.timestamp("2026-09-23T14:16:13.119520224Z"))
        let first = try #require(page.entries.first)
        #expect(first.client == "198.51.100.41")
        #expect(first.domain?.hasSuffix(".example") == true)
        #expect(first.time == QueryLogParser.timestamp("2026-09-23T14:34:40.610Z"))
        #expect(page.entries.allSatisfy { $0.time != nil && $0.client != nil && $0.domain != nil })
        let results = Dictionary(grouping: page.entries, by: \.result).mapValues(\.count)
        #expect(results == [.processed: 176, .blocked: 35])
    }

    @Test func summarizesOneClientExactly() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: queryLogFixture())
        let page = try #require(QueryLogParser.parse(json, limit: 500))
        let fetchedAt = Date()
        let activity = ClientQueryActivity.summarize(page, clientIP: "198.51.100.43", fetchedAt: fetchedAt)
        #expect(activity.total == 88)
        #expect(activity.blocked == 29)
        #expect(activity.topRequested.count == 5)
        #expect(activity.topRequested.first == DomainCount(domain: "host24.example", count: 18))
        #expect(activity.topBlocked.first == DomainCount(domain: "host24.example", count: 18))
        #expect(activity.topBlocked.count <= 5)
        #expect(zip(activity.entries, activity.entries.dropFirst()).allSatisfy { ($0.time ?? .distantPast) >= ($1.time ?? .distantPast) })
        #expect(activity.windowStart == page.oldest)
        #expect(!activity.windowLimited)
        // A near-match address, as a server-side search could return, is excluded.
        #expect(ClientQueryActivity.summarize(page, clientIP: "198.51.100.4", fetchedAt: fetchedAt).total == 0)
    }

    @Test func toleratesMissingAndOddFields() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"data":[
          {"time":"2026-09-23T14:34:40Z","client":"192.0.2.5","question":{"name":"a.example"},"reason":"FilteredSafeBrowsing"},
          {"time":"not a time","client":"","question":{},"reason":"SomethingNew"},
          {"time":"2026-09-23T15:34:40.5+01:00","client":"192.0.2.5","question":{"name":"b.example"},"reason":"Rewrite"},
          42
        ]}
        """#.utf8))
        let page = try #require(QueryLogParser.parse(json, limit: 3))
        #expect(page.entries.count == 3)
        #expect(page.isFull)
        #expect(page.oldest == nil)
        #expect(page.entries[0].result == .blocked)
        #expect(page.entries[1] == QueryLogEntry(timeText: "not a time", reason: "SomethingNew"))
        #expect(page.entries[1].result == .unknown)
        #expect(page.entries[2].result == .rewritten)
        #expect(page.entries[2].time == QueryLogParser.timestamp("2026-09-23T14:34:40.500Z"))
        #expect(QueryLogParser.parse(.object(["data": .null]), limit: 5)?.entries == [])
        #expect(QueryLogParser.parse(.object(["other": .array([])]), limit: 5) == nil)
    }

    @Test func requestAsksForABoundedPageAndStaysOnTheAdGuardHost() async throws {
        let body = try queryLogFixture()
        let transport = StubHTTPTransport { request in (body, StubHTTPTransport.response(200, url: request.url!)) }
        let client = AdGuardClient(baseURL: adGuardURL, credentials: NoCredentials(), transport: transport)
        let service = LiveQueryLogService(adGuard: client)
        let result = try await service.recentQueries(search: "198.51.100.43", limit: 9_999)
        guard case .success(let page, _, .adGuardAPI) = result else { Issue.record("expected a page"); return }
        #expect(page.limit == QueryLogLimits.maximum)
        let url = try #require(await transport.recorded().first?.request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "192.0.2.20" && components.port == 3000)
        #expect(components.path == "/control/querylog")
        #expect(components.queryItems?.contains(URLQueryItem(name: "limit", value: "500")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "search", value: "198.51.100.43")) == true)
    }

    @Test func failuresAreResultsAndTheProbeStaysUnknown() async throws {
        let transport = StubHTTPTransport { request in (Data("{}".utf8), StubHTTPTransport.response(404, url: request.url!)) }
        let service = LiveQueryLogService(adGuard: AdGuardClient(baseURL: adGuardURL, credentials: NoCredentials(), transport: transport))
        guard case .failure(.malformedResponse, _) = try await service.recentQueries(search: nil, limit: 10) else {
            Issue.record("expected a failure result"); return
        }
        #expect(await service.probe().state == .unknown)

        let malformed = StubHTTPTransport { request in (Data(#"{"data":"x"}"#.utf8), StubHTTPTransport.response(200, url: request.url!)) }
        let second = LiveQueryLogService(adGuard: AdGuardClient(baseURL: adGuardURL, credentials: NoCredentials(), transport: malformed))
        guard case .failure(.malformedResponse, _) = try await second.recentQueries(search: nil, limit: 10) else {
            Issue.record("expected malformed"); return
        }
    }

    @Test func sessionFencesTheReadAndReportsNoServiceAsNil() async throws {
        let session = RouterSession()
        let token = SessionToken(profileID: "a", revision: 1)
        let backend = MockRouterBackend()
        try await session.beginRevision(token)
        let lease = SessionLease(token: token, backend: backend)
        try await session.installLease(lease)
        let result = try await session.query(lease) { try await $0.queryLog?.recentQueries(search: "192.168.8.192", limit: 500) }
        guard case .success(let page, _, .mock)? = result else { Issue.record("expected mock page"); return }
        // The mock log is longer than one page for every client.
        let activity = ClientQueryActivity.summarize(page, clientIP: "192.168.8.192", fetchedAt: .now)
        #expect(activity.total == 500)
        #expect(activity.windowLimited)

        try await session.beginRevision(SessionToken(profileID: "a", revision: 2))
        await #expect(throws: SessionError.self) { _ = try await session.query(lease) { try await $0.queryLog?.recentQueries(search: nil, limit: 5) } }
    }
}

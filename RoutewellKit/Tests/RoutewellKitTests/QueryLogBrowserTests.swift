import Foundation
import Testing
@testable import RoutewellKit

/// Chunk 18: the Query Log tab's pages, Live, dates, and domain rules,
/// against the anonymized AdGuard Home v1.0.0-b.1 recording.
private func recorded(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/adguard/querylog/v1.0.0-b.1"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

private func page(_ name: String) throws -> QueryLogPage {
    try #require(QueryLogParser.parse(try recorded(name), limit: 500))
}

private func entry(_ second: Int, _ domain: String = "a.example") -> QueryLogEntry {
    let time = Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(second))
    return QueryLogEntry(time: time, timeText: time.formatted(.iso8601), client: "192.0.2.1", domain: domain, reason: "NotFilteredNotFound")
}

/// Newest first: seconds `from` down to `from - count + 1`.
private func synthetic(from: Int, count: Int, limit: Int = 500) -> QueryLogPage {
    let entries = (0..<count).map { entry(from - $0) }
    return QueryLogPage(entries: entries, oldest: entries.last?.time, oldestText: entries.last?.timeText, limit: limit)
}

@Suite struct QueryLogBrowserTests {
    @Test func parsesEveryRecordedField() throws {
        let first = try page("querylog-500")
        #expect(first.entries.count == 500)
        #expect(first.oldestText == "2026-10-09T18:55:13.580763507Z")
        #expect(zip(first.entries, first.entries.dropFirst()).allSatisfy { $0.time! >= $1.time! })
        let results = Dictionary(grouping: first.entries, by: \.result).mapValues(\.count)
        #expect(results == [.processed: 446, .blocked: 54])

        let blocked = try page("querylog-status-blocked")
        let filtering = AdGuardFilteringStatus.parse(try recorded("control-filtering-status"))
        let listIDs = Set(filtering.blocklists.map(\.id))
        let byList = blocked.entries.filter { $0.reason == "FilteredBlackList" }
        #expect(!byList.isEmpty && byList.allSatisfy { $0.filterID.map(listIDs.contains) == true })
        #expect(byList.allSatisfy { $0.rule == "||\($0.domain!)^" })
        let service = try #require(blocked.entries.first { $0.reason == "FilteredBlockedService" })
        #expect(service.filterID == -2)
        #expect(service.serviceName == "Example service")

        let cached = try #require(first.entries.first { $0.cached == true && $0.elapsedMilliseconds != nil })
        #expect(cached.clientProtocol == "")
        #expect(cached.type != nil)
        // The recorder hid some `elapsedMs` values: they stay unknown.
        #expect(first.entries.contains { $0.elapsedMilliseconds == nil })
        #expect(first.entries.contains { !$0.answers.isEmpty })
    }

    @Test func loadMoreReadsTheNextPageWithOlderThan() throws {
        var browser = QueryLogBrowser()
        #expect(browser.nextPageQuery == nil)
        let first = try page("querylog-500")
        browser.replace(with: first)
        let next = try #require(browser.nextPageQuery)
        #expect(next.olderThan == "2026-10-09T18:55:13.580763507Z")
        #expect(next.limit == 500)
        let older = try page("querylog-500-older")
        browser.append(older)
        #expect(browser.entries.count == 1_000)
        #expect(Set(browser.entries.map(\.id)).count == 1_000)
        #expect(zip(browser.entries, browser.entries.dropFirst()).allSatisfy { $0.time! >= $1.time! })
        #expect(browser.oldestLoaded == older.entries.last?.time)
        #expect(browser.nextPageQuery?.olderThan == older.oldestText)
    }

    @Test func aShortFilteredPageIsNotTheEnd() throws {
        var browser = QueryLogBrowser(status: .blocked)
        let blocked = try page("querylog-status-blocked")
        #expect(blocked.entries.count == 104)
        browser.replace(with: blocked)
        #expect(browser.isFiltered)
        #expect(browser.canLoadMore)
        #expect(browser.nextPageQuery?.status == .blocked)
        browser.append(QueryLogPage(entries: [], limit: 500))
        #expect(browser.reachedEnd)
        #expect(browser.nextPageQuery == nil)
    }

    @Test func keepsAtMostFiveThousand() {
        var browser = QueryLogBrowser()
        browser.replace(with: synthetic(from: 100_000, count: 500))
        var from = 99_500
        while let query = browser.nextPageQuery {
            #expect(query.olderThan == browser.entries.last?.timeText)
            browser.append(synthetic(from: from, count: 500))
            from -= 500
        }
        #expect(browser.entries.count == QueryLogLimits.loadedCap)
        #expect(browser.isAtCap)
        #expect(!browser.reachedEnd)
    }

    @Test func liveAddsNewerEntriesAndReloadsAfterAGap() {
        var browser = QueryLogBrowser()
        browser.replace(with: synthetic(from: 1_000, count: 500))
        // Three new entries, then the 97 newest already shown.
        #expect(browser.mergeLive(synthetic(from: 1_003, count: 100, limit: 100)) == .merged(count: 3))
        #expect(browser.entries.count == 503)
        #expect(browser.entries.first?.id == entry(1_003).id)
        #expect(browser.mergeLive(synthetic(from: 1_003, count: 100, limit: 100)) == .merged(count: 0))
        // A full read where every entry is newer: some are missing in between.
        #expect(browser.mergeLive(synthetic(from: 2_000, count: 100, limit: 100)) == .reloadNeeded)
        // A short read where every entry is newer is the whole gap.
        #expect(browser.mergeLive(synthetic(from: 1_010, count: 7, limit: 100)) == .merged(count: 7))
        #expect(browser.entries.count == 510)
    }

    @Test func liveDropsTheOldestAtTheCap() {
        var browser = QueryLogBrowser(cap: 10)
        browser.replace(with: synthetic(from: 100, count: 10))
        #expect(browser.mergeLive(synthetic(from: 102, count: 5, limit: 100)) == .merged(count: 2))
        #expect(browser.entries.count == 10)
        #expect(browser.entries.last?.id == entry(93).id)
        #expect(browser.cursor == entry(93).timeText)
    }

    @Test func statusFilterSendsResponseStatus() async throws {
        #expect(QueryLogStatusFilter.allCases.map(\.responseStatus) == ["all", "blocked", "processed", "whitelisted", "rewritten"])
        let transport = StubHTTPTransport { request in
            (Data(#"{"data":[],"oldest":""}"#.utf8), StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(baseURL: URL(string: "http://192.0.2.20:3000/")!,
                                   credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }), transport: transport)
        _ = try await client.queryLog(QueryLogQuery(limit: 500))
        _ = try await client.queryLog(QueryLogQuery(search: " 192.0.2.7 ", status: .allowed, olderThan: "2026-01-02T03:04:05.5+01:00", limit: 9_999))
        let urls = await transport.recorded().map { $0.request.url?.absoluteString }
        #expect(urls == [
            "http://192.0.2.20:3000/control/querylog?limit=500",
            "http://192.0.2.20:3000/control/querylog?limit=500&older_than=2026-01-02T03:04:05.5%2B01:00&search=192.0.2.7&response_status=whitelisted",
        ])
    }

    @Test func resultsFollowTheReason() {
        #expect(QueryResult(reason: "NotFilteredNotFound") == .processed)
        #expect(QueryResult(reason: "NotFilteredWhiteList") == .allowed)
        #expect(QueryResult(reason: "FilteredBlockedService") == .blocked)
        #expect(QueryResult(reason: "Rewrite") == .rewritten)
        #expect(QueryResult(reason: "Other") == .unknown)
    }

    @Test func formatsRowAndInspectorDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let locale = Locale(identifier: "en_GB")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 20, minute: 30)))
        func at(_ day: Int, _ month: Int = 10, _ year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 21, minute: 14, second: 5))!
        }
        #expect(QueryLogTimeFormat.row(at(9), now: now, calendar: calendar, locale: locale) == "21:14:05")
        #expect(QueryLogTimeFormat.row(at(8), now: now, calendar: calendar, locale: locale) == "Yesterday 21:14")
        #expect(QueryLogTimeFormat.row(at(6), now: now, calendar: calendar, locale: locale) == "6 Oct 21:14")
        #expect(QueryLogTimeFormat.row(at(6, 10, 2025), now: now, calendar: calendar, locale: locale) == "6 Oct 2025 21:14")
        #expect(QueryLogTimeFormat.full(at(9), now: now, calendar: calendar, locale: locale) == "Today at 21:14:05")
        #expect(QueryLogTimeFormat.full(at(8), now: now, calendar: calendar, locale: locale) == "Yesterday at 21:14:05")
        #expect(QueryLogTimeFormat.full(at(6), now: now, calendar: calendar, locale: locale) == "6 October 2026 at 21:14:05")
    }

    @Test func domainRulesAreOneLine() {
        #expect(DomainRuleAction.block.rule(for: "Ads.Example.NET.") == "||ads.example.net^")
        #expect(DomainRuleAction.unblock.rule(for: "ads.example.net") == "@@||ads.example.net^")
        #expect(DomainRuleAction.block.rule(for: "ads.example.net^\n||other.example") == nil)
        #expect(DomainRuleAction.block.rule(for: "") == nil)
        #expect(DomainRuleAction.block.rule(for: "_dns-sd._udp.example.arpa") == "||_dns-sd._udp.example.arpa^")
        let rules = ["# mine", "@@||ads.example.net^", "||other.example^", ""]
        let blocked = DomainRuleAction.block.apply(to: rules, domain: "ads.example.net")
        #expect(blocked == ["# mine", "||other.example^", "||ads.example.net^"])
        #expect(DomainRuleAction.block.isApplied(in: blocked ?? [], domain: "ads.example.net"))
        #expect(!DomainRuleAction.block.isApplied(in: rules, domain: "ads.example.net"))
        let unblocked = DomainRuleAction.unblock.apply(to: blocked ?? [], domain: "ads.example.net")
        #expect(unblocked == ["# mine", "||other.example^", "@@||ads.example.net^"])
    }

    @Test func recorderKeepsLongDecimals() {
        let value: JSONValue = .object(["elapsedMs": .string("19.232000000000003")])
        #expect(RecordedFixtureRedactor.redact(value)["elapsedMs"]?.string == "19.232000000000003")
    }
}

/// Custom rules in memory; `applies` false keeps them unchanged.
private actor RulesTransport: AdGuardSettingTransport {
    var rules: [String]
    let applies: Bool
    private(set) var sent: [[String]] = []

    init(rules: [String], applies: Bool = true) {
        self.rules = rules
        self.applies = applies
    }

    func readStatus() async throws -> AdGuardStatusResponse { throw AdGuardClientError.malformedResponse }
    func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue { .null }
    func readFiltering() async throws -> AdGuardFilteringStatus { AdGuardFilteringStatus() }
    func readUserRules() async throws -> [String] { rules }
    func write(_ write: AdGuardWrite) async throws {
        guard case .setRules(let list) = write else { return }
        sent.append(list)
        if applies { rules = list }
    }
}

@Suite struct DomainRuleWriteTests {
    private func executor(_ transport: RulesTransport) -> AdGuardSettingExecutor {
        var policy = AdGuardSettingVerifyPolicy()
        policy.deadline = .milliseconds(50)
        policy.pollInterval = .milliseconds(10)
        return AdGuardSettingExecutor(transport: transport, gate: MutationGate(), policy: policy)
    }

    @Test func blockSendsTheWholeListWithOneNewRule() async {
        let transport = RulesTransport(rules: ["||other.example^", ""])
        let report = await executor(transport).run(.domainRule(.block, domain: "ads.example.net"), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.rule(applied: true)))
        #expect(report.dispatched)
        #expect(await transport.sent == [["||other.example^", "||ads.example.net^"]])
        #expect(AdGuardWrite.setRules(["a"]).body == .object(["rules": .array([.string("a")])]))
        #expect(AdGuardWrite.setRules([]).path == "control/filtering/set_rules")
    }

    @Test func aRuleAlreadyThereSendsNothing() async {
        let transport = RulesTransport(rules: ["@@||ads.example.net^"])
        let report = await executor(transport).run(.domainRule(.unblock, domain: "ads.example.net"), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.rule(applied: true)))
        #expect(!report.dispatched)
        #expect(await transport.sent.isEmpty)
    }

    @Test func unchangedRulesAreAMismatch() async {
        let transport = RulesTransport(rules: [], applies: false)
        let report = await executor(transport).run(.domainRule(.block, domain: "ads.example.net"), availability: .running)
        #expect(report.outcome == .verifiedMismatch(expected: .rule(applied: true), actual: .rule(applied: false)))
    }

    @Test func onlyWhileRunningAndOnlyForADomain() async {
        let transport = RulesTransport(rules: [])
        let cached = await executor(transport).run(.domainRule(.block, domain: "ads.example.net"), availability: .cached)
        #expect(cached.outcome == .rejected(.preconditionFailed("AdGuard Home is not running.")))
        let odd = await executor(transport).run(.domainRule(.block, domain: "a b"), availability: .running)
        #expect(odd.outcome == .rejected(.invalidIntent("Not a domain name")))
        #expect(await transport.sent.isEmpty)
    }
}

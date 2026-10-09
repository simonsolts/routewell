import Foundation
import Testing
@testable import RoutewellKit
import RoutewellMock

struct AdGuardFiltersRecordingTests {
    @Test func recorderKeepsListDatesAndPublicListURLs() {
        let value: JSONValue = .object(["filters": .array([
            .object(["url": .string("https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"),
                     "last_updated": .string("2026-01-02T03:04:05+01:00")]),
            .object(["url": .string("https://lists.example.com/private.txt"), "last_updated": .string("yesterday")]),
            .object(["url": .string("http://adguardteam.github.io/list.txt")]),
            .object(["url": .string("https://user@raw.githubusercontent.com/list.txt")]),
        ])])
        let lists = RecordedFixtureRedactor.redact(value)["filters"]?.array ?? []
        #expect(lists[0]["url"]?.string == "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt")
        #expect(lists[0]["last_updated"]?.string == "2026-01-02T03:04:05+01:00")
        #expect(lists[1]["url"]?.string == "[REDACTED TEXT]")
        #expect(lists[1]["last_updated"]?.string == "[REDACTED TEXT]")
        #expect(lists[2]["url"]?.string == "[REDACTED TEXT]")
        #expect(lists[3]["url"]?.string == "[REDACTED TEXT]")
    }
}

/// A virtual clock: `sleep` advances time at once, so a verify window ends
/// without real waiting.
private final class FiltersClock: Sendable {
    private nonisolated(unsafe) var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let lock = NSLock()

    func now() -> Date { lock.withLock { current } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { current = current.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) }
    }
}

/// AdGuard Home's lists and rules in memory. `applies` false accepts each
/// write and changes nothing.
private actor FiltersTransport: AdGuardSettingTransport {
    var status: AdGuardFilteringStatus
    var applies = true
    var refreshCount: Int? = 2
    var refreshError: Error?
    var writeError: Error?
    /// Rules another client writes just before the next rules read.
    var externalRules: [String]?
    private(set) var writes: [AdGuardWrite] = []

    init(_ status: AdGuardFilteringStatus) { self.status = status }

    func set(applies: Bool) { self.applies = applies }
    func set(refreshError: Error?) { self.refreshError = refreshError }
    func set(writeError: Error?) { self.writeError = writeError }
    func set(externalRules: [String]?) { self.externalRules = externalRules }

    func readStatus() async throws -> AdGuardStatusResponse { throw AdGuardClientError.malformedResponse }
    func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue { .null }
    func readFiltering() async throws -> AdGuardFilteringStatus { status }
    func readUserRules() async throws -> [String] {
        if let externalRules {
            status.userRules = externalRules
            self.externalRules = nil
        }
        return status.userRules ?? []
    }
    func refreshLists(_ kind: FilterListKind) async throws -> Int? {
        writes.append(.refreshLists(whitelist: kind.isAllowlist))
        if let refreshError { throw refreshError }
        return refreshCount
    }
    func write(_ write: AdGuardWrite) async throws {
        writes.append(write)
        if let writeError { throw writeError }
        guard applies else { return }
        switch write {
        case .addList(let name, let url, let whitelist):
            let list = AdGuardFilterList(id: 99, name: name, url: url, enabled: true, rulesCount: 0)
            if whitelist { status.allowlists.append(list) } else { status.blocklists.append(list) }
        case .setList(let url, let whitelist, _, let enabled):
            if whitelist {
                for index in status.allowlists.indices where status.allowlists[index].url == url { status.allowlists[index].enabled = enabled }
            } else {
                for index in status.blocklists.indices where status.blocklists[index].url == url { status.blocklists[index].enabled = enabled }
            }
        case .removeList(let url, let whitelist):
            if whitelist { status.allowlists.removeAll { $0.url == url } } else { status.blocklists.removeAll { $0.url == url } }
        case .filteringConfig(let enabled, let hours):
            status.enabled = enabled
            status.intervalHours = hours
        case .setRules(let rules):
            status.userRules = rules
        default: break
        }
    }
}

private func fixtureStatus() throws -> AdGuardFilteringStatus {
    let url = try #require(Bundle.module.url(forResource: "control-filtering-status", withExtension: "json",
                                             subdirectory: "Fixtures/adguard/querylog/v1.0.0-b.1"))
    return AdGuardFilteringStatus.parse(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)))
}

private func sample() -> AdGuardFilteringStatus {
    var status = AdGuardFilteringStatus()
    status.enabled = true
    status.intervalHours = 24
    status.blocklists = [
        AdGuardFilterList(id: 1, name: "Example one", url: "https://lists.example.com/one.txt", enabled: true, rulesCount: 1_000),
        AdGuardFilterList(id: 2, name: "Example two", url: "https://lists.example.com/two.txt", enabled: false, rulesCount: 0),
    ]
    status.allowlists = [AdGuardFilterList(id: 3, name: "Example allow", url: "https://lists.example.net/allow.txt", enabled: true, rulesCount: 5)]
    status.userRules = ["||one.example^", ""]
    return status
}

struct AdGuardFiltersParsingTests {
    @Test func fixtureParsesListsRulesAndInterval() throws {
        let status = try fixtureStatus()
        #expect(status.enabled == true)
        #expect(status.intervalHours == 24)
        #expect(status.blocklists.count == 6)
        #expect(status.allowlists.isEmpty)
        #expect(status.userRules == ["||blocked.example^", "@@||allowed.example^", "# comment", ""])
        let first = status.blocklists[0]
        #expect(first.host == "lists.example.com")
        #expect(first.rulesCount == 179_708)
        #expect(first.lastUpdatedDate == Date(timeIntervalSince1970: 1_767_225_600))
        // An off list that was never downloaded has no time.
        #expect(status.blocklists[1].lastUpdated == nil)
        #expect(status.blocklists[1].lastUpdatedDate == nil)
    }

    @Test func allowlistsAndNullRules() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"enabled":false,"interval":72,"filters":null,"user_rules":null,
         "whitelist_filters":[{"id":5,"name":"Allow","url":"https://lists.example.net/a.txt","enabled":true,"rules_count":12,
                               "last_updated":"2026-01-02T03:04:05.123+01:00"}]}
        """#.utf8))
        let status = AdGuardFilteringStatus.parse(json)
        #expect(status.blocklists.isEmpty)
        #expect(status.allowlists.first?.name == "Allow")
        #expect(abs((status.allowlists.first?.lastUpdatedDate?.timeIntervalSince1970 ?? 0) - 1_767_319_445.123) < 0.001)
        #expect(status.userRules == [])
        #expect(status.intervalHours == 72)
        // Missing `user_rules` is unknown, not empty.
        #expect(AdGuardFilteringStatus.parse(.object([:])).userRules == nil)
    }

    @Test func archivedStatusWithoutRulesStillDecodes() throws {
        let old = Data(#"{"enabled":true,"intervalHours":24,"blocklists":[],"allowlists":[]}"#.utf8)
        let status = try JSONDecoder().decode(AdGuardFilteringStatus.self, from: old)
        #expect(status.userRules == nil)
        #expect(status.intervalHours == 24)
    }

    @Test func listURLsAndRulesText() {
        #expect(FilterListURL.validated("  https://lists.example.com/a.txt ") == "https://lists.example.com/a.txt")
        #expect(FilterListURL.validated("http://lists.example.com/a.txt") != nil)
        #expect(FilterListURL.validated("ftp://lists.example.com/a.txt") == nil)
        #expect(FilterListURL.validated("lists.example.com/a.txt") == nil)
        #expect(FilterListURL.validated("https://lists.example.com/a b.txt") == nil)
        #expect(FilterListURL.validated("https:///a.txt") == nil)
        #expect(FilterListURL.matches("HTTPS://Lists.Example.com/a.txt", "https://lists.example.com/a.txt"))
        #expect(!FilterListURL.matches("https://lists.example.com/A.txt", "https://lists.example.com/a.txt"))

        let rules = ["||a.example^", "", "! note", ""]
        #expect(CustomRulesText.rules(CustomRulesText.text(rules)) == rules)
        #expect(CustomRulesText.rules("") == [])
        #expect(CustomRulesText.rules("a\r\nb") == ["a", "b"])
    }

    @Test func intervalValues() {
        #expect(FilterUpdateInterval.hours == [1, 12, 24, 72, 168, 0])
        #expect(FilterUpdateInterval.isValid(0))
        #expect(!FilterUpdateInterval.isValid(6))
    }

    @Test func listWritesHaveTheSchemaBodies() {
        #expect(AdGuardWrite.addList(name: "N", url: "https://l.example/a", whitelist: true).path == "control/filtering/add_url")
        #expect(AdGuardWrite.addList(name: "N", url: "https://l.example/a", whitelist: true).body
            == .object(["name": .string("N"), "url": .string("https://l.example/a"), "whitelist": .bool(true)]))
        #expect(AdGuardWrite.setList(url: "https://l.example/a", whitelist: false, name: "N", enabled: false).body
            == .object(["url": .string("https://l.example/a"), "whitelist": .bool(false),
                        "data": .object(["name": .string("N"), "url": .string("https://l.example/a"), "enabled": .bool(false)])]))
        #expect(AdGuardWrite.setList(url: "u", whitelist: false, name: "N", enabled: true).path == "control/filtering/set_url")
        #expect(AdGuardWrite.removeList(url: "u", whitelist: true).path == "control/filtering/remove_url")
        #expect(AdGuardWrite.removeList(url: "u", whitelist: true).body == .object(["url": .string("u"), "whitelist": .bool(true)]))
        #expect(AdGuardWrite.refreshLists(whitelist: false).path == "control/filtering/refresh")
        #expect(AdGuardWrite.refreshLists(whitelist: false).body == .object(["whitelist": .bool(false)]))
    }

    @Test func liveRefreshReadsTheUpdatedCount() async throws {
        let transport = StubHTTPTransport { request in
            (Data(#"{"updated":3}"#.utf8), StubHTTPTransport.response(200, url: request.url!))
        }
        let client = AdGuardClient(baseURL: URL(string: "http://192.0.2.1:3000")!,
                                   credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }), transport: transport)
        let count = try await LiveAdGuardSettingTransport(adGuard: client).refreshLists(.allowlist)
        #expect(count == 3)
        let sent = await transport.recorded()
        #expect(sent.first?.request.url?.path == "/control/filtering/refresh")
        #expect(sent.first?.body == Data(#"{"whitelist":true}"#.utf8))
    }
}

struct AdGuardListCatalogTests {
    @Test func bundledCopyDecodesInRegistryOrder() {
        let catalog = AdGuardListCatalog.bundled
        #expect(!catalog.lists.isEmpty)
        let sections = catalog.sections
        #expect(sections.first?.group.name == "General")
        #expect(sections.allSatisfy { !$0.lists.isEmpty })
        #expect(catalog.lists.allSatisfy { FilterListURL.validated($0.url) != nil })
    }

    @Test func deprecatedListsAndEmptyGroupsAreLeftOut() throws {
        let catalog = try AdGuardListCatalog.decode(Data(#"""
        {"groups":[{"groupId":4,"groupName":"Security","displayNumber":4},{"groupId":1,"groupName":"General","displayNumber":1},
                   {"groupId":2,"groupName":"Other","displayNumber":2}],
         "filters":[{"filterId":2,"groupId":1,"name":"B","downloadUrl":"https://adguardteam.github.io/b.txt","displayNumber":2,"deprecated":false},
                    {"filterId":1,"groupId":1,"name":"A","downloadUrl":"https://adguardteam.github.io/a.txt","displayNumber":1},
                    {"filterId":3,"groupId":4,"name":"Old","downloadUrl":"https://adguardteam.github.io/c.txt","displayNumber":1,"deprecated":true},
                    {"filterId":4,"groupId":4,"name":"S","downloadUrl":"https://adguardteam.github.io/s.txt","displayNumber":2}]}
        """#.utf8))
        #expect(catalog.sections.map(\.group.name) == ["General", "Security"])
        #expect(catalog.sections[0].lists.map(\.name) == ["A", "B"])
        #expect(catalog.sections[1].lists.map(\.name) == ["S"])
    }

    @Test func addedMatchesTheSameURL() throws {
        let catalog = try AdGuardListCatalog.decode(Data(#"""
        {"groups":[{"groupId":1,"groupName":"General"}],
         "filters":[{"filterId":1,"groupId":1,"name":"A","downloadUrl":"https://adguardteam.github.io/a.txt"},
                    {"filterId":2,"groupId":1,"name":"B","downloadUrl":"https://adguardteam.github.io/b.txt"}]}
        """#.utf8))
        var status = AdGuardFilteringStatus()
        status.blocklists = [AdGuardFilterList(url: "https://AdGuardTeam.github.io/a.txt")]
        // An allowlist with the same URL is not an added blocklist.
        status.allowlists = [AdGuardFilterList(url: "https://adguardteam.github.io/b.txt")]
        #expect(catalog.isAdded(catalog.lists[0], in: status))
        #expect(!catalog.isAdded(catalog.lists[1], in: status))
        #expect(!catalog.isAdded(catalog.lists[0], in: nil))
    }
}

struct AdGuardFiltersWriteTests {
    @Test func turnOffSendsNameAndURLAsRead() async {
        let transport = FiltersTransport(sample())
        let report = await executor(transport).run(.listEnabled(.blocklist, url: "https://lists.example.com/one.txt", enabled: false), availability: .running)
        guard case .verifiedSuccess(.filters(let status)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(status.blocklists[0].enabled == false)
        #expect(await transport.writes == [.setList(url: "https://lists.example.com/one.txt", whitelist: false, name: "Example one", enabled: false)])
    }

    @Test func listAlreadyAtTheValueSendsNothing() async {
        let transport = FiltersTransport(sample())
        let report = await executor(transport).run(.listEnabled(.allowlist, url: "https://lists.example.net/allow.txt", enabled: true), availability: .running)
        guard case .verifiedSuccess = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(!report.dispatched)
        #expect(await transport.writes.isEmpty)
    }

    @Test func missingListIsRejected() async {
        let transport = FiltersTransport(sample())
        let report = await executor(transport).run(.listEnabled(.blocklist, url: "https://lists.example.com/gone.txt", enabled: true), availability: .running)
        guard case .rejected = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(await transport.writes.isEmpty)
    }

    @Test func listThatStaysIsAMismatch() async {
        let transport = FiltersTransport(sample())
        await transport.set(applies: false)
        let report = await executor(transport).run(.listEnabled(.blocklist, url: "https://lists.example.com/two.txt", enabled: true), availability: .running)
        guard case .verifiedMismatch(.filters(let expected), .filters(let actual)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(expected.blocklists[1].enabled == true)
        #expect(actual.blocklists[1].enabled == false)
        #expect(await transport.writes.count == 1)
    }

    @Test func addSendsTheKindAndVerifiesByURL() async {
        let transport = FiltersTransport(sample())
        let report = await executor(transport).run(.addList(.allowlist, name: " Mine ", url: " https://lists.example.org/mine.txt"), availability: .running)
        guard case .verifiedSuccess(.filters(let status)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(status.allowlists.last?.url == "https://lists.example.org/mine.txt")
        #expect(await transport.writes == [.addList(name: "Mine", url: "https://lists.example.org/mine.txt", whitelist: true)])
    }

    @Test func addRejectsBadInputAndDuplicates() async {
        let transport = FiltersTransport(sample())
        let run = executor(transport)
        for intent: AdGuardSettingIntent in [
            .addList(.blocklist, name: "", url: "https://lists.example.org/x.txt"),
            .addList(.blocklist, name: "X", url: "file:///etc/hosts"),
            .addList(.blocklist, name: "X", url: "https://LISTS.example.com/one.txt"),
        ] {
            guard case .rejected = await run.run(intent, availability: .running).outcome else { Issue.record("\(intent)"); continue }
        }
        #expect(await transport.writes.isEmpty)
    }

    @Test func addThatAdGuardRefusesIsAMismatch() async {
        // A 400 (the list could not be downloaded): verify finds no list.
        let transport = FiltersTransport(sample())
        await transport.set(writeError: AdGuardClientError.httpStatus(400))
        let report = await executor(transport).run(.addList(.blocklist, name: "X", url: "https://lists.example.org/x.txt"), availability: .running)
        guard case .verifiedMismatch = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(report.dispatched)
    }

    @Test func removeVerifiesTheListIsGone() async {
        let transport = FiltersTransport(sample())
        let run = executor(transport)
        let report = await run.run(.removeList(.blocklist, url: "https://lists.example.com/two.txt"), availability: .running)
        guard case .verifiedSuccess(.filters(let status)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(status.blocklists.map(\.id) == [1])
        // Already gone: nothing more is sent.
        let again = await run.run(.removeList(.blocklist, url: "https://lists.example.com/two.txt"), availability: .running)
        guard case .verifiedSuccess = again.outcome else { Issue.record("\(again.outcome)"); return }
        #expect(await transport.writes == [.removeList(url: "https://lists.example.com/two.txt", whitelist: false)])
    }

    @Test func intervalSendsFilteringBackAsRead() async {
        var status = sample()
        status.enabled = false
        let transport = FiltersTransport(status)
        let run = executor(transport)
        let report = await run.run(.updateInterval(hours: 168), availability: .running)
        guard case .verifiedSuccess(.filters(let after)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(after.intervalHours == 168)
        #expect(await transport.writes == [.filteringConfig(enabled: false, intervalHours: 168)])
        guard case .rejected = await run.run(.updateInterval(hours: 5), availability: .running).outcome else { Issue.record("5 h"); return }
    }

    @Test func intervalWithoutFilteringStateSendsNothing() async {
        var status = sample()
        status.enabled = nil
        let transport = FiltersTransport(status)
        guard case .rejected = await executor(transport).run(.updateInterval(hours: 1), availability: .running).outcome else { Issue.record("no enabled"); return }
        #expect(await transport.writes.isEmpty)
    }

    @Test func updateNowReportsTheCount() async {
        let transport = FiltersTransport(sample())
        let report = await executor(transport).run(.updateLists(.blocklist), availability: .running)
        guard case .verifiedSuccess(.listsUpdated(let count, let after)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(count == 2)
        #expect(after?.blocklists.count == 2)
        #expect(await transport.writes == [.refreshLists(whitelist: false)])
    }

    @Test func lostUpdateNowIsUnknown() async {
        let transport = FiltersTransport(sample())
        await transport.set(refreshError: AdGuardClientError.transport(.timedOut))
        let report = await executor(transport).run(.updateLists(.allowlist), availability: .running)
        guard case .unknownAfterDispatch = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(report.dispatched)
    }

    @Test func writesNeedAdGuardHomeRunning() async {
        let transport = FiltersTransport(sample())
        for availability: AdGuardAvailability in [.cached, .off, .unknown] {
            guard case .rejected = await executor(transport).run(.updateLists(.blocklist), availability: availability).outcome else {
                Issue.record("\(availability)"); continue
            }
        }
        #expect(await transport.writes.isEmpty)
    }
}

struct AdGuardRulesSaveTests {
    @Test func saveWritesTheWholeList() async {
        let transport = FiltersTransport(sample())
        let rules = ["||one.example^", "||two.example^"]
        let report = await executor(transport).run(.saveRules(rules, loaded: ["||one.example^", ""]), availability: .running)
        guard case .verifiedSuccess(.rules(let saved)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(saved == rules)
        #expect(await transport.writes == [.setRules(rules)])
    }

    @Test func rulesChangedSinceLoadStopBeforeSending() async {
        let transport = FiltersTransport(sample())
        await transport.set(externalRules: ["||elsewhere.example^"])
        let report = await executor(transport).run(.saveRules(["||mine.example^"], loaded: ["||one.example^", ""]), availability: .running)
        guard case .conflictingExternalEdit(.rules(let actual)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(actual == ["||elsewhere.example^"])
        #expect(!report.dispatched)
        #expect(await transport.writes.isEmpty)
    }

    @Test func sameRulesSendNothing() async {
        let transport = FiltersTransport(sample())
        let report = await executor(transport).run(.saveRules(["||one.example^", ""], loaded: ["||x.example^"]), availability: .running)
        guard case .verifiedSuccess = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(await transport.writes.isEmpty)
    }

    @Test func rulesThatStayAreAMismatch() async {
        let transport = FiltersTransport(sample())
        await transport.set(applies: false)
        let report = await executor(transport).run(.saveRules(["||new.example^"], loaded: ["||one.example^", ""]), availability: .running)
        guard case .verifiedMismatch(.rules(["||new.example^"]), .rules(["||one.example^", ""])) = report.outcome else {
            Issue.record("\(report.outcome)"); return
        }
    }

    @Test func lostSaveIsUnknownWhenRulesCannotBeRead() async {
        let transport = FailingRulesTransport()
        let report = await executor(transport).run(.saveRules(["a"], loaded: ["b"]), availability: .running)
        guard case .rejected = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(!report.dispatched)
    }
}

/// Rules that never read.
private struct FailingRulesTransport: AdGuardSettingTransport {
    func readStatus() async throws -> AdGuardStatusResponse { throw AdGuardClientError.malformedResponse }
    func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue { .null }
    func readFiltering() async throws -> AdGuardFilteringStatus { throw AdGuardClientError.transport(.timedOut) }
    func readUserRules() async throws -> [String] { throw AdGuardClientError.transport(.timedOut) }
    func write(_ write: AdGuardWrite) async throws {}
}

private func executor(_ transport: some AdGuardSettingTransport) -> AdGuardSettingExecutor {
    let clock = FiltersClock()
    return AdGuardSettingExecutor(transport: transport, gate: MutationGate(), clock: { clock.now() }, sleep: { try await clock.sleep($0) })
}

struct MockFiltersScenarioTests {
    private func mock(_ scenario: MockAdGuardScenario) async -> MockAdGuardTransport {
        let mock = MockAdGuardTransport()
        await mock.setScenario(scenario)
        return mock
    }

    @Test func populatedHasBothKindsAndRules() async throws {
        let status = try await mock(.running).readFiltering()
        #expect(status.blocklists.count == 4)
        #expect(status.allowlists.count == 1)
        #expect(status.intervalHours == 24)
        #expect(status.userRules?.isEmpty == false)
        #expect(status.blocklists.allSatisfy { $0.url?.contains("example") == true })
    }

    @Test func addedListDownloadsThenHasRules() async throws {
        let mock = await mock(.running)
        let report = await executor(mock).run(.addList(.blocklist, name: "Mine", url: "https://lists.example.org/mine.txt"), availability: .running)
        guard case .verifiedSuccess(.filters(let status)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        let added = try #require(status.list(.blocklist, url: "https://lists.example.org/mine.txt"))
        #expect(added.rulesCount == 0)
        #expect(added.lastUpdated == nil)
        let later = await mock.currentFiltering(now: Date().addingTimeInterval(60))
        #expect((later.list(.blocklist, url: "https://lists.example.org/mine.txt")?.rulesCount ?? 0) > 0)
    }

    @Test func addFailsIsAMismatch() async {
        let mock = await mock(.addListFails)
        let report = await executor(mock).run(.addList(.blocklist, name: "Mine", url: "https://lists.example.org/mine.txt"), availability: .running)
        guard case .verifiedMismatch = report.outcome else { Issue.record("\(report.outcome)"); return }
    }

    @Test func refreshPartialUpdatesOneList() async {
        let mock = await mock(.refreshPartial)
        let report = await executor(mock).run(.updateLists(.blocklist), availability: .running)
        guard case .verifiedSuccess(.listsUpdated(let count, _)) = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(count == 1)
        let full = await self.mock(.running)
        guard case .verifiedSuccess(.listsUpdated(3, _)) = await executor(full).run(.updateLists(.blocklist), availability: .running).outcome else {
            Issue.record("full refresh"); return
        }
    }

    @Test func rulesConflictStopsSave() async throws {
        let mock = await mock(.rulesConflict)
        let loaded = try #require(try await mock.readFiltering().userRules)
        let report = await executor(mock).run(.saveRules(loaded + ["||mine.example^"], loaded: loaded), availability: .running)
        guard case .conflictingExternalEdit = report.outcome else { Issue.record("\(report.outcome)"); return }
        #expect(await mock.writes.isEmpty)
    }
}

struct FiltersRefreshPlanTests {
    @Test func filtersTabReadsTheLists() {
        let areas = ScreenRefreshPlan.resolve(destination: "adGuard", segment: "Filters", defaultInterval: .seconds(30)).map(\.area)
        #expect(areas.contains(.adGuardOverview))
        let dns = ScreenRefreshPlan.resolve(destination: "adGuard", segment: "DNS", defaultInterval: .seconds(30)).map(\.area)
        #expect(!dns.contains(.adGuardOverview))
    }
}

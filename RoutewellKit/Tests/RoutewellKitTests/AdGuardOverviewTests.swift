import Foundation
import Testing
@testable import RoutewellKit

/// AdGuard Home › Overview's models, reads, and saved copy.
@Suite struct AdGuardOverviewTests {
    private static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private static let hourly = json("""
    {"time_units":"hours","num_dns_queries":3000,"num_blocked_filtering":450,"num_replaced_safebrowsing":2,
     "num_replaced_parental":1,"num_replaced_safesearch":0,"avg_processing_time":0.00113,
     "dns_queries":[\((0..<24).map { _ in "125" }.joined(separator: ","))],
     "blocked_filtering":[\((0..<24).map { _ in "18.0" }.joined(separator: ","))],
     "top_queried_domains":[{"example.com":900},{"cdn.example.net":300}],
     "top_blocked_domains":[{"ads.example.com":200},{"bad":"x"},{"two":1,"keys":2}],
     "top_clients":[{"192.0.2.10":1800},{"192.0.2.11":1200}],
     "top_upstreams_responses":[{"https://dns.example.net/dns-query":3000}]}
    """)

    // MARK: Stats

    @Test func statsParseHours() {
        let stats = AdGuardStats.parse(Self.hourly)
        #expect(stats.timeUnits == .hours)
        #expect(stats.queries == 3000)
        #expect(stats.blockedFiltering == 450)
        #expect(stats.queriesSeries.count == 24)
        #expect(stats.blockedSeries.allSatisfy { $0 == 18 })
        #expect(stats.averageProcessingSeconds == 0.00113)
        #expect(stats.topQueried == [.init(name: "example.com", count: 900), .init(name: "cdn.example.net", count: 300)])
        // A row that is not one name with one number is dropped, not guessed.
        #expect(stats.topBlocked == [.init(name: "ads.example.com", count: 200)])
        #expect(stats.topClients.map(\.name) == ["192.0.2.10", "192.0.2.11"])
        #expect(stats.matches(.day))
        #expect(!stats.matches(.week))
        #expect(stats.blockedPercent == 15)
    }

    @Test func statsParseDays() {
        let stats = AdGuardStats.parse(Self.json("""
        {"time_units":"days","dns_queries":[1,2,3,4,5,6,7],"blocked_filtering":[0,1,0,1,0,1,0],"num_dns_queries":28}
        """))
        #expect(stats.timeUnits == .days)
        #expect(stats.matches(.week))
        #expect(!stats.matches(.month))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let starts = try! #require(stats.bucketStarts(now: now, calendar: calendar))
        #expect(starts.count == 7)
        #expect(starts.last == calendar.startOfDay(for: now))
        #expect(starts.first == calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)))
    }

    @Test func missingStatsFieldsStayUnknown() {
        let stats = AdGuardStats.parse(Self.json(#"{"dns_queries":null}"#))
        #expect(stats.timeUnits == nil)
        #expect(stats.queries == nil)
        #expect(stats.threatsBlocked == nil)
        #expect(stats.blockedPercent == nil)
        #expect(stats.queriesSeries.isEmpty)
        #expect(stats.topClients.isEmpty)
        #expect(stats.bucketStarts(now: Date()) == nil)
    }

    /// "Threats blocked": Safe Browsing plus Parental.
    @Test func threatsAreSafeBrowsingPlusParental() {
        var stats = AdGuardStats.parse(Self.hourly)
        #expect(stats.threatsBlocked == 3)
        stats.replacedParental = nil
        #expect(stats.threatsBlocked == nil)
    }

    @Test func deviceCountSaysAtLeastWhenTheListIsFull() {
        var stats = AdGuardStats()
        stats.topClients = (0..<19).map { .init(name: "192.0.2.\($0)", count: 1) }
        #expect(stats.deviceCount == (19, false))
        stats.topClients = (0..<100).map { .init(name: "192.0.2.\($0)", count: 1) }
        #expect(stats.deviceCount == (100, true))
    }

    // MARK: Ranges and retention

    @Test func rangesLongerThanTheRetentionAreNotOffered() {
        let day = 86_400_000
        #expect(AdGuardStatsRange.day.isAvailable(retentionMilliseconds: nil))
        #expect(!AdGuardStatsRange.week.isAvailable(retentionMilliseconds: nil))
        #expect(!AdGuardStatsRange.week.isAvailable(retentionMilliseconds: day))
        #expect(AdGuardStatsRange.week.isAvailable(retentionMilliseconds: 7 * day))
        #expect(!AdGuardStatsRange.month.isAvailable(retentionMilliseconds: 7 * day))
        #expect(AdGuardStatsRange.month.isAvailable(retentionMilliseconds: 90 * day))
    }

    @Test func recentIsCutToTheRetentionInWholeHours() {
        #expect(AdGuardStatsRange.day.recentMilliseconds(retentionMilliseconds: nil) == 86_400_000)
        #expect(AdGuardStatsRange.day.recentMilliseconds(retentionMilliseconds: 90 * 86_400_000) == 86_400_000)
        #expect(AdGuardStatsRange.day.recentMilliseconds(retentionMilliseconds: 6 * 3_600_000 + 5) == 6 * 3_600_000)
        #expect(AdGuardStatsRange.day.recentMilliseconds(retentionMilliseconds: 1_800_000) == nil)
        #expect(AdGuardStats.expectedShape(recentMilliseconds: 6 * 3_600_000) == (.hours, 6))
    }

    @Test func statsConfigParses() {
        let config = AdGuardStatsConfig.parse(Self.json(#"{"enabled":true,"interval":604800000,"ignored":["a.example"],"ignored_enabled":false}"#))
        #expect(config.enabled == true)
        #expect(config.intervalMilliseconds == 604_800_000)
        #expect(config.ignored == ["a.example"])
        #expect(config.ignoredEnabled == false)
        #expect(AdGuardStatsConfig.parse(Self.json("{}")) == AdGuardStatsConfig())
    }

    // MARK: Blocklists

    @Test func filteringStatusCountsTheListsThatAreOn() throws {
        let status = AdGuardFilteringStatus.parse(Self.json("""
        {"enabled":true,"interval":24,"whitelist_filters":null,"filters":[
         {"id":1,"name":"Example 1","url":"https://lists.example.com/1.txt","enabled":true,"rules_count":1000},
         {"id":2,"name":"Example 2","url":"https://lists.example.com/2.txt","enabled":false,"rules_count":0},
         {"id":3,"name":"Example 3","url":"https://lists.example.com/3.txt","enabled":true,"rules_count":500}]}
        """))
        #expect(status.blocklists.count == 3)
        #expect(status.allowlists.isEmpty)
        #expect(status.enabledBlocklists.map(\.id) == [1, 3])
        #expect(status.activeRuleCount == 1500)
        var unknown = status
        unknown.blocklists[0].rulesCount = nil
        #expect(unknown.activeRuleCount == nil)
    }

    // MARK: Pause menu

    @Test func pauseEndsForEachMenuItem() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 11, minute: 25)))
        #expect(ProtectionPauseChoice.thirtySeconds.end(from: now, calendar: calendar) == now.addingTimeInterval(30))
        #expect(ProtectionPauseChoice.oneMinute.end(from: now, calendar: calendar) == now.addingTimeInterval(60))
        #expect(ProtectionPauseChoice.tenMinutes.end(from: now, calendar: calendar) == now.addingTimeInterval(600))
        #expect(ProtectionPauseChoice.oneHour.end(from: now, calendar: calendar) == now.addingTimeInterval(3600))
        let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 8)))
        #expect(ProtectionPauseChoice.untilTomorrow.end(from: now, calendar: calendar) == tomorrow)
        // Just after midnight, "tomorrow" is still the next calendar day.
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 0, minute: 30)))
        let next = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 8)))
        #expect(ProtectionPauseChoice.untilTomorrow.end(from: early, calendar: calendar) == next)
        // Every item is a valid write, in whole milliseconds.
        for choice in ProtectionPauseChoice.allCases {
            for start in [now, early] {
                let intent = choice.intent(from: start, calendar: calendar)
                #expect(intent.validate() == nil)
                let expected = Int((choice.end(from: start, calendar: calendar).timeIntervalSince(start) * 1000).rounded())
                #expect(intent.wire == (false, expected))
            }
        }
        #expect(ProtectionPauseChoice.thirtySeconds.intent(from: now, calendar: calendar).wire.durationMilliseconds == 30_000)
    }

    /// The day the clocks go back: "until tomorrow" is still 08:00 local.
    @Test func untilTomorrowFollowsLocalTimeAcrossAClockChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 22)))
        let end = ProtectionPauseChoice.untilTomorrow.end(from: evening, calendar: calendar)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: end) == DateComponents(day: 25, hour: 8, minute: 0))
        #expect(end.timeIntervalSince(evening) == 11 * 3600)
    }

    // MARK: Device names

    @Test func topDeviceNamesComeFromTheRouterThenTheRegistry() throws {
        let phone = try #require(MACAddress("02:00:00:00:00:01"))
        let tv = try #require(MACAddress("02:00:00:00:00:02"))
        let clients = [Client(mac: phone, ip: "192.0.2.10", hostname: "phone-host")]
        let records: [MACAddress: DeviceRecord] = [
            phone: DeviceRecord(mac: phone, userName: "Kitchen phone", firstSeen: .distantPast),
            tv: DeviceRecord(mac: tv, firstSeen: .distantPast, lastSeen: Date(), lastIP: "192.0.2.20", lastRouterName: "Example TV"),
        ]
        #expect(ClientNaming.automatic(ip: "192.0.2.10", clients: clients, records: records) == "Kitchen phone")
        #expect(ClientNaming.automatic(ip: "192.0.2.20", clients: clients, records: records) == "Example TV")
        #expect(ClientNaming.automatic(ip: "192.0.2.30", clients: clients, records: records) == nil)
    }

    // MARK: Saved copy

    private static func reading(_ range: AdGuardStatsRange, at date: Date, honoured: Bool = true,
                                options: ProtectionOptions = ProtectionOptions(safeBrowsing: true, parental: false, safeSearch: nil)) -> AdGuardOverviewReading {
        AdGuardOverviewReading(range: range, stats: .success(AdGuardStats.parse(hourly)), rangeHonoured: honoured,
                               statsConfig: .success(AdGuardStatsConfig(enabled: true, intervalMilliseconds: 86_400_000)),
                               protection: .success(options), filtering: .failure(.timeout), observedAt: date)
    }

    @Test func overviewSectionsSaveEachRangeAndThrottle() async {
        let store = AdGuardArchiveStore(root: nil)
        let profile = UUID()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        await store.save(Self.reading(.day, at: start), for: profile)
        await store.save(Self.reading(.week, at: start.addingTimeInterval(5)), for: profile)
        var archive = await store.archive(for: profile)
        #expect(archive?.stats(for: .day)?.savedAt == start)
        #expect(archive?.stats(for: .week)?.savedAt == start.addingTimeInterval(5))
        #expect(archive?.statsConfig?.savedAt == start)
        #expect(archive?.filtering == nil)
        // Within 60 s nothing is replaced, unless forced (Stop's final sync).
        await store.save(Self.reading(.day, at: start.addingTimeInterval(30)), for: profile)
        archive = await store.archive(for: profile)
        #expect(archive?.stats(for: .day)?.savedAt == start)
        await store.save(Self.reading(.day, at: start.addingTimeInterval(31)), for: profile, force: true)
        archive = await store.archive(for: profile)
        #expect(archive?.stats(for: .day)?.savedAt == start.addingTimeInterval(31))
        #expect(archive?.savedAt == start.addingTimeInterval(31))
    }

    @Test func aSwitchWhoseReadFailedKeepsItsSavedValue() async {
        let store = AdGuardArchiveStore(root: nil)
        let profile = UUID()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        await store.save(Self.reading(.day, at: start, options: ProtectionOptions(safeBrowsing: true, parental: true, safeSearch: true)), for: profile)
        await store.save(Self.reading(.day, at: start.addingTimeInterval(61), options: ProtectionOptions(safeBrowsing: false)), for: profile)
        let saved = await store.archive(for: profile)?.protection?.value
        #expect(saved == ProtectionOptions(safeBrowsing: false, parental: true, safeSearch: true))
    }

    /// Review: a plain read may cover the whole retention, so it is never
    /// saved, not even as 24 hours.
    @Test func statsThatIgnoredTheRangeAreNotSaved() async {
        let store = AdGuardArchiveStore(root: nil)
        let profile = UUID()
        await store.save(Self.reading(.week, at: Date(), honoured: false), for: profile)
        await store.save(Self.reading(.day, at: Date(), honoured: false), for: profile, force: true)
        let archive = await store.archive(for: profile)
        #expect(archive?.stats == nil)
        // The other sections of the same read are still saved.
        #expect(archive?.statsConfig != nil)
    }

    /// Day buckets may come one more or one less; a whole retention does not.
    @Test func shapeAllowsOneBucketMoreOrLess() {
        var stats = AdGuardStats()
        stats.timeUnits = .days
        for (count, week, month) in [(6, true, false), (7, true, false), (8, true, false), (29, false, true), (31, false, true), (90, false, false)] {
            stats.queriesSeries = Array(repeating: 1, count: count)
            #expect(stats.matches(.week) == week)
            #expect(stats.matches(.month) == month)
        }
        stats.timeUnits = .hours
        stats.queriesSeries = Array(repeating: 1, count: 24)
        #expect(stats.matches(.day))
        #expect(!stats.matches(.week))
    }

    /// An older file has no Overview sections and still loads.
    @Test func olderArchiveStillDecodes() throws {
        let old = #"{"status":{"savedAt":0,"value":{"dnsAddresses":[],"version":"0.107.73"}},"config":{"savedAt":0,"value":{"enabled":true}}}"#
        let archive = try JSONDecoder().decode(AdGuardArchive.self, from: Data(old.utf8))
        #expect(archive.status?.value.version == "0.107.73")
        #expect(archive.stats == nil)
        #expect(!archive.isEmpty)
    }

    // MARK: Recorded on the router (AdGuard Home v1.0.0-b.1)

    private static func fixture(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/adguard/overview"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    /// 24 hourly buckets, totals, and the top lists.
    @Test func recordedStatsParse() throws {
        let stats = AdGuardStats.parse(try Self.fixture("stats-24h"))
        #expect(stats.timeUnits == .hours)
        #expect(stats.matches(.day))
        #expect(stats.queriesSeries.count == 24)
        #expect(stats.blockedSeries.count == 24)
        #expect(stats.queries == 38_687)
        #expect(stats.blockedFiltering == 6_003)
        #expect(stats.threatsBlocked == 0)
        #expect(stats.averageProcessingSeconds == 0.000946)
        #expect(stats.queriesSeries.reduce(0, +) == stats.queries)
        // Domain lists stop at 100. One row's count was replaced by the
        // recorder (its name looked like a secret), so it is dropped.
        #expect(stats.topBlocked.count == 100)
        #expect(stats.topQueried.count == 99)
        #expect(stats.topClients.count == 15)
        #expect(stats.deviceCount == (15, false))
        #expect(stats.topClients.allSatisfy { $0.name.hasPrefix("198.51.10") })
        #expect(stats.topUpstreams.count == 5)
    }

    /// The router keeps 1 day of stats, so only 24 hours is offered.
    @Test func recordedRetentionOffersOneRange() throws {
        let config = AdGuardStatsConfig.parse(try Self.fixture("stats-config"))
        #expect(config.enabled == true)
        #expect(config.intervalMilliseconds == 86_400_000)
        #expect(AdGuardStatsRange.allCases.filter { $0.isAvailable(retentionMilliseconds: config.intervalMilliseconds) } == [.day])
        #expect(AdGuardStatsRange.day.recentMilliseconds(retentionMilliseconds: config.intervalMilliseconds) == 86_400_000)
    }

    @Test func recordedSwitchesAndBlocklists() throws {
        #expect(try Self.fixture("safebrowsing-status")["enabled"] == .bool(false))
        #expect(try Self.fixture("parental-status") == .object(["enabled": .bool(false)]))
        let safeSearch = try Self.fixture("safesearch-status")
        #expect(safeSearch["enabled"] == .bool(false))
        #expect(safeSearch.object?.count == 8)
        let filtering = AdGuardFilteringStatus.parse(try Self.fixture("filtering-status"))
        #expect(filtering.enabled == true)
        #expect(filtering.intervalHours == 24)
        #expect(filtering.blocklists.count == 6)
        #expect(filtering.allowlists.isEmpty)
        #expect(filtering.enabledBlocklists.count == 3)
        #expect(filtering.activeRuleCount == 179_479 + 158_505 + 240_364)
    }

    /// The whole Overview read against the recorded router: `recent` for
    /// 24 hours is honoured; 7 days is not read with a 1-day retention.
    @Test func recordedRouterOverview() async throws {
        let bodies: [String: JSONValue] = [
            "/control/stats": try Self.fixture("stats-24h"),
            "/control/stats/config": try Self.fixture("stats-config"),
            "/control/safebrowsing/status": try Self.fixture("safebrowsing-status"),
            "/control/parental/status": try Self.fixture("parental-status"),
            "/control/safesearch/status": try Self.fixture("safesearch-status"),
            "/control/filtering/status": try Self.fixture("filtering-status"),
        ]
        let (service, transport) = Self.service { request in
            let url = request.url!
            return (try JSONEncoder().encode(bodies[url.path] ?? .object([:])), StubHTTPTransport.response(200, url: url))
        }
        let day = try await service.overview(range: .day)
        #expect(day.rangeHonoured)
        #expect(try day.stats.get().queries == 38_687)
        #expect(try day.protection.get() == ProtectionOptions(safeBrowsing: false, parental: false, safeSearch: false))
        let week = try await service.overview(range: .week)
        #expect(week.stats == .failure(.unavailable))
        let statsQueries = await transport.recorded().compactMap(\.request.url).filter { $0.path == "/control/stats" }.map(\.query)
        #expect(statsQueries == ["recent=86400000"])
        let status = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: try #require(
            Bundle.module.url(forResource: "status-1.0.0-b.1", withExtension: "json", subdirectory: "Fixtures/adguard/overview"))))
        #expect(status["version"]?.string == "v1.0.0-b.1")
    }

    // MARK: Live reads

    private static func service(_ handler: @escaping StubHTTPTransport.Handler) -> (LiveAdGuardOverviewService, StubHTTPTransport) {
        let transport = StubHTTPTransport(handler: handler)
        let client = AdGuardClient(baseURL: URL(string: "http://192.0.2.1:3000/")!,
                                   credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }), transport: transport)
        return (LiveAdGuardOverviewService(adGuard: client), transport)
    }

    private static func body(_ path: String, query: String?) -> JSONValue? {
        switch path {
        case "/control/stats/config": json(#"{"enabled":true,"interval":604800000,"ignored":[]}"#)
        case "/control/safebrowsing/status": json(#"{"enabled":true}"#)
        case "/control/parental/status": json(#"{"enabled":false,"sensitivity":13}"#)
        case "/control/safesearch/status": json(#"{"enabled":false,"google":true}"#)
        case "/control/filtering/status": json(#"{"enabled":true,"filters":[]}"#)
        default: nil
        }
    }

    @Test func overviewSendsRecentAndChecksTheReplyShape() async throws {
        let (service, transport) = Self.service { request in
            let url = request.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
            let value: JSONValue = url.path == "/control/stats"
                ? Self.json(#"{"time_units":"days","dns_queries":[1,2,3,4,5,6,7],"blocked_filtering":[0,0,0,0,0,0,0]}"#)
                : Self.body(url.path, query: query) ?? .object([:])
            return (try JSONEncoder().encode(value), StubHTTPTransport.response(200, url: url))
        }
        let reading = try await service.overview(range: .week)
        #expect(reading.rangeHonoured)
        #expect(try reading.stats.get().matches(.week))
        #expect(try reading.protection.get() == ProtectionOptions(safeBrowsing: true, parental: false, safeSearch: false))
        let statsURLs = await transport.recorded().compactMap(\.request.url).filter { $0.path == "/control/stats" }
        #expect(statsURLs.map { $0.query } == ["recent=604800000"])
    }

    /// An AdGuard Home without `recent` answers 400: the plain stats show,
    /// marked as not honouring the range.
    @Test func overviewFallsBackToThePlainReadOn400() async throws {
        let (service, transport) = Self.service { request in
            let url = request.url!
            if url.path == "/control/stats" {
                if url.query != nil { return (Data(), StubHTTPTransport.response(400, url: url)) }
                return (try JSONEncoder().encode(Self.hourly), StubHTTPTransport.response(200, url: url))
            }
            return (try JSONEncoder().encode(Self.body(url.path, query: nil) ?? .object([:])), StubHTTPTransport.response(200, url: url))
        }
        let reading = try await service.overview(range: .week)
        #expect(!reading.rangeHonoured)
        #expect(try reading.stats.get().matches(.day))
        let statsQueries = await transport.recorded().compactMap(\.request.url).filter { $0.path == "/control/stats" }.map(\.query)
        #expect(statsQueries == ["recent=604800000", nil])
    }

    /// Review: a `recent` read that fails for another reason is a failed
    /// read; it does not mark the ranges as unsupported.
    @Test func overviewKeepsTheRangesWhenTheRecentReadTimesOut() async throws {
        let (service, transport) = Self.service { request in
            let url = request.url!
            if url.path == "/control/stats" { throw TransportError.timedOut }
            return (try JSONEncoder().encode(Self.body(url.path, query: nil) ?? .object([:])), StubHTTPTransport.response(200, url: url))
        }
        let reading = try await service.overview(range: .week)
        #expect(reading.rangeHonoured)
        #expect(reading.stats == .failure(.timeout))
        let statsReads = await transport.recorded().filter { $0.request.url?.path == "/control/stats" }
        #expect(statsReads.count == 1)
    }

    /// Without a known retention a 400 may mean "longer than the retention";
    /// it stays a failed read.
    @Test func a400WithAnUnknownRetentionIsAFailedRead() async throws {
        let (service, transport) = Self.service { request in
            let url = request.url!
            if url.path == "/control/stats" || url.path == "/control/stats/config" { return (Data(), StubHTTPTransport.response(400, url: url)) }
            return (try JSONEncoder().encode(Self.body(url.path, query: nil) ?? .object([:])), StubHTTPTransport.response(200, url: url))
        }
        let reading = try await service.overview(range: .day)
        #expect(reading.rangeHonoured)
        #expect(reading.stats == .failure(.malformedResponse))
        let statsReads = await transport.recorded().filter { $0.request.url?.path == "/control/stats" }
        #expect(statsReads.count == 1)
    }

    @Test func overviewWithAnIgnoredRecentIsNotHonoured() async throws {
        let (service, _) = Self.service { request in
            let url = request.url!
            let value = url.path == "/control/stats" ? Self.hourly : Self.body(url.path, query: nil) ?? .object([:])
            return (try JSONEncoder().encode(value), StubHTTPTransport.response(200, url: url))
        }
        let reading = try await service.overview(range: .week)
        #expect(!reading.rangeHonoured)
    }

    /// One failed status call leaves only that switch Unknown.
    @Test func overviewKeepsTheSwitchesThatAnswered() async throws {
        let (service, _) = Self.service { request in
            let url = request.url!
            if url.path == "/control/parental/status" { return (Data(), StubHTTPTransport.response(500, url: url)) }
            let value = url.path == "/control/stats" ? Self.hourly : Self.body(url.path, query: nil) ?? .object([:])
            return (try JSONEncoder().encode(value), StubHTTPTransport.response(200, url: url))
        }
        let reading = try await service.overview(range: .day)
        #expect(try reading.protection.get() == ProtectionOptions(safeBrowsing: true, parental: nil, safeSearch: false))
    }
}

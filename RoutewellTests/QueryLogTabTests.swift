import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

/// AdGuard Home › Query Log in the app.

@MainActor
private func eventually(timeout: Duration = .seconds(10), _ predicate: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Condition did not settle")
}

@MainActor
private func runningEnvironment() async -> AppEnvironment {
    let environment = AppEnvironment(model: AppModel(mode: .mock), backend: MockRouterBackend())
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    await eventually {
        await environment.refresh.waitForRefresh()
        return environment.adGuard.availability == .running
    }
    return environment
}

/// Hosts the AdGuard Home screen on the Query Log tab, so its view tasks run.
@MainActor
private func host(_ environment: AppEnvironment) -> NSWindow {
    environment.model.selection = .adGuard
    environment.model.subpages[.adGuard] = AdGuardTab.queryLog.rawValue
    let view = AdGuardScreen().environment(environment.model).environment(environment)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(x: 0, y: 0, width: 1100, height: 700)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // Swift owns the window; `close()` must not release it a second time.
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    return window
}

private let lists: AdGuardFilteringStatus = {
    var status = AdGuardFilteringStatus()
    status.blocklists = [AdGuardFilterList(id: 7, name: "Example list", url: "https://lists.example.com/a.txt", enabled: true, rulesCount: 10)]
    return status
}()

private func entry(_ reason: String, filterID: Int? = nil, cached: Bool? = false, upstream: String? = "192.0.2.53:53",
                   type: String = "A", proto: String? = "", answers: [String] = ["192.0.2.80"], service: String? = nil) -> QueryLogEntry {
    QueryLogEntry(time: .now, client: "192.0.2.10", domain: "ads.example.net", type: type, reason: reason, upstream: upstream,
                  elapsedMilliseconds: 0.254, cached: cached, clientProtocol: proto, rule: "||ads.example.net^",
                  filterID: filterID, serviceName: service, responseCode: "NOERROR", answers: answers)
}

// MARK: - Inspector and table texts

@Test func inspectorVariants() {
    let blocked = entry("FilteredBlackList", filterID: 7, upstream: nil, answers: ["0.0.0.0"])
    #expect(QueryLogPresentation.pillText(blocked.result) == "Blocked")
    #expect(QueryLogPresentation.reasonRow(blocked, filtering: lists) == ("Blocked by", "Example list"))
    #expect(QueryLogPresentation.reasonCell(blocked, filtering: lists) == "Example list")
    #expect(QueryLogPresentation.upstreamRow(blocked) == "—")
    #expect(QueryLogPresentation.answerRow(blocked) == "0.0.0.0")
    #expect(QueryLogPresentation.reasonRow(entry("FilteredBlackList", filterID: 99), filtering: lists).value == "Unknown list")

    let service = entry("FilteredBlockedService", filterID: -2, service: "Example video")
    #expect(QueryLogPresentation.reasonRow(service, filtering: lists) == ("Blocked by", "Blocked service: Example video"))

    let processed = entry("NotFilteredNotFound")
    #expect(QueryLogPresentation.pillText(processed.result) == "Allowed")
    #expect(QueryLogPresentation.statusText(processed.result) == "Processed")
    #expect(QueryLogPresentation.reasonRow(processed, filtering: lists) == ("Reason", "Not filtered"))
    #expect(QueryLogPresentation.reasonCell(processed, filtering: lists) == "192.0.2.53:53")
    #expect(QueryLogPresentation.upstreamRow(processed) == "192.0.2.53:53")

    let cached = entry("NotFilteredNotFound", cached: true, upstream: nil, type: "HTTPS")
    #expect(QueryLogPresentation.reasonRow(cached, filtering: lists).value == "Not filtered · answered from cache")
    #expect(QueryLogPresentation.reasonCell(cached, filtering: lists) == "From cache")
    #expect(QueryLogPresentation.upstreamRow(cached) == "Cache")
    #expect(QueryLogPresentation.answerRow(cached) == "HTTPS record")

    let allowed = entry("NotFilteredWhiteList", filterID: 0)
    #expect(QueryLogPresentation.pillText(allowed.result) == "Allowed")
    #expect(QueryLogPresentation.reasonRow(allowed, filtering: lists) == ("Reason", "Custom rules"))
    let rewritten = entry("Rewrite")
    #expect(QueryLogPresentation.reasonCell(rewritten, filtering: lists) == "DNS rewrite")

    #expect(QueryLogPresentation.deviceRow(processed, name: "Example laptop") == "Example laptop · 192.0.2.10")
    #expect(QueryLogPresentation.deviceRow(processed, name: nil) == "192.0.2.10")
    #expect(QueryLogPresentation.deviceCell(processed, name: nil) == "192.0.2.10")
    #expect(QueryLogPresentation.typeRow(processed) == "A · Plain DNS")
    #expect(QueryLogPresentation.typeRow(entry("NotFilteredNotFound", proto: "doh")) == "A · DNS-over-HTTPS")
    #expect(QueryLogPresentation.typeRow(entry("NotFilteredNotFound", proto: nil)) == "A")
    #expect(QueryLogPresentation.response(0.254) == "0.25 ms")
    #expect(QueryLogPresentation.response(12.4) == "12 ms")
    #expect(QueryLogPresentation.response(nil) == "—")
    #expect(QueryLogPresentation.response(.infinity) == "—")
    #expect(QueryLogPresentation.response(.nan) == "—")
    #expect(QueryLogPresentation.response(1e300).hasSuffix(" ms"))
}

@Test func footerSaysLoadedNotTotal() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
    let locale = Locale(identifier: "en_GB")
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 20)))
    let oldest = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 21, minute: 14)))
    #expect(QueryLogPresentation.footer(count: 1_000, oldest: oldest, filtered: false, now: now, calendar: calendar, locale: locale)
            == "1,000 queries loaded · since 6 Oct 21:14")
    #expect(QueryLogPresentation.footer(count: 1, oldest: nil, filtered: true, now: now, calendar: calendar, locale: locale)
            == "1 matching query loaded")
}

@Test func unavailableStateSaysTheLogIsReadLive() {
    #expect(QueryLogPresentation.unavailableMessage(.cached).contains("read from AdGuard Home while it runs"))
    #expect(QueryLogPresentation.unavailableMessage(.unreachable(.notConfigured)).contains("does not answer"))
}

@MainActor @Test func domainRuleResultNamesTheRule() {
    let intent = AdGuardSettingIntent.domainRule(.unblock, domain: "ads.example.net")
    #expect(QueryLogInspectorContent.resultText(intent, .verifiedSuccess(.rule(applied: true))) == "Added @@||ads.example.net^ to the custom rules.")
    #expect(QueryLogInspectorContent.resultText(intent, .verifiedMismatch(expected: .rule(applied: true), actual: .rule(applied: false)))
            == "AdGuard Home did not add the rule to unblock ads.example.net.")
}

// MARK: - Controller against the mock

@MainActor @Test func readsPageOneThenLoadMoreThenStops() async {
    let environment = await runningEnvironment()
    let controller = environment.queryLog
    await controller.loadFirstPage()
    #expect(controller.phase == .loaded)
    #expect(controller.entries.count == 500)
    #expect(controller.isLive)
    await controller.loadMore()
    #expect(controller.entries.count == 1_000)
    #expect(Set(controller.entries.map(\.id)).count == 1_000)
    controller.stop()
    #expect(controller.entries.isEmpty)
    #expect(controller.phase == .idle)
}

@MainActor @Test func searchAndStatusAreNotLive() async {
    let environment = await runningEnvironment()
    let controller = environment.queryLog
    controller.setStatus(.blocked)
    await controller.loadFirstPage()
    #expect(!controller.entries.isEmpty)
    #expect(controller.entries.allSatisfy { $0.result == .blocked })
    #expect(!controller.isLive)
    controller.search(for: "192.168.8.150")
    #expect(controller.filter == .init(search: "192.168.8.150", status: .blocked))
    await controller.loadFirstPage()
    #expect(controller.entries.allSatisfy { $0.client == "192.168.8.150" && $0.result == .blocked })
    controller.clear()
    #expect(controller.filter == .init())
    #expect(controller.searchText.isEmpty)
}

@MainActor @Test func readFailureAndEmptyLog() async throws {
    let environment = await runningEnvironment()
    let backend = try #require(environment.model.session.lease?.backend as? MockRouterBackend)
    await backend.mockQueryLog.setEmpty(true)
    await environment.queryLog.loadFirstPage()
    #expect(environment.queryLog.phase == .loaded)
    #expect(environment.queryLog.entries.isEmpty)
    await backend.mockQueryLog.setBehavior(.failing)
    await environment.queryLog.loadFirstPage()
    #expect(environment.queryLog.phase == .failed(.network))
}

@MainActor @Test func oldRetryCannotReplaceANewerSearch() async throws {
    let environment = await runningEnvironment()
    let backend = try #require(environment.model.session.lease?.backend as? MockRouterBackend)
    let controller = environment.queryLog
    // Try Again starts a slow read of the whole log.
    await backend.mockQueryLog.setBehavior(.slow)
    let retry = Task { await controller.loadFirstPage() }
    await eventually { controller.phase == .loading }
    await backend.mockQueryLog.setBehavior(.supported)
    // A new search loads first.
    controller.search(for: "192.168.8.150")
    await controller.loadFirstPage()
    #expect(controller.phase == .loaded)
    await retry.value
    #expect(!controller.entries.isEmpty)
    #expect(controller.entries.allSatisfy { $0.client == "192.168.8.150" })
    #expect(controller.browser.search == "192.168.8.150")
}

@MainActor @Test func handOffsOpenTheTabSearching() async {
    let environment = await runningEnvironment()
    let window = host(environment)
    defer { window.close() }
    // Overview › Top blocked sends a domain.
    environment.model.showQueryLog(AdGuardQueryLogFilter(search: "ads.example.net"))
    await eventually { environment.queryLog.filter.search == "ads.example.net" }
    #expect(environment.model.adGuardQueryLogFilter == nil)
    #expect(environment.queryLog.searchText == "ads.example.net")
    await eventually { environment.queryLog.phase == .loaded }
    #expect(environment.queryLog.entries.allSatisfy { $0.domain?.contains("ads.example.net") == true })
    // Clients › Show DNS Log sends an IP; the status goes back to all.
    environment.queryLog.setStatus(.blocked)
    environment.model.showDNSLog(client: "192.168.8.20")
    await eventually { environment.queryLog.filter == .init(search: "192.168.8.20", status: .all) }
}

@MainActor @Test func liveAddsRowsWhileUnfiltered() async {
    let environment = await runningEnvironment()
    let controller = environment.queryLog
    controller.liveInterval = .milliseconds(50)
    let task = Task { await controller.follow() }
    defer { task.cancel() }
    await eventually { controller.liveReads >= 2 }
    #expect(controller.phase == .loaded)
    controller.isAtTop = false
    let reads = controller.liveReads
    try? await Task.sleep(for: .milliseconds(300))
    #expect(controller.liveReads == reads)
}

@MainActor @Test func blockDomainAddsTheRuleInMock() async throws {
    let environment = await runningEnvironment()
    let backend = try #require(environment.model.session.lease?.backend as? MockRouterBackend)
    environment.adGuard.runSetting(.domainRule(.block, domain: "ads.example.net"))
    await eventually { environment.adGuard.settingInFlight == nil && environment.adGuard.lastSettingReport != nil }
    #expect(environment.adGuard.lastSettingReport?.outcome == .verifiedSuccess(.rule(applied: true)))
    #expect(await backend.mockAdGuard.userRules.contains("||ads.example.net^"))
}

@MainActor @Test func cachedShowsNoLog() async {
    let environment = await runningEnvironment()
    environment.setMockAdGuardScenario(.cached)
    await eventually {
        await environment.refresh.waitForRefresh()
        return environment.adGuard.availability == .cached
    }
    let window = host(environment)
    defer { window.close() }
    try? await Task.sleep(for: .milliseconds(200))
    // The Query Log view never ran, so nothing was read.
    #expect(environment.queryLog.phase == .idle)
    #expect(environment.queryLog.entries.isEmpty)
}

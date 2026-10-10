import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

@MainActor
private func eventually(timeout: Duration = .seconds(10), _ predicate: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Condition did not settle")
}

/// A mock environment in `scenario`, on the DNS tab with its read done.
@MainActor
private func environment(_ scenario: MockAdGuardScenario = .running) async -> AppEnvironment {
    let backend = MockRouterBackend()
    let environment = AppEnvironment(model: AppModel(mode: .mock), backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.setMockAdGuardScenario(scenario)
    await eventually { await backend.mockAdGuard.scenario == scenario }
    let wanted: AdGuardAvailability = scenario == .cached ? .cached : .running
    await eventually {
        await environment.refresh.waitForRefresh()
        return environment.adGuard.availability == wanted
    }
    environment.model.selection = .adGuard
    environment.model.subpages[.adGuard] = AdGuardTab.dns.rawValue
    await read(environment)
    return environment
}

@MainActor
private func read(_ environment: AppEnvironment) async {
    guard let lease = environment.model.session.lease else { return }
    try? await environment.adGuard.refreshOverview(using: lease)
}

@MainActor
private func host<V: View>(_ environment: AppEnvironment, _ view: V, size: CGSize = CGSize(width: 1000, height: 900)) -> NSWindow {
    let hosting = NSHostingView(rootView: view.environment(environment.model).environment(environment))
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    return window
}

// MARK: - Texts

@Test func dnsTexts() {
    #expect(DNSPresentation.duration(nil) == "Not overridden")
    #expect(DNSPresentation.duration(0) == "Not overridden")
    #expect(DNSPresentation.duration(86_400) == "1 day")
    #expect(DNSPresentation.duration(172_800) == "2 days")
    #expect(DNSPresentation.duration(3_600) == "1 h")
    #expect(DNSPresentation.duration(600) == "10 min")
    #expect(DNSPresentation.duration(90) == "90 s")
    #expect(DNSPresentation.rateLimit(0) == "Off")
    #expect(DNSPresentation.rateLimit(20) == "20 req/s")
    #expect(DNSPresentation.cacheSizeChoices(current: 4_194_304).map(DNSPresentation.cacheSizeTitle) == ["1 MB", "4 MB", "16 MB", "32 MB"])
    #expect(DNSPresentation.cacheSizeChoices(current: 524_288).map(DNSPresentation.cacheSizeTitle) == ["512 KB", "1 MB", "4 MB", "16 MB", "32 MB"])
    #expect(DNSPresentation.addresses(["# note", "192.0.2.10", " 198.51.100.10 "]) == "192.0.2.10, 198.51.100.10")
    #expect(DNSPresentation.addresses([]) == "None")
    #expect(DNSPresentation.addresses(nil) == "Unknown")
    #expect(DNSPresentation.lines("192.0.2.10\r\n\n# note\n 203.0.113.53 ") == ["192.0.2.10", "# note", "203.0.113.53"])
    #expect(DNSPresentation.time(18.4) == "18 ms")
    #expect(DNSPresentation.time(740) == "0.7 s")
    #expect(DNSPresentation.modeDescription(.parallel) == "Asks every server at once and uses the first answer")
    #expect(DNSPresentation.blockingDescription(.nxdomain) == "Answers as if the domain doesn’t exist")
}

@Test func responseColumnShowsStatsThenTheTest() {
    let fast = UpstreamUsage(sharePercent: 60, averageMilliseconds: 18)
    let slow = UpstreamUsage(sharePercent: 30, averageMilliseconds: 740)
    let address = "tls://dns.example.org"
    #expect(DNSPresentation.response(fast, test: .idle, address: address).text == "18 ms")
    #expect(DNSPresentation.response(slow, test: .idle, address: address).style == .slow)
    #expect(DNSPresentation.response(slow, test: .testing, address: address).text == "…")
    let done = AdGuardDNSController.TestState.done(UpstreamTestResult(statuses: [address: .ok, "192.0.2.53": .failed("i/o timeout")]))
    #expect(DNSPresentation.response(fast, test: done, address: address).text == "✓ 18 ms")
    #expect(DNSPresentation.response(slow, test: done, address: address).text == "Slow · 0.7 s")
    #expect(DNSPresentation.response(UpstreamUsage(), test: done, address: address).text == "✓ OK")
    let failed = DNSPresentation.response(fast, test: done, address: "192.0.2.53")
    #expect(failed.text == "✗ Failed")
    #expect(failed.help == "i/o timeout")
    #expect(DNSPresentation.response(UpstreamUsage(), test: .idle, address: address).text == "Unknown")
}

@Test func slowNoteCoversOneAndMany() {
    #expect(DNSPresentation.slowNote([], mode: .loadBalance) == nil)
    #expect(DNSPresentation.slowNote([("tls://dns.example.org", 740)], mode: .loadBalance)
        == "tls://dns.example.org averages 0.7 s. With load balancing it’s rarely picked, but removing it may speed up first lookups.")
    #expect(DNSPresentation.slowNote([("tls://dns.example.org", 740)], mode: .parallel)
        == "tls://dns.example.org averages 0.7 s. Removing it may speed up first lookups.")
    #expect(DNSPresentation.slowNote([("a", 900), ("b", 800)], mode: .loadBalance)
        == "2 servers average over 0.5 s. Removing them may speed up first lookups.")
}

// MARK: - Tab

@MainActor @Test func runningTabShowsSettingsAndJoinsStats() async {
    let environment = await environment()
    let dns = environment.dns
    #expect(dns.canEdit)
    #expect(dns.upstreamLines.count == 5)
    let usage = dns.stats?.usage(of: "https://dns.example.net/dns-query")
    #expect(abs((usage?.sharePercent ?? 0) - 60) < 0.5)
    #expect(!(usage?.isSlow ?? true))
    let window = host(environment, AdGuardScreen())
    window.close()
}

@MainActor @Test func slowUpstreamScenarioMarksOneServer() async {
    let environment = await environment(.slowUpstream)
    let usage = environment.dns.stats?.usage(of: "tls://dns.example.org")
    #expect(usage?.isSlow == true)
}

/// Edits stage, survive a refresh and a tab change, and the bar shows only
/// with changes; editing back to the read value clears them.
@MainActor @Test func dirtyBarStagesUntilApplyOrRevert() async {
    let environment = await environment()
    let dns = environment.dns
    #expect(!dns.hasChanges)
    dns.edit { $0.rateLimit = 30 }
    #expect(dns.hasChanges)
    #expect(dns.changes == ["ratelimit": .number(30)])
    await read(environment)
    environment.model.subpages[.adGuard] = AdGuardTab.overview.rawValue
    environment.model.subpages[.adGuard] = AdGuardTab.dns.rawValue
    #expect(dns.settings?.rateLimit == 30)
    let window = host(environment, AdGuardScreen())
    window.close()
    dns.edit { $0.rateLimit = 20 }
    #expect(!dns.hasChanges)
    dns.edit { $0.cacheSize = 16_777_216 }
    dns.revert()
    #expect(!dns.hasChanges)
    #expect(dns.settings?.cacheSize == 4_194_304)
    #expect(await environment.mockAdGuardWrites().isEmpty)
}

@MainActor @Test func applySendsOnlyTheChanges() async {
    let environment = await environment()
    let dns = environment.dns
    dns.addUpstream("quic://dns.example.com")
    dns.selection = 2
    dns.removeSelectedUpstream()
    dns.edit { $0.cacheSize = 16_777_216 }
    dns.apply()
    await eventually { environment.adGuard.settingInFlight == nil && !dns.hasChanges }
    let writes = await environment.mockAdGuardWrites()
    let expected: [String: JSONValue] = [
        "cache_size": .number(16_777_216),
        "upstream_dns": .array(["https://dns.example.net/dns-query", "tls://dns.example.org", "# Local names",
                                "[/home.arpa/]192.0.2.1", "quic://dns.example.com"].map(JSONValue.string)),
    ]
    #expect(writes == [.dnsConfig(expected)])
    #expect(dns.settings?.cacheSize == 16_777_216)
}

@MainActor @Test func editsDuringApplyStayAgainstTheNewValues() async {
    let environment = await environment()
    let dns = environment.dns
    dns.edit { $0.cacheSize = 16_777_216 }
    dns.apply()
    dns.edit { $0.rateLimit = 7 }
    dns.edit { $0.cacheSize = 4_194_304 }
    await eventually { environment.adGuard.settingInFlight == nil && environment.adGuard.lastSettingReport != nil }
    #expect(await environment.mockAdGuardWrites() == [.dnsConfig(["cache_size": .number(16_777_216)])])
    #expect(dns.changes == ["cache_size": .number(4_194_304), "ratelimit": .number(7)])
}

@MainActor @Test func applyMismatchShowsAdGuardHomeValues() async {
    let environment = await environment(.dnsApplyMismatch)
    let dns = environment.dns
    dns.edit { $0.cacheSize = 1_048_576 }
    dns.apply()
    await eventually { environment.adGuard.settingInFlight == nil && environment.adGuard.lastSettingReport != nil }
    guard case .verifiedMismatch? = environment.adGuard.lastSettingReport?.outcome else {
        Issue.record("\(String(describing: environment.adGuard.lastSettingReport?.outcome))")
        return
    }
    #expect(!dns.hasChanges)
    #expect(dns.settings?.cacheSize == 4_194_304)
    let text = AdGuardPresentation.settingOutcomeText(.dns(changes: [:]), environment.adGuard.lastSettingReport!.outcome)
    #expect(text == "AdGuard Home did not take every DNS change. The tab shows its settings now.")
}

@MainActor @Test func customIPFieldsBlockApplyUntilValid() async {
    let environment = await environment()
    let dns = environment.dns
    dns.edit { $0.blockingMode = .customIP }
    #expect(!dns.canApply)
    #expect(dns.settings?.problem == "Enter a custom IPv4 or IPv6 address.")
    dns.edit { $0.blockingIPv4 = "192.0.2" }
    #expect(!dns.canApply)
    dns.edit { $0.blockingIPv4 = "192.0.2.99" }
    #expect(dns.canApply)
    let window = host(environment, AdGuardScreen())
    window.close()
}

@MainActor @Test func serverSheetsStageTheirLists() async {
    let environment = await environment()
    let dns = environment.dns
    for list in [DNSPresentation.ServerList.fallback, .bootstrap] {
        let window = host(environment, DNSServerListSheet(list: list), size: CGSize(width: 420, height: 320))
        window.close()
    }
    let window = host(environment, DNSAddUpstreamSheet(), size: CGSize(width: 380, height: 200))
    window.close()
    dns.edit { $0.fallback = DNSPresentation.lines("# backup\n203.0.113.54") }
    #expect(dns.changes == ["fallback_dns": .array([.string("# backup"), .string("203.0.113.54")])])
    #expect(DNSPresentation.addresses(dns.settings?.fallback) == "203.0.113.54")
}

@MainActor @Test func testUpstreamsReportsTheBadServer() async {
    let environment = await environment(.upstreamTestFails)
    let dns = environment.dns
    dns.runTest()
    #expect(dns.test == .testing)
    await eventually { dns.test != .testing }
    guard case .done(let result) = dns.test else { Issue.record("\(dns.test)"); return }
    #expect(result.status(of: "https://dns.example.net/dns-query") == .ok)
    guard case .failed? = result.status(of: "tls://dns.example.org") else { Issue.record("no failure"); return }
}

@MainActor @Test func changingAServerListClearsTheTestResult() async {
    let environment = await environment(.upstreamTestFails)
    let dns = environment.dns
    dns.runTest()
    await eventually { dns.test != .testing }
    guard case .done = dns.test else { Issue.record("\(dns.test)"); return }
    dns.edit { $0.bootstrap = ["192.0.2.10"] }
    #expect(dns.test == .idle)
    dns.revert()
    guard case .done = dns.test else { Issue.record("\(dns.test)"); return }

    dns.runTest()
    dns.edit { $0.fallback = ["203.0.113.54"] }
    #expect(dns.test == .idle)
    dns.revert()
    await eventually { if case .done = dns.test { true } else { false } }
}

@MainActor @Test func clearCacheRunsAtOnce() async {
    let environment = await environment()
    let dns = environment.dns
    dns.clearCache()
    await eventually { dns.cacheCleared }
    #expect(await environment.mockAdGuardWrites() == [.clearDNSCache])
    #expect(!dns.hasChanges)
}

@MainActor @Test func routerSwitchDropsStagedEdits() async {
    let environment = await environment()
    environment.dns.edit { $0.rateLimit = 5 }
    environment.dns.reset()
    #expect(!environment.dns.hasChanges)
}

// MARK: - Cached

@MainActor @Test func cachedShowsAdGuardHomeValuesNotStagedEdits() async {
    let environment = await environment()
    let dns = environment.dns
    dns.edit { $0.rateLimit = 5 }
    environment.setMockAdGuardScenario(.cached)
    await eventually {
        await environment.refresh.waitForRefresh()
        return environment.adGuard.availability == .cached
    }
    #expect(dns.settings?.rateLimit != 5)
    #expect(dns.settings == dns.server)
    #expect(dns.staged?.rateLimit == 5)
}

@MainActor @Test func cachedShowsTheCopyAndDisablesEveryControl() async {
    let environment = await environment(.cached)
    let dns = environment.dns
    #expect(environment.adGuard.availability == .cached)
    #expect(dns.settings?.upstreams?.isEmpty == false)
    #expect(!dns.canEdit)
    dns.edit { $0.rateLimit = 1 }
    #expect(!dns.hasChanges)
    dns.runTest()
    #expect(dns.test == .idle)
    dns.clearCache()
    try? await Task.sleep(for: .milliseconds(300))
    #expect(await environment.mockAdGuardWrites().isEmpty)
    let window = host(environment, AdGuardScreen())
    window.close()
}

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

@MainActor
private func mockEnvironment(_ scenario: MockAdGuardScenario) async -> AppEnvironment {
    let environment = AppEnvironment(model: AppModel(mode: .mock), backend: MockRouterBackend())
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.setMockAdGuardScenario(scenario)
    await settle(environment, scenario)
    return environment
}

/// Waits until the screen shows the scenario's state.
@MainActor
private func settle(_ environment: AppEnvironment, _ scenario: MockAdGuardScenario) async {
    let adGuard = environment.adGuard
    await eventually {
        await environment.refresh.waitForRefresh()
        switch scenario {
        case .off, .turnOnFails: return adGuard.availability == .off
        case .running, .runningWithoutDNS, .switchFails:
            return adGuard.availability == .running && adGuard.handlesDNS == (scenario != .runningWithoutDNS)
        case .paused:
            guard adGuard.availability == .running, case .paused? = adGuard.protection else { return false }
            return true
        case .cached: return adGuard.availability == .cached
        case .unreachable: return adGuard.availability == .unreachable(.notAnswering(.authentication))
        }
    }
}

/// The Overview tab's reads, as the refresh loop runs them while the tab
/// is visible (tests have no visible window).
@MainActor
private func loadOverview(_ environment: AppEnvironment) async {
    guard let lease = environment.model.session.lease else { Issue.record("no lease"); return }
    try? await environment.adGuard.refreshOverview(using: lease)
}

// MARK: - Sidebar and hand-off

@Test func sidebarHasAdGuardHomeAndNoDNSActivity() {
    let titles = SidebarDestination.allCases.map(\.title)
    #expect(titles.contains("AdGuard Home"))
    #expect(!titles.contains("DNS Activity"))
    #expect(!titles.contains("Protection"))
    #expect(SidebarDestination.adGuard.group == .monitoring)
    #expect(SidebarDestination.adGuard.segments == ["Overview", "Query Log", "Filters", "DNS", "Instance"])
}

@MainActor @Test func showDNSLogOpensQueryLogForThatClient() {
    let model = AppModel(mode: .mock)
    model.showDNSLog(client: "192.0.2.20")
    #expect(model.selection == .adGuard)
    #expect(model.subpages[.adGuard] == "Query Log")
    #expect(model.adGuardQueryLogFilter == AdGuardQueryLogFilter(client: "192.0.2.20"))
}

// MARK: - Presentation

@Test func stripNamesTheStateAndTheSavedDate() throws {
    let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let archive = AdGuardArchive(status: .init(savedAt: savedAt, value: AdGuardStatusResponse(version: "0.107.0")))
    let cached = try #require(AdGuardPresentation.strip(.cached, archive: archive))
    #expect(cached.title == "AdGuard Home is off")
    #expect(cached.message == "Showing a read-only copy saved \(AdGuardPresentation.savedDate(savedAt)).")
    #expect(cached.action == .turnOn)
    let refused = try #require(AdGuardPresentation.strip(.unreachable(.notAnswering(.authentication)), archive: archive))
    #expect(refused.title == "AdGuard Home refused the sign-in")
    #expect(refused.action == .openRouterSettings)
    #expect(AdGuardPresentation.strip(.unreachable(.routerUnreadable(.timeout)), archive: archive)?.title
            == "The router did not say whether AdGuard Home is on")
    #expect(AdGuardPresentation.strip(.running, archive: archive) == nil)
    #expect(AdGuardPresentation.strip(.cached, archive: nil) == nil)
    // Never "off" for a problem.
    for problem in [AdGuardProblem.notConfigured, .notAnswering(.timeout), .routerUnreadable(.network)] {
        #expect(!AdGuardPresentation.problemTitle(problem).contains("off"))
    }
}

@Test func sidebarDotAndInstanceLine() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(AdGuardPresentation.sidebarTone(.running, protection: .enabled) == .healthy)
    #expect(AdGuardPresentation.sidebarTone(.running, protection: .paused(until: now)) == .degraded)
    #expect(AdGuardPresentation.sidebarTone(.cached, protection: nil) == .unknown)
    #expect(AdGuardPresentation.sidebarTone(.unreachable(.notConfigured), protection: nil) == .error)
    #expect(AdGuardPresentation.sidebarTone(.off, protection: nil) == nil)

    var status = AdGuardStatusResponse(version: "0.107.0")
    status.startTime = now.addingTimeInterval(-3 * 24 * 60 * 60 - 600)
    #expect(AdGuardPresentation.instanceLine(.running, status: status, sshConfigured: false, now: now)
            == "Running for 3 days · Version 0.107.0 · Memory needs SSH")
    #expect(AdGuardPresentation.instanceLine(.running, status: status, sshConfigured: true, now: now) == "Running for 3 days · Version 0.107.0")
    #expect(AdGuardPresentation.instanceLine(.cached, status: status, sshConfigured: false, now: now) == "Stopped · Version 0.107.0")
}

@Test func outcomeTextNamesWhatHappened() {
    let notOn = AdGuardServiceState(enabled: false, handlesDNS: true)
    let silent = AdGuardServiceState(enabled: true, handlesDNS: true, answering: false)
    let expected = AdGuardServiceState(enabled: true, handlesDNS: true, answering: true)
    #expect(AdGuardPresentation.outcomeText(.turnOn(handlesDNS: true), .verifiedSuccess(expected)) == nil)
    #expect(AdGuardPresentation.outcomeText(.turnOn(handlesDNS: true), .verifiedMismatch(expected: expected, actual: notOn))
            == "The router did not turn AdGuard Home on.")
    #expect(AdGuardPresentation.outcomeText(.turnOn(handlesDNS: true), .verifiedMismatch(expected: expected, actual: silent))
            == "AdGuard Home is on, but it did not answer in time. Refresh to check.")
    #expect(AdGuardPresentation.outcomeText(.restart, .verifiedMismatch(expected: expected, actual: notOn))
            == "AdGuard Home is off after the restart. Turn it on to start it again.")
    #expect(AdGuardPresentation.outcomeText(.turnOff, .unknownAfterDispatch)
            == "The router did not answer in time. The change may have applied. Refresh to check.")
    #expect(AdGuardPresentation.outcomeText(.setHandlesDNS(false), .rejected(.preconditionFailed("AdGuard Home is not running.")))
            == "AdGuard Home is not running.")
}

// MARK: - States and lifecycle on the mock router

@MainActor @Test func emptyStateTurnOnRunsAndOpensOverview() async {
    let environment = await mockEnvironment(.off)
    let adGuard = environment.adGuard
    #expect(!adGuard.showsTabs)
    environment.model.subpages[.adGuard] = AdGuardTab.instance.rawValue

    adGuard.run(.turnOn(handlesDNS: false))
    #expect(adGuard.inFlight == .turnOn(handlesDNS: false))
    await eventually { adGuard.inFlight == nil }
    #expect(adGuard.lastReport?.outcome == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: false, answering: true)))
    await settle(environment, .runningWithoutDNS)
    #expect(adGuard.showsTabs)
    #expect(environment.model.subpages[.adGuard] == "Overview")
}

@MainActor @Test func stopSavesTheCopyAndShowsItReadOnlyThenTurnOnFromTheStrip() async {
    let environment = await mockEnvironment(.running)
    let adGuard = environment.adGuard
    #expect(adGuard.archive?.status?.value.version == MockAdGuardTransport.version)

    adGuard.run(.turnOff)
    await eventually { adGuard.inFlight == nil }
    #expect(adGuard.lastReport?.outcome == .verifiedSuccess(AdGuardServiceState(enabled: false, handlesDNS: true)))
    await settle(environment, .cached)
    #expect(adGuard.showsTabs)
    #expect(adGuard.availability.isReadOnly)
    #expect(AdGuardPresentation.strip(adGuard.availability, archive: adGuard.archive)?.action == .turnOn)
    // The saved Handle DNS setting is what Turn On sends.
    #expect(adGuard.handlesDNS == true)

    adGuard.run(.turnOn(handlesDNS: adGuard.handlesDNS ?? true))
    await eventually { adGuard.inFlight == nil }
    await settle(environment, .running)
}

@MainActor @Test func cachedCopyDisablesWritesExceptTurnOn() async {
    let environment = await mockEnvironment(.cached)
    let adGuard = environment.adGuard
    #expect(adGuard.archive != nil)
    #expect(adGuard.availability.isReadOnly)
    for intent in [AdGuardServiceIntent.restart, .turnOff, .setHandlesDNS(false)] {
        #expect(intent.validate(adGuard.availability) != nil)
    }
    #expect(AdGuardServiceIntent.turnOn(handlesDNS: true).validate(adGuard.availability) == nil)

    // Even past the disabled controls, the executor refuses and sends nothing.
    adGuard.run(.restart)
    await eventually { adGuard.inFlight == nil }
    #expect(adGuard.lastReport?.outcome == .rejected(.preconditionFailed("AdGuard Home is not running.")))
    #expect(adGuard.lastReport?.dispatched == false)
}

@MainActor @Test func notAnsweringShowsTheCopyAndNeverOff() async {
    let environment = await mockEnvironment(.unreachable)
    let adGuard = environment.adGuard
    #expect(adGuard.showsTabs)
    #expect(AdGuardPresentation.strip(adGuard.availability, archive: adGuard.archive)?.title == "AdGuard Home refused the sign-in")

    await adGuard.replaceArchive(nil)
    #expect(!adGuard.showsTabs)
    #expect(adGuard.availability == .unreachable(.notAnswering(.authentication)))
}

@MainActor @Test func refusedTurnOnStaysOffAndSaysSo() async {
    let environment = await mockEnvironment(.turnOnFails)
    let adGuard = environment.adGuard
    adGuard.run(.turnOn(handlesDNS: true))
    await eventually { adGuard.inFlight == nil }
    let outcome = adGuard.lastReport?.outcome
    // The mock refuses as GL.iNet documents it: `err_code` 1.
    #expect(outcome.flatMap { AdGuardPresentation.outcomeText(.turnOn(handlesDNS: true), $0) } == AdGuardServiceExecutor.otherDNSMessage)
    await settle(environment, .off)
}

@MainActor @Test func handleDNSAndRestartOnTheMockRouter() async {
    let environment = await mockEnvironment(.running)
    let adGuard = environment.adGuard
    adGuard.run(.setHandlesDNS(false))
    await eventually { adGuard.inFlight == nil }
    await settle(environment, .runningWithoutDNS)

    adGuard.run(.restart)
    await eventually { adGuard.inFlight == nil }
    #expect(adGuard.lastReport?.outcome == .verifiedSuccess(AdGuardServiceState(enabled: true, handlesDNS: false, answering: true)))
}

@MainActor @Test func removingTheRouterRemovesItsCopy() async {
    let environment = await mockEnvironment(.cached)
    guard let profile = environment.persistence.selectedProfile?.id else { Issue.record("no mock profile"); return }
    #expect(environment.adGuard.archive != nil)
    await environment.adGuard.removeArchive(profile: profile)
    #expect(environment.adGuard.archive == nil)
}

// MARK: - Overview (chunk 17)

@Test func bannerHasTheFourDesignVariants() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 11, minute: 25)))
    var stats = AdGuardStats()
    stats.queries = 100
    stats.topClients = (1...14).map { .init(name: "192.0.2.\($0)", count: 1) }
    var filtering = AdGuardFilteringStatus()
    filtering.blocklists = [AdGuardFilterList(enabled: true, rulesCount: 581_421), AdGuardFilterList(enabled: false, rulesCount: 0)]

    let on = AdGuardPresentation.banner(.running, protection: .enabled, handlesDNS: true, stats: stats, filtering: filtering,
                                        savedAt: nil, now: now, calendar: calendar)
    #expect(on == .init(tone: .on, title: "Protection is on", message: "Filtering DNS for 14 devices · 581,421 rules active", actions: [.pause]))

    let paused = AdGuardPresentation.banner(.running, protection: .paused(until: now.addingTimeInterval(60)), handlesDNS: true,
                                            stats: stats, filtering: filtering, savedAt: nil, now: now, calendar: calendar)
    #expect(paused.tone == .paused)
    #expect(paused.title == "Protection paused until \(AdGuardPresentation.pauseEnd(now.addingTimeInterval(60), now: now, calendar: calendar))")
    #expect(!paused.title.contains("tomorrow"))
    #expect(paused.actions == [.resume])

    let noDNS = AdGuardPresentation.banner(.running, protection: .enabled, handlesDNS: false, stats: stats, filtering: filtering,
                                           savedAt: nil, now: now, calendar: calendar)
    #expect(noDNS.title == "Running, but not filtering your network")
    #expect(noDNS.actions == [.handleDNS, .pause])

    let savedAt = now.addingTimeInterval(-3600)
    let cached = AdGuardPresentation.banner(.cached, protection: .enabled, handlesDNS: true, stats: stats, filtering: filtering,
                                            savedAt: savedAt, now: now, calendar: calendar)
    #expect(cached == .init(tone: .readOnly, title: "AdGuard Home is off",
                            message: "These numbers are from \(AdGuardPresentation.savedDate(savedAt)), when it was last running.", actions: []))

    // Not in the design: protection turned off, and not answering.
    let off = AdGuardPresentation.banner(.running, protection: .disabled, handlesDNS: true, stats: stats, filtering: filtering,
                                         savedAt: nil, now: now, calendar: calendar)
    #expect(off.title == "Protection is off")
    #expect(off.actions == [.turnOnProtection])
    let silent = AdGuardPresentation.banner(.unreachable(.notAnswering(.timeout)), protection: nil, handlesDNS: nil, stats: nil,
                                            filtering: nil, savedAt: savedAt, now: now, calendar: calendar)
    #expect(silent.title == "AdGuard Home is not answering")
    #expect(silent.actions.isEmpty)
}

@Test func bannerDeviceCountAndPauseEndText() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 23, minute: 50)))
    let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 8)))
    #expect(AdGuardPresentation.pauseEnd(tomorrow, now: now, calendar: calendar).hasPrefix("tomorrow, "))
    #expect(!AdGuardPresentation.pauseEnd(now.addingTimeInterval(300), now: now, calendar: calendar).contains("tomorrow"))
    #expect(AdGuardPresentation.devices((100, true)) == "at least 100 devices")
    #expect(AdGuardPresentation.devices((1, false)) == "1 device")
    #expect(AdGuardPresentation.onMessage(stats: nil, filtering: nil) == "Filtering DNS requests.")
}

@Test func metricsAndTopRows() {
    var stats = AdGuardStats()
    stats.queries = 38_733
    stats.blockedFiltering = 5_527
    stats.replacedSafeBrowsing = 2
    stats.replacedParental = 1
    stats.averageProcessingSeconds = 0.00113
    stats.topBlocked = [.init(name: "ads.example.com", count: 2_500), .init(name: "metrics.example.net", count: 683)]
    stats.topClients = [.init(name: "192.0.2.10", count: 9_600), .init(name: "192.0.2.99", count: 7_500)]
    let metrics = AdGuardPresentation.metrics(stats)
    #expect(metrics.map(\.value) == ["38,733", "5,527", "3", "1.1 ms"])
    #expect(metrics[1].detail == "14.3%")
    #expect(AdGuardPresentation.metrics(nil).allSatisfy { $0.value == nil })

    let blocked = AdGuardPresentation.domainList(title: "Top blocked", entries: stats.topBlocked, total: stats.blockedFiltering)
    #expect(blocked.hint == "5,527 total")
    #expect(blocked.rows.map(\.detail) == ["45.2%", "12.4%"])
    #expect(blocked.rows.first?.fraction == 1)

    let devices = AdGuardPresentation.deviceList(stats) { $0 == "192.0.2.10" ? "Example phone" : nil }
    #expect(devices.hint == "2 active")
    #expect(devices.rows.map(\.name) == ["Example phone", "192.0.2.99"])
    #expect(devices.rows.map(\.detail) == ["192.0.2.10", "Unnamed"])
    // Compact and in the person's locale: "9.6K" in en_US, "9.6k" in en_GB.
    #expect(devices.rows.first?.count == 9_600.formatted(.number.notation(.compactName)))
}

/// "Filter requests" off: the banner does not claim rules are active.
@MainActor @Test func filterRequestsOffInTheMock() async {
    let environment = await mockEnvironment(.running)
    let adGuard = environment.adGuard
    await loadOverview(environment)
    #expect(adGuard.filtering?.enabled == true)
    adGuard.runSetting(.filtering(enabled: false))
    #expect(adGuard.settingInFlight == .filtering(enabled: false))
    await eventually { adGuard.settingInFlight == nil }
    #expect(adGuard.lastSettingReport?.outcome == .verifiedSuccess(.feature(false)))
    // The verified value shows at once, before the next read.
    #expect(adGuard.filtering?.enabled == false)
    await loadOverview(environment)
    #expect(adGuard.filtering?.enabled == false)
    #expect(AdGuardPresentation.onMessage(stats: nil, filtering: adGuard.filtering) == "Filter requests is off")
    #expect(AdGuardPresentation.settingOutcomeText(.filtering(enabled: true), .verifiedMismatch(expected: .feature(true), actual: .feature(false)))
            == "AdGuard Home did not change “Filter requests”.")
}

@Test func settingOutcomeTextNamesWhatHappened() {
    #expect(AdGuardPresentation.settingOutcomeText(.protection(.enable), .verifiedSuccess(.protection(.enabled))) == nil)
    #expect(AdGuardPresentation.settingOutcomeText(.feature(.parental, enabled: true), .verifiedMismatch(expected: .feature(true), actual: .feature(false)))
            == "AdGuard Home did not change “Block adult content”.")
    #expect(AdGuardPresentation.settingOutcomeText(.protection(.pause(.seconds(60))), .verifiedMismatch(expected: .protection(.enabled), actual: .protection(.enabled)))
            == "AdGuard Home did not pause protection.")
    #expect(AdGuardPresentation.settingOutcomeText(.protection(.enable), .rejected(.preconditionFailed("AdGuard Home is not running.")))
            == "AdGuard Home is not running.")
    #expect(AdGuardPresentation.blocklistSummary(nil) == "Unknown")
}

/// One range only (AdGuard Home ignored `recent`): the label names what
/// the stats cover.
@Test func spanNamesThePeriodTheStatsCover() {
    var stats = AdGuardStats()
    #expect(AdGuardPresentation.span(stats) == nil)
    stats.timeUnits = .days
    stats.queriesSeries = Array(repeating: 0, count: 90)
    #expect(AdGuardPresentation.span(stats) == "Last 90 days")
    stats.timeUnits = .hours
    stats.queriesSeries = Array(repeating: 0, count: 24)
    #expect(AdGuardPresentation.span(stats) == "Last 24 hours")
}

/// Brief item 6: the Pause menu, Resume, and the banner states end to end
/// in the mock, through the real executor.
@MainActor @Test func pauseResumeAndTurnOffRunEndToEndInTheMock() async {
    let environment = await mockEnvironment(.running)
    let adGuard = environment.adGuard
    #expect(adGuard.protection == .enabled)

    adGuard.runSetting(.protection(ProtectionPauseChoice.oneMinute.intent(from: .now)))
    await eventually { adGuard.settingInFlight == nil }
    guard case .verifiedSuccess(.protection(.paused))? = adGuard.lastSettingReport?.outcome else {
        Issue.record("expected a verified pause, got \(String(describing: adGuard.lastSettingReport))"); return
    }
    await settle(environment, .paused)
    let banner = AdGuardPresentation.banner(adGuard.availability, protection: adGuard.protection, handlesDNS: adGuard.handlesDNS,
                                            stats: nil, filtering: nil, savedAt: nil, now: .now)
    #expect(banner.actions == [.resume])
    // The sidebar dot turns orange.
    await eventually {
        await environment.refresh.waitForRefresh()
        return AdGuardPresentation.sidebarTone(adGuard.availability, protection: environment.model.snapshot?.adGuard.protection) == .degraded
    }

    adGuard.runSetting(.protection(.enable))
    await eventually { adGuard.settingInFlight == nil }
    #expect(adGuard.lastSettingReport?.outcome == .verifiedSuccess(.protection(.enabled)))
    await eventually { await environment.refresh.waitForRefresh(); return adGuard.protection == .enabled }

    adGuard.runSetting(.protection(.disable))
    await eventually { adGuard.settingInFlight == nil }
    await eventually { await environment.refresh.waitForRefresh(); return adGuard.protection == .disabled }
    #expect(AdGuardPresentation.banner(.running, protection: adGuard.protection, handlesDNS: true, stats: nil, filtering: nil,
                                       savedAt: nil, now: .now).actions == [.turnOnProtection])
}

/// A timed pause ends on its own and the banner follows.
@MainActor @Test func aShortPauseEndsOnItsOwn() async {
    let environment = await mockEnvironment(.running)
    let adGuard = environment.adGuard
    adGuard.runSetting(.protection(.pause(.seconds(1))))
    await eventually { adGuard.settingInFlight == nil }
    await eventually { await environment.refresh.waitForRefresh(); return adGuard.protection == .enabled }
}

@MainActor @Test func handleDNSRequestsFromTheBanner() async {
    let environment = await mockEnvironment(.runningWithoutDNS)
    environment.adGuard.run(.setHandlesDNS(true))
    await eventually { environment.adGuard.inFlight == nil }
    await settle(environment, .running)
}

@MainActor @Test func overviewReadsRangesUpToTheRetention() async {
    let environment = await mockEnvironment(.running)
    let adGuard = environment.adGuard
    await loadOverview(environment)
    #expect(adGuard.stats?.value.matches(.day) == true)
    #expect(adGuard.stats?.savedAt == nil)
    #expect(adGuard.protectionOptions == ProtectionOptions(safeBrowsing: true, parental: false, safeSearch: false))
    #expect(adGuard.filtering?.enabledBlocklists.count == 3)
    // The mock keeps 7 days of stats.
    #expect(adGuard.availableRanges == [.day, .week])

    adGuard.setRange(.week)
    await eventually { adGuard.stats?.value.matches(.week) == true }
    #expect(adGuard.archive?.stats(for: .week) != nil)
}

@MainActor @Test func cachedOverviewShowsTheCopyAndRefusesWrites() async {
    let environment = await mockEnvironment(.cached)
    let adGuard = environment.adGuard
    #expect(adGuard.stats?.savedAt != nil)
    #expect(adGuard.protectionOptions?.safeBrowsing == true)
    #expect(adGuard.availableRanges == [.day])
    #expect(adGuard.protection == .enabled)

    // Every Overview write is refused before any request reaches AdGuard Home.
    for intent in [AdGuardSettingIntent.protection(.enable), .protection(.pause(.seconds(60))), .feature(.safeBrowsing, enabled: false)] {
        #expect(intent.validate(adGuard.availability) != nil)
        adGuard.runSetting(intent)
        await eventually { adGuard.settingInFlight == nil }
        #expect(adGuard.lastSettingReport?.outcome == .rejected(.preconditionFailed("AdGuard Home is not running.")))
        #expect(adGuard.lastSettingReport?.dispatched == false)
    }
    #expect(await environment.mockAdGuardWrites().isEmpty)
}

@MainActor @Test func aFailingSwitchSaysSoAndKeepsItsValue() async {
    let environment = await mockEnvironment(.switchFails)
    let adGuard = environment.adGuard
    await loadOverview(environment)
    adGuard.runSetting(.feature(.parental, enabled: true))
    #expect(adGuard.settingInFlight == .feature(.parental, enabled: true))
    await eventually { adGuard.settingInFlight == nil }
    let text = adGuard.lastSettingReport.flatMap { AdGuardPresentation.settingOutcomeText(.feature(.parental, enabled: true), $0.outcome) }
    #expect(text == "AdGuard Home did not change “Block adult content”.")
    await loadOverview(environment)
    #expect(adGuard.protectionOptions?.parental == false)

    adGuard.runSetting(.feature(.safeBrowsing, enabled: false))
    await eventually { adGuard.settingInFlight == nil }
    #expect(adGuard.lastSettingReport?.outcome == .verifiedSuccess(.feature(false)))
    #expect(adGuard.protectionOptions?.safeBrowsing == false)
}

@MainActor @Test func topRowsOpenTheQueryLogFiltered() {
    let model = AppModel(mode: .mock)
    model.showQueryLog(AdGuardQueryLogFilter(search: "ads.example.com"))
    #expect(model.selection == .adGuard)
    #expect(model.subpages[.adGuard] == "Query Log")
    #expect(model.adGuardQueryLogFilter == AdGuardQueryLogFilter(search: "ads.example.com"))
    model.showQueryLog(AdGuardQueryLogFilter(client: "192.0.2.10"))
    #expect(model.adGuardQueryLogFilter?.client == "192.0.2.10")
    #expect(AdGuardScreen.filterText(model.adGuardQueryLogFilter) == "Opened for 192.0.2.10.")
}

@Test func refreshPlanReadsTheOverviewOnlyOnItsTab() {
    let overview = ScreenRefreshPlan.resolve(destination: "adGuard", segment: "Overview").map(\.area)
    #expect(overview.contains(.adGuardOverview))
    let instance = ScreenRefreshPlan.resolve(destination: "adGuard", segment: "Instance").map(\.area)
    #expect(!instance.contains(.adGuardOverview))
}

// MARK: - Snapshots

/// Writes PNGs of each AdGuard Home state, light and dark, to the test
/// host's temporary folder (`adguard-snapshots`) when `ROUTEWELL_SNAPSHOTS=1`.
/// For reviewing the layout; it checks nothing else.
@MainActor @Test func writeAdGuardSnapshotsWhenAsked() async throws {
    guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("adguard-snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    func write(_ name: String, _ environment: AppEnvironment) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = AdGuardScreen().environment(environment.model).environment(environment)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(x: 0, y: 0, width: 1000, height: 860)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let file = "\(name)-\(appearance == .aqua ? "light" : "dark").png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
        }
    }

    let off = await mockEnvironment(.off)
    write("off", off)
    for (name, scenario) in [("running", MockAdGuardScenario.running), ("cached", .cached), ("unreachable", .unreachable)] {
        let environment = await mockEnvironment(scenario)
        environment.model.subpages[.adGuard] = AdGuardTab.instance.rawValue
        write("instance-\(name)", environment)
    }
    // Chunk 17: the Overview's banner variants.
    for (name, scenario) in [("running", MockAdGuardScenario.running), ("paused", .paused), ("no-dns", .runningWithoutDNS),
                             ("cached", .cached), ("unreachable", .unreachable)] {
        let environment = await mockEnvironment(scenario)
        await loadOverview(environment)
        environment.model.subpages[.adGuard] = AdGuardTab.overview.rawValue
        write("overview-\(name)", environment)
    }
    let off2 = await mockEnvironment(.running)
    await loadOverview(off2)
    off2.adGuard.runSetting(.protection(.disable))
    await eventually { off2.adGuard.settingInFlight == nil }
    write("overview-protection-off", off2)
    let noCopy = await mockEnvironment(.unreachable)
    await noCopy.adGuard.replaceArchive(nil)
    write("unreachable-no-copy", noCopy)
}

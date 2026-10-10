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

/// A mock environment in `scenario`, with the Filters tab's read done.
@MainActor
private func environment(_ scenario: MockAdGuardScenario = .running) async -> AppEnvironment {
    let environment = AppEnvironment(model: AppModel(mode: .mock), backend: MockRouterBackend())
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.setMockAdGuardScenario(scenario)
    let wanted: AdGuardAvailability = scenario == .cached ? .cached : .running
    await eventually {
        await environment.refresh.waitForRefresh()
        return environment.adGuard.availability == wanted
    }
    environment.model.selection = .adGuard
    environment.model.subpages[.adGuard] = AdGuardTab.filters.rawValue
    await read(environment)
    return environment
}

/// The tab's read, as the refresh loop runs it while the tab is visible.
@MainActor
private func read(_ environment: AppEnvironment) async {
    guard let lease = environment.model.session.lease else { return }
    try? await environment.adGuard.refreshOverview(using: lease)
}

/// Hosts the screen on the Filters tab, so its views build.
@MainActor
private func host(_ environment: AppEnvironment) -> NSWindow {
    let view = AdGuardScreen().environment(environment.model).environment(environment)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    return window
}

// MARK: - Texts

@Test func listTexts() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calendar = Calendar.current
    var list = AdGuardFilterList(name: "Example", url: "https://lists.example.com/a.txt", enabled: true, rulesCount: 123_456)
    #expect(FiltersPresentation.rules(list, downloading: false) == 123_456.formatted(.number))
    #expect(FiltersPresentation.rules(list, downloading: true) == "Downloading…")
    #expect(FiltersPresentation.lastUpdated(list, now: now) == "—")
    list.lastUpdated = now.addingTimeInterval(-20).formatted(.iso8601)
    #expect(FiltersPresentation.lastUpdated(list, now: now) == "Just now")
    let earlier = calendar.date(bySettingHour: 0, minute: 30, second: 0, of: now)!
    list.lastUpdated = earlier.formatted(.iso8601)
    if abs(now.timeIntervalSince(earlier)) >= 60 {
        #expect(FiltersPresentation.lastUpdated(list, now: now) == "Today at \(earlier.formatted(date: .omitted, time: .shortened))")
    }
    list.lastUpdated = "not a date"
    #expect(FiltersPresentation.lastUpdated(list, now: now) == "Unknown")

    let off = AdGuardFilterList(name: "Off", url: "https://lists.example.com/b.txt", enabled: false, rulesCount: 0)
    #expect(FiltersPresentation.rules(off, downloading: false) == "—")
    #expect(FiltersPresentation.rules(AdGuardFilterList(enabled: true), downloading: false) == "Unknown")

    #expect(FiltersPresentation.intervalChoices(current: 24).map(FiltersPresentation.intervalTitle)
        == ["1 hour", "12 hours", "24 hours", "3 days", "7 days", "Never"])
    #expect(FiltersPresentation.intervalChoices(current: 6).last == 6)
    #expect(FiltersPresentation.intervalTitle(6) == "6 hours")
    #expect(FiltersPresentation.updateResult(0) == "Lists are up to date")
    #expect(FiltersPresentation.updateResult(1) == "Updated 1 list")
    #expect(FiltersPresentation.updateResult(3) == "Updated 3 lists")
    #expect(FiltersPresentation.updateResult(nil) == nil)
    #expect(FiltersPresentation.addTitle(selected: 0) == "Add")
    #expect(FiltersPresentation.addTitle(selected: 2) == "Add 2")
    #expect(FiltersPresentation.sheetTitle(.blocklist) == "Add blocklists")
    #expect(FiltersPresentation.sheetTitle(.allowlist) == "Add allowlists")

    var status = AdGuardFilteringStatus()
    status.blocklists = [list, off]
    status.allowlists = [AdGuardFilterList(enabled: true, rulesCount: 5)]
    // The summary counts the blocklists on both segments.
    #expect(FiltersPresentation.summary(status) == "1 of 2 on · \(123_456.formatted(.number)) rules")
}

// MARK: - Segments

@MainActor @Test func bothListSegmentsShowTheirLists() async {
    let environment = await environment()
    let filters = environment.filters
    #expect(filters.lists(.blocklist).count == 4)
    #expect(filters.lists(.allowlist).count == 1)
    #expect(filters.status?.intervalHours == 24)
    #expect(filters.canWrite)
    let window = host(environment)
    for segment in AdGuardFiltersController.Segment.allCases {
        filters.segment = segment
        window.contentView?.layoutSubtreeIfNeeded()
    }
    filters.segment = .blocklists
    filters.selection = filters.lists(.blocklist).first?.url
    filters.segment = .allowlists
    // A segment change clears the selection.
    #expect(filters.selection == nil)
    window.close()
}

@MainActor @Test func turningOnAListDownloadsIt() async {
    let environment = await environment()
    let filters = environment.filters
    let off = filters.lists(.blocklist).first { $0.enabled == false }!
    filters.setEnabled(off, kind: .blocklist, enabled: true)
    await eventually { filters.lists(.blocklist).first { $0.url == off.url }?.enabled == true }
    let turnedOn = filters.lists(.blocklist).first { $0.url == off.url }!
    #expect(filters.isDownloading(turnedOn))
    // The mock has the rules after 2 s; the controller reads again.
    await eventually { (filters.lists(.blocklist).first { $0.url == off.url }?.rulesCount ?? 0) > 0 }
    #expect(!filters.isDownloading(filters.lists(.blocklist).first { $0.url == off.url }!))
    await eventually { filters.downloadTask == nil }
}

@MainActor @Test func downloadPollStopsOffTheAdGuardScreen() async {
    let environment = await environment()
    let filters = environment.filters
    let off = filters.lists(.blocklist).first { $0.enabled == false }!
    filters.setEnabled(off, kind: .blocklist, enabled: true)
    await eventually { filters.downloadTask != nil }
    environment.model.selection = .router
    await eventually { filters.downloadTask == nil }
    #expect(filters.isDownloading(filters.lists(.blocklist).first { $0.url == off.url }!))
}

@MainActor @Test func addRemoveIntervalAndUpdateNow() async {
    let environment = await environment()
    let filters = environment.filters
    filters.add([("Example added", "https://lists.example.org/added.txt")], kind: .allowlist)
    await eventually { filters.lists(.allowlist).contains { $0.url == "https://lists.example.org/added.txt" } }
    #expect(filters.isDownloading(filters.lists(.allowlist).last!))

    await eventually { !environment.adGuard.isWriting }
    filters.segment = .allowlists
    filters.selection = "https://lists.example.org/added.txt"
    filters.removeSelected(kind: .allowlist)
    await eventually { !filters.lists(.allowlist).contains { $0.url == "https://lists.example.org/added.txt" } }

    await eventually { !environment.adGuard.isWriting }
    filters.setInterval(168)
    await eventually { filters.status?.intervalHours == 168 }

    await eventually { !environment.adGuard.isWriting }
    filters.updateNow(kind: .blocklist)
    #expect(filters.isUpdating)
    await eventually { filters.lastUpdate?.count == 3 }
    #expect(filters.lastUpdate?.kind == .blocklist)
    #expect(await environment.mockAdGuardWrites().contains(.refreshLists(whitelist: false)))
}

@MainActor @Test func catalogAddsSeveralListsInTurn() async {
    let environment = await environment()
    let filters = environment.filters
    let entries = Array(AdGuardListCatalog.bundled.sections.first!.lists.prefix(2))
    filters.add(entries.map { ($0.name, $0.url) }, kind: .blocklist)
    await eventually { entries.allSatisfy { AdGuardListCatalog.bundled.isAdded($0, in: filters.status) } }
    #expect(filters.lists(.blocklist).count == 6)
}

@MainActor @Test func addFailsShowsANotice() async {
    let environment = await environment(.addListFails)
    environment.filters.add([("Example", "https://lists.example.org/x.txt"), ("Second", "https://lists.example.org/y.txt")], kind: .blocklist)
    await eventually { environment.adGuard.lastSettingReport != nil }
    let report = environment.adGuard.lastSettingReport!
    guard case .verifiedMismatch = report.outcome else { Issue.record("\(report.outcome)"); return }
    #expect(AdGuardPresentation.settingOutcomeText(environment.adGuard.lastSettingIntent!, report.outcome)?.hasPrefix("AdGuard Home did not add the list") == true)
    // It stops at the first failure.
    try? await Task.sleep(for: .milliseconds(300))
    #expect(await environment.mockAdGuardWrites().filter { if case .addList = $0 { true } else { false } }.count == 1)
}

@MainActor @Test func refreshPartialReportsOneList() async {
    let environment = await environment(.refreshPartial)
    environment.filters.updateNow(kind: .blocklist)
    await eventually { environment.filters.lastUpdate != nil }
    #expect(environment.filters.lastUpdate?.count == 1)
}

// MARK: - Rules editor

@MainActor @Test func rulesEditorStates() async {
    let environment = await environment()
    let filters = environment.filters
    let server = filters.serverRules ?? []
    #expect(filters.canEditRules)
    #expect(!filters.hasRuleChanges)
    #expect(filters.rulesText == CustomRulesText.text(server))

    filters.editRules(filters.rulesText + "\n||new.example^")
    #expect(filters.hasRuleChanges)
    filters.revertRules()
    #expect(!filters.hasRuleChanges)
    #expect(filters.rulesText == CustomRulesText.text(server))

    // Typing back to the same text is no change.
    filters.editRules(filters.rulesText)
    #expect(!filters.hasRuleChanges)

    filters.editRules("||saved.example^")
    filters.saveRules()
    await eventually { filters.serverRules == ["||saved.example^"] && !environment.adGuard.isWriting }
    #expect(!filters.hasRuleChanges)
    #expect(filters.rulesText == "||saved.example^")
}

@MainActor @Test func rulesConflictStopsSaveAndOffersBothWays() async {
    let environment = await environment(.rulesConflict)
    let filters = environment.filters
    filters.editRules(filters.rulesText + "\n||mine.example^")
    filters.saveRules()
    await eventually { filters.conflict != nil }
    #expect(filters.conflict?.first == "||changed-elsewhere.example^")
    #expect(!(await environment.mockAdGuardWrites().contains { if case .setRules = $0 { true } else { false } }))
    #expect(AdGuardPresentation.settingOutcomeText(environment.adGuard.lastSettingIntent!, environment.adGuard.lastSettingReport!.outcome) == nil)

    // Keep Editing: the next Save replaces the rules AdGuard Home has now.
    filters.keepEditingAfterConflict()
    #expect(filters.conflict == nil)
    #expect(filters.hasRuleChanges)
    filters.saveRules()
    await eventually { filters.serverRules?.last == "||mine.example^" && !environment.adGuard.isWriting }

    // Discard drops the edits.
    filters.editRules("||other.example^")
    filters.conflict = ["x"]
    filters.discardForConflict()
    #expect(!filters.hasRuleChanges)
}

@MainActor @Test func anotherRouterDropsTheDraftAndConflict() async {
    let environment = await environment()
    let filters = environment.filters
    filters.editRules(filters.rulesText + "\n||router-a.example^")
    filters.conflict = ["||router-a.example^"]
    filters.selection = filters.lists(.blocklist).first?.url
    #expect(filters.hasRuleChanges)
    // Not on the Filters tab: the reset does not need its view.
    environment.model.selection = .clients
    environment.addMockProfile()
    #expect(!filters.hasRuleChanges)
    #expect(filters.conflict == nil)
    #expect(filters.selection == nil)
    #expect(!filters.rulesText.contains("router-a"))
}

// MARK: - Cached

@MainActor @Test func cachedShowsTheCopyAndDisablesEveryWrite() async {
    let environment = await environment(.cached)
    let filters = environment.filters
    #expect(environment.adGuard.availability == .cached)
    #expect(filters.lists(.blocklist).count == 4)
    #expect(filters.serverRules != nil)
    #expect(!filters.canWrite)
    #expect(!filters.canEditRules)
    filters.editRules("||nope.example^")
    #expect(!filters.hasRuleChanges)
    filters.add([("Example", "https://lists.example.org/x.txt")], kind: .blocklist)
    filters.updateNow(kind: .blocklist)
    filters.setInterval(1)
    filters.selection = filters.lists(.blocklist).first?.url
    filters.removeSelected(kind: .blocklist)
    try? await Task.sleep(for: .milliseconds(300))
    #expect(await environment.mockAdGuardWrites().isEmpty)
    let window = host(environment)
    for segment in AdGuardFiltersController.Segment.allCases {
        filters.segment = segment
        window.contentView?.layoutSubtreeIfNeeded()
    }
    window.close()
}

@MainActor @Test func addSheetBuildsInBothModes() async {
    let environment = await environment()
    for kind in FilterListKind.allCases {
        let view = AddFilterListSheet(kind: kind).environment(environment.model).environment(environment)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: 420, height: 440)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }
}

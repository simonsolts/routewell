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
        case .running, .runningWithoutDNS: return adGuard.availability == .running && adGuard.handlesDNS == (scenario == .running)
        case .cached: return adGuard.availability == .cached
        case .unreachable: return adGuard.availability == .unreachable(.notAnswering(.authentication))
        }
    }
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
    #expect(model.adGuardQueryLogClient == "192.0.2.20")
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
        environment.model.subpages[.adGuard] = AdGuardTab.overview.rawValue
        write("overview-\(name)", environment)
    }
    let noCopy = await mockEnvironment(.unreachable)
    await noCopy.adGuard.replaceArchive(nil)
    write("unreachable-no-copy", noCopy)
}

import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

/// A mock environment on Wi-Fi › Overview after the reads, with the given
/// apply scenario.
@MainActor private func editEnvironment(_ apply: MockWiFiService.ApplyScenario = .success) async -> (AppEnvironment, MockRouterBackend) {
    let backend = MockRouterBackend()
    backend.mockWiFi.setApplyScenario(apply)
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    model.selection = .wifi
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    return (environment, backend)
}

@MainActor private func group(_ environment: AppEnvironment, _ name: String) throws -> WiFiNetworkGroup {
    try #require(environment.wifi.overview?.groups.first { $0.name == name })
}

@MainActor private func waitForOutcome(_ environment: AppEnvironment, timeout: Duration = .seconds(15)) async -> MutationOutcome<WiFiApplyState>? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let outcome = environment.wifi.run?.outcome, !environment.wifi.isApplying { return outcome }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
}

@MainActor private func review(_ environment: AppEnvironment) throws -> WiFiReviewPresentation {
    let change = try #require(environment.wifi.pending)
    let plan = try #require(environment.wifi.plan(for: change))
    return WiFiReviewPresentation(change: change, plan: plan, wireless: try #require(environment.model.wireless))
}

// MARK: Network sheet

@MainActor @Test func networkCardsOpenTheSheetWithTheRouterValues() async throws {
    let (environment, _) = await editEnvironment()
    let controller = environment.wifi
    #expect(controller.canEdit)
    controller.openNetwork(try group(environment, MockWiFiService.fast))
    #expect(controller.sheet == .network)
    let draft = try #require(controller.draft)
    #expect(draft.name == MockWiFiService.fast)
    #expect(draft.password == "example-password")
    #expect(draft.security == .wpa3 && draft.visible && draft.randomBSSID)
    #expect(draft.bands == [.ghz5, .ghz6])
    #expect(draft.isolate == false)
    #expect(!draft.hasChanges)

    let wireless = try #require(environment.model.wireless)
    let devices = controller.overview?.devices ?? []
    #expect(WirelessBand.allCases.map { WiFiEditFormat.bandTile($0, draft: draft, wireless: wireless, devices: devices) }
        == ["Used by Flint Home", "Not used", "2 devices"])
    #expect(WiFiEditFormat.joinCode(name: draft.name, password: draft.password, security: .wpa3, hidden: false)
        == "WIFI:T:WPA;S:Flint Home Fast;P:example-password;;")
    #expect(WiFiEditFormat.joinCode(name: "A;B", password: "p:w", security: WiFiSecurity.none, hidden: true) == "WIFI:T:nopass;S:A\\;B;H:true;;")
    #expect(WiFiJoinCode.image("WIFI:T:WPA;S:Flint Home;P:example-password;;") != nil)

    let view = NSHostingView(rootView: WiFiSheetHost(sheet: .network).environment(environment.model).environment(environment))
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.height > 300)
}

@MainActor @Test func sheetValidation() async throws {
    let (environment, _) = await editEnvironment()
    let controller = environment.wifi
    controller.openNetwork(try group(environment, MockWiFiService.home))
    controller.draft?.name = ""
    #expect(controller.draft?.edit.problems == [.emptyName])
    controller.draft?.name = MockWiFiService.home
    controller.draft?.password = "short"
    #expect(controller.draft?.edit.problems == [.passwordLength])
    controller.draft?.password = "example-password"
    // 6 GHz allows only WPA3, whatever the menu had.
    controller.draft?.bands.insert(.ghz6)
    #expect(controller.draft?.effectiveSecurity == .wpa3)
    #expect(controller.draft?.edit.problems == [])
    let wireless = try #require(environment.model.wireless)
    #expect(WiFiEditFormat.movedBands(try #require(controller.draft), wireless: wireless) == [.ghz6])
    controller.closeSheet()
    #expect(controller.sheet == nil && controller.draft == nil)
}

// MARK: Review texts

@MainActor @Test func reviewTextForVisible() async throws {
    let (environment, _) = await editEnvironment()
    let controller = environment.wifi
    controller.openNetwork(try group(environment, MockWiFiService.home))
    controller.draft?.visible = false
    controller.review(try #require(controller.draft?.change))
    #expect(controller.sheet == .review)
    let page = try review(environment)
    #expect(page.title == "Apply 1 change?")
    #expect(page.changes == ["Flint Home visible: Off"])
    #expect(page.before == page.after)
    #expect(page.impacts.map { "\($0.bold) \($0.rest)" } == [
        "2.4 GHz restarts",
        "3 devices drop, then join again by themselves",
        "This Mac stays connected",
    ])
    #expect(page.ethernetHint == nil)
    #expect(WiFiReviewPresentation.trail(macDrops: page.macDrops) == ["Send changes", "Restart", "Check the router"])
}

@MainActor @Test func reviewTextForPasswordAndName() async throws {
    let (environment, _) = await editEnvironment()
    let controller = environment.wifi
    controller.openNetwork(try group(environment, MockWiFiService.fast))
    controller.draft?.password = "another-password"
    controller.review(try #require(controller.draft?.change))
    var page = try review(environment)
    #expect(page.title == "Apply 1 change?")
    #expect(page.changes == ["Flint Home Fast: new password"])
    #expect(page.impacts.map { "\($0.bold) \($0.rest)" } == [
        "The network on 5 and 6 GHz restarts; other networks there stay up",
        "2 devices must join again",
        "This Mac must enter the new password for Flint Home Fast",
    ])
    #expect(page.ethernetHint == "Use Ethernet for this change if you can.")
    #expect(WiFiReviewPresentation.trail(macDrops: page.macDrops) == ["Send changes", "Restart", "Reconnect this Mac"])

    controller.openNetwork(try group(environment, MockWiFiService.fast))
    controller.draft?.name = "Flint Home Up"
    controller.review(try #require(controller.draft?.change))
    page = try review(environment)
    #expect(page.changes == ["Name: Flint Home Fast → Flint Home Up"])
    #expect(page.after.map(\.name) == ["Flint Home", "Flint Home Up"])
    #expect(page.impacts.last?.rest == "must join Flint Home Up by hand")
}

@MainActor @Test func useOneNameMovesBandsAndCountsWhoJoinsAgain() async throws {
    let (environment, _) = await editEnvironment()
    let controller = environment.wifi
    controller.openUseOneName()
    #expect(controller.sheet == .useOneName)
    #expect(controller.keepName == MockWiFiService.home)
    let change = try #require(controller.useOneNameChange(keeping: MockWiFiService.home))
    #expect(change.networks.first?.bands == [.ghz2_4, .ghz5, .ghz6])
    #expect(change.networks.first?.security == .wpa3)
    let plan = try #require(controller.plan(for: change))
    #expect(plan.mustJoin.count == 5)
    controller.review(change)
    let page = try review(environment)
    #expect(page.after.map(\.name) == [MockWiFiService.home])
    #expect(page.after.first?.bands == [.ghz2_4, .ghz5, .ghz6])
    #expect(page.changes.contains("5 GHz moves from Flint Home Fast to Flint Home"))
    #expect(page.changes.contains("Flint Home security: WPA2/WPA3 → WPA3"))

    let fastChange = try #require(controller.useOneNameChange(keeping: MockWiFiService.fast))
    let keepFast = try #require(controller.plan(for: fastChange))
    // Keeping the 5 and 6 GHz name: only the 2.4 GHz devices join again.
    #expect(keepFast.mustJoin.count == 3)

    let view = NSHostingView(rootView: WiFiSheetHost(sheet: .useOneName).environment(environment.model).environment(environment))
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.height > 100)
}

@MainActor @Test func reviewTextForIsolation() async throws {
    let (environment, _) = await editEnvironment(.macOnEthernet)
    let controller = environment.wifi
    controller.openNetwork(try group(environment, MockWiFiService.home))
    controller.draft?.isolate = true
    controller.review(try #require(controller.draft?.change))
    let page = try review(environment)
    #expect(page.changes == ["Isolate devices: On, on every main network"])
    #expect(page.impacts.map { "\($0.bold) \($0.rest)" } == ["Main network settings reload", "This Mac stays on Ethernet"])
}

// MARK: Outcomes

@MainActor @Test func outcomeTexts() {
    let plan = WiFiApplyPlan(change: WiFiChangeSet(), wireless: MockWiFiService.wireless(.today), subnets: nil, devices: [], thisMac: .ethernet)
    var run = WiFiApplyRun(plan: plan, macWasOnWiFi: false)
    func text(_ outcome: MutationOutcome<WiFiApplyState>) -> WiFiOutcomePresentation { WiFiOutcomePresentation(outcome, run: run) }
    #expect(text(.verifiedSuccess(WiFiApplyState())).title == "Applied")
    #expect(text(.verifiedSuccess(WiFiApplyState())).text == "The router has the new settings.")
    #expect(text(.unknownAfterDispatch).title == "The router did not answer")
    #expect(!text(.unknownAfterDispatch).showsWiFiSettings)
    #expect(text(.verifiedMismatch(expected: WiFiApplyState(), actual: WiFiApplyState())).title == "Not every change applied")
    #expect(text(.conflictingExternalEdit(actual: WiFiApplyState())).title == "Changed on the router")
    let refused = text(.rejected(.preconditionFailed(WiFiApplyExecutor.refusedMessage(-1))))
    #expect(refused.title == "Not applied" && refused.text == "The router refused the change (code -1). Nothing was changed.")
    run = WiFiApplyRun(plan: plan, macWasOnWiFi: true)
    let notBack = text(.unknownAfterDispatch)
    #expect(notBack.title == "This Mac is not back on Wi-Fi")
    #expect(notBack.text == "Join the router's network on this Mac. Routewell then connects again by itself.")
    #expect(notBack.showsWiFiSettings)
}

// MARK: Apply in the mock

@MainActor @Test func applyVerifiesAndTheScreenShowsTheNewValue() async throws {
    let (environment, backend) = await editEnvironment()
    let controller = environment.wifi
    controller.openNetwork(try group(environment, MockWiFiService.home))
    controller.draft?.visible = false
    controller.review(try #require(controller.draft?.change))
    controller.apply()
    #expect(controller.isApplying)
    #expect(!controller.canEdit)
    let outcome = await waitForOutcome(environment)
    guard case .verifiedSuccess = outcome else { Issue.record("\(String(describing: outcome))"); return }
    #expect(controller.run?.step == .checking)
    await environment.refresh.waitForRefresh()
    #expect(environment.model.wireless?.radio(.ghz2_4)?.mainNetwork?.hidden == true)
    #expect(try await backend.mockWiFi.readWireless().radio(.ghz2_4)?.mainNetwork?.hidden == true)
    controller.closeSheet()
    #expect(controller.sheet == nil && controller.run == nil)
}

@MainActor @Test func macThatDoesNotComeBackSaysSo() async throws {
    let (environment, _) = await editEnvironment(.macNotBack)
    let controller = environment.wifi
    #expect(controller.thisMacLink == .wifi(band: .ghz6, interface: "rax0"))
    controller.openNetwork(try group(environment, MockWiFiService.fast))
    controller.draft?.visible = false
    controller.review(try #require(controller.draft?.change))
    controller.apply()
    let outcome = await waitForOutcome(environment)
    #expect(outcome == .unknownAfterDispatch)
    let run = try #require(controller.run)
    let page = WiFiOutcomePresentation(.unknownAfterDispatch, run: run)
    #expect(page.title == "This Mac is not back on Wi-Fi")
    #expect(page.text == "Join Flint Home Fast on this Mac. Routewell then connects again by itself.")
    #expect(page.showsWiFiSettings)
}

@MainActor @Test func refusedAndMismatchOutcomes() async throws {
    for (scenario, title) in [(MockWiFiService.ApplyScenario.refused, "Not applied"), (.mismatch, "Not every change applied"),
                              (.replyLost, "Applied")] {
        let (environment, _) = await editEnvironment(scenario)
        let controller = environment.wifi
        controller.openNetwork(try group(environment, MockWiFiService.home))
        controller.draft?.visible = false
        controller.review(try #require(controller.draft?.change))
        controller.apply()
        let outcome = try #require(await waitForOutcome(environment))
        let run = try #require(controller.run)
        #expect(WiFiOutcomePresentation(outcome, run: run).title == title, "\(scenario)")
    }
}

@MainActor @Test func macOnEthernetStaysOnEthernet() async throws {
    let (environment, _) = await editEnvironment(.macOnEthernet)
    #expect(environment.wifi.thisMacLink == .ethernet)
    let change = WiFiChangeSet(networks: [WiFiNetworkDraft(group: try group(environment, MockWiFiService.fast),
                                                           wireless: try #require(environment.model.wireless), isolate: nil).edit])
    var edited = change
    edited.networks[0].hidden = true
    #expect(environment.wifi.plan(for: edited)?.thisMac == .staysOnEthernet)
}

@MainActor @Test func refreshSkipsWiFiAndHidesFailuresWhileApplying() async throws {
    let (environment, _) = await editEnvironment(.macNotBack)
    let model = environment.model
    let controller = environment.wifi
    controller.openNetwork(try group(environment, MockWiFiService.fast))
    controller.draft?.visible = false
    controller.review(try #require(controller.draft?.change))
    let before = model.wifiFreshness.lastAttempt
    let airBefore = model.wifiAirFreshness.lastAttempt
    controller.apply()
    #expect(model.wifiApplying)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    #expect(model.wifiFreshness.lastAttempt == before)
    #expect(model.wifiAirFreshness.lastAttempt == airBefore)
    model.accept(.failure(.network, Date()), token: try #require(model.session.expectedToken))
    #expect(!model.refreshFailed)
    _ = await waitForOutcome(environment)
    #expect(!model.wifiApplying)
}

@MainActor @Test func sessionChangeDuringApplyDropsTheRun() async throws {
    let (environment, _) = await editEnvironment(.macNotBack)
    let model = environment.model
    let controller = environment.wifi
    controller.openNetwork(try group(environment, MockWiFiService.fast))
    controller.draft?.visible = false
    controller.review(try #require(controller.draft?.change))
    controller.apply()
    try await Task.sleep(for: .milliseconds(200))
    await model.session.switchProfile("second", model: model, refresh: environment.refresh) {
        SessionLease(token: $0, backend: MockRouterBackend())
    }.value
    let deadline = ContinuousClock.now + .seconds(15)
    // The new session clears the flag at once; the old apply's report is dropped when it ends.
    #expect(!controller.isApplying)
    while controller.run != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(controller.run == nil && controller.sheet == nil)
}

@MainActor @Test func writeWiFiEditSnapshotsWhenAsked() async throws {
    guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write(_ name: String, _ environment: AppEnvironment, _ sheet: WiFiSheet) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = WiFiSheetHost(sheet: sheet).environment(environment.model).environment(environment)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let file = "edit-\(name)-\(appearance == .aqua ? "light" : "dark").png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
        }
    }
    let (environment, _) = await editEnvironment()
    let controller = environment.wifi
    controller.openNetwork(try group(environment, MockWiFiService.fast))
    controller.draft?.password = "another-password"
    write("network", environment, .network)
    controller.review(try #require(controller.draft?.change))
    write("review", environment, .review)
    controller.openUseOneName()
    write("use-one-name", environment, .useOneName)
    controller.openNetwork(try group(environment, MockWiFiService.home))
    controller.draft?.visible = false
    controller.review(try #require(controller.draft?.change))
    controller.apply()
    try await Task.sleep(for: .milliseconds(100))
    write("progress", environment, .review)
    _ = await waitForOutcome(environment)
    write("applied", environment, .review)
}

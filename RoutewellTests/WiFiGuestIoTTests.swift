import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

@MainActor private func guestEnvironment(_ scenario: MockWiFiService.Scenario = .today, apply: MockWiFiService.ApplyScenario = .success) async
    -> AppEnvironment {
    let backend = MockRouterBackend()
    backend.mockWiFi.setScenario(scenario)
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
    return environment
}

@MainActor private func outcome(_ environment: AppEnvironment) async -> MutationOutcome<WiFiApplyState>? {
    let deadline = ContinuousClock.now + .seconds(15)
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

@MainActor @Test func guestTurnOnAddsTheNetworkAndShowsTheShareCard() async throws {
    let environment = await guestEnvironment()
    let controller = environment.wifi
    let overview = try #require(controller.overview)
    #expect(overview.missing.contains(.guest) && overview.missing.contains(.iot))
    controller.openGuest(.guest)
    #expect(controller.sheet == .guestIoT)
    let draft = try #require(controller.guestDraft)
    #expect(!draft.isOn && draft.name == MockWiFiService.guest && draft.password == "example-password")
    #expect(draft.bands == [.ghz2_4, .ghz5] && draft.effectiveSecurity == .wpa2WPA3)
    #expect(draft.eachOther == false && draft.reachesModem == false)
    #expect(draft.range == "192.168.9.1/24")
    let plan = try #require(controller.plan(for: draft.change))
    #expect(plan.restarts == [.added(.ghz2_4), .added(.ghz5)])
    #expect(plan.thisMac == .staysConnected)

    controller.guestDraft?.bands.insert(.ghz6)
    #expect(controller.guestDraft?.effectiveSecurity == .wpa3)
    controller.guestDraft?.bands.remove(.ghz6)
    controller.guestDraft?.password = "short"
    #expect(controller.guestDraft?.edit.problems == [.passwordLength])
    controller.guestDraft?.password = WiFiGuestDraft.newPassword()
    #expect(controller.guestDraft?.password.count == 14)

    controller.turnOn()
    guard case .verifiedSuccess = await outcome(environment) else { Issue.record("not applied"); return }
    #expect(controller.sheet == .guestIoT && controller.guestDraft != nil)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    let guest = try #require(controller.overview?.groups.first { $0.kind == .guest })
    #expect(guest.bands == [.ghz2_4, .ghz5])
    #expect(!(controller.overview?.missing.contains(.guest) ?? true))
}

@MainActor @Test func iotTurnOnSendsTheRulesAndWatchesTheDevicesJoin() async throws {
    let environment = await guestEnvironment()
    let controller = environment.wifi
    let overview = try #require(controller.overview)
    let wireless = try #require(environment.model.wireless)
    let page = WiFiOverviewPresentation(overview: overview, wireless: wireless, suggestions: controller.suggestions)
    let line = try #require(page.suggestions.first { $0.suggestion.kind == .ownNetwork })
    #expect(line.action?.target == .iot)
    controller.openGuest(.iot)
    let draft = try #require(controller.guestDraft)
    let watch = MACAddress("d8:1c:79:aa:04:53")!
    #expect(draft.moving == [watch] && controller.moveCandidates.map(\.mac).contains(watch))
    #expect(draft.bands == [.ghz2_4] && draft.security == .wpa2 && draft.eachOther == true && draft.reachesModem == false)
    let plan = try #require(controller.plan(for: draft.change))
    guard case .rules(_, let rules)? = plan.calls.first else { Issue.record("no subnet call first"); return }
    #expect(rules == WiFiSubnetRules(kind: .iot, eachOther: true, reachesModem: false))

    let rows = WiFiGuestFormat.reach(draft)
    #expect(rows.filter { !$0.locked }.map(\.row) == [.eachOther, .modem])
    #expect(WiFiGuestFormat.into.allSatisfy { $0.locked && $0.on == false })

    controller.turnOn()
    guard case .verifiedSuccess = await outcome(environment) else { Issue.record("not applied"); return }
    #expect(controller.joinedIoT([watch]).isEmpty)
    try await Task.sleep(for: .seconds(MockWiFiService.iotJoinTime + 0.5))
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(controller.joinedIoT([watch]) == [watch])
    #expect(WiFiGuestFormat.joinedLine(joined: 1, of: 1) == "On · 1 of 1 device joined")
}

@MainActor @Test func onNetworkChangesAndTurnsOffThroughReview() async throws {
    let environment = await guestEnvironment(.guestAndIoT)
    let controller = environment.wifi
    controller.openGuest(.guest)
    let draft = try #require(controller.guestDraft)
    #expect(draft.isOn && draft.bands == [.ghz2_4, .ghz5] && draft.eachOther == false)
    controller.guestDraft?.eachOther = true
    let change = try #require(controller.guestDraft?.change)
    controller.review(change)
    #expect(controller.sheet == .review)
    var page = try review(environment)
    #expect(page.changes == ["Guests can reach each other: On"])
    #expect(page.impacts.contains { $0.bold == "Guest network settings" })

    controller.openGuest(.guest)
    let off = try #require(controller.guestDraft?.turnOffChange)
    controller.review(off)
    page = try review(environment)
    #expect(page.changes == ["Turn off \(MockWiFiService.guest)"])
    let pending = try #require(controller.pending)
    let plan = try #require(controller.plan(for: pending))
    let slots = plan.calls.compactMap { call -> WiFiSlotState? in if case .network(let slot, _, _) = call { slot } else { nil } }
    #expect(slots.map(\.interface) == ["ra1", "rai1"] && slots.allSatisfy { $0.enabled == false })
    controller.apply()
    guard case .verifiedSuccess = await outcome(environment) else { Issue.record("not applied"); return }
}

@MainActor @Test func subnetConflictIsRefusedWithItsText() async throws {
    let environment = await guestEnvironment(apply: .subnetConflict)
    let controller = environment.wifi
    controller.openGuest(.iot)
    controller.turnOn()
    let result = try #require(await outcome(environment))
    let run = try #require(controller.run)
    let page = WiFiOutcomePresentation(result, run: run)
    #expect(page.title == "Not applied")
    #expect(page.text.contains("overlaps another network"))
}

@MainActor @Test func writeWiFiGuestSnapshotsWhenAsked() async throws {
    guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write(_ name: String, _ environment: AppEnvironment) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = WiFiSheetHost(sheet: .guestIoT).environment(environment.model).environment(environment)
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
            let file = "guest-\(name)-\(appearance == .aqua ? "light" : "dark").png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
        }
    }
    let environment = await guestEnvironment()
    let controller = environment.wifi
    controller.openGuest(.guest)
    write("guest-setup", environment)
    controller.turnOn()
    _ = await outcome(environment)
    write("guest-ready", environment)
    controller.closeSheet()
    controller.openGuest(.iot)
    write("iot-setup", environment)
    controller.turnOn()
    _ = await outcome(environment)
    write("iot-ready", environment)
    let on = await guestEnvironment(.guestAndIoT)
    on.wifi.openGuest(.guest)
    write("guest-on", on)
}

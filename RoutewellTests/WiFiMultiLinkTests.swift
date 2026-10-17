import AppKit
import Foundation
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

@MainActor private func linkEnvironment(_ scenario: MockWiFiService.Scenario = .today) async -> AppEnvironment {
    let backend = MockRouterBackend()
    backend.mockWiFi.setScenario(scenario)
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    model.selection = .wifi
    model.subpages[.wifi] = WiFiTab.multiLink.rawValue
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

@MainActor @Test func multiLinkSetupWithANewNameTurnsItOn() async throws {
    let environment = await linkEnvironment()
    let controller = environment.wifi
    controller.openMultiLinkSetup()
    #expect(controller.sheet == .multiLink)
    let draft = try #require(controller.mloDraft)
    #expect(draft.bands == [.ghz5, .ghz6] && !draft.sameName && draft.samePassword)
    #expect(draft.name == "Flint Home 7" && draft.fastName == MockWiFiService.fast)
    controller.mloDraft?.name = "Flint Home Link"
    let named = try #require(controller.mloDraft)
    let plan = try #require(controller.plan(for: named.change))
    #expect(plan.restarts == [.added(.ghz5), .added(.ghz6)])
    let review = WiFiMLOFormat.Review(plan: plan)
    #expect(review.restartBold == "5 and 6 GHz" && review.devicesBold == "No devices" && review.mac == "stays connected")

    controller.turnOnMultiLink()
    guard case .verifiedSuccess = await outcome(environment) else { Issue.record("not applied"); return }
    #expect(controller.sheet == .multiLink)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    let link = try #require(controller.overview?.multiLink)
    #expect(link.ssid == "Flint Home Link" && link.bands == [.ghz5, .ghz6] && link.encryption == .wpa3)
    #expect(controller.overview?.devices.filter(\.viaLink).count == 2)
}

@MainActor @Test func multiLinkSameNameIsSentAsTheFastName() async throws {
    let environment = await linkEnvironment()
    let controller = environment.wifi
    controller.openMultiLinkSetup()
    controller.mloDraft?.sameName = true
    let draft = try #require(controller.mloDraft)
    #expect(draft.network.problems.isEmpty)
    #expect(draft.change.mlo?.ssid == MockWiFiService.fast)
    #expect(WiFiMLOFormat.doneLine(name: MockWiFiService.fast, sameName: true, devices: ["Mac"]) == "Mac use it the next time they join.")
}

@MainActor @Test func multiLinkTurnOffGoesThroughReview() async throws {
    let environment = await linkEnvironment(.multiLinkOn)
    let controller = environment.wifi
    controller.editMLO { $0.bands.insert(.ghz2_4) }
    #expect(controller.mloEdits.map(WiFiMLOFormat.applyBar) == "Use 2.4 and 5 and 6 GHz")
    controller.editMLO { $0.enabled = false }
    let draft = try #require(controller.mloEdits)
    #expect(WiFiMLOFormat.applyBar(draft) == "Turn off multi-link")
    controller.revertMLO()
    controller.editMLO { $0.enabled = false }

    controller.reviewMLO()
    #expect(controller.sheet == .review)
    let change = try #require(controller.pending)
    let plan = try #require(controller.plan(for: change))
    let page = WiFiReviewPresentation(change: change, plan: plan, wireless: try #require(controller.base))
    #expect(page.changes == ["Turn off Flint Home 7"])
    #expect(plan.mustJoin.count == 2)
    controller.apply()
    guard case .verifiedSuccess = await outcome(environment) else { Issue.record("not applied"); return }
    controller.closeSheet()
    #expect(controller.mloEdits == nil)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(controller.overview?.multiLink == nil)
}

/// Writes PNGs of the setup steps, the done screen and the tab with staged
/// edits when `ROUTEWELL_SNAPSHOTS=1`. For reviewing the layout only.
@MainActor @Test func writeWiFiMultiLinkSnapshotsWhenAsked() async throws {
    guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write<V: View>(_ name: String, _ environment: AppEnvironment, size: CGSize? = nil, _ view: () -> V) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: view().environment(environment.model).environment(environment)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(origin: .zero, size: size ?? host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let file = "multilink-\(name)-\(appearance == .aqua ? "light" : "dark").png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
        }
    }
    let environment = await linkEnvironment()
    let controller = environment.wifi
    controller.openMultiLinkSetup()
    for step in WiFiMultiLinkSheet.Step.allCases {
        write("setup-\(step)", environment) { WiFiMultiLinkSheet(step: step).padding(20).frame(width: 620) }
    }
    controller.mloDraft?.sameName = true
    controller.mloDraft?.samePassword = false
    controller.mloDraft?.password = "example-password"
    write("setup-name-same", environment) { WiFiMultiLinkSheet(step: .name).padding(20).frame(width: 620) }
    controller.mloDraft?.sameName = false
    controller.mloDraft?.samePassword = true
    controller.turnOnMultiLink()
    _ = await outcome(environment)
    write("setup-done", environment) { WiFiMultiLinkSheet(step: .review).padding(20).frame(width: 620) }
    controller.closeSheet()

    let on = await linkEnvironment(.multiLinkOn)
    on.wifi.editMLO { $0.enabled = false }
    write("on-staged", on, size: CGSize(width: 1100, height: 900)) { WiFiScreen() }
}

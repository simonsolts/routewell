import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

/// A mock environment on Wi-Fi › Radios after the reads.
@MainActor private func radiosEnvironment(_ scenario: MockWiFiService.Scenario = .today,
                                          apply: MockWiFiService.ApplyScenario = .success) async -> (AppEnvironment, MockRouterBackend) {
    let backend = MockRouterBackend()
    backend.mockWiFi.setScenario(scenario)
    backend.mockWiFi.setApplyScenario(apply)
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    model.selection = .wifi
    model.subpages[.wifi] = WiFiTab.radios.rawValue
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    return (environment, backend)
}

@MainActor private func inspector(_ environment: AppEnvironment, _ band: WirelessBand) throws -> WiFiRadioInspector {
    let controller = environment.wifi
    return WiFiRadioInspector(wireless: try #require(environment.model.wireless), band: band, devices: controller.overview?.devices ?? [],
                              air: controller.airState == .available ? environment.model.wifiAir : nil, edits: controller.radioEdits,
                              editable: controller.canEdit)
}

@MainActor private func waitForOutcome(_ environment: AppEnvironment, timeout: Duration = .seconds(20)) async -> MutationOutcome<WiFiApplyState>? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let outcome = environment.wifi.run?.outcome, !environment.wifi.isApplying { return outcome }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
}

@MainActor private func review(_ environment: AppEnvironment) throws -> WiFiReviewPresentation {
    let controller = environment.wifi
    let change = try #require(controller.pending)
    return WiFiReviewPresentation(change: change, plan: try #require(controller.plan(for: change)), wireless: try #require(controller.base),
                                  sections: controller.baseSections)
}

// MARK: Controls

@MainActor @Test func widthChoicesPerBand() async throws {
    let (environment, _) = await radiosEnvironment()
    #expect(try inspector(environment, .ghz2_4).widths.map(\.label) == ["Auto", "20", "40"])
    let five = try inspector(environment, .ghz5)
    #expect(five.editable)
    #expect(five.widths.map(\.label) == ["20", "40", "80", "160"])
    // Auto skips every DFS channel, so 160 MHz cannot fit.
    #expect(five.widths.last?.disabledReason == "Needs DFS channels")
    #expect(five.autoDFS == false && five.autoDFSWritable)
    let six = try inspector(environment, .ghz6)
    #expect(six.widths.map(\.label) == ["20", "40", "80", "160", "320"])
    #expect(six.widths.allSatisfy { $0.disabledReason == nil })
    #expect(six.versions.map(\.label) == ["Wi-Fi 6E and 7"])
    #expect(five.channels.first { $0.number == 100 }?.label == "100 (DFS)")
    #expect(six.channels.first { $0.number == 37 }?.label == "37 (preferred)")
}

@MainActor @Test func aManualChannelLimitsTheWidth() async throws {
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    controller.setAutoChannel(.ghz5, false)
    #expect(controller.radioEdits?.current(.ghz5)?.channel == 44)
    controller.pickChannel(.ghz5, 140)
    let settings = try #require(controller.radioEdits?.current(.ghz5))
    #expect(settings.channel == 140 && settings.width == 20)
    let five = try inspector(environment, .ghz5)
    #expect(five.widths.first { $0.width == 80 }?.disabledReason == "Channel 140 cannot use 80 MHz")
    #expect(five.widths.first { $0.width == 20 }?.disabledReason == nil)
    // Manual channels may use 160 MHz without Auto's DFS.
    controller.pickChannel(.ghz5, 36)
    controller.editRadio(.ghz5) { $0.width = 160 }
    #expect(try inspector(environment, .ghz5).widths.first { $0.width == 160 }?.disabledReason == nil)
    // Back to Auto: 160 MHz needs DFS, so the width drops.
    controller.setAutoChannel(.ghz5, true)
    #expect(controller.radioEdits?.current(.ghz5)?.width == 80)
    #expect(controller.radioEdits?.changeCount == 0)
}

@Test func widthFitsTheBondingGroups() {
    let five = [36, 40, 44, 48, 52, 56, 60, 64] + Array(stride(from: 100, through: 140, by: 4))
    #expect(WiFiLane.fits(band: .ghz5, channel: 100, width: 160, channels: five))
    #expect(!WiFiLane.fits(band: .ghz5, channel: 132, width: 160, channels: five))
    #expect(WiFiLane.fits(band: .ghz5, channel: 116, width: 80, channels: five))
    // 132 to 144 at 80 MHz needs 144, which this list lacks.
    #expect(!WiFiLane.fits(band: .ghz5, channel: 132, width: 80, channels: five))
    #expect(!WiFiLane.fits(band: .ghz5, channel: 140, width: 40, channels: five))
    #expect(WiFiLane.fits(band: .ghz2_4, channel: 6, width: 40, channels: Array(1...13)))
    let six = Array(stride(from: 1, through: 93, by: 4))
    #expect(WiFiLane.fits(band: .ghz6, channel: 37, width: 320, channels: six))
    #expect(!WiFiLane.fits(band: .ghz6, channel: 85, width: 320, channels: six))
}

@MainActor @Test func sixGHzAutoGreysChannelsThatAreNotPreferred() async throws {
    let (environment, _) = await radiosEnvironment()
    let radio = try #require(environment.model.wireless?.radio(.ghz6))
    let lane = WiFiLane(radio: radio, autoSkips: nil)
    #expect(lane.skipped(1) && !lane.skipped(37))
    environment.wifi.editRadio(.ghz6) { $0.pscOnly = false }
    let open = WiFiLane(radio: radio.applying(environment.wifi.radioEdits?.current(.ghz6)), autoSkips: nil)
    #expect(!open.skipped(1))
}

// MARK: Warnings

@MainActor @Test func warningsFirstMatchWins() async throws {
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    #expect(try inspector(environment, .ghz2_4).warning == nil)
    controller.editRadio(.ghz2_4) { $0.width = 40 }
    #expect(try inspector(environment, .ghz2_4).warning == "40 MHz overlaps most neighbours on 2.4 GHz.")
    controller.editRadio(.ghz2_4) { $0.hwmode = "11ax/be" }
    let versions = try #require(try inspector(environment, .ghz2_4).warning)
    #expect(versions.hasSuffix("uses Wi-Fi 4. It would lose Wi-Fi."))

    controller.pickChannel(.ghz5, 100)
    #expect(try inspector(environment, .ghz5).warning
        == "Channel 100 needs a radar check before use. The radar check takes about 1 minute, or up to 10 minutes on some channels.")
}

@MainActor @Test func lowerPowerMovesTheDotsAndWarns() async throws {
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    let before = try #require(try inspector(environment, .ghz6).ruler)
    #expect(before.allSatisfy { !$0.weak })
    controller.editRadio(.ghz6) { $0.txPower = .low }
    let six = try inspector(environment, .ghz6)
    let after = try #require(six.ruler)
    #expect(zip(before, after).allSatisfy { $0.position < $1.position })
    #expect(after.filter(\.weak).count == 1)
    #expect(six.warning == "1 device would get a weak signal.")
    #expect(after.contains { $0.help.contains("about -72 dBm") })
}

@Test func noDeviceForThreeHundredTwentyMegahertz() {
    let original = WiFiRadioSettings(device: "MT7990_1_3", band: .ghz6, channel: 0, width: 160, hwmode: "11ax/be", txPower: .max, pscOnly: true)
    var wide = original
    wide.width = 320
    let wifi6 = WiFiDevice(mac: MACAddress("0e:e5:7b:da:22:c7")!, band: .ghz6, signal: -60, rate: WiFiRate(generation: .wifi6))
    let radio = WirelessRadio(band: .ghz6)
    #expect(WiFiRadioInspector.warning(band: .ghz6, original: original, current: wide, radio: radio, devices: [wifi6], offset: 0)
        == "No device here can use 320 MHz.")
    var wifi7 = wifi6
    wifi7.rate = WiFiRate(generation: .wifi7)
    #expect(WiFiRadioInspector.warning(band: .ghz6, original: original, current: wide, radio: radio, devices: [wifi7], offset: 0) == nil)
    // Without versions (no SSH) nothing is claimed.
    var unknown = wifi6
    unknown.rate = nil
    #expect(WiFiRadioInspector.warning(band: .ghz6, original: original, current: wide, radio: radio, devices: [unknown], offset: 0) == nil)
}

// MARK: Apply bar and review

@MainActor @Test func applyBarCountsChangesAndRevertClears() async throws {
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    #expect(controller.radioEdits == nil)
    controller.editRadio(.ghz5) { $0.txPower = .medium }
    #expect(WiFiRadioFormat.applyBar(try #require(controller.radioEdits)) == "1 change · 5 GHz restarts")
    controller.pickChannel(.ghz2_4, 6)
    #expect(WiFiRadioFormat.applyBar(try #require(controller.radioEdits)) == "2 changes · 2.4 and 5 GHz restart")
    controller.revertRadios()
    #expect(controller.radioEdits == nil)
}

@MainActor @Test func reviewListsRadioChangesWithTimes() async throws {
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    controller.editRadio(.ghz5) { $0.txPower = .medium }
    controller.pickChannel(.ghz5, 100)
    controller.reviewRadios()
    #expect(controller.sheet == .review)
    let page = try review(environment)
    #expect(page.title == "Apply 2 changes?")
    #expect(page.changes == ["5 GHz channel: Auto → 100", "5 GHz power: Max → Medium"])
    #expect(page.impacts.map { "\($0.bold) \($0.rest)" } == [
        "5 GHz restarts, about 20 s",
        "5 GHz checks channel 100 for radar first. The radar check takes about 1 minute, or up to 10 minutes on some channels.",
        "This Mac stays connected",
    ])
    #expect(page.before == page.after)
}

@MainActor @Test func dfsCheckRunsThenTheChangeApplies() async throws {
    let (environment, backend) = await radiosEnvironment()
    let controller = environment.wifi
    controller.pickChannel(.ghz5, 100)
    controller.reviewRadios()
    controller.apply()
    var sawRadar = false
    let deadline = ContinuousClock.now + .seconds(20)
    while controller.run?.outcome == nil, ContinuousClock.now < deadline {
        if controller.run?.step == .radarCheck { sawRadar = true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(sawRadar)
    let outcome = await waitForOutcome(environment)
    guard case .verifiedSuccess = outcome else { Issue.record("\(String(describing: outcome))"); return }
    #expect(try await backend.mockWiFi.readWireless().radio(.ghz5)?.configuredChannel == 100)
    #expect(WiFiReviewPresentation.progressTitle(.radarCheck, plan: try #require(controller.run?.plan)) == "Checking 5 GHz for radar…")
    controller.closeSheet()
    #expect(controller.radioEdits == nil)
}

@MainActor @Test func radarConflictShowsTheRadarText() async throws {
    let (environment, _) = await radiosEnvironment(apply: .radarFound)
    let controller = environment.wifi
    controller.pickChannel(.ghz5, 100)
    controller.reviewRadios()
    controller.apply()
    let outcome = try #require(await waitForOutcome(environment))
    let page = WiFiOutcomePresentation(outcome, run: try #require(controller.run))
    #expect(page.title == "Radar on 5 GHz")
    #expect(page.text == "5 GHz found radar during its check, so it cannot use channel 100 now. Choose another channel or Auto.")
}

@MainActor @Test func autoDFSWritesTheSkipListOverSSH() async throws {
    let (environment, backend) = await radiosEnvironment()
    let controller = environment.wifi
    controller.setAutoDFS(true)
    let change = try #require(controller.radioEdits?.change)
    #expect(change.options == [WiFiOptionEdit(section: "MT7990_1_2", band: .ghz5, setting: .autoSkips([144, 149, 153, 157, 161, 165]))])
    // With DFS, 160 MHz fits on Auto.
    #expect(try inspector(environment, .ghz5).widths.last?.disabledReason == nil)
    controller.reviewRadios()
    let page = try review(environment)
    #expect(page.changes == ["5 GHz DFS channels for Auto: On"])
    controller.apply()
    guard case .verifiedSuccess = await waitForOutcome(environment) else { Issue.record("not applied"); return }
    let sections = try await backend.mockWiFi.readOptions()
    #expect(sections.first { $0.section == "MT7990_1_2" }?.autoSkips == [144, 149, 153, 157, 161, 165])
}

@MainActor @Test func autoDFSOffDropsAWidthAutoCannotUse() async throws {
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    controller.setAutoDFS(true)
    controller.editRadio(.ghz5) { $0.width = 160 }
    controller.setAutoDFS(false)
    #expect(controller.radioEdits?.current(.ghz5)?.width == 80)
    #expect(controller.radioEdits?.changeCount == 0)
}

@MainActor @Test func countryShowsAsTheRouterReportsIt() async throws {
    let (environment, _) = await radiosEnvironment()
    #expect(WiFiRadioFormat.country(environment.model.wifiAir) == "Country: GB")
    #expect(WiFiRadioFormat.country(nil) == "Country: —")
}

@MainActor @Test func withoutSSHTheSSHControlsAreReadOnly() async throws {
    let (environment, _) = await radiosEnvironment(.sshOff)
    let controller = environment.wifi
    let five = try inspector(environment, .ghz5)
    #expect(five.editable && !five.autoDFSWritable && five.autoDFS == nil)
    controller.setAutoDFS(true)
    #expect(controller.radioEdits == nil)
    // RPC radio fields still change.
    controller.editRadio(.ghz5) { $0.txPower = .high }
    #expect(controller.radioEdits?.changeCount == 1)

    let group = try #require(controller.overview?.groups.first { $0.name == MockWiFiService.fast })
    controller.openNetwork(group)
    let draft = try #require(controller.draft)
    #expect(!draft.canWriteRoaming && draft.roamingHelp == nil)
}

// MARK: Roaming

@MainActor @Test func roamingSwitchesWriteEveryBandOfTheNetwork() async throws {
    let (environment, backend) = await radiosEnvironment()
    let controller = environment.wifi
    let group = try #require(controller.overview?.groups.first { $0.name == MockWiFiService.fast })
    controller.openNetwork(group)
    #expect(controller.draft?.canWriteRoaming == true)
    #expect(controller.draft?.roamingHelp == true && controller.draft?.fastRoaming == false)
    controller.draft?.fastRoaming = true
    let change = try #require(controller.draft?.change)
    #expect(change.networks.isEmpty)
    #expect(change.options.map(\.section) == ["wifi5g", "wifi6g"])
    controller.review(change)
    let page = try review(environment)
    #expect(page.changes == ["Flint Home Fast fast roaming: On"])
    #expect(page.impacts.first.map { "\($0.bold) \($0.rest)" } == "5 and 6 GHz restart, about 20 s")
    controller.apply()
    guard case .verifiedSuccess = await waitForOutcome(environment) else { Issue.record("not applied"); return }
    let sections = try await backend.mockWiFi.readOptions()
    #expect(sections.filter { $0.ieee80211r == true }.map(\.section) == ["wifi5g", "wifi6g"])
}

@MainActor @Test func anAddedBandGetsTheRoamingValues() async throws {
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    let group = try #require(controller.overview?.groups.first { $0.name == MockWiFiService.fast })
    controller.openNetwork(group)
    controller.draft?.bands.insert(.ghz2_4)
    controller.draft?.fastRoaming = true
    let change = try #require(controller.draft?.change)
    #expect(Set(change.options.filter { $0.setting == .fastRoaming(true) }.map(\.section)) == ["wifi2g", "wifi5g", "wifi6g"])
    // A removed band is not written.
    controller.draft?.bands.remove(.ghz6)
    #expect(controller.draft?.change.options.contains { $0.section == "wifi6g" } == false)
}

@MainActor @Test func missingRoamingFlagsAreOff() async throws {
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    let group = try #require(controller.overview?.groups.first { $0.name == MockWiFiService.fast })
    let wireless = try #require(environment.model.wireless)
    let sections = try #require(controller.sections).map { section in
        var section = section
        section.ieee80211k = nil
        section.bssTransition = nil
        section.ieee80211r = nil
        return section
    }
    let draft = WiFiNetworkDraft(group: group, wireless: wireless, isolate: nil, sections: sections)
    #expect(draft.canWriteRoaming && draft.roamingHelp == false && draft.fastRoaming == false)
}

// MARK: Snapshots

/// Writes PNGs of the Radios tab with staged edits and their review to the
/// test host's temporary folder (`wifi-snapshots`) when `ROUTEWELL_SNAPSHOTS=1`.
@MainActor @Test func writeWiFiRadiosSnapshotsWhenAsked() async throws {
    guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write<V: View>(_ name: String, _ view: V, size: CGSize?) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(origin: .zero, size: size ?? host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let file = "radios-\(name)-\(appearance == .aqua ? "light" : "dark").png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
        }
    }
    let (environment, _) = await radiosEnvironment()
    let controller = environment.wifi
    for band in WirelessBand.allCases {
        controller.selectedBand = band
        write("read-\(band.rawValue)", WiFiScreen().environment(environment.model).environment(environment), size: CGSize(width: 1100, height: 820))
    }
    controller.selectedBand = .ghz5
    controller.pickChannel(.ghz5, 100)
    controller.editRadio(.ghz5) { $0.txPower = .medium }
    write("manual-5g", WiFiScreen().environment(environment.model).environment(environment), size: CGSize(width: 1100, height: 820))
    controller.selectedBand = .ghz6
    controller.editRadio(.ghz6) { $0.txPower = .low }
    write("weak-6g", WiFiScreen().environment(environment.model).environment(environment), size: CGSize(width: 1100, height: 820))
    controller.reviewRadios()
    write("review", WiFiSheetHost(sheet: .review).environment(environment.model).environment(environment), size: nil)
}

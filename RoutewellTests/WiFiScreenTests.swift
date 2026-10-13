import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

/// A mock environment with the window visible and Wi-Fi selected, after the
/// RPC refresh and the SSH reads have finished.
@MainActor private func wifiEnvironment(_ scenario: MockWiFiService.Scenario = .today, tab: WiFiTab = .overview) async -> AppEnvironment {
    let backend = MockRouterBackend()
    backend.mockWiFi.setScenario(scenario)
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    model.subpages[.wifi] = tab.rawValue
    model.selection = .wifi
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    // The air read can be queued behind the probe.
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    return environment
}

@MainActor private func page(_ environment: AppEnvironment) throws -> WiFiOverviewPresentation {
    let overview = try #require(environment.wifi.overview)
    let wireless = try #require(environment.model.wireless)
    return WiFiOverviewPresentation(overview: overview, wireless: wireless, suggestions: environment.wifi.suggestions)
}

// MARK: Sidebar and Router

@Test func wifiFollowsRouterInTheSidebarAndShortcutsFollowTheOrder() {
    let order = SidebarDestination.allCases
    #expect(order.prefix(4) == [.overview, .router, .wifi, .network])
    #expect(SidebarDestination.wifi.title == "Wi-Fi")
    #expect(SidebarDestination.wifi.symbol == "wifi")
    #expect(SidebarDestination.wifi.group == .monitoring)
    #expect(SidebarDestination.wifi.shortcut == "3")
    #expect(SidebarDestination.network.shortcut == "4")
    #expect(order.compactMap(\.shortcut).count == 9)
    #expect(SidebarDestination.wifi.segments == ["Overview", "Radios", "Multi-link"])
    #expect(SidebarDestination.wifi.showsSubtitle)
    #expect(!RouterSegment.allCases.map(\.rawValue).contains("Wi-Fi"))
}

@MainActor @Test func sidebarCountsWiFiDevicesOnline() async {
    let environment = await wifiEnvironment()
    #expect(environment.model.wifiDevicesOnline == 5)
    let empty = AppModel(mode: .mock)
    #expect(empty.wifiDevicesOnline == nil)
}

@MainActor @Test func routerOverviewWiFiRowOpensWiFi() async {
    let environment = await wifiEnvironment()
    let row = RouterOverviewModel(snapshot: environment.model.snapshot!, wireless: environment.model.wireless).services[2]
    #expect(row.label == "Wi-Fi")
    #expect(row.opens == .wifi)
    #expect(row.value == "3 radios · 5 clients")
}

// MARK: Tabs in each scenario

@MainActor @Test func everyTabLaysOutInEveryScenario() async {
    for scenario in MockWiFiService.Scenario.allCases {
        let environment = await wifiEnvironment(scenario)
        for tab in WiFiTab.allCases {
            environment.model.subpages[.wifi] = tab.rawValue
            let view = NSHostingView(rootView: WiFiScreen().environment(environment.model).environment(environment).frame(width: 1100, height: 820))
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0, "\(scenario) \(tab)")
        }
        switch scenario {
        case .methodNotFound:
            #expect(environment.model.wifiCapability.state == .unsupported)
            #expect(environment.model.wireless == nil)
        case .sshOff:
            #expect(environment.wifi.airState == .notSetUp)
            #expect(environment.model.wifiAir == nil)
            #expect(environment.model.wireless != nil)
        case .multiLinkFails:
            #expect(environment.model.wifi?.mlo == .failure(.timeout))
            #expect(environment.model.wireless != nil)
        default:
            #expect(environment.wifi.airState == .available, "\(scenario)")
            #expect(environment.model.wifiAir?.stations?.count == 5, "\(scenario)")
        }
    }
}

@MainActor @Test func todayOverviewShowsTheMapNetworksSuggestionsAndTiles() async throws {
    let environment = await wifiEnvironment()
    let today = try page(environment)
    #expect(today.deviceCount == 5)
    #expect(today.signalLine == "No weak signals")
    #expect(today.showsRings)
    #expect(today.sectorLabels.map(\.label) == ["3", "Not used", "2"])
    #expect(today.dots.count == 5)
    #expect(today.cards.map(\.name) == ["Flint Home", "Flint Home Fast"])
    #expect(today.cards.map(\.count) == ["3", "2"])
    #expect(today.addTiles == [.guest, .iot, .multiLink])
    #expect(today.suggestions.map(\.title) == [
        "iPhone and iPhone can use a faster band",
        "Multi-link is ready for 2 Wi-Fi 7 devices",
        "Watch can move to its own network",
        "5 GHz can use more channels with DFS",
    ])
    // Actions that open a later sheet stay hidden.
    #expect(today.suggestions.map { $0.action?.label } == [nil, "Set Up…", nil, "Review"])
    #expect(today.radios.map(\.now) == ["Ch 9 · Auto width", "Ch 44 · 80 MHz", "Ch 37 · 160 MHz"])
    #expect(today.radios.map(\.mode) == ["Auto", "Auto", "Auto"])
    #expect(today.radios[1].dfs != nil)
    #expect(today.radios[0].dfs == nil)

    let phone = try #require(today.dots.first { $0.device.generation == .wifi6 && $0.device.band == .ghz2_4 }?.device)
    #expect(WiFiOverviewPresentation.tooltip(phone) == "iPhone\nFlint Home · 2.4 GHz · Wi-Fi 6\nFair signal (-61 dBm) · can use a faster band")
    #expect(WiFiOverviewPresentation.accessibilityLabel(phone) == "iPhone, 2.4 GHz, -61 dBm")
}

@MainActor @Test func otherScenariosChangeCardsAndSuggestions() async throws {
    let after = try page(await wifiEnvironment(.afterSuggestions))
    #expect(after.cards.map(\.name) == ["Flint Home", "Flint Home 7"])
    #expect(after.cards[1].multiLink)
    #expect(after.cards[1].count == "2")
    #expect(after.suggestions.map(\.suggestion.kind) == [.ownNetwork])
    #expect(after.radios[1].now == "Ch 100 · 160 MHz")

    let guests = try page(await wifiEnvironment(.guestAndIoT))
    #expect(guests.cards.map(\.name) == ["Flint Home", "Flint Home Fast", "Flint Home Guest", "Flint Home IoT"])
    #expect(guests.cards.map(\.kind) == [.main, .main, .guest, .iot])
    #expect(guests.addTiles == [.multiLink])

    let failing = try page(await wifiEnvironment(.multiLinkFails))
    #expect(!failing.addTiles.contains(.multiLink))
}

@MainActor @Test func dismissedSuggestionsStayGoneForTheSession() async throws {
    let environment = await wifiEnvironment()
    let first = try #require(environment.wifi.suggestions.first)
    environment.wifi.highlighted = Set(first.devices)
    environment.wifi.dismiss(first)
    #expect(!environment.wifi.suggestions.contains(first))
    #expect(environment.wifi.highlighted.isEmpty)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(!environment.wifi.suggestions.contains(first))
}

@MainActor @Test func suggestionActionsOpenTheirTab() async {
    let environment = await wifiEnvironment()
    environment.wifi.openRadios(.ghz5)
    #expect(environment.model.subpages[.wifi] == WiFiTab.radios.rawValue)
    #expect(environment.wifi.selectedBand == .ghz5)
    environment.wifi.openMultiLink()
    #expect(environment.model.subpages[.wifi] == WiFiTab.multiLink.rawValue)
}

// MARK: SSH off

@MainActor @Test func withoutSSHBandsStayAndSignalShowsADash() async throws {
    let environment = await wifiEnvironment(.sshOff)
    let page = try page(environment)
    #expect(page.deviceCount == 5)
    #expect(page.signalLine == nil)
    #expect(!page.showsRings)
    #expect(page.suggestions.isEmpty)
    #expect(page.dots.allSatisfy { hypot($0.x - 250, $0.y - 248) - WiFiOverviewPresentation.unknownRadius < 0.001 })
    #expect(page.cards.map(\.count) == ["3", "2"])
    let device = try #require(page.dots.first?.device)
    #expect(WiFiOverviewPresentation.tooltip(device).hasSuffix("Signal —"))
    #expect(WiFiNotes.sshNote(.notSetUp) == "Signal, Wi-Fi versions, and the channels Auto skips need SSH.")
    #expect(WiFiNotes.sshNote(.available) == nil)

    let wireless = try #require(environment.model.wireless)
    let five = WiFiRadioInspector(radio: try #require(wireless.radio(.ghz5)), band: .ghz5, devices: environment.wifi.overview!.devices, air: nil)
    #expect(five.rows.first { $0.label == "DFS channels" }?.value == "—")
    let low = WiFiRadioInspector(radio: try #require(wireless.radio(.ghz2_4)), band: .ghz2_4, devices: environment.wifi.overview!.devices, air: nil)
    #expect(low.ruler == nil)
    let lane = WiFiLane(radio: try #require(wireless.radio(.ghz2_4)), autoSkips: nil)
    #expect(!lane.skipped(13))
}

// MARK: Radios

@MainActor @Test func radiosShowValuesAndTheChannelsAutoSkips() async throws {
    let environment = await wifiEnvironment(tab: .radios)
    let wireless = try #require(environment.model.wireless)
    let air = environment.model.wifiAir
    let devices = try #require(environment.wifi.overview?.devices)
    let five = WiFiRadioInspector(radio: try #require(wireless.radio(.ghz5)), band: .ghz5, devices: devices, air: air)
    #expect(five.deviceLine == "No devices")
    #expect(five.rows.map(\.label) == ["Channel", "Width", "DFS channels", "Power"])
    #expect(five.rows.map(\.value) == ["Auto · 44", "80 MHz", "Off", "Max"])
    #expect(five.advanced.first?.value == "All (4 to 7)")
    #expect(five.ruler?.isEmpty == true)
    let six = WiFiRadioInspector(radio: try #require(wireless.radio(.ghz6)), band: .ghz6, devices: devices, air: air)
    #expect(six.rows.first { $0.label == "Preferred channels only" }?.value == "On")
    #expect(six.advanced.first?.value == "Wi-Fi 6E and 7")
    let low = WiFiRadioInspector(radio: try #require(wireless.radio(.ghz2_4)), band: .ghz2_4, devices: devices, air: air)
    #expect(low.deviceLine == "3 devices")
    #expect(low.ruler?.count == 3)

    let lane = WiFiLane(radio: try #require(wireless.radio(.ghz2_4)), autoSkips: air?.autoSkips(device: "MT7990_1_1"))
    #expect(lane.skipped(12) && lane.skipped(13) && !lane.skipped(11))
    #expect(lane.block == [7, 8, 9, 10, 11])
}

@Test func laneBlocksFollowTheBondingGroups() {
    let five = [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140]
    #expect(WiFiLane.block(band: .ghz5, channel: 44, width: 80, channels: five) == [36, 40, 44, 48])
    #expect(WiFiLane.block(band: .ghz5, channel: 100, width: 160, channels: five) == [100, 104, 108, 112, 116, 120, 124, 128])
    #expect(WiFiLane.block(band: .ghz5, channel: 52, width: 20, channels: five) == [52])
    #expect(WiFiLane.block(band: .ghz2_4, channel: 1, width: 40, channels: Array(1...13)) == [1, 2, 3, 4, 5, 6, 7])
    #expect(WiFiLane.block(band: .ghz2_4, channel: 165, width: 20, channels: Array(1...13)) == nil)
    let six = Array(stride(from: 1, through: 93, by: 4))
    #expect(WiFiLane.block(band: .ghz6, channel: 37, width: 160, channels: six) == [33, 37, 41, 45, 49, 53, 57, 61])
}

// MARK: Multi-link

@MainActor @Test func multiLinkOffShowsWiFi7DevicesWithoutAnEstimate() async throws {
    let environment = await wifiEnvironment(tab: .multiLink)
    let mlo = try #require(try? environment.model.wifi?.mlo.get())
    let off = WiFiMultiLinkPresentation(mlo: mlo, devices: try #require(environment.wifi.overview?.devices), air: environment.model.wifiAir)
    #expect(!off.isOn)
    #expect(off.cards.map(\.name) == ["iPhone", "Mac"])
    #expect(off.cards.map(\.sub) == ["Wi-Fi 7 · one band now", "Wi-Fi 7 · one band now"])
    #expect(off.cards.map(\.rate) == ["0.3", "2.2"])
    #expect(off.others == 3)
    #expect(off.subtitle == "2 of your devices can use two bands at the same time.")

    let on = await wifiEnvironment(.multiLinkOn, tab: .multiLink)
    let link = WiFiMultiLinkPresentation(mlo: try #require(try? on.model.wifi?.mlo.get()), devices: try #require(on.wifi.overview?.devices),
                                         air: on.model.wifiAir)
    #expect(link.isOn)
    #expect(link.name == "Flint Home 7")
    #expect(link.bands == [.ghz5, .ghz6])
    #expect(link.cards.count == 2)
    #expect(link.subtitle == "Multi-link on 5 GHz + 6 GHz · 2 devices")
    #expect(link.linkMode == "EMLSR")
    #expect(link.others == 3)
}

// MARK: Snapshots

/// Writes PNGs of each Wi-Fi tab in each scenario, light and dark, to the
/// test host's temporary folder (`wifi-snapshots`) when `ROUTEWELL_SNAPSHOTS=1`.
/// For reviewing the layout; it checks nothing else.
@MainActor @Test func writeWiFiSnapshotsWhenAsked() async throws {
    guard ProcessInfo.processInfo.environment["ROUTEWELL_SNAPSHOTS"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write(_ name: String, _ environment: AppEnvironment) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = WiFiScreen().environment(environment.model).environment(environment)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(x: 0, y: 0, width: 1100, height: 820)
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

    for scenario in MockWiFiService.Scenario.allCases {
        let environment = await wifiEnvironment(scenario)
        for tab in WiFiTab.allCases {
            environment.model.subpages[.wifi] = tab.rawValue
            write("\(scenario.rawValue)-\(tab.rawValue.lowercased())", environment)
        }
    }
}

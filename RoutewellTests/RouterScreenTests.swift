import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

private let british = Locale(identifier: "en_GB")

/// A mock environment with the window visible and Router selected, after
/// one refresh has read the Router details.
@MainActor private func routerEnvironment(segment: RouterSegment = .overview) async -> (AppEnvironment, MockRouterBackend) {
    let backend = MockRouterBackend()
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    model.subpages[.router] = segment.rawValue
    model.selection = .router
    await environment.refresh.waitForRefresh()
    return (environment, backend)
}

// MARK: Toolbar and SSH segments

@Test func routerToolbarHasTenSegmentsAndNoSubtitle() {
    #expect(SidebarDestination.router.segments == ["Overview", "Ports", "Wi-Fi", "Multi-WAN", "DNS", "SQM", "Performance", "Storage", "Firmware", "Logs"])
    #expect(!SidebarDestination.router.showsSubtitle)
    #expect(SidebarDestination.overview.showsSubtitle)
}

@MainActor @Test func portsStorageAndLogsAskForSSHAndOpenRouterSettings() {
    #expect(RouterSegment.allCases.filter(\.requiresSSH) == [.ports, .storage, .logs])
    let model = AppModel(mode: .mock)
    model.settingsTab = .general
    var opened = false
    SSHRequiredView.openRouterSettings(model) { opened = true }
    #expect(model.settingsTab == .router)
    #expect(opened)
}

@MainActor @Test func everySegmentLaysOut() async {
    let (environment, _) = await routerEnvironment()
    for segment in RouterSegment.allCases {
        environment.model.subpages[.router] = segment.rawValue
        let view = NSHostingView(rootView: RouterScreen().environment(environment.model).environment(environment).frame(width: 1100, height: 800))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0, "\(segment.rawValue)")
    }
}

// MARK: Overview and Performance

@MainActor @Test func overviewStatStripUsesTheMockupTexts() throws {
    var router = RouterStatus()
    router.cpuUtilizationPercent = .value(2.9)
    router.loadAverages = [2.33, 2.32, 2.28]
    router.memoryUsedBytes = 826_214_973
    router.memoryTotalBytes = 2_083_059_139
    router.temperatureCelsius = .value(54.1)
    router.uptimeSeconds = 2 * 86_400 + 4 * 3_600 + 52 * 60
    let boot = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 18, minute: 17)))
    router.routerTime = boot.addingTimeInterval(TimeInterval(router.uptimeSeconds!))
    let strip = RouterOverviewModel.strip(router, locale: british)
    #expect(strip.map(\.title) == ["CPU", "Memory", "Temperature", "Uptime"])
    #expect(strip[0].value == "2.9" && strip[0].unit == "%" && strip[0].detail == "Load 2.33 / 2.32 / 2.28")
    #expect(strip[1].value == "39.7" && strip[1].unit == "%" && strip[1].detail == "787.94 MiB of 1.94 GiB used")
    #expect(strip[2].value == "54.1" && strip[2].unit == "°C" && strip[2].detail == "Normal · below 65 °C")
    #expect(strip[3].value == "2 d 4 h 52 m" && strip[3].detail == "Last reboot 19 Sep, 18:17")
}

@MainActor @Test func liveOverviewNeverInventsCPUUtilization() {
    var router = RouterStatus()
    router.loadAverages = [2.41, 2.34, 2.29]
    let strip = RouterOverviewModel.strip(router, locale: british)
    #expect(strip[0].value == "Unknown" && strip[0].unit == nil && strip[0].detail == "Load 2.41 / 2.34 / 2.29")
    #expect(strip[1].value == "Unknown")
    #expect(strip[2].detail == "Not reported by the router")
    #expect(strip[3].detail == "Last reboot unknown")
    #expect(RouterFormat.temperatureGuidance(70) == "Elevated · 65–79 °C")
    #expect(RouterFormat.temperatureGuidance(80) == "High · 80 °C or above")
}

@MainActor @Test func overviewServicesShowVersionOnlyAndAPrivateWANIsNotPublic() {
    var snapshot = MockRouterBackend.snapshot(at: .now)
    snapshot.internet.publicAddress = "172.16.10.5"
    snapshot.adGuard.version = "0.107.73"
    let overview = RouterOverviewModel(snapshot: snapshot, wireless: MockRouterService.wireless, locale: british)
    #expect(overview.network[1].value == "Unknown")
    #expect(overview.network[1].detail == "The WAN address 172.16.10.5 is private")
    #expect(overview.services[0].value == "Active")
    #expect(overview.services[0].detail == "0.107.73 · process ID needs SSH")
    #expect(overview.services[2].value == "3 radios · 8 clients")
    #expect(overview.services[3].value == "2 % used · 56.6 GiB available")
    #expect(overview.identity.map(\.label) == ["Model", "Hostname", "Firmware", "OpenWrt", "Kernel", "Architecture"])
    #expect(overview.identity[4].value == "5.4.281")
    #expect(RouterOverviewModel.footnote == "Read-only telemetry reported by the router. Change settings in the router UI.")
    snapshot.internet.publicAddress = "86.181.58.147"
    #expect(RouterOverviewModel(snapshot: snapshot, wireless: nil).network[1].value == "86.181.58.147")
}

@MainActor @Test func performanceSessionCountsReadsAndResets() async {
    let (environment, _) = await routerEnvironment(segment: .performance)
    let model = environment.model
    #expect(model.telemetrySession.observations >= 1)
    #expect(model.telemetrySession.peakCPUPercent == 2.9)
    let performance = RouterPerformanceModel(snapshot: model.snapshot!, history: model.telemetryHistory, session: model.telemetrySession, locale: british)
    #expect(performance.strip.map(\.title) == ["CPU", "Load average", "Memory", "Temperature"])
    #expect(performance.strip[1].detail == "1 · 5 · 15 min · not CPU percentages")
    #expect(performance.session.map(\.label) == ["Observations", "Peak CPU", "Peak memory", "Peak temperature", "Router uptime"])
    #expect(performance.summary(hostname: "flint-demo").contains("Load average"))
    await environment.refresh.resetTelemetrySession()
    #expect(model.telemetrySession.observations == 0)
    #expect(model.telemetrySession.peakCPUPercent == nil)
    #expect(RouterFormat.uptimeLong(2 * 86_400 + 4 * 3_600 + 52 * 60) == "2 days 4 hours 52 minutes")
    #expect(RouterFormat.uptimeLong(3_660) == "1 hour 1 minute")
}

// MARK: SQM

@Test func sqmControlsAreFullyDisabledWhenTheRouterHasNoNativeAPI() {
    let missing = Capability(.unsupported, evidence: .methodNotFound(method: "sqm.get_config"))
    let unavailable = RouterSQMModel(capability: missing, configuration: nil, failure: .unavailable, legacyEnabled: .value(false))
    #expect(unavailable.controlsDisabled)
    #expect(unavailable.status[0].value == "Unavailable" && unavailable.status[0].tone == .degraded)
    #expect(unavailable.status[2].value == "Never")
    #expect(!unavailable.switchOn)
    // The rule is the capability, not the label: even with writes, -32601 disables every control.
    #expect(RouterSQMModel(capability: missing, configuration: nil, failure: .unavailable, legacyEnabled: .unknown, writesAvailable: true).controlsDisabled)
    #expect(RouterSQMModel(capability: Capability(), configuration: nil, failure: .timeout, legacyEnabled: .unknown, writesAvailable: true).controlsDisabled)
    let supported = Capability(.supported, evidence: .successfulResponse)
    #expect(!RouterSQMModel(capability: supported, configuration: SQMConfiguration(enabled: .value(false)), failure: nil, legacyEnabled: .unknown, writesAvailable: true).controlsDisabled)
    // No SQM writes: the available state is read-only too.
    let available = RouterSQMModel(capability: supported, configuration: SQMConfiguration(enabled: .value(true), queueDiscipline: "cake", upload: "40", download: "450"),
                                   failure: nil, legacyEnabled: .unknown)
    #expect(available.controlsDisabled)
    #expect(available.status[0].value == "Available")
    #expect(available.status[1].value == "↑ 40 Mbps · ↓ 450 Mbps")
    #expect(available.switchOn && available.upload == "40")
}

@MainActor @Test func mockSQMScenariosReachTheModel() async {
    let (environment, backend) = await routerEnvironment(segment: .sqm)
    #expect(environment.model.sqmCapability.state == .unsupported)
    #expect(environment.model.sqm == nil)
    await backend.mockRouter.setSQMBehavior(.available)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(environment.model.sqmCapability.state == .supported)
    #expect(environment.model.sqm?.enabled == .value(false))
}

// MARK: Wi-Fi, Multi-WAN, DNS

@Test func wifiTablesShowUnknownTXPowerAndAutoChannels() {
    let wifi = RouterWiFiModel(wireless: MockRouterService.wireless, onlineByBand: [.ghz2_4: 5, .ghz6: 3], signals: nil)
    #expect(wifi.strip.map(\.value) == ["3", "9", "8", "Unknown"])
    #expect(wifi.strip[0].detail == "2.4, 5 and 6 GHz")
    #expect(wifi.strip[1].detail == "3 active · 6 disabled")
    #expect(wifi.strip[2].detail == "5 on 2.4 GHz · 3 on 6 GHz")
    #expect(wifi.strip[3].detail == "Signal is not reported by the router")
    #expect(wifi.bands.map(\.title) == ["2.4 GHz", "5 GHz", "6 GHz"])
    #expect(wifi.bands[0].radio == "MT7990_1_1")
    let active = wifi.bands[0].rows[0].map(\.text)
    #expect(active == ["Flint Home", "rai0", "Active", "2g", "9", "40 MHz", "5", "Unknown"])
    let disabled = wifi.bands[0].rows[1].map(\.text)
    #expect(disabled == ["GL-BE14000-2bd-Guest", "rai1", "Disabled", "2g", "Auto", "40 MHz", "0", "Unknown"])
    // 5 GHz has no band count, so no per-SSID count either.
    #expect(wifi.bands[1].rows[0][6].text == "—")
    #expect(RouterWiFiModel.columns.last == "TX power")
    #expect(wifi.summary(hostname: "flint-demo").contains("TX power: Unknown"))
    // 4.9.1 sends `htmode` as `auto`, `80`, `160` and `txpower` as `Max`.
    let radio = WirelessRadio(band: .ghz2_4, htmode: "auto", txPower: "Max", networks: [WirelessNetwork(ssid: "A", enabled: .value(true))])
    let live = RouterWiFiModel.row(radio.networks[0], radio: radio, onlineByBand: nil).map(\.text)
    #expect(live[5] == "Auto" && live[7] == "Max")
    #expect(RouterWiFiModel.row(radio.networks[0], radio: WirelessRadio(htmode: "80", networks: radio.networks), onlineByBand: nil)[5].text == "80 MHz")
    let weak = RouterWiFiModel(wireless: MockRouterService.wireless, onlineByBand: nil, signals: [-50, -80])
    #expect(weak.strip[3].value == "1" && weak.strip[3].detail == "Below −75 dBm")
}

@Test func multiWANStaysHonestlyUnknown() {
    var internet = InternetStatus()
    internet.uplinks = [UplinkInterface(name: "wan"), UplinkInterface(name: "wwan")]
    internet.publicAddress = "172.16.10.5"
    internet.gateway = "172.16.10.72"
    let wan = RouterMultiWANModel(internet: internet, tracker: WANPathTracker())
    #expect(wan.multiWAN.map(\.value) == ["Unknown", "Unavailable", "0"])
    #expect(wan.multiWAN[1].detail == "Multi-WAN telemetry is not exposed by this firmware.")
    #expect(wan.activePath.map(\.value) == ["Unknown", "Not configured"])
    #expect(wan.rows.map { $0.map(\.text) } == [
        ["wan", "Unknown", "Ethernet", "172.16.10.5", "—", "—", "—"],
        ["wwan", "Unknown", "Unknown", "—", "—", "—", "—"],
    ])
    #expect(wan.history.value == "None")
    #expect(RouterMultiWANModel.footnote == "Observations only. Multi-WAN policy is configured in the router UI.")
    internet.uplinks[0].up = .value(true)
    let up = RouterMultiWANModel(internet: internet, tracker: WANPathTracker())
    #expect(up.activePath[0].value == "wan · 172.16.10.72")
    #expect(up.rows[0][1] == RouterCell(text: "Up", tone: .healthy))
}

@Test func dnsShowsAdGuardPortAndTheVerbatimFootnote() {
    let dns = RouterDNSModel(snapshot: MockRouterBackend.snapshot(at: .now))
    #expect(dns.path == "Client → Router → AdGuard Home → Upstream")
    #expect(dns.services[1].value == "Running")
    #expect(dns.services[1].detail == "0.107.65 · port 3053")
    #expect(dns.services[2].value == "Yes")
    #expect(dns.services[3].value == "Unknown")
    #expect(dns.configuration[0].value == "Unknown")
    #expect(dns.upstreams == ["192.0.2.53", "192.0.2.54"])
    #expect(RouterDNSModel.footnote == "Client DNS activity is visible only when it passes through AdGuard Home. VPN or direct encrypted DNS paths may not be observable.")
}

// MARK: Firmware

@MainActor @Test func firmwareStatesNeverCheckedUnableAndAvailable() {
    let router = MockRouterBackend.snapshot(at: .now).router
    let never = RouterFirmwareModel(router: router, state: nil)
    #expect(never.statusRow.value == "Not checked" && never.statusRow.detail == "Never checked")
    #expect(never.latest == "—" && !never.releaseNotesAvailable)
    let token = SessionToken(profileID: "Home mock", revision: 1)
    let checkedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let unable = RouterFirmwareModel(router: router, state: .init(token: token, check: FirmwareCheck(status: .unableToCheck(.failed(.network)), checkedAt: checkedAt)), locale: british)
    #expect(unable.statusRow.value == "Unable to check" && unable.statusRow.tone == .degraded)
    #expect(unable.statusRow.detail?.hasPrefix("Last checked ") == true)
    let available = RouterFirmwareModel(router: router, state: .init(token: token, check: FirmwareCheck(
        current: .value("4.9.1"), latest: .value("4.9.2"), status: .updateAvailable, releaseNotes: "Notes", checkedAt: checkedAt)))
    #expect(available.statusRow.value == "Update available")
    #expect(available.latest == "4.9.2" && available.releaseNotesAvailable)
    #expect(RouterFirmwareModel(router: router, state: .init(token: token, check: nil, checking: true)).statusRow.value == "Checking…")
    let lifecycle = RouterFirmwareModel.lifecycle(baseline: nil, check: nil)
    #expect(lifecycle.baselineValue == "None saved" && lifecycle.checkValue == "Not run" && !lifecycle.runCheckEnabled)
    #expect(lifecycle.footnote == "No firmware lifecycle check has been run.")
}

@MainActor @Test func firmwareCheckAndBaselineRunThroughTheController() async {
    let (environment, backend) = await routerEnvironment(segment: .firmware)
    let router = environment.router
    #expect(router.firmware == nil)
    await backend.mockRouter.setFirmwareBehavior(.updateAvailable)
    await router.checkForUpdates()
    #expect(router.firmware?.check?.status == .updateAvailable)
    #expect(router.firmware?.checking == false)
    // Mock mode has no router web interface.
    #expect(router.routerURL() == nil)

    #expect(router.baseline == nil)
    await router.saveBaseline()
    #expect(router.baseline?.state.firmware == "4.9.1")
    #expect(router.baseline?.state.wifiRadios == 3)
    await router.runPostUpgradeCheck()
    #expect(router.postUpgradeCheck?.differences.isEmpty == true)
    let lifecycle = RouterFirmwareModel.lifecycle(baseline: router.baseline, check: router.postUpgradeCheck)
    #expect(lifecycle.checkValue == "No changes" && lifecycle.runCheckEnabled)
}

@MainActor @Test func aFirmwareCheckFromAnotherSessionIsNotShown() async {
    let (environment, backend) = await routerEnvironment(segment: .firmware)
    await backend.mockRouter.setFirmwareBehavior(.upToDate)
    await environment.router.checkForUpdates()
    #expect(environment.router.firmware?.check?.status == .upToDate)
    environment.switchMockProfile(AppEnvironment.mockProfiles[1])
    await environment.waitUntilReady()
    #expect(environment.router.firmware == nil)
}

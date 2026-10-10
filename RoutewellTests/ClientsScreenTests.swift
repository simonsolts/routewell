import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

private func mac(_ raw: String) -> MACAddress { MACAddress(raw)! }

/// Builds a mock environment with the window visible and Clients selected,
/// after one refresh has read the inventory.
@MainActor private func clientsEnvironment(scenario: MockClientsService.Scenario = .newDevices) async -> (AppEnvironment, MockRouterBackend) {
    let backend = MockRouterBackend()
    await backend.setClientsScenario(scenario)
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    model.selection = .clients
    await environment.refresh.waitForRefresh()
    return (environment, backend)
}

@MainActor @Test func paneVisibilityHeightAndSectionPersist() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(mode: .mock)
    let persistence = PersistenceController(model: model, store: AtomicJSONStore(directory: directory), credentials: InMemoryCredentialStore())
    await persistence.load()
    #expect(model.clientsDetailsVisible)
    model.clientsDetailsVisible = false
    model.clientsDetailsHeight = 420
    model.clientsDetailsSection = ClientDetailsSection.dnsActivity.rawValue
    await persistence.flush()

    let restoredModel = AppModel(mode: .mock)
    let restored = PersistenceController(model: restoredModel, store: AtomicJSONStore(directory: directory), credentials: InMemoryCredentialStore())
    await restored.load()
    #expect(!restoredModel.clientsDetailsVisible)
    #expect(restoredModel.clientsDetailsHeight == 420)
    #expect(restoredModel.clientsDetailsSection == "dnsActivity")
}

@MainActor @Test func olderSettingsFileLoadsPaneDefaultsWithoutRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old = #"{"version":1,"value":{"showInMenuBar":false,"refreshIntervalSeconds":60,"pauseWhenHidden":true,"showStatusBar":true}}"#
    try Data(old.utf8).write(to: directory.appendingPathComponent("settings.json"))
    let model = AppModel(mode: .mock)
    let persistence = PersistenceController(model: model, store: AtomicJSONStore(directory: directory), credentials: InMemoryCredentialStore())
    await persistence.load()
    #expect(persistence.recoveryNotice == nil)
    #expect(!model.showInMenuBar)
    #expect(model.refreshIntervalSeconds == 60)
    #expect(model.clientsDetailsVisible)
    #expect(model.clientsDetailsHeight == 300)
    #expect(model.clientsDetailsSection == "overview")
}

@Test func multiSelectDisablesThePane() {
    let entries = [
        ClientListEntry(mac: mac("AA:00:00:00:00:01"), client: Client(mac: mac("AA:00:00:00:00:01")), record: nil),
        ClientListEntry(mac: mac("AA:00:00:00:00:02"), client: Client(mac: mac("AA:00:00:00:00:02")), record: nil),
    ]
    #expect(ClientsPaneContent.resolve(selection: [], entries: entries) == .none)
    #expect(ClientsPaneContent.resolve(selection: [entries[0].mac], entries: entries) == .single(entries[0]))
    #expect(ClientsPaneContent.resolve(selection: [entries[0].mac, entries[1].mac], entries: entries) == .multiple(2))
    #expect(ClientsPaneContent.resolve(selection: [mac("AA:00:00:00:00:09")], entries: entries) == .none)
}

@Test func overviewShowsUnknownForUnreadValues() {
    let client = Client(mac: mac("66:29:ea:33:fb:78"), ip: "192.168.8.192", hostname: "iPhone", online: .value(true),
                        connection: ClientConnection(medium: .value(.wifi), band: "2.4 GHz", ssid: "Homewifi", interface: "rai0"),
                        signal: .value(-66), dnsQueries: .value(12_550), dnsBlocked: .value(107))
    let record = DeviceRecord(mac: client.mac, favourite: true, firstSeen: .now, lastSeen: .now, category: .phone)
    let entry = ClientListEntry(mac: client.mac, client: client, record: record)
    let groups = Dictionary(uniqueKeysWithValues: ClientsFormat.overviewGroups(entry).map { ($0.title, $0.rows) })
    #expect(groups.keys.sorted() == ["Connection", "DHCP", "Identity"])
    func value(_ group: String, _ label: String) -> String? { groups[group]?.first { $0.label == label }?.value }
    #expect(value("Identity", "Vendor") == "Not resolvable (randomised)")
    #expect(value("Identity", "MAC address") == "66:29:ea:33:fb:78")
    #expect(value("Identity", "Category") == "Phone")
    #expect(value("Connection", "Interface") == "Wi-Fi · 2.4 GHz · Homewifi")
    #expect(value("Connection", "Signal") == "Fair -66 dBm")
    #expect(value("Connection", "Radio") == "Unknown")
    #expect(value("Connection", "Channel · width") == "Unknown")
    for label in ["Assignment", "Lease", "Address", "Remaining"] {
        #expect(value("DHCP", label) == "Unknown")
    }
    let metrics = ClientsFormat.overviewMetrics(entry, now: .now)
    #expect(metrics.map(\.title) == ["Queries", "Blocked", "Block rate", "VPN routing"])
    #expect(metrics[1].emphasised)
    #expect(metrics[2].value.hasPrefix("0.9"))
    #expect(metrics[3].value == "Unknown")
}

@Test func liveShapedClientShowsHonestUnknowns() {
    let client = Client(mac: mac("a4:83:e7:12:9c:01"), ip: "198.51.100.3", online: .value(false), connection: ClientConnection(interface: "ra0"))
    let entry = ClientListEntry(mac: client.mac, client: client, record: nil)
    let row = ClientRow(entry: entry, nameMode: .automatic, now: .now)
    #expect(row.name == "Unknown device")
    #expect(row.connection == "ra0")
    #expect(row.signal == nil)
    #expect(row.queries == "—" && row.blocked == "—" && row.rate == "—")
    #expect(row.status.text == "Offline")
    #expect(ClientRow(entry: entry, nameMode: .hostname, now: .now).name == "—")
    let vendor = ClientsFormat.overviewGroups(entry)[0].rows.first { $0.label == "Vendor" }?.value
    #expect(vendor == "Unknown")
}

@Test func statusAndCountText() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(ClientsFormat.relative(now.addingTimeInterval(-20), now: now) == "Just now")
    #expect(ClientsFormat.relative(now.addingTimeInterval(-3 * 3_600), now: now) == "3 h ago")
    #expect(ClientsFormat.relative(now.addingTimeInterval(-2 * 86_400), now: now) == "2 d ago")
    let record = DeviceRecord(mac: mac("AA:00:00:00:00:01"), firstSeen: now, lastSeen: now.addingTimeInterval(-6 * 86_400))
    let absent = ClientListEntry(mac: record.mac, client: nil, record: record)
    #expect(ClientsFormat.status(absent, now: now).text == "Offline · 6 d ago")
    #expect(ClientsFormat.rate(.unavailable) == "–")
    let wired = Client(mac: mac("AA:00:00:00:00:02"), connection: GLiNetClientListParser.connection(interface: "cable"))
    let wifi = Client(mac: mac("AA:00:00:00:00:03"), connection: GLiNetClientListParser.connection(interface: "5G"))
    #expect(ClientsFormat.connection(wired) == "Ethernet")
    #expect(ClientsFormat.connection(wifi) == "Wi-Fi · 5 GHz")
    #expect(ClientsFormat.newDevicesText(1) == "1 new device awaiting review")
    #expect(ClientsFormat.showingText(visible: 3, total: 14) == "Showing 3 of 14 clients")
}

@Test func reviewSheetRowsListDevicesAwaitingReview() {
    let now = Date()
    let watch = DeviceRecord(mac: mac("d8:1c:79:aa:04:53"), firstSeen: now.addingTimeInterval(-60), lastIP: "192.168.8.116", awaitingReview: true)
    let known = DeviceRecord(mac: mac("00:11:32:9f:c2:5e"), firstSeen: now.addingTimeInterval(-86_400 * 40))
    let vm = DeviceRecord(mac: mac("52:54:00:12:34:56"), firstSeen: now.addingTimeInterval(-30), awaitingReview: true)
    let registry = DeviceRegistryState(baselineEstablished: true, records: [watch, known, vm])
    let clients = [Client(mac: watch.mac, ip: "192.168.8.116", adGuardName: "Watch", online: .value(true))]
    let rows = ClientsFormat.reviewRows(registry: registry, clients: clients, now: now)
    #expect(rows.map(\.mac) == [watch.mac, vm.mac])
    #expect(rows[0].name == "Watch")
    #expect(rows[0].detail == "192.168.8.116 · d8:1c:79:aa:04:53")
    #expect(rows[0].firstObserved.hasPrefix("First observed today"))
    #expect(rows[1].name == "Unknown device")
}

@Test func knownClientsStatStripCounts() {
    let records = [
        DeviceRecord(mac: mac("AA:00:00:00:00:01"), favourite: true, monitored: true, firstSeen: .now),
        DeviceRecord(mac: mac("AA:00:00:00:00:02"), monitored: true, firstSeen: .now),
        DeviceRecord(mac: mac("AA:00:00:00:00:03"), firstSeen: .now),
    ]
    let clients = [Client(mac: records[0].mac, online: .value(true)), Client(mac: records[1].mac, online: .value(false))]
    let summary = ClientsFormat.knownSummary(registry: DeviceRegistryState(records: records), clients: clients)
    #expect(summary == KnownClientsSummary(known: 3, online: 1, favourites: 1, monitored: 2))
    #expect(summary.offline == 2)
}

@MainActor @Test func mockClientsRefreshFindsThreeNewDevicesOnce() async {
    let (environment, _) = await clientsEnvironment()
    let model = environment.model
    #expect(model.clientInventory?.clients.count == 11)
    #expect(model.capabilities[.clients]?.state == .supported)
    #expect(model.newDeviceCount == 3)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(model.newDeviceCount == 3)
    let first = model.deviceRegistry.awaitingReview[0].mac
    await environment.clients.markReviewed(first)
    #expect(model.newDeviceCount == 2)
    #expect(model.deviceRegistry.records[first]?.awaitingReview == false)
}

@MainActor @Test func primaryListFailureKeepsTheLastListAndShowsTheFailure() async {
    let (environment, backend) = await clientsEnvironment(scenario: .standard)
    let model = environment.model
    #expect(model.clientInventory?.clients.count == 8)
    #expect(model.newDeviceCount == 0)
    await backend.setClientsScenario(.primaryFailure)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(model.clientsFreshness.failure == .network)
    #expect(model.clientInventory?.clients.count == 8)
}

@MainActor @Test func inventoryIsReadOnlyWhileClientsIsVisible() async {
    let backend = MockRouterBackend()
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    environment.refresh.refreshNow()
    await environment.refresh.waitForRefresh()
    #expect(model.selection == .overview)
    #expect(model.clientInventory == nil)
    #expect(model.capabilities[.clients] == nil)
}

@MainActor @Test func sessionSwitchClearsTheListButKeepsDeviceHistory() async {
    let (environment, _) = await clientsEnvironment()
    let model = environment.model
    #expect(model.clientInventory != nil)
    let history = model.deviceRegistry
    model.clearSession()
    #expect(model.clientInventory == nil)
    #expect(model.deviceRegistry == history)
}

@MainActor @Test func clientsScreenStatesLayOut() async {
    let (environment, _) = await clientsEnvironment()
    for segment in ["All Clients", "Known Clients"] {
        environment.model.subpages[.clients] = segment
        let view = NSHostingView(rootView: ClientsScreen().environment(environment.model).environment(environment)
            .frame(width: 1100, height: 760))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
    }
    let sheet = NSHostingView(rootView: NewDevicesSheet(rows: [], onReview: { _ in }, onDone: {}))
    #expect(sheet.fittingSize.height > 0)
}

import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

private func mac(_ raw: String) -> MACAddress { MACAddress(raw)! }
private let iPhone = mac("66:29:ea:33:fb:78")
private let printer = mac("3c:52:82:7a:0d:91")
private let kindle = mac("fc:65:de:02:1b:9a")

/// A mock environment with the window visible and Clients selected, after
/// one refresh has read the inventory and sampled presence.
@MainActor private func detailsEnvironment() async -> (AppEnvironment, MockRouterBackend) {
    let backend = MockRouterBackend()
    await backend.setClientsScenario(.standard)
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    model.selection = .clients
    await environment.refresh.waitForRefresh()
    return (environment, backend)
}

@MainActor private func entry(_ environment: AppEnvironment, _ address: MACAddress) -> ClientListEntry? {
    let model = environment.model
    return ClientListing.entries(clients: model.clientInventory?.clients ?? [], records: model.deviceRegistry.records)
        .first { $0.mac == address }
}

@MainActor private func eventually(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(3)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor @Test func everySectionRendersInThePane() async throws {
    let (environment, _) = await detailsEnvironment()
    let model = environment.model
    model.clientsSelection = [iPhone]
    model.clientsDetailsVisible = true
    for section in ClientDetailsSection.allCases {
        model.clientsDetailsSection = section.rawValue
        let view = NSHostingView(rootView: ClientsScreen().environment(model).environment(environment)
            .frame(width: 1180, height: 820))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0, "\(section)")
    }
}

@MainActor @Test func refreshSamplesPresenceForListedAndRememberedDevices() async throws {
    let (environment, _) = await detailsEnvironment()
    let presence = environment.model.presence
    let phone = try #require(presence.devices[iPhone])
    #expect(phone.open)
    #expect(phone.runs.last?.state == .online)
    // Kindle is remembered but no longer listed, so a refresh samples it offline.
    #expect(presence.devices[kindle]?.runs.last?.state == .offline)
}

@MainActor @Test func availabilityRowsAndHistoryFromTheSeed() async throws {
    let (environment, _) = await detailsEnvironment()
    let phone = try #require(entry(environment, iPhone))
    let now = Date()
    let model = ClientDetailsFormat.availability(phone, history: environment.model.presence.devices[iPhone], range: .week, now: now)
    #expect(model.hasHistory)
    #expect(model.segments.map(\.state).contains(.unknown))
    #expect(model.segments.map(\.state).contains(.offline))
    #expect(model.segments.last?.state == .online)
    #expect(model.segments.first?.start == now.addingTimeInterval(-7 * 86_400))
    let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.label, $0.value) })
    #expect(rows.keys.sorted() == ["Current online period", "First observed", "Last observed", "Last offline", "Last seen by Routewell", "Online today"])
    #expect(rows["Last offline"] != "None observed")
    #expect(model.historySummary.hasSuffix("stored on this Mac."))

    let empty = ClientDetailsFormat.availability(phone, history: nil, range: .day, now: now)
    #expect(empty.segments == [PresenceSegment(start: now.addingTimeInterval(-86_400), end: now, state: .unknown)])
    #expect(empty.rows.first?.value == "Unknown")
    #expect(!empty.hasHistory)
    #expect(ClientDetailsFormat.duration(30) == "< 1 min")
    #expect(ClientDetailsFormat.duration(3 * 3_600 + 300) == "3 h 5 min")
    #expect(ClientDetailsFormat.duration(2 * 86_400 + 4 * 3_600) == "2 d 4 h")
}

@MainActor @Test func dnsFeedLoadsAndPauseStopsIt() async throws {
    let (environment, _) = await detailsEnvironment()
    let dns = environment.clientDNS
    dns.visibleInterval = .milliseconds(40)
    let follow = Task { await dns.follow(mac: iPhone, ip: "192.168.8.192", sectionVisible: true) }
    #expect(await eventually { dns.fetchCount >= 2 })
    let activity = try #require(dns.feed(for: iPhone)?.activity)
    // The mock log has more than one page for this client.
    #expect(activity.total == 500)
    #expect(activity.windowLimited)
    #expect(activity.blocked > 0)
    #expect(activity.topRequested.count == 5 && activity.topBlocked.count <= 5)
    #expect(ClientDetailsFormat.dnsHeader(activity, paused: false) == "Latest 10 of 500 · live")

    dns.paused = true
    _ = await follow.value
    let stopped = dns.fetchCount
    try await Task.sleep(for: .milliseconds(200))
    #expect(dns.fetchCount == stopped)
    #expect(dns.feed(for: iPhone)?.activity != nil)
    #expect(ClientDetailsFormat.dnsHeader(activity, paused: true) == "Latest 10 of 500 · paused")
    dns.paused = false
}

@MainActor @Test func dnsFeedStatesForNoAddressNoAdGuardAndFailure() async throws {
    let (environment, backend) = await detailsEnvironment()
    let dns = environment.clientDNS
    await dns.follow(mac: kindle, ip: nil, sectionVisible: true)
    #expect(dns.feed(for: kindle)?.unavailable == .noAddress)

    await backend.setFeatureBehavior(.failing, for: .queryLog)
    dns.visibleInterval = .milliseconds(20)
    let follow = Task { await dns.follow(mac: iPhone, ip: "192.168.8.192", sectionVisible: true) }
    #expect(await eventually { dns.feed(for: iPhone)?.failure == .network })
    follow.cancel()
    _ = await follow.value
    #expect(dns.feed(for: iPhone)?.activity == nil)
}

@MainActor @Test func dnsFeedIgnoresAnotherSession() async throws {
    let (environment, _) = await detailsEnvironment()
    let dns = environment.clientDNS
    dns.visibleInterval = .milliseconds(20)
    let follow = Task { await dns.follow(mac: iPhone, ip: "192.168.8.192", sectionVisible: true) }
    #expect(await eventually { dns.feed(for: iPhone)?.activity != nil })
    environment.switchMockProfile(AppEnvironment.mockProfiles[1])
    // The old session's data is never shown for the new one.
    #expect(dns.feed(for: iPhone) == nil)
    follow.cancel()
    _ = await follow.value
}

@Test func vpnRoutingIsUnknownUntilItsChunk() {
    #expect((ClientDetailsFormat.vpnClientRows + ClientDetailsFormat.vpnGlobalRows).allSatisfy { $0.value == "Unknown" })
    #expect(ClientDetailsFormat.vpnClientRows.map(\.label) == ["Route", "Policy source", "Matched by"])
    #expect(ClientDetailsFormat.vpnGlobalRows.map(\.label) == ["Global VPN", "Client", "Policy mode"])
}

@MainActor @Test func pingAndWakeOverRPCAndSSH() async throws {
    let (environment, backend) = await detailsEnvironment()
    let actions = environment.clientActions
    let phone = try #require(entry(environment, iPhone))
    for mechanism in [ClientActionMechanism.rpc, .ssh] {
        environment.setMockClientActions(mechanism)
        #expect(actions.mechanism == mechanism)
        actions.ping(phone)
        #expect(actions.isRunning(iPhone))
        #expect(await eventually { actions.status(for: iPhone)?.running == false })
        #expect(actions.status(for: iPhone)?.text == "Ping: replied to 3 of 3 · 3.2 ms average.")
        actions.wake(phone)
        #expect(await eventually { actions.status(for: iPhone)?.running == false })
        #expect(actions.status(for: iPhone)?.text.hasPrefix("Wake-on-LAN packet sent") == true)
    }
    let offline = try #require(entry(environment, printer))
    actions.ping(offline)
    #expect(await eventually { actions.status(for: printer)?.running == false })
    #expect(actions.status(for: printer)?.text == "Ping: no reply to 3 packets.")
    _ = backend
}

@MainActor @Test func pingAndWakeNeedSSHWhenItIsNotSetUp() async throws {
    let (environment, _) = await detailsEnvironment()
    let actions = environment.clientActions
    let phone = try #require(entry(environment, iPhone))
    environment.setMockClientActions(.sshRequired)
    actions.wake(phone)
    #expect(actions.sshRequiredAction == .wake)
    #expect(actions.status(for: iPhone) == nil)
    actions.sshRequiredAction = nil
    actions.ping(phone)
    #expect(actions.sshRequiredAction == .ping)
    let view = NSHostingView(rootView: SSHRequiredView(title: "Ping needs SSH").environment(environment.model))
    #expect(view.fittingSize.height > 0)
}

@MainActor @Test func pingAndWakeAreHiddenWithoutAMechanism() async throws {
    let (environment, _) = await detailsEnvironment()
    environment.setMockClientActions(nil)
    #expect(environment.clientActions.mechanism == nil)
    let phone = try #require(entry(environment, iPhone))
    environment.clientActions.ping(phone)
    #expect(environment.clientActions.status(for: iPhone) == nil)
    #expect(environment.clientActions.sshRequiredAction == nil)
    let header = NSHostingView(rootView: ClientHeaderActions(entry: phone, now: .now).environment(environment.model).environment(environment))
    header.layoutSubtreeIfNeeded()
    #expect(header.fittingSize.width > 0)
}

@MainActor @Test func contextMenuAndReviewOpenTheRightSection() async throws {
    let (environment, _) = await detailsEnvironment()
    let model = environment.model
    model.clientsDetailsVisible = false
    model.subpages[.clients] = "Known Clients"
    model.revealClient(printer, section: .personalise)
    #expect(model.selection == .clients)
    #expect(model.subpages[.clients] == "All Clients")
    #expect(model.clientsSelection == [printer])
    #expect(model.clientsDetailsVisible)
    #expect(model.clientsDetailsSection == "personalise")

    let phone = try #require(entry(environment, iPhone))
    #expect(ClientDetailsFormat.copyDetails(phone, now: .now).contains("MAC address: 66:29:ea:33:fb:78"))
    #expect(ClientDetailsFormat.copyDetails(phone, now: .now).contains("IP address: 192.168.8.192"))
    // The Favourite item runs the same local edit as the Personalise switch.
    let before = phone.isFavourite
    await environment.clients.edit(iPhone, .setFavourite(!before))
    #expect(entry(environment, iPhone)?.isFavourite == !before)
}

@MainActor @Test func personaliseSavesLocallyWithoutANetworkCall() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AtomicJSONStore(directory: directory)
    let device = DeviceRecord(mac: printer, firstSeen: .now)
    let registry = DeviceRegistry(store: store, initial: DeviceRegistryState(baselineEstablished: true, records: [device]))
    let environment = AppEnvironment(model: AppModel(mode: .live), backend: nil, store: store, registry: registry,
                                     transportFactory: { _ in fatalError("personalisation must not build a transport") })
    await environment.waitUntilReady()
    let report = await environment.clients.edit(printer, .save(userName: "HP LaserJet", category: .printer, notes: "Upstairs"))
    guard case .verifiedSuccess(let profile) = report.outcome else { Issue.record("expected success"); return }
    #expect(profile.userName == "HP LaserJet")
    #expect(!environment.transportFactoryWasUsed)
    #expect(environment.model.deviceRegistry.records[printer]?.personalisedAt != nil)
    let saved = try await AtomicJSONStore(directory: directory).load(DeviceRegistryState.self, from: .devices)
    #expect(saved?.records[printer]?.userName == "HP LaserJet")
}

@MainActor @Test func forgetIsBlockedWhileOnlineAndRemovesHistoryWhenOffline() async throws {
    let (environment, _) = await detailsEnvironment()
    let model = environment.model
    let phone = try #require(entry(environment, iPhone))
    #expect(!ClientDetailsFormat.forgetState(phone, inventoryLoaded: true).enabled)
    #expect(ClientDetailsFormat.forgetState(phone, inventoryLoaded: true).status == "Currently on the network — disconnect it before forgetting.")
    let refused = await environment.clients.forget(iPhone, online: ClientDetailsFormat.onlineForForget(phone, inventoryLoaded: true))
    guard case .rejected = refused.outcome else { Issue.record("expected rejection"); return }
    #expect(model.deviceRegistry.records[iPhone] != nil)

    let absent = try #require(entry(environment, kindle))
    #expect(absent.client == nil)
    #expect(ClientDetailsFormat.forgetState(absent, inventoryLoaded: true).enabled)
    #expect(!ClientDetailsFormat.forgetState(absent, inventoryLoaded: false).enabled)
    #expect(model.presence.devices[kindle] != nil)
    model.clientsSelection = [kindle]
    let report = await environment.clients.forget(kindle, online: ClientDetailsFormat.onlineForForget(absent, inventoryLoaded: true))
    #expect(report.outcome == .verifiedSuccess(kindle))
    #expect(model.deviceRegistry.records[kindle] == nil)
    #expect(model.presence.devices[kindle] == nil)
    #expect(model.clientsSelection.isEmpty)
}

@MainActor @Test func clearHistoryRemovesOnlyThisDevice() async throws {
    let (environment, _) = await detailsEnvironment()
    let model = environment.model
    #expect(model.presence.devices[printer] != nil)
    await environment.clients.clearHistory(printer)
    #expect(model.presence.devices[printer] == nil)
    #expect(model.presence.devices[iPhone] != nil)
    #expect(model.deviceRegistry.records[printer] != nil)
}

@MainActor @Test func knownClientsLaysOutWithWiredActions() async throws {
    let (environment, _) = await detailsEnvironment()
    environment.model.subpages[.clients] = "Known Clients"
    let view = NSHostingView(rootView: ClientsScreen().environment(environment.model).environment(environment)
        .frame(width: 1100, height: 760))
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.width > 0)
    let savedRows = ClientDetailsFormat.savedOnThisMac(try #require(entry(environment, iPhone)), history: environment.model.presence.devices[iPhone], now: .now)
    #expect(savedRows.map(\.label) == ["Presence history", "Profile", "Notes", "Matched by"])
    #expect(savedRows.last?.value == "66:29:ea:33:fb:78")
}

import Foundation
import RoutewellKit

/// Synthetic client data shaped like the Clients v2 mockups. Mock data covers
/// fields that live firmware 4.9.1 does not report yet (signal, band, SSID,
/// blocked counts), so the finished layout can be reviewed.
public actor MockClientsService: ClientsService {
    public enum Scenario: String, CaseIterable, Sendable {
        /// Three devices the seed registry has never seen.
        case newDevices
        /// Every listed device is already known.
        case standard
        /// The router list is empty.
        case empty
        /// AdGuard Home data uses addresses no router client holds.
        case adGuardMismatch
        /// The router list fails; the Clients area fails with it.
        case primaryFailure
    }

    private var scenario: Scenario = .newDevices
    private var behavior: MockRouterBackend.FeatureBehavior = .supported

    public init() {}

    public func setScenario(_ value: Scenario) { scenario = value }
    public func setBehavior(_ value: MockRouterBackend.FeatureBehavior) { behavior = value }

    public func probe() async -> Capability {
        let selected = behavior
        if selected == .slow {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return Capability() }
        }
        guard !Task.isCancelled else { return Capability() }
        return Self.capability(for: selected, at: .now)
    }

    public func inventory() async throws -> ClientInventoryResult {
        try Task.checkCancellation()
        let selected = behavior
        if selected == .slow { try await Task.sleep(for: .seconds(5)) }
        let now = Date.now
        switch selected {
        case .unsupported:
            return ClientInventoryResult(area: .failure(.unavailable, attemptedAt: now), capability: Self.capability(for: selected, at: now))
        case .failing, .unknown:
            return ClientInventoryResult(area: .failure(.network, attemptedAt: now), capability: Capability())
        case .supported, .slow:
            break
        }
        let result = Self.inventory(for: scenario)
        switch result {
        case .success(let inventory):
            return ClientInventoryResult(
                area: .success(inventory, observedAt: now, source: .mock),
                capability: Capability(.supported, evidence: .mockScenario(scenario.rawValue), observedAt: now)
            )
        case .failure(let category):
            return ClientInventoryResult(area: .failure(category, attemptedAt: now), capability: Capability())
        }
    }

    private static func capability(for behavior: MockRouterBackend.FeatureBehavior, at date: Date) -> Capability {
        switch behavior {
        case .supported, .slow: Capability(.supported, evidence: .mockScenario("supported"), observedAt: date)
        case .unsupported: Capability(.unsupported, evidence: .mockScenario("unsupported"), observedAt: date)
        case .unknown, .failing: Capability()
        }
    }

    // MARK: - Data

    private struct Row {
        let mac: String
        let ip: String?
        let hostname: String?
        let routerName: String?
        let adGuardName: String?
        let online: Bool
        let connection: ClientConnection
        let signal: Int?
        let queries: Int?
        let blocked: Int?
        let vendor: String?
        let new: Bool
    }

    private static func wifi(_ band: String, _ ssid: String, _ iface: String) -> ClientConnection {
        ClientConnection(medium: .value(.wifi), band: band, ssid: ssid, interface: iface)
    }

    private static func wired(_ port: String) -> ClientConnection {
        ClientConnection(medium: .value(.wired), interface: port)
    }

    private static let rows: [Row] = [
        Row(mac: "66:29:ea:33:fb:78", ip: "192.168.8.192", hostname: "iPhone", routerName: nil, adGuardName: nil, online: true,
            connection: wifi("2.4 GHz", "Homewifi", "rai0"), signal: -66, queries: 12_550, blocked: 107, vendor: nil, new: false),
        Row(mac: "ba:4d:21:07:3e:91", ip: "192.168.8.150", hostname: "iPhone", routerName: nil, adGuardName: nil, online: true,
            connection: wifi("2.4 GHz", "Homewifi", "rai0"), signal: -66, queries: 6_747, blocked: 47, vendor: nil, new: true),
        Row(mac: "0e:e5:7b:da:22:c7", ip: "192.168.8.233", hostname: "Mac", routerName: nil, adGuardName: nil, online: true,
            connection: wifi("6 GHz", "Homewifi Fast", "rax0"), signal: -57, queries: 3_119, blocked: 18, vendor: nil, new: false),
        Row(mac: "a4:83:e7:12:9c:01", ip: "192.168.8.199", hostname: "MacBook-Air", routerName: "MacBook Air", adGuardName: nil, online: true,
            connection: wifi("6 GHz", "Homewifi Fast", "rax0"), signal: -52, queries: 2_406, blocked: 9, vendor: nil, new: false),
        Row(mac: "00:0c:29:bf:88:8a", ip: "192.168.8.228", hostname: "DESKTOP-LQDJLQF", routerName: nil, adGuardName: nil, online: true,
            connection: wired("lan3"), signal: nil, queries: 1_982, blocked: 3, vendor: nil, new: false),
        Row(mac: "00:17:88:4a:1e:2f", ip: "192.168.8.120", hostname: "Hue-Bridge-Simon", routerName: nil, adGuardName: nil, online: true,
            connection: wired("eth2"), signal: nil, queries: 1_204, blocked: 0, vendor: "Philips Lighting BV", new: false),
        Row(mac: "f0:b3:ec:8d:44:10", ip: "192.168.8.105", hostname: nil, routerName: "Apple TV", adGuardName: nil, online: true,
            connection: wired("eth2"), signal: nil, queries: 866, blocked: 2, vendor: nil, new: false),
        Row(mac: "d8:1c:79:aa:04:53", ip: "192.168.8.116", hostname: nil, routerName: nil, adGuardName: "Watch", online: true,
            connection: wifi("2.4 GHz", "Homewifi", "rai0"), signal: -71, queries: 312, blocked: 0, vendor: nil, new: true),
        Row(mac: "00:11:32:9f:c2:5e", ip: "192.168.8.20", hostname: "nas", routerName: nil, adGuardName: nil, online: true,
            connection: wired("eth1"), signal: nil, queries: 140, blocked: 0, vendor: nil, new: false),
        Row(mac: "3c:52:82:7a:0d:91", ip: "192.168.8.31", hostname: "Printer", routerName: nil, adGuardName: nil, online: false,
            connection: wifi("2.4 GHz", "Homewifi", "rai0"), signal: nil, queries: 12, blocked: 0, vendor: nil, new: false),
        Row(mac: "52:54:00:12:34:56", ip: "192.168.8.240", hostname: nil, routerName: "Work PC (VM)", adGuardName: nil, online: false,
            connection: wired("eth2"), signal: nil, queries: 0, blocked: 0, vendor: nil, new: true),
    ]

    private static func inventory(for scenario: Scenario) -> Result<ClientInventory, RefreshFailureCategory> {
        switch scenario {
        case .primaryFailure:
            return .failure(.network)
        case .empty:
            return .success(ClientInventory(clients: [], enrichment: .joined))
        case .standard, .newDevices, .adGuardMismatch:
            let listed = rows.filter { scenario == .standard ? !$0.new : true }
            let clients = listed.compactMap { row -> Client? in
                guard let mac = MACAddress(row.mac) else { return nil }
                let joined = scenario != .adGuardMismatch
                return Client(
                    mac: mac, ip: row.ip, routerName: row.routerName, hostname: row.hostname,
                    adGuardName: joined ? row.adGuardName : nil,
                    online: .value(row.online), connection: row.connection,
                    signal: row.signal.map(Observed.value) ?? .unknown,
                    dnsQueries: joined ? (row.queries.map(Observed.value) ?? .unknown) : .unknown,
                    dnsBlocked: joined ? (row.blocked.map(Observed.value) ?? .unknown) : .unknown,
                    reportedVendor: row.vendor
                )
            }
            return .success(ClientInventory(clients: clients, enrichment: .joined))
        }
    }

    /// Each listed client's online flag for the mock Overview's presence
    /// sample; `nil` when the scenario's router list fails.
    public func listedPresence() -> [MACAddress: Observed<Bool>]? {
        guard case .success(let inventory) = Self.inventory(for: scenario) else { return nil }
        return Dictionary(inventory.clients.map { ($0.mac, $0.online) }, uniquingKeysWith: { first, _ in first })
    }

    /// Presence history a mock session starts with: three earlier days with
    /// unknown nights (Routewell was not running), a lunchtime offline hour,
    /// and today up to a minute ago. Memory only.
    public static func seedPresence(now: Date, calendar: Calendar = .current) -> PresenceLogState {
        let hour: TimeInterval = 3_600
        func run(_ start: Date, _ end: Date, _ state: PresenceState) -> PresenceRun? {
            guard end > start else { return nil }
            return PresenceRun(start: start, end: end, state: state, observations: max(1, Int(end.timeIntervalSince(start) / 30)))
        }
        let today = calendar.startOfDay(for: now)
        let recent = now.addingTimeInterval(-60)
        var devices: [MACAddress: PresenceHistory] = [:]
        for row in rows {
            guard let mac = MACAddress(row.mac), !row.new else { continue }
            var runs: [PresenceRun?] = []
            for day in (1...3).reversed() {
                let base = today.addingTimeInterval(-Double(day) * 86_400)
                runs += [run(base + 8 * hour, base + 13 * hour, .online), run(base + 13 * hour, base + 14 * hour, .offline),
                         run(base + 14 * hour, base + 22 * hour, .online)]
            }
            let morning = min(today + 8 * hour, now.addingTimeInterval(-2 * hour))
            if row.online {
                runs.append(run(morning, recent, .online))
            } else {
                let lastSeen = now.addingTimeInterval(-3 * hour)
                runs += [run(morning, lastSeen, .online), run(lastSeen, recent, .offline)]
            }
            devices[mac] = PresenceHistory(runs: runs.compactMap { $0 }, open: true)
        }
        return PresenceLogState(devices: devices)
    }

    /// The device registry a mock session starts with: every device except
    /// the three new ones, plus three the router no longer lists. Memory only.
    public static func seedRegistry(now: Date) -> DeviceRegistryState {
        func record(_ mac: String, _ build: (inout DeviceRecord) -> Void) -> DeviceRecord? {
            guard let address = MACAddress(mac) else { return nil }
            var value = DeviceRecord(mac: address, firstSeen: now.addingTimeInterval(-40 * 86_400))
            build(&value)
            return value
        }
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400
        let records: [DeviceRecord?] = [
            record("66:29:ea:33:fb:78") { $0.favourite = true; $0.monitored = true; $0.category = .phone; $0.lastSeen = now },
            record("0e:e5:7b:da:22:c7") { $0.favourite = true; $0.monitored = true; $0.category = .desktop; $0.lastSeen = now
                $0.notes = "Wired via lan3 when docked." },
            record("a4:83:e7:12:9c:01") { $0.category = .laptop; $0.lastSeen = now },
            record("00:0c:29:bf:88:8a") { $0.category = .desktop; $0.lastSeen = now },
            record("00:17:88:4a:1e:2f") { $0.category = .smartHome; $0.monitored = true; $0.lastSeen = now },
            record("f0:b3:ec:8d:44:10") { $0.category = .tv; $0.lastSeen = now },
            record("00:11:32:9f:c2:5e") { $0.favourite = true; $0.monitored = true; $0.category = .server; $0.lastSeen = now },
            record("3c:52:82:7a:0d:91") { $0.userName = "HP LaserJet"; $0.category = .printer; $0.lastSeen = now.addingTimeInterval(-3 * hour) },
            record("9c:f4:8e:31:77:b2") { $0.userName = "Kitchen iPad"; $0.category = .tablet; $0.lastHostname = "iPad"
                $0.lastSeen = now.addingTimeInterval(-2 * day) },
            record("48:a6:b8:5c:ee:07") { $0.category = .smartHome; $0.lastHostname = "Sonos-One"; $0.lastSeen = now.addingTimeInterval(-6 * day) },
            record("fc:65:de:02:1b:9a") { $0.category = .tablet; $0.lastHostname = "Kindle"; $0.lastSeen = now.addingTimeInterval(-18 * day) },
        ]
        return DeviceRegistryState(baselineEstablished: true, records: records.compactMap { $0 })
    }

    /// Online count in the default scenario, used by the mock Overview.
    public static var defaultOnlineCount: Int { rows.filter(\.online).count }
}

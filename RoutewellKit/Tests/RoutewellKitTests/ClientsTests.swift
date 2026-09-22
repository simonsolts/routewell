import Foundation
import Testing
@testable import RoutewellKit

func clientFixture(_ name: String, _ subdirectory: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(subdirectory)"))
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

func mac(_ raw: String) -> MACAddress { MACAddress(raw)! }

@Suite struct ClientParserTests {
    @Test func macNormalizationAndLocalBit() {
        #expect(MACAddress("66:29:ea:33:fb:78")?.normalized == "6629EA33FB78")
        #expect(MACAddress("66-29-EA-33-FB-78")?.colonSeparated == "66:29:ea:33:fb:78")
        #expect(MACAddress("6629.ea33.fb78") == MACAddress("6629EA33FB78"))
        #expect(MACAddress("00:00:00:00:00:00") == nil)
        #expect(MACAddress("not-a-mac") == nil)
        #expect(MACAddress("66:29:ea:33:fb") == nil)
        #expect(mac("66:29:ea:33:fb:78").isLocallyAdministered)
        #expect(!mac("a4:83:e7:12:9c:01").isLocallyAdministered)
    }

    /// Recorded on firmware 4.9.1 `[verified live]`: 37 entries, 11 online,
    /// no vendor, signal, or SSID fields; `alias` on 3 entries.
    @Test func liveClientListParses() throws {
        let parsed = try #require(GLiNetClientListParser.parse(clientFixture("clients-get_list-4.9.1", "glinet/clients")))
        #expect(parsed.entries.count == 37)
        #expect(parsed.skippedEntries == 0)
        #expect(parsed.entries.filter { $0.online == .value(true) }.count == 11)
        #expect(parsed.entries.allSatisfy { $0.reportedVendor == nil && $0.ip != nil && $0.interface != nil })
        #expect(parsed.entries.filter { $0.routerName != nil }.count == 3)
        #expect(parsed.entries.first?.mac == mac("02:00:00:00:00:01"))
    }

    /// The 2022 public-client cassette had `vendor: "unknown"` and `iface: "eth0"`.
    @Test func publicClientVendorPlaceholderIsNotAVendor() throws {
        let envelope = try clientFixture("clients-get_list", "glinet")
        let result = try #require(envelope["result"])
        let parsed = try #require(GLiNetClientListParser.parse(result))
        let entry = try #require(parsed.entries.first)
        #expect(entry.reportedVendor == nil)
        #expect(entry.interface == "eth0")
        #expect(entry.hostname == "DESKTOP-HO0T5C1")
    }

    @Test func clientListToleratesOddEntries() throws {
        let json: JSONValue = .object(["clients": .array([
            .object(["mac": .string("AA:BB:CC:00:00:01"), "online": .bool(false), "name": .string("*"), "ip": .string("")]),
            .object(["mac": .string("aa:bb:cc:00:00:01"), "online": .bool(true), "name": .string("tv")]),
            .object(["ip": .string("198.51.100.4")]),
            .object(["mac": .string("garbage")]),
            .object(["mac": .string("AA:BB:CC:00:00:02"), "online": .string("yes"), "name": .string(" Unknown ")]),
        ])])
        let parsed = try #require(GLiNetClientListParser.parse(json))
        #expect(parsed.skippedEntries == 2)
        #expect(parsed.entries.count == 2)
        #expect(parsed.entries[0].online == .value(true))
        #expect(parsed.entries[0].hostname == "tv")
        #expect(parsed.entries[1].online == .unknown)
        #expect(parsed.entries[1].hostname == nil)
        #expect(parsed.entries[1].ip == nil)
        #expect(GLiNetClientListParser.parse(.object(["clients": .null]))?.entries.isEmpty == true)
        #expect(GLiNetClientListParser.parse(.object([:])) == nil)
    }

    @Test func liveAdGuardDirectoryAndStatsParse() throws {
        let directory = try #require(AdGuardClientsParser.parse(clientFixture("control-clients-4.9.1", "adguard/clients")))
        #expect(directory.persistent.isEmpty)
        #expect(directory.automaticNames.count == 22)
        // Live `top_clients` keys were hidden by the recorder, so none look like
        // an address and nothing can join; the counts are still read.
        let stats = try #require(AdGuardStatsParser.topClientQueries(clientFixture("control-stats-4.9.1", "adguard/clients")))
        #expect(stats.keys.allSatisfy { !IPAddressText.isValid($0) })
        #expect(stats.values.reduce(0, +) == 45_750)
        #expect(AdGuardStatsParser.topClientQueries(.object([:])) == nil)
        #expect(AdGuardClientsParser.parse(.object(["other": .bool(true)])) == nil)
    }
}

@Suite struct ClientMergeTests {
    private func mergedLive() throws -> [MACAddress: Client] {
        let router = try #require(GLiNetClientListParser.parse(clientFixture("clients-get_list-4.9.1", "glinet/clients"))).entries
        let directory = AdGuardClientsParser.parse(try clientFixture("control-clients-persistent", "adguard/clients"))
        let stats = AdGuardStatsParser.topClientQueries(try clientFixture("control-stats-ip-keys", "adguard/clients"))
        let clients = ClientMerge.merge(router: router, adGuardDirectory: directory, topClientQueries: stats)
        #expect(clients.count == router.count)
        return Dictionary(uniqueKeysWithValues: clients.map { ($0.mac, $0) })
    }

    @Test func macJoinWinsOverIPJoin() throws {
        let clients = try mergedLive()
        // 02:…:05 holds 198.51.100.13, whose persistent entry has no name; the MAC id names it.
        #expect(clients[mac("02:00:00:00:00:05")]?.adGuardName == "Studio")
    }

    @Test func ipJoinNamesAndCountsTheOwner() throws {
        let clients = try mergedLive()
        #expect(clients[mac("02:00:00:00:00:04")]?.adGuardName == "Living room")
        #expect(clients[mac("02:00:00:00:00:04")]?.dnsQueries == .value(6_600))
        #expect(clients[mac("02:00:00:00:00:03")]?.adGuardName == "phone.lan")
        #expect(clients[mac("02:00:00:00:00:03")]?.dnsQueries == .value(14_212))
        // Blank AdGuard names never become names.
        #expect(clients[mac("02:00:00:00:00:09")]?.adGuardName == nil)
    }

    /// Two offline router entries share 198.51.100.35 `[verified live]`: no join.
    @Test func ambiguousIPDoesNotJoin() throws {
        let clients = try mergedLive()
        for raw in ["02:00:00:00:00:1B", "02:00:00:00:00:1C"] {
            #expect(clients[mac(raw)]?.adGuardName == nil)
            #expect(clients[mac(raw)]?.dnsQueries == .unknown)
        }
    }

    @Test func onlineHolderOwnsASharedIP() {
        let entries = [
            RouterClientEntry(mac: mac("AA:00:00:00:00:01"), ip: "198.51.100.8", online: .value(false)),
            RouterClientEntry(mac: mac("AA:00:00:00:00:02"), ip: "198.51.100.8", online: .value(true)),
        ]
        let clients = ClientMerge.merge(router: entries, adGuardDirectory: nil, topClientQueries: ["198.51.100.8": 5])
        #expect(clients[0].dnsQueries == .unknown)
        #expect(clients[1].dnsQueries == .value(5))
    }

    @Test func missingAdGuardLeavesEnrichmentUnknown() throws {
        let router = try #require(GLiNetClientListParser.parse(clientFixture("clients-get_list-4.9.1", "glinet/clients"))).entries
        let clients = ClientMerge.merge(router: router, adGuardDirectory: nil, topClientQueries: nil)
        #expect(clients.allSatisfy { $0.adGuardName == nil && $0.dnsQueries == .unknown && $0.dnsBlocked == .unknown })
        #expect(clients.allSatisfy { $0.signal == .unknown && $0.connection.medium == .unknown })
    }
}

extension RouterClientEntry {
    init(mac: MACAddress, ip: String?, online: Observed<Bool>) {
        self.init(mac: mac, ip: ip, routerName: nil, hostname: nil, online: online, interface: nil, reportedVendor: nil)
    }
}

@Suite struct ClientNamingTests {
    private let full = Client(mac: mac("AA:00:00:00:00:01"), routerName: "Router name", hostname: "host", adGuardName: "ad.lan")

    @Test func automaticOrder() {
        let record = DeviceRecord(mac: full.mac, userName: "Mine", firstSeen: .now)
        #expect(ClientNaming.automatic(client: full, record: record) == ResolvedClientName("Mine", source: .user))
        #expect(ClientNaming.automatic(client: full, record: nil).source == .router)
        var client = full
        client.routerName = nil
        #expect(ClientNaming.automatic(client: client, record: nil) == ResolvedClientName("host", source: .hostname))
        client.hostname = nil
        #expect(ClientNaming.automatic(client: client, record: nil) == ResolvedClientName("ad.lan", source: .adGuard))
        client.adGuardName = nil
        #expect(ClientNaming.automatic(client: client, record: nil) == ResolvedClientName(nil, source: .none))
        #expect(ClientNaming.automatic(client: client, record: DeviceRecord(mac: client.mac, userName: "", firstSeen: .now)).source == .none)
    }

    @Test func rememberedDeviceUsesStoredNames() {
        var record = DeviceRecord(mac: full.mac, firstSeen: .now, lastHostname: "kindle")
        #expect(ClientNaming.automatic(client: nil, record: record) == ResolvedClientName("kindle", source: .hostname))
        record.lastRouterName = "Kindle"
        #expect(ClientNaming.automatic(client: nil, record: record).source == .router)
        // A listed client never falls back to stale stored names.
        #expect(ClientNaming.automatic(client: Client(mac: full.mac), record: record).source == .none)
    }

    @Test func explicitModesHaveNoFallback() {
        #expect(ClientNaming.name(.hostname, client: full, record: nil).text == "host")
        #expect(ClientNaming.name(.displayName, client: full, record: nil).text == nil)
        let record = DeviceRecord(mac: full.mac, userName: "Mine", firstSeen: .now)
        #expect(ClientNaming.name(.displayName, client: full, record: record).text == "Mine")
        #expect(ClientNaming.name(.hostname, client: Client(mac: full.mac, routerName: "R"), record: record).text == nil)
    }

    @Test func vendorResolution() {
        #expect(ClientVendor.resolve(reported: "Philips", mac: mac("66:29:ea:33:fb:78")) == .reported("Philips"))
        #expect(ClientVendor.resolve(reported: nil, mac: mac("66:29:ea:33:fb:78")) == .randomised)
        #expect(ClientVendor.resolve(reported: nil, mac: mac("a4:83:e7:12:9c:01")) == .unknown)
        #expect(Client(mac: mac("02:00:00:00:00:01")).vendor == .randomised)
    }
}

@Suite struct ClientListingTests {
    private func entry(_ suffix: Int, name: String?, online: Bool?, queries: Int? = nil, blocked: Int? = nil,
                       favourite: Bool = false, ip: String? = nil) -> ClientListEntry {
        let address = mac(String(format: "AA:00:00:00:00:%02X", suffix))
        let observedOnline: Observed<Bool> = online.map(Observed.value) ?? .unknown
        let client = Client(mac: address, ip: ip, hostname: name, online: observedOnline,
                            dnsQueries: queries.map(Observed.value) ?? .unknown,
                            dnsBlocked: blocked.map(Observed.value) ?? .unknown)
        let record = favourite ? DeviceRecord(mac: address, favourite: true, firstSeen: .now) : nil
        return ClientListEntry(mac: address, client: client, record: record)
    }

    @Test func blockRate() {
        #expect(ClientListing.blockRate(queries: .value(200), blocked: .value(2)) == .value(0.01))
        #expect(ClientListing.blockRate(queries: .value(0), blocked: .value(0)) == .unavailable)
        #expect(ClientListing.blockRate(queries: .value(10), blocked: .unknown) == .unknown)
    }

    @Test func entriesAddRememberedDevices() {
        let listed = Client(mac: mac("AA:00:00:00:00:01"), online: .value(true))
        let remembered = DeviceRecord(mac: mac("AA:00:00:00:00:09"), firstSeen: .now)
        let entries = ClientListing.entries(clients: [listed], records: [remembered.mac: remembered])
        #expect(entries.map(\.presence) == [.online, .absent])
    }

    @Test func blockedDescendingPutsUnknownLast() {
        let entries = [
            entry(1, name: "a", online: true, queries: 10, blocked: nil),
            entry(2, name: "b", online: true, queries: 10, blocked: 3),
            entry(3, name: "c", online: true, queries: 10, blocked: 7),
            entry(4, name: "d", online: false, queries: 10, blocked: 3),
        ]
        let sorted = ClientListing.apply(filter: .init(), sort: .standard, nameMode: .automatic, to: entries)
        #expect(sorted.map { $0.client?.hostname } == ["c", "b", "d", "a"])
        let ascending = ClientListing.apply(filter: .init(), sort: .init(column: .blocked, ascending: true), nameMode: .automatic, to: entries)
        #expect(ascending.map { $0.client?.hostname } == ["b", "d", "c", "a"])
    }

    @Test func nameAndAddressSorts() {
        let entries = [
            entry(1, name: nil, online: true, ip: "198.51.100.20"),
            entry(2, name: "Zed", online: true, ip: "198.51.100.3"),
            entry(3, name: "alpha", online: true, ip: nil),
        ]
        let byName = ClientListing.apply(filter: .init(), sort: .init(column: .name, ascending: true), nameMode: .automatic, to: entries)
        #expect(byName.map { String($0.mac.normalized.suffix(2)) } == ["03", "02", "01"])
        let byIP = ClientListing.apply(filter: .init(), sort: .init(column: .ip, ascending: true), nameMode: .automatic, to: entries)
        #expect(byIP.map { String($0.mac.normalized.suffix(2)) } == ["02", "01", "03"])
        let byStatus = ClientListing.apply(filter: .init(), sort: .init(column: .status, ascending: true), nameMode: .automatic,
                                       to: [entry(5, name: "x", online: nil), entry(6, name: "y", online: false), entry(7, name: "z", online: true)])
        #expect(byStatus.map(\.presence) == [.online, .offline, .unknown])
    }

    @Test func filters() {
        let entries = [
            entry(1, name: "Phone", online: true, favourite: true, ip: "198.51.100.5"),
            entry(2, name: nil, online: true),
            entry(3, name: "Printer", online: false),
        ]
        func names(_ filter: ClientFilter) -> [String] {
            ClientListing.apply(filter: filter, sort: .init(column: .name, ascending: true), nameMode: .automatic, to: entries)
                .map { $0.mac.normalized.suffix(2).description }
        }
        #expect(names(.init(onlineOnly: true)) == ["01", "02"])
        #expect(names(.init(favouritesOnly: true)) == ["01"])
        #expect(names(.init(hideUnknown: true)) == ["01", "03"])
        #expect(names(.init(search: "print")) == ["03"])
        #expect(names(.init(search: "100.5")) == ["01"])
        #expect(names(.init(search: "aa:00:00:00:00:02")) == ["02"])
        #expect(names(.init(search: "AA0000000003")) == ["03"])
        #expect(names(.init(search: "nothing")) == [])
    }
}

import Foundation
import Testing
@testable import RoutewellKit
import RoutewellMock

/// Serves the GL.iNet login handshake, `clients.get_list`, and the two AdGuard
/// reads. Never touches the network.
private enum ServiceStub {
    static let endpoint = try! RouterEndpoint(scheme: .https, host: "192.0.2.20", port: 443)
    static let adGuardURL = URL(string: "http://192.0.2.20:3000/")!

    enum ListOutcome: Sendable { case fixture(String, String), rpcError(Int), transport(TransportError), body(JSONValue) }
    enum AdGuardOutcome: Sendable { case fixture(String), status(Int) }

    static func transport(list: ListOutcome, clients: AdGuardOutcome, stats: AdGuardOutcome) -> StubHTTPTransport {
        StubHTTPTransport { request in
            let url = request.url!
            if url.path.hasPrefix("/control/") {
                let outcome = url.path.hasSuffix("clients") ? clients : stats
                switch outcome {
                case .fixture(let name):
                    let data = try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/adguard/clients")!)
                    return (data, StubHTTPTransport.response(200, url: url))
                case .status(let code):
                    return (Data(), StubHTTPTransport.response(code, url: url))
                }
            }
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            let id = body["id"]?.int ?? 0
            func ok(_ result: JSONValue) throws -> (Data, HTTPURLResponse) {
                let envelope: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result])
                return (try JSONEncoder().encode(envelope), StubHTTPTransport.response(200, url: url))
            }
            switch body["method"]?.string {
            case "challenge": return try ok(.object(["alg": .number(1), "salt": .string("saltsalt12"), "nonce": .string("nonceabcdef")]))
            case "login": return try ok(.object(["username": .string("root"), "sid": .string("SID")]))
            default: break
            }
            switch list {
            case .fixture(let name, let subdirectory): return try ok(clientFixture(name, subdirectory))
            case .body(let value): return try ok(value)
            case .transport(let error): throw error
            case .rpcError(let code):
                let envelope: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                                   "error": .object(["code": .number(Double(code)), "message": .string("err")])])
                return (try JSONEncoder().encode(envelope), StubHTTPTransport.response(200, url: url))
            }
        }
    }

    static func service(_ transport: StubHTTPTransport, adGuard: Bool = true) -> LiveClientsService {
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: "root", password: { "pw" }, transport: transport)
        let client = adGuard ? AdGuardClient(baseURL: adGuardURL, credentials: RouterTokenAdGuardCredentials(session: rpc), transport: transport) : nil
        return LiveClientsService(rpc: rpc, adGuard: client, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
    }
}

@Suite struct LiveClientsServiceTests {
    @Test func joinsAdGuardDataOntoTheRouterList() async throws {
        let transport = ServiceStub.transport(list: .fixture("clients-get_list-4.9.1", "glinet/clients"),
                                              clients: .fixture("control-clients-persistent"), stats: .fixture("control-stats-ip-keys"))
        let result = try await ServiceStub.service(transport).inventory()
        guard case .success(let inventory, _, let source) = result.area else { Issue.record("expected success"); return }
        #expect(source == .routerRPC)
        #expect(result.capability.state == .supported)
        #expect(inventory.enrichment == .joined)
        #expect(inventory.clients.count == 37)
        #expect(inventory.clients.first { $0.mac == mac("02:00:00:00:00:03") }?.dnsQueries == .value(14_212))
    }

    @Test func adGuardFailureDegradesButDoesNotFailTheArea() async throws {
        let transport = ServiceStub.transport(list: .fixture("clients-get_list-4.9.1", "glinet/clients"),
                                              clients: .status(500), stats: .status(502))
        let result = try await ServiceStub.service(transport).inventory()
        guard case .success(let inventory, _, _) = result.area else { Issue.record("expected success"); return }
        #expect(inventory.enrichment == .failed(.malformedResponse))
        #expect(inventory.clients.count == 37)
        #expect(inventory.clients.allSatisfy { $0.dnsQueries == .unknown && $0.adGuardName == nil })

        let partial = try await ServiceStub.service(ServiceStub.transport(
            list: .fixture("clients-get_list-4.9.1", "glinet/clients"),
            clients: .fixture("control-clients-persistent"), stats: .status(500))).inventory()
        guard case .success(let partialInventory, _, _) = partial.area else { Issue.record("expected success"); return }
        #expect(partialInventory.enrichment == .partial(.malformedResponse))
        #expect(partialInventory.clients.contains { $0.adGuardName != nil })
        #expect(partialInventory.clients.allSatisfy { $0.dnsQueries == .unknown })
    }

    @Test func noAdGuardConfiguredIsNotAFailure() async throws {
        let transport = ServiceStub.transport(list: .fixture("clients-get_list-4.9.1", "glinet/clients"), clients: .status(500), stats: .status(500))
        let result = try await ServiceStub.service(transport, adGuard: false).inventory()
        guard case .success(let inventory, _, _) = result.area else { Issue.record("expected success"); return }
        #expect(inventory.enrichment == .notConfigured)
        #expect(await transport.recorded().allSatisfy { !($0.request.url?.path.hasPrefix("/control/") ?? false) })
    }

    @Test func primaryListFailureFailsTheArea() async throws {
        let network = try await ServiceStub.service(ServiceStub.transport(
            list: .transport(.unreachable(code: -1004)), clients: .fixture("control-clients-4.9.1"), stats: .fixture("control-stats-4.9.1"))).inventory()
        guard case .failure(let category, _) = network.area else { Issue.record("expected failure"); return }
        #expect(category == .network)
        #expect(network.capability.state == .unknown)

        let missing = try await ServiceStub.service(ServiceStub.transport(
            list: .rpcError(-32601), clients: .fixture("control-clients-4.9.1"), stats: .fixture("control-stats-4.9.1"))).inventory()
        guard case .failure(.unavailable, _) = missing.area else { Issue.record("expected unavailable"); return }
        #expect(missing.capability.state == .unsupported)
        #expect(missing.capability.evidence == .methodNotFound(method: "clients.get_list"))

        let malformed = try await ServiceStub.service(ServiceStub.transport(
            list: .body(.object(["other": .bool(true)])), clients: .status(500), stats: .status(500))).inventory()
        guard case .failure(.malformedResponse, _) = malformed.area else { Issue.record("expected malformed"); return }
    }

    @Test func sessionFenceRejectsAStaleLease() async throws {
        let backend = MockRouterBackend()
        let session = RouterSession()
        let old = SessionToken(profileID: "home", revision: 1)
        let lease = SessionLease(token: old, backend: backend)
        try await session.beginRevision(old)
        try await session.installLease(lease)
        #expect(try await session.query(lease) { try await $0.clients?.inventory() } != nil)
        try await session.beginRevision(SessionToken(profileID: "home", revision: 2))
        await #expect(throws: SessionError.self) { try await session.query(lease) { try await $0.clients?.inventory() } }
    }
}

@Suite struct MockClientsScenarioTests {
    private func inventory(_ scenario: MockClientsService.Scenario) async throws -> AreaRefreshResult<ClientInventory> {
        let backend = MockRouterBackend()
        await backend.setClientsScenario(scenario)
        return try await backend.mockClients.inventory().area
    }

    @Test func seedRegistryMakesThreeDevicesNew() async throws {
        let seed = MockClientsService.seedRegistry(now: .now)
        guard case .success(let withNew, _, _) = try await inventory(.newDevices) else { Issue.record("newDevices"); return }
        let registry = DeviceRegistry(store: nil, initial: seed)
        let observation = try await registry.observe(withNew.clients, at: .now)
        #expect(observation.newDevices.count == 3)
        let entries = ClientListing.entries(clients: withNew.clients, records: observation.state.records)
        #expect(entries.filter { $0.presence == .absent }.count == 3)
    }

    @Test func featureBehaviorControlsCapability() async throws {
        let backend = MockRouterBackend()
        #expect(MockRouterBackend.defaultFeatureBehavior(for: .clients) == .supported)
        #expect(try await backend.mockClients.inventory().capability.state == .supported)
        await backend.setFeatureBehavior(.unsupported, for: .clients)
        let unsupported = try await backend.mockClients.inventory()
        #expect(unsupported.capability.state == .unsupported)
        guard case .failure(.unavailable, _) = unsupported.area else { Issue.record("expected unavailable"); return }
        await backend.setFeatureBehavior(.failing, for: .clients)
        #expect(try await backend.mockClients.inventory().capability.state == .unknown)
    }
}

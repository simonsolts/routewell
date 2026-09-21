import Foundation
import Testing
@testable import RoutewellKit

private func fixtureEnvelope(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/glinet")!
    return try! Data(contentsOf: url)
}

private func fixtureData(_ name: String, subdirectory: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory)!
    return try! Data(contentsOf: url)
}

/// One canned outcome for an authenticated `object.method` RPC call.
private enum MethodOutcome: Sendable {
    case fixture(String) // fixture name under Fixtures/glinet, used verbatim as the response envelope
    case rpcError(code: Int)
    case transportError(TransportError)
}

/// One canned outcome for an AdGuard HTTP request.
private enum AdGuardOutcome: Sendable {
    case fixture(String) // fixture name under Fixtures/adguard
    case httpStatus(Int)
    case transportError(TransportError)
}

private actor CallCounter {
    private var counts: [String: Int] = [:]
    func increment(_ key: String) -> Int {
        let value = (counts[key] ?? 0) + 1
        counts[key] = value
        return value
    }
    func count(_ key: String) -> Int { counts[key] ?? 0 }
}

private enum LiveFixtures {
    static let endpoint = try! RouterEndpoint(scheme: .https, host: "192.0.2.20", port: 443)
    static let rpcURL = endpoint.url.appendingPathComponent("rpc")
    static let adGuardBaseURL = URL(string: "http://192.0.2.20:3000/")!

    static let challengeResult: JSONValue = .object([
        "alg": .number(1),
        "salt": .string("saltsalt12"),
        "nonce": .string("nonceabcdef"),
    ])

    static func decodedBody(_ request: URLRequest) -> JSONValue? {
        guard let body = request.httpBody else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: body)
    }

    static func requestID(_ request: URLRequest) -> Int? { decodedBody(request)?["id"]?.int }

    static func okResponse(id: Int, result: JSONValue, url: URL) -> (Data, HTTPURLResponse) {
        let envelope: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result])
        return (try! JSONEncoder().encode(envelope), StubHTTPTransport.response(200, url: url))
    }

    static func errorResponse(id: Int, code: Int, url: URL) -> (Data, HTTPURLResponse) {
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "error": .object(["code": .number(Double(code)), "message": .string("err")]),
        ])
        return (try! JSONEncoder().encode(envelope), StubHTTPTransport.response(200, url: url))
    }

    /// Builds a `StubHTTPTransport` that serves the GL.iNet login handshake
    /// automatically, dispatches authenticated `call`s by `object.method` to
    /// `methods`, and dispatches `control/status`/`control/stats` requests to
    /// `adGuard`. `attempt` lets a method behave differently the Nth time it
    /// is invoked (used by the trust-retry tests).
    static func makeTransport(
        methods: [String: @Sendable (Int) -> MethodOutcome],
        adGuard: [String: @Sendable (Int) -> AdGuardOutcome] = [:],
        counter: CallCounter = CallCounter()
    ) -> StubHTTPTransport {
        StubHTTPTransport { request in
            let url = request.url!
            if url.path.hasPrefix("/control/") {
                let key = String(url.path.dropFirst("/control/".count))
                let n = await counter.increment("adguard:\(key)")
                guard let outcome = adGuard[key]?(n) else {
                    Issue.record("unscripted AdGuard path \(key)")
                    return (Data(), StubHTTPTransport.response(404, url: url))
                }
                switch outcome {
                case .fixture(let name):
                    return (fixtureData(name, subdirectory: "Fixtures/adguard"), StubHTTPTransport.response(200, url: url))
                case .httpStatus(let status):
                    return (Data(), StubHTTPTransport.response(status, url: url))
                case .transportError(let error):
                    throw error
                }
            }

            let id = requestID(request) ?? 0
            guard let body = decodedBody(request), let method = body["method"]?.string else {
                Issue.record("undecodable request")
                return (Data(), StubHTTPTransport.response(400, url: url))
            }
            switch method {
            case "challenge":
                return okResponse(id: id, result: challengeResult, url: url)
            case "login":
                return okResponse(id: id, result: .object(["username": .string("root"), "sid": .string("SID-LIVE")]), url: url)
            case "call":
                guard let params = body["params"]?.array, params.count == 4,
                      let object = params[1].string, let methodName = params[2].string else {
                    Issue.record("malformed call params")
                    return (Data(), StubHTTPTransport.response(400, url: url))
                }
                let key = "\(object).\(methodName)"
                let n = await counter.increment(key)
                guard let outcome = methods[key]?(n) else {
                    Issue.record("unscripted call \(key)")
                    return (Data(), StubHTTPTransport.response(404, url: url))
                }
                switch outcome {
                case .fixture(let name):
                    let envelope = fixtureEnvelope(name)
                    guard let value = try? JSONDecoder().decode(JSONValue.self, from: envelope), let result = value["result"] else {
                        Issue.record("fixture \(name) has no result")
                        return (Data(), StubHTTPTransport.response(500, url: url))
                    }
                    return okResponse(id: id, result: result, url: url)
                case .rpcError(let code):
                    return errorResponse(id: id, code: code, url: url)
                case .transportError(let error):
                    throw error
                }
            default:
                Issue.record("unexpected method \(method)")
                return (Data(), StubHTTPTransport.response(400, url: url))
            }
        }
    }

    static func makeBackend(
        transport: StubHTTPTransport,
        adGuardSettings: AdGuardSettings? = AdGuardSettings(port: 3000, useRouterCredentials: true),
        trustStore: any EndpointTrustStore = InMemoryEndpointTrustStore(),
        trustPrompt: any TrustPromptHandler = DenyAllTrustPromptHandler(),
        clock: @Sendable @escaping () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    ) -> LiveRouterBackend {
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: "root", password: { "correct horse" }, transport: transport)
        let adGuardClient: AdGuardClient? = adGuardSettings == nil ? nil : AdGuardClient(
            baseURL: adGuardBaseURL,
            credentials: RouterTokenAdGuardCredentials(session: rpc),
            transport: transport
        )
        let configuration = LiveBackendConfiguration(
            routerEndpoint: endpoint,
            adGuard: adGuardSettings,
            adGuardBaseURL: adGuardSettings == nil ? nil : adGuardBaseURL
        )
        return LiveRouterBackend(
            configuration: configuration,
            rpc: rpc,
            adGuard: adGuardClient,
            trustStore: trustStore,
            trustPrompt: trustPrompt,
            clock: clock
        )
    }
}

private actor SpyTrustPromptHandler: TrustPromptHandler {
    private(set) var callCount = 0
    private let answer: Bool
    init(answer: Bool) { self.answer = answer }
    func requestTrust(host: String, port: Int, decision: TrustDecision) async -> Bool {
        callCount += 1
        return answer
    }
}

// MARK: - All four areas succeed from fixtures

@Test func allFourAreasSucceedFromFixtures() async throws {
    let counter = CallCounter()
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { _ in .fixture("system-get_status") },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .fixture("cable-get_status") },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .fixture("control-status") },
            "stats": { _ in .fixture("control-stats") },
        ],
        counter: counter
    )
    let backend = LiveFixtures.makeBackend(transport: transport)

    let result = try await backend.overview()

    guard case .success(let router, _, let routerSource) = result.router else {
        Issue.record("expected router success, got \(result.router)"); return
    }
    #expect(router.model == "GL Technologies, Inc. AXT1800")
    #expect(router.hostname == "GL-AXT1800")
    #expect(routerSource == .routerRPC)

    guard case .success(let internet, _, _) = result.internet else {
        Issue.record("expected internet success, got \(result.internet)"); return
    }
    #expect(internet.reachability == .unreachable) // fixture's wan entry has online:false
    #expect(internet.gateway == "192.168.113.1")

    guard case .success(let adGuard, _, let adGuardSource) = result.adGuard else {
        Issue.record("expected adGuard success, got \(result.adGuard)"); return
    }
    #expect(adGuard.protection == .enabled)
    #expect(adGuard.queriesToday == 1234)
    #expect(adGuardSource == .adGuardAPI)

    guard case .success(let clients, _, _) = result.clients else {
        Issue.record("expected clients success, got \(result.clients)"); return
    }
    #expect(clients.activeCount == .value(1))
}

// MARK: - AdGuard 403 fails only the AdGuard area

@Test func adGuard403FailsOnlyAdGuardArea() async throws {
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { _ in .fixture("system-get_status") },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .fixture("cable-get_status") },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .httpStatus(403) },
        ]
    )
    let backend = LiveFixtures.makeBackend(transport: transport)

    let result = try await backend.overview()

    guard case .failure(let category, _) = result.adGuard else {
        Issue.record("expected adGuard failure, got \(result.adGuard)"); return
    }
    #expect(category == .authentication)

    guard case .success = result.router else { Issue.record("expected router success"); return }
    guard case .success = result.internet else { Issue.record("expected internet success"); return }
    guard case .success = result.clients else { Issue.record("expected clients success"); return }
}

// MARK: - AdGuard stats 403 fails the area (unlike a missing/malformed stats window)

@Test func adGuardStats403FailsAreaWithAuthentication() async throws {
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { _ in .fixture("system-get_status") },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .fixture("cable-get_status") },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .fixture("control-status") },
            "stats": { _ in .httpStatus(403) },
        ]
    )
    let backend = LiveFixtures.makeBackend(transport: transport)

    let result = try await backend.overview()

    guard case .failure(let category, _) = result.adGuard else {
        Issue.record("expected adGuard failure, got \(result.adGuard)"); return
    }
    #expect(category == .authentication)

    guard case .success = result.router else { Issue.record("expected router success"); return }
    guard case .success = result.internet else { Issue.record("expected internet success"); return }
    guard case .success = result.clients else { Issue.record("expected clients success"); return }
}

// MARK: - cable.get_status -32601 leaves internet succeeding from get_status alone

@Test func cableMethodNotFoundLeavesInternetSucceedingFromStatus() async throws {
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { _ in .fixture("system-get_status") },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .rpcError(code: -32601) },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .fixture("control-status") },
            "stats": { _ in .fixture("control-stats") },
        ]
    )
    let backend = LiveFixtures.makeBackend(transport: transport)

    let result = try await backend.overview()

    guard case .success(let internet, _, _) = result.internet else {
        Issue.record("expected internet success, got \(result.internet)"); return
    }
    #expect(internet.reachability == .unreachable) // reachability still derived from get_status
    #expect(internet.gateway == nil) // cable's fields are absent since cable.get_status failed
    #expect(internet.publicAddress == nil)
}

// MARK: - router timeout fails router and internet, leaves adGuard and clients succeeding

@Test func routerTimeoutFailsRouterAndInternetOnly() async throws {
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { _ in .transportError(.timedOut) },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .fixture("cable-get_status") },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .fixture("control-status") },
            "stats": { _ in .fixture("control-stats") },
        ]
    )
    let backend = LiveFixtures.makeBackend(transport: transport)

    let result = try await backend.overview()

    guard case .failure(let routerCategory, _) = result.router else {
        Issue.record("expected router failure, got \(result.router)"); return
    }
    #expect(routerCategory == .timeout)

    guard case .failure(let internetCategory, _) = result.internet else {
        Issue.record("expected internet failure, got \(result.internet)"); return
    }
    #expect(internetCategory == .timeout)

    guard case .success = result.adGuard else { Issue.record("expected adGuard success"); return }
    guard case .success = result.clients else { Issue.record("expected clients success"); return }
}

// MARK: - Untrusted certificate: one prompt, approval stored, overview retried and succeeds

@Test func untrustedCertificateApprovedIsStoredAndOverviewRetriedOnce() async throws {
    let trustPrompt = SpyTrustPromptHandler(answer: true)
    let trustStore = InMemoryEndpointTrustStore()
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { attempt in attempt == 1 ? .transportError(.untrustedServer(.untrustedNew(try! CertificateFingerprint(sha256: Data(repeating: 7, count: 32))))) : .fixture("system-get_status") },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .fixture("cable-get_status") },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .fixture("control-status") },
            "stats": { _ in .fixture("control-stats") },
        ]
    )
    let backend = LiveFixtures.makeBackend(transport: transport, trustStore: trustStore, trustPrompt: trustPrompt)

    let result = try await backend.overview()

    guard case .success = result.router else { Issue.record("expected router success after retry, got \(result.router)"); return }
    guard case .success = result.internet else { Issue.record("expected internet success after retry"); return }
    guard case .success = result.clients else { Issue.record("expected clients success after retry"); return }

    let promptCalls = await trustPrompt.callCount
    #expect(promptCalls == 1)

    let stored = await trustStore.all()
    #expect(stored.count == 1)
    #expect(stored.first?.host == LiveFixtures.endpoint.host)
    #expect(stored.first?.port == LiveFixtures.endpoint.port)
}

// MARK: - Untrusted certificate refused: everything fails .network, nothing stored

@Test func untrustedCertificateRefusedFailsAllAreasAndStoresNothing() async throws {
    let trustPrompt = SpyTrustPromptHandler(answer: false)
    let trustStore = InMemoryEndpointTrustStore()
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { _ in .transportError(.untrustedServer(.untrustedNew(try! CertificateFingerprint(sha256: Data(repeating: 7, count: 32))))) },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .fixture("cable-get_status") },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .fixture("control-status") },
            "stats": { _ in .fixture("control-stats") },
        ]
    )
    let backend = LiveFixtures.makeBackend(transport: transport, trustStore: trustStore, trustPrompt: trustPrompt)

    let result = try await backend.overview()

    for area in [result.router.categoryOrNil, result.internet.categoryOrNil, result.adGuard.categoryOrNil, result.clients.categoryOrNil] {
        #expect(area == .network)
    }

    let promptCalls = await trustPrompt.callCount
    #expect(promptCalls == 1)

    let stored = await trustStore.all()
    #expect(stored.isEmpty)
}

// MARK: - get_status is fetched exactly once per overview

@Test func getStatusIsCalledExactlyOncePerOverview() async throws {
    let counter = CallCounter()
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { _ in .fixture("system-get_status") },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .fixture("cable-get_status") },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .fixture("control-status") },
            "stats": { _ in .fixture("control-stats") },
        ],
        counter: counter
    )
    let backend = LiveFixtures.makeBackend(transport: transport)

    _ = try await backend.overview()

    let count = await counter.count("system.get_status")
    #expect(count == 1)
}

// MARK: - probe()

@Test func probeReturnsModelFirmwareAndHostnameFromGetInfo() async throws {
    let transport = LiveFixtures.makeTransport(methods: [
        "system.get_info": { _ in .fixture("system-get_info") },
    ])
    let backend = LiveFixtures.makeBackend(transport: transport)

    let probe = try await backend.probe()
    #expect(probe.model == "GL Technologies, Inc. AXT1800")
    #expect(probe.firmware == "4.0.0")
    #expect(probe.hostname == "GL-AXT1800")
}

// MARK: - Cancellation propagates

@Test func cancellationPropagatesOutOfOverview() async throws {
    let transport = LiveFixtures.makeTransport(methods: [
        "system.get_status": { _ in .fixture("system-get_status") },
        "system.get_info": { _ in .fixture("system-get_info") },
        "cable.get_status": { _ in .fixture("cable-get_status") },
        "clients.get_list": { _ in .fixture("clients-get_list") },
        "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
    ])
    // A backend that stalls on every authenticated call, so cancellation is
    // the only way the awaited task finishes. The login handshake itself
    // (challenge/login) runs on GLiNetRPCClient's own shared, unstructured
    // login task, which does not observe this outer task's cancellation, so
    // it is left unstalled here to keep the test fast.
    let stallingTransport = StubHTTPTransport { request in
        guard let method = LiveFixtures.decodedBody(request)?["method"]?.string, method == "call" else {
            return try await transport.send(request, limits: .init())
        }
        for _ in 0..<1000 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try await transport.send(request, limits: .init())
    }
    let backend = LiveFixtures.makeBackend(transport: stallingTransport)

    let task = Task { try await backend.overview() }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
}

// MARK: - TransportError.cancelled surfaces as cancellation, not a .network failure

@Test func transportCancelledSurfacesAsCancellationNotNetworkFailure() async throws {
    let transport = LiveFixtures.makeTransport(
        methods: [
            "system.get_status": { _ in .transportError(.cancelled) },
            "system.get_info": { _ in .fixture("system-get_info") },
            "cable.get_status": { _ in .fixture("cable-get_status") },
            "clients.get_list": { _ in .fixture("clients-get_list") },
            "adguardhome.get_config": { _ in .fixture("adguardhome-get_config") },
        ],
        adGuard: [
            "status": { _ in .fixture("control-status") },
            "stats": { _ in .fixture("control-stats") },
        ]
    )
    let backend = LiveFixtures.makeBackend(transport: transport)

    let task = Task { try await backend.overview() }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
}

private extension AreaRefreshResult {
    var categoryOrNil: RefreshFailureCategory? {
        if case .failure(let category, _) = self { return category }
        return nil
    }
}

import Foundation
import Testing
@testable import RoutewellKit

/// Counts requests by JSON-RPC `method`, and lets a handler pick a different
/// canned response for the Nth request of a given method (e.g. "the first
/// `call` fails, the second succeeds").
private actor RPCCallCounter {
    private var counts: [String: Int] = [:]

    func next(_ method: String) -> Int {
        let value = (counts[method] ?? 0) + 1
        counts[method] = value
        return value
    }

    func count(_ method: String) -> Int { counts[method] ?? 0 }
}

private enum RPCFixtures {
    static let endpoint = try! RouterEndpoint(scheme: .https, host: "192.0.2.10", port: 443)
    static let rpcURL = endpoint.url.appendingPathComponent("rpc")

    static let challengeResult: JSONValue = .object([
        "alg": .number(1),
        "salt": .string("saltsalt12"),
        "nonce": .string("nonceabcdef"),
    ])

    static func decodedBody(_ request: URLRequest) -> JSONValue? {
        guard let body = request.httpBody else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: body)
    }

    static func method(_ request: URLRequest) -> String? {
        decodedBody(request)?["method"]?.string
    }

    static func requestID(_ request: URLRequest) -> Int? {
        decodedBody(request)?["id"]?.int
    }

    static func okResponse(id: Int, result: JSONValue) -> (Data, HTTPURLResponse) {
        let envelope: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result])
        let data = try! JSONEncoder().encode(envelope)
        return (data, StubHTTPTransport.response(200, url: rpcURL))
    }

    static func errorResponse(id: Int, code: Int, message: String = "error") -> (Data, HTTPURLResponse) {
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ])
        let data = try! JSONEncoder().encode(envelope)
        return (data, StubHTTPTransport.response(200, url: rpcURL))
    }

    static func loginResponse(id: Int, sid: String) -> (Data, HTTPURLResponse) {
        okResponse(id: id, result: .object(["username": .string("root"), "sid": .string(sid)]))
    }

    static func makeClient(
        password: @Sendable @escaping () async throws -> String = { "correct horse" },
        transport: any HTTPTransport
    ) -> GLiNetRPCClient {
        GLiNetRPCClient(endpoint: endpoint, username: "root", password: password, transport: transport)
    }
}

// MARK: - Happy path: login then call, sid in params[0] and Cookie header

@Test func happyLoginThenCallSendsSIDInParamsAndCookie() async throws {
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge": return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        case "login": return RPCFixtures.loginResponse(id: id, sid: "SID-A")
        case "call": return RPCFixtures.okResponse(id: id, result: .object(["online": .bool(true)]))
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    let result = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    #expect(result["online"]?.bool == true)

    let recorded = await stub.recorded()
    #expect(recorded.count == 3)

    let challengeBody = try #require(RPCFixtures.decodedBody(recorded[0].request))
    #expect(challengeBody["method"]?.string == "challenge")
    #expect(challengeBody["params"]?["username"]?.string == "root")
    #expect(challengeBody["jsonrpc"]?.string == "2.0")

    let loginBody = try #require(RPCFixtures.decodedBody(recorded[1].request))
    #expect(loginBody["method"]?.string == "login")
    #expect(loginBody["params"]?["username"]?.string == "root")
    #expect(loginBody["params"]?["hash"]?.string != nil)

    let callBody = try #require(RPCFixtures.decodedBody(recorded[2].request))
    #expect(callBody["method"]?.string == "call")
    let callParams = try #require(callBody["params"]?.array)
    #expect(callParams.count == 4)
    #expect(callParams[0].string == "SID-A")
    #expect(callParams[1].string == "system")
    #expect(callParams[2].string == "get_status")
    #expect(recorded[2].request.value(forHTTPHeaderField: "Cookie") == "Admin-Token=SID-A")
    #expect(recorded[2].request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(recorded[2].request.httpMethod == "POST")
    // The two earlier requests (challenge, login) are unauthenticated and must not carry the cookie.
    #expect(recorded[0].request.value(forHTTPHeaderField: "Cookie") == nil)
}

// MARK: - Shared in-flight login

@Test func tenConcurrentCallsTriggerExactlyOneChallengeAndOneLogin() async throws {
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge": return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        case "login": return RPCFixtures.loginResponse(id: id, sid: "SID-SHARED")
        case "call": return RPCFixtures.okResponse(id: id, result: .object(["ok": .bool(true)]))
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    try await withThrowingTaskGroup(of: JSONValue.self) { group in
        for _ in 0..<10 {
            group.addTask { try await client.call(.init(object: "system", method: "get_status", params: .object([:]))) }
        }
        for try await result in group {
            #expect(result["ok"]?.bool == true)
        }
    }

    let recorded = await stub.recorded()
    let methods = recorded.compactMap { RPCFixtures.method($0.request) }
    #expect(methods.filter { $0 == "challenge" }.count == 1)
    #expect(methods.filter { $0 == "login" }.count == 1)
    #expect(methods.filter { $0 == "call" }.count == 10)
}

// MARK: - Retry once on access denied

@Test func accessDeniedOnCallInvalidatesRelogsInAndRetriesOnceThenSucceeds() async throws {
    let counter = RPCCallCounter()
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge": return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        case "login":
            let n = await counter.next("login")
            return RPCFixtures.loginResponse(id: id, sid: n == 1 ? "SID-1" : "SID-2")
        case "call":
            let n = await counter.next("call")
            if n == 1 { return RPCFixtures.errorResponse(id: id, code: -32000, message: "Access denied") }
            return RPCFixtures.okResponse(id: id, result: .object(["ok": .bool(true)]))
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    let result = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    #expect(result["ok"]?.bool == true)
    #expect(await counter.count("challenge") == 0) // challenge isn't tracked by this counter; login/call are
    #expect(await counter.count("login") == 2)
    #expect(await counter.count("call") == 2)

    let recorded = await stub.recorded()
    let secondCallRequest = recorded.last { RPCFixtures.method($0.request) == "call" }!.request
    #expect(secondCallRequest.value(forHTTPHeaderField: "Cookie") == "Admin-Token=SID-2")
}

// MARK: - Access denied twice: no further retry

@Test func accessDeniedTwiceStopsAfterTwoPairsAndTwoCalls() async throws {
    let counter = RPCCallCounter()
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge":
            _ = await counter.next("challenge")
            return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        case "login":
            let n = await counter.next("login")
            return RPCFixtures.loginResponse(id: id, sid: "SID-\(n)")
        case "call":
            _ = await counter.next("call")
            return RPCFixtures.errorResponse(id: id, code: -32000, message: "Access denied")
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    await #expect(throws: GLiNetRPCError.accessDenied) {
        _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    }

    #expect(await counter.count("challenge") == 2)
    #expect(await counter.count("login") == 2)
    #expect(await counter.count("call") == 2)
}

// MARK: - Method not found

@Test func methodNotFoundMapsToObjectDotMethod() async throws {
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge": return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        case "login": return RPCFixtures.loginResponse(id: id, sid: "SID-A")
        case "call": return RPCFixtures.errorResponse(id: id, code: -32601, message: "Method not found")
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    await #expect(throws: GLiNetRPCError.methodNotFound("system.get_status")) {
        _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    }
}

// MARK: - Non-200 HTTP status

@Test func nonHTTP200MapsToHTTPStatus() async throws {
    let stub = StubHTTPTransport { request in
        (Data(), StubHTTPTransport.response(503, url: RPCFixtures.rpcURL))
    }
    let client = RPCFixtures.makeClient(transport: stub)

    await #expect(throws: GLiNetRPCError.httpStatus(503)) {
        _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    }
}

// MARK: - Non-JSON body

@Test func nonJSONBodyMapsToMalformedResponse() async throws {
    let stub = StubHTTPTransport { request in
        (Data("not json".utf8), StubHTTPTransport.response(200, url: RPCFixtures.rpcURL))
    }
    let client = RPCFixtures.makeClient(transport: stub)

    await #expect(throws: GLiNetRPCError.malformedResponse) {
        _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    }
}

// MARK: - Unsupported algorithm

@Test func unsupportedAlgorithmPropagatesFromChallenge() async throws {
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge":
            let result: JSONValue = .object(["alg": .number(7), "salt": .string("s"), "nonce": .string("n")])
            return RPCFixtures.okResponse(id: id, result: result)
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    await #expect(throws: GLiNetRPCError.unsupportedAlgorithm(7)) {
        _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    }
}

// MARK: - alg as numeric string is accepted

@Test func challengeAlgAsStringIsAcceptedAndLoginSucceeds() async throws {
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge":
            let result: JSONValue = .object(["alg": .string("1"), "salt": .string("saltsalt12"), "nonce": .string("nonceabcdef")])
            return RPCFixtures.okResponse(id: id, result: result)
        case "login": return RPCFixtures.loginResponse(id: id, sid: "SID-A")
        case "call": return RPCFixtures.okResponse(id: id, result: .object(["ok": .bool(true)]))
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    let result = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    #expect(result["ok"]?.bool == true)
}

// MARK: - Transport error passthrough

@Test func redirectRefusedFromTransportIsWrapped() async throws {
    struct FailingTransport: HTTPTransport {
        func send(_ request: URLRequest, limits: HTTPRequestLimits) async throws -> (Data, HTTPURLResponse) {
            throw TransportError.redirectRefused(to: "evil.example")
        }
    }
    let client = RPCFixtures.makeClient(transport: FailingTransport())

    await #expect(throws: GLiNetRPCError.transport(.redirectRefused(to: "evil.example"))) {
        _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    }
}

// MARK: - Credential unavailable

@Test func credentialUnavailablePropagatesFromPasswordProvider() async throws {
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge": return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(password: { throw CredentialError.missing }, transport: stub)

    await #expect(throws: GLiNetRPCError.credentialUnavailable(.missing)) {
        _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    }
}

// MARK: - Access denied on challenge/login themselves: no retry

@Test func accessDeniedOnChallengeItselfIsNotRetried() async throws {
    let counter = RPCCallCounter()
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge":
            _ = await counter.next("challenge")
            return RPCFixtures.errorResponse(id: id, code: -32000, message: "Access denied")
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    await #expect(throws: GLiNetRPCError.accessDenied) {
        _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))
    }
    #expect(await counter.count("challenge") == 1)
}

// MARK: - keepAlive

@Test func keepAliveReturnsTrueWhenSIDStillValid() async throws {
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge": return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        case "login": return RPCFixtures.loginResponse(id: id, sid: "SID-A")
        case "alive":
            #expect(request.value(forHTTPHeaderField: "Cookie") == "Admin-Token=SID-A")
            return RPCFixtures.okResponse(id: id, result: .null)
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    let alive = try await client.keepAlive()
    #expect(alive == true)
}

@Test func keepAliveReturnsFalseOnAccessDenied() async throws {
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge": return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        case "login": return RPCFixtures.loginResponse(id: id, sid: "SID-A")
        case "alive": return RPCFixtures.errorResponse(id: id, code: -32000, message: "Access denied")
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = RPCFixtures.makeClient(transport: stub)

    let alive = try await client.keepAlive()
    #expect(alive == false)
}

// MARK: - Logging never carries secrets

@Test func logEventsNeverContainSIDHashPasswordNonceOrSalt() async throws {
    let log = SessionEventLog()
    let stub = StubHTTPTransport { request in
        let id = RPCFixtures.requestID(request) ?? 0
        switch RPCFixtures.method(request) {
        case "challenge": return RPCFixtures.okResponse(id: id, result: RPCFixtures.challengeResult)
        case "login": return RPCFixtures.loginResponse(id: id, sid: "SID-SECRET-VALUE")
        case "call": return RPCFixtures.okResponse(id: id, result: .object(["ok": .bool(true)]))
        default: Issue.record("unexpected method"); return RPCFixtures.errorResponse(id: id, code: -1)
        }
    }
    let client = GLiNetRPCClient(endpoint: RPCFixtures.endpoint, username: "root", password: { "correct horse" }, transport: stub, log: log)

    _ = try await client.call(.init(object: "system", method: "get_status", params: .object([:])))

    let events = await log.events()
    #expect(!events.isEmpty)
    for event in events {
        #expect(!event.message.contains("SID-SECRET-VALUE"))
        #expect(!event.message.lowercased().contains("nonceabcdef"))
        #expect(!event.message.lowercased().contains("saltsalt12"))
        #expect(!event.message.lowercased().contains("correct horse"))
    }
}

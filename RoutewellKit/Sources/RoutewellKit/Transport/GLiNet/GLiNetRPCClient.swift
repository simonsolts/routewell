import Foundation

/// A GL.iNet JSON-RPC client: login (challenge → hash → login), authenticated
/// `call`s, and `alive` keep-alives, all over the `/rpc` endpoint.
///
/// Concurrency: login is shared. When several callers need a session at
/// once, only one `challenge`/`login` round trip happens; the rest await the
/// same in-flight login. A read that fails with `-32000` (access denied) is
/// retried exactly once, after re-logging in.
public actor GLiNetRPCClient: RouterSessionTokenProvider {
    private let endpoint: RouterEndpoint
    private let username: String
    private let passwordProvider: @Sendable () async throws -> String
    private let transport: any HTTPTransport
    private let limits: HTTPRequestLimits
    private let log: SessionEventLog?

    private var sid: String?
    private var inFlightLogin: Task<String, Error>?
    private var requestCounter: Int = 0

    public init(
        endpoint: RouterEndpoint,
        username: String,
        password: @Sendable @escaping () async throws -> String,
        transport: any HTTPTransport,
        limits: HTTPRequestLimits = .init(),
        log: SessionEventLog? = nil
    ) {
        self.endpoint = endpoint
        self.username = username
        self.passwordProvider = password
        self.transport = transport
        self.limits = limits
        self.log = log
    }

    /// "https://host:port/rpc".
    public var rpcURL: URL { endpoint.url.appendingPathComponent("rpc") }

    // MARK: RouterSessionTokenProvider

    public func sessionID() async throws -> String {
        if let sid { return sid }
        return try await login()
    }

    public func invalidateSession() async {
        sid = nil
    }

    // MARK: Authenticated calls

    /// Authenticated call. Retries once after `accessDenied` by re-logging in.
    public func call(_ call: GLiNetRPCCall) async throws -> JSONValue {
        let firstSID = try await sessionID()
        do {
            return try await performCall(call, sid: firstSID)
        } catch GLiNetRPCError.accessDenied {
            await invalidateSession()
            let secondSID = try await login()
            return try await performCall(call, sid: secondSID)
        }
    }

    /// Calls `alive`. Returns true when the sid is still valid.
    public func keepAlive() async throws -> Bool {
        let currentSID = try await sessionID()
        do {
            _ = try await performRPC(
                name: "alive", method: "alive",
                params: .object(["sid": .string(currentSID)]), cookie: currentSID
            )
            return true
        } catch GLiNetRPCError.accessDenied {
            await invalidateSession()
            return false
        }
    }

    // MARK: Login

    private func login() async throws -> String {
        if let inFlightLogin {
            return try await inFlightLogin.value
        }
        let task = Task { try await self.performLogin() }
        inFlightLogin = task
        defer { inFlightLogin = nil }
        return try await task.value
    }

    private func performLogin() async throws -> String {
        let challenge = try await requestChallenge()

        let password: String
        do {
            password = try await passwordProvider()
        } catch let credentialError as CredentialError {
            throw GLiNetRPCError.credentialUnavailable(credentialError)
        } catch {
            throw GLiNetRPCError.credentialUnavailable(.unexpected)
        }

        let hash = try GLiNetLoginHasher.loginHash(username: username, password: password, challenge: challenge)
        let newSID = try await requestLogin(hash: hash)
        sid = newSID
        return newSID
    }

    private func requestChallenge() async throws -> GLiNetChallenge {
        let result = try await performRPC(
            name: "challenge", method: "challenge",
            params: .object(["username": .string(username)])
        )
        return try GLiNetChallenge(result: result)
    }

    private func requestLogin(hash: String) async throws -> String {
        let result = try await performRPC(
            name: "login", method: "login",
            params: .object(["username": .string(username), "hash": .string(hash)])
        )
        guard let newSID = result["sid"]?.string else { throw GLiNetRPCError.malformedResponse }
        return newSID
    }

    private func performCall(_ call: GLiNetRPCCall, sid: String) async throws -> JSONValue {
        let context = "\(call.object).\(call.method)"
        let params: JSONValue = .array([.string(sid), .string(call.object), .string(call.method), call.params])
        return try await performRPC(name: context, method: "call", params: params, cookie: sid, methodContext: context)
    }

    // MARK: Wire format

    private func nextRequestID() -> Int {
        requestCounter += 1
        return requestCounter
    }

    private func performRPC(
        name: String,
        method: String,
        params: JSONValue,
        cookie: String? = nil,
        methodContext: String? = nil
    ) async throws -> JSONValue {
        let id = nextRequestID()
        let body: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])

        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie {
            request.setValue("Admin-Token=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)

        do {
            let (data, response) = try await transport.send(request, limits: limits)
            let envelope = try Self.decodeEnvelope(data, statusCode: response.statusCode)
            let result = try Self.extractResult(envelope, methodContext: methodContext)
            await logRPC(name: name, outcome: .success(data.count))
            return result
        } catch let error as GLiNetRPCError {
            await logRPC(name: name, outcome: .failure(error))
            throw error
        } catch let error as TransportError {
            let wrapped = GLiNetRPCError.transport(error)
            await logRPC(name: name, outcome: .failure(wrapped))
            throw wrapped
        }
    }

    private static func decodeEnvelope(_ data: Data, statusCode: Int) throws -> JSONValue {
        guard statusCode == 200 else { throw GLiNetRPCError.httpStatus(statusCode) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw GLiNetRPCError.malformedResponse
        }
        guard case .object(let object) = value, object["jsonrpc"] != nil else {
            throw GLiNetRPCError.malformedResponse
        }
        return value
    }

    private static func extractResult(_ envelope: JSONValue, methodContext: String?) throws -> JSONValue {
        guard case .object(let object) = envelope else { throw GLiNetRPCError.malformedResponse }
        if let errorValue = object["error"] {
            throw mapError(errorValue, methodContext: methodContext)
        }
        if let result = object["result"] {
            return result
        }
        throw GLiNetRPCError.malformedResponse
    }

    /// `message` is never surfaced beyond 120 characters and `params` is
    /// never echoed, so a leaked sid or hash in a server-sent error string
    /// cannot make it into `.rpcError`.
    private static func mapError(_ error: JSONValue, methodContext: String?) -> GLiNetRPCError {
        guard let code = error["code"]?.int else { return .malformedResponse }
        switch code {
        case -32000:
            return .accessDenied
        case -32601:
            return .methodNotFound(methodContext ?? "")
        case -32602:
            return .invalidParameters
        default:
            let message = String((error["message"]?.string ?? "").prefix(120))
            return .rpcError(code: code, message: message)
        }
    }

    // MARK: Logging (never a secret: no sid, hash, password, nonce, or salt)

    private enum RPCOutcome {
        case success(Int)
        case failure(GLiNetRPCError)
    }

    private func logRPC(name: String, outcome: RPCOutcome) async {
        guard let log else { return }
        switch outcome {
        case .success(let bytes):
            await log.record(LogEvent(level: .info, kind: .transport, message: "rpc \(name) ok \(bytes) bytes"))
        case .failure(let error):
            await log.record(LogEvent(level: .warning, kind: .transport, message: "rpc \(name) failed \(Self.failureLabel(error))"))
        }
    }

    private static func failureLabel(_ error: GLiNetRPCError) -> String {
        switch error {
        case .transport: return "transport"
        case .httpStatus(let code): return "httpStatus(\(code))"
        case .malformedResponse: return "malformedResponse"
        case .accessDenied: return "accessDenied"
        case .methodNotFound: return "methodNotFound"
        case .invalidParameters: return "invalidParameters"
        case .rpcError(let code, _): return "rpcError(\(code))"
        case .unsupportedAlgorithm(let alg): return "unsupportedAlgorithm(\(alg))"
        case .unsupportedHashMethod: return "unsupportedHashMethod"
        case .credentialUnavailable: return "credentialUnavailable"
        }
    }
}

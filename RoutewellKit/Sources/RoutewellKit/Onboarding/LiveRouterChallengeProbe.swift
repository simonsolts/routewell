import Foundation
import os
import Security

/// The live `RouterChallengeProbing`: one `POST /rpc` with
/// `{"method":"challenge","params":{"username":"root"}}` and nothing else.
/// No cookie, no session, no password, no hash. It accepts any server
/// certificate, because nothing secret is sent, and reports the leaf
/// fingerprint so the person can check it before anything secret is sent.
public final class LiveRouterChallengeProbe: RouterChallengeProbing, Sendable {
    private let session: URLSession
    private let delegate: ProbeDelegate

    /// - Parameter protocolClasses: for tests only.
    public init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let delegate = ProbeDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// The only request discovery ever sends.
    public static func challengeRequest(for endpoint: RouterEndpoint) -> URLRequest {
        var request = URLRequest(url: endpoint.url.appendingPathComponent("rpc"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        let body: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("challenge"),
            "params": .object(["username": .string("root")]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try? encoder.encode(body)
        return request
    }

    /// A GL.iNet `challenge` reply has a `result` with string `salt` and `nonce`.
    public static func isGLiNetChallenge(_ data: Data, statusCode: Int) -> Bool {
        guard statusCode == 200, data.count <= Self.maxResponseBytes,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let result = value["result"] else { return false }
        return result["salt"]?.string != nil && result["nonce"]?.string != nil
    }

    static let maxResponseBytes = 64 * 1024

    public func probe(_ endpoint: RouterEndpoint) async -> ChallengeProbeOutcome {
        let request = Self.challengeRequest(for: endpoint)
        let task = session.dataTask(with: request)
        let outcome: (Data, URLResponse?, Error?) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.register(task.taskIdentifier, continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        let fingerprint = delegate.takeFingerprint(task.taskIdentifier)
        if outcome.2 != nil { return .noAnswer }
        guard let response = outcome.1 as? HTTPURLResponse else { return .noAnswer }
        return Self.isGLiNetChallenge(outcome.0, statusCode: response.statusCode)
            ? .glinet(fingerprint: endpoint.scheme == .https ? fingerprint : nil) : .notGLiNet
    }
}

/// Collects each task's body and leaf fingerprint. Refuses redirects.
private final class ProbeDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State: Sendable {
        var data = Data()
        var fingerprint: CertificateFingerprint?
        var continuation: CheckedContinuation<(Data, URLResponse?, Error?), Never>?
    }

    private let states = OSAllocatedUnfairLock<[Int: State]>(initialState: [:])

    func register(_ id: Int, _ continuation: CheckedContinuation<(Data, URLResponse?, Error?), Never>) {
        states.withLock { $0[id, default: State()].continuation = continuation }
    }

    func takeFingerprint(_ id: Int) -> CertificateFingerprint? {
        states.withLock { $0.removeValue(forKey: id)?.fingerprint }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = CertificateFingerprint(derEncodedCertificate: SecCertificateCopyData(leaf) as Data)
        states.withLock { $0[task.taskIdentifier, default: State()].fingerprint = fingerprint }
        // Discovery only: the request carries no secret.
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = states.withLock { states -> Bool in
            states[dataTask.taskIdentifier, default: State()].data.append(data)
            return (states[dataTask.taskIdentifier]?.data.count ?? 0) > LiveRouterChallengeProbe.maxResponseBytes
        }
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = states.withLock { states -> CheckedContinuation<(Data, URLResponse?, Error?), Never>? in
            let state = states[task.taskIdentifier]
            states[task.taskIdentifier]?.continuation = nil
            return state?.continuation
        }
        let data = states.withLock { $0[task.taskIdentifier]?.data ?? Data() }
        continuation?.resume(returning: (data, task.response, error))
    }
}

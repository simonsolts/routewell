import Foundation
import os
import Security

/// The live `RouterChallengeProbing`: one `POST /rpc` with
/// `{"method":"challenge","params":{"username":"root"}}` and nothing else.
/// No cookie, no session, no password, no hash. It accepts any server
/// certificate, because nothing secret is sent, and reports the leaf
/// fingerprint so the person can check it before anything secret is sent.
public final class LiveRouterChallengeProbe: RouterChallengeProbing, Sendable {
    public init() {}

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

    /// Each probe has its own session, so no connection or TLS session is
    /// reused. A reused connection gets no trust challenge, and the
    /// fingerprint would be lost.
    public func probe(_ endpoint: RouterEndpoint) async -> ChallengeProbeOutcome {
        let delegate = ProbeDelegate()
        let session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: Self.challengeRequest(for: endpoint))
        let outcome: (Data, URLResponse?, Error?) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delegate.register(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        if outcome.2 != nil { return .noAnswer }
        guard let response = outcome.1 as? HTTPURLResponse else { return .noAnswer }
        return Self.isGLiNetChallenge(outcome.0, statusCode: response.statusCode)
            ? .glinet(fingerprint: endpoint.scheme == .https ? delegate.fingerprint : nil) : .notGLiNet
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        return configuration
    }
}

/// Collects one task's body and leaf fingerprint. Refuses redirects.
private final class ProbeDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State: Sendable {
        var data = Data()
        var fingerprint: CertificateFingerprint?
        var continuation: CheckedContinuation<(Data, URLResponse?, Error?), Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var fingerprint: CertificateFingerprint? { state.withLock { $0.fingerprint } }

    func register(_ continuation: CheckedContinuation<(Data, URLResponse?, Error?), Never>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = CertificateFingerprint(derEncodedCertificate: SecCertificateCopyData(leaf) as Data)
        state.withLock { $0.fingerprint = fingerprint }
        // Discovery only: the request carries no secret.
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = state.withLock { state -> Bool in
            state.data.append(data)
            return state.data.count > LiveRouterChallengeProbe.maxResponseBytes
        }
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, data) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.data)
        }
        continuation?.resume(returning: (data, task.response, error))
    }
}

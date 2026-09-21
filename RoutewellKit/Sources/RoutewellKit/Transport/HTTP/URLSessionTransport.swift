import Foundation
import os
import Security

/// An `HTTPTransport` backed by `URLSession`. One ephemeral session per
/// instance: isolated in-memory cookies, no disk cache, no credential
/// storage, and every redirect is refused rather than followed.
public final class URLSessionTransport: HTTPTransport, Sendable {
    private let session: URLSession
    private let delegate: TransportSessionDelegate
    private let trustStore: any EndpointTrustStore

    /// - Parameter protocolClasses: for tests only, to register a `URLProtocol`
    ///   that intercepts requests instead of touching the network.
    public init(trustStore: any EndpointTrustStore, protocolClasses: [AnyClass]? = nil) {
        self.trustStore = trustStore
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = true
        configuration.waitsForConnectivity = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        let delegate = TransportSessionDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func send(_ request: URLRequest, limits: HTTPRequestLimits) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host else {
            throw TransportError.invalidResponse
        }
        let port = url.port ?? (url.scheme == "http" ? 80 : 443)

        // Fetched before the task exists so the delegate has it in hand the
        // moment a server-trust challenge for this task arrives.
        let trusted = await trustStore.trusted(host: host, port: port)

        var outgoing = request
        outgoing.timeoutInterval = limits.deadline.timeInterval

        let task = session.dataTask(with: outgoing)
        delegate.register(taskIdentifier: task.taskIdentifier, trusted: trusted, limits: limits)

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                    delegate.setContinuation(continuation, for: task.taskIdentifier)
                    delegate.scheduleDeadline(limits.deadline, taskIdentifier: task.taskIdentifier, task: task)
                    task.resume()
                }
            },
            onCancel: {
                task.cancel()
            }
        )
    }

    public func invalidate() {
        session.finishTasksAndInvalidate()
    }
}

/// Per-task state for one in-flight request, guarded entirely by `states`'s
/// lock. A value type so `OSAllocatedUnfairLock` can hold it without an
/// `@unchecked Sendable` conformance; every read and mutation happens inside
/// a `withLock` closure.
private final class TransportSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    fileprivate struct TaskState: Sendable {
        let trusted: TrustedEndpoint?
        let limits: HTTPRequestLimits
        var accumulated = Data()
        var pendingFailure: TransportError?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var deadlineTask: Task<Void, Never>?

        init(trusted: TrustedEndpoint?, limits: HTTPRequestLimits) {
            self.trusted = trusted
            self.limits = limits
        }
    }

    private let states = OSAllocatedUnfairLock<[Int: TaskState]>(initialState: [:])

    func register(taskIdentifier: Int, trusted: TrustedEndpoint?, limits: HTTPRequestLimits) {
        states.withLock { $0[taskIdentifier] = TaskState(trusted: trusted, limits: limits) }
    }

    func setContinuation(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>, for taskIdentifier: Int) {
        states.withLock { $0[taskIdentifier]?.continuation = continuation }
    }

    func scheduleDeadline(_ deadline: Duration, taskIdentifier: Int, task: URLSessionTask) {
        let timer = Task {
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self.markPendingFailure(.timedOut, for: taskIdentifier)
            task.cancel()
        }
        states.withLock { $0[taskIdentifier]?.deadlineTask = timer }
    }

    private func markPendingFailure(_ error: TransportError, for taskIdentifier: Int) {
        states.withLock { states in
            guard states[taskIdentifier]?.pendingFailure == nil else { return }
            states[taskIdentifier]?.pendingFailure = error
        }
    }

    // MARK: - URLSessionTaskDelegate

    /// Server-trust challenges are the only ones this transport answers
    /// itself; everything else gets default handling. This path cannot be
    /// exercised through `URLProtocol` interception in tests because
    /// `URLProtocol` stubs never trigger `SecTrust` evaluation — it is
    /// covered by the `TrustEvaluator` unit tests instead (Task 1).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let systemTrustSucceeded = SecTrustEvaluateWithError(trust, nil)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCertificate = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let leafData = SecCertificateCopyData(leafCertificate) as Data
        let leaf = CertificateFingerprint(derEncodedCertificate: leafData)
        let stored = states.withLock { $0[task.taskIdentifier]?.trusted }
        let decision = TrustEvaluator.decide(systemTrustSucceeded: systemTrustSucceeded, leaf: leaf, stored: stored)
        switch decision {
        case .trusted:
            return (.useCredential, URLCredential(trust: trust))
        case .untrustedNew, .untrustedChanged:
            markPendingFailure(.untrustedServer(decision), for: task.taskIdentifier)
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// The real network stack calls this before following a 3xx response;
    /// returning nil refuses the redirect. Custom `URLProtocol` responses
    /// (used in tests) never reach this callback at all — the loading system
    /// only offers a redirect decision for its own built-in HTTP loading, so
    /// this path is unverified by `URLSessionTransportTests` and the
    /// `didCompleteWithError` fallback below is what tests exercise.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        markPendingFailure(.redirectRefused(to: request.url?.host), for: task.taskIdentifier)
        return nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskIdentifier = task.taskIdentifier
        let finishedState: (state: TaskState, httpResponse: HTTPURLResponse?)? = states.withLock { states in
            // Removing the entry makes this idempotent: a second completion
            // callback for the same task (should not happen, but the delegate
            // makes no assumption otherwise) finds nothing and no-ops.
            guard let state = states[taskIdentifier] else { return nil }
            state.deadlineTask?.cancel()
            let result = (state, task.response as? HTTPURLResponse)
            states.removeValue(forKey: taskIdentifier)
            return result
        }
        guard let (state, httpResponse) = finishedState, let continuation = state.continuation else { return }

        if let pending = state.pendingFailure {
            continuation.resume(throwing: pending)
        } else if let error {
            continuation.resume(throwing: Self.map(error))
        } else if let httpResponse {
            if let refusal = Self.redirectRefusal(for: httpResponse) {
                // Belt and suspenders: if a redirect response reached
                // completion without `willPerformHTTPRedirection` firing
                // (never happens on the real network stack, but is exactly
                // what a stubbed `URLProtocol` response does), still refuse
                // it instead of surfacing a 3xx as a normal success.
                continuation.resume(throwing: refusal)
            } else {
                continuation.resume(returning: (state.accumulated, httpResponse))
            }
        } else {
            continuation.resume(throwing: TransportError.invalidResponse)
        }
    }

    private static let redirectStatusCodes: Set<Int> = [300, 301, 302, 303, 307, 308]

    private static func redirectRefusal(for response: HTTPURLResponse) -> TransportError? {
        guard redirectStatusCodes.contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location") else {
            return nil
        }
        return .redirectRefused(to: URL(string: location)?.host)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let limit = handleReceivedData(data, taskIdentifier: dataTask.taskIdentifier) {
            markPendingFailure(.responseTooLarge(limit: limit), for: dataTask.taskIdentifier)
            dataTask.cancel()
        }
    }

    private func handleReceivedData(_ data: Data, taskIdentifier: Int) -> Int? {
        states.withLock { states in
            guard states[taskIdentifier] != nil else { return nil }
            states[taskIdentifier]?.accumulated.append(data)
            guard let updated = states[taskIdentifier] else { return nil }
            return updated.accumulated.count > updated.limits.maxResponseBytes ? updated.limits.maxResponseBytes : nil
        }
    }

    private static func map(_ error: Error) -> TransportError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .invalidResponse }
        switch nsError.code {
        case URLError.timedOut.rawValue:
            return .timedOut
        case URLError.cancelled.rawValue:
            return .cancelled
        case URLError.cannotConnectToHost.rawValue,
             URLError.dnsLookupFailed.rawValue,
             URLError.notConnectedToInternet.rawValue,
             URLError.networkConnectionLost.rawValue:
            return .unreachable(code: nsError.code)
        case URLError.secureConnectionFailed.rawValue,
             URLError.serverCertificateUntrusted.rawValue,
             URLError.serverCertificateHasBadDate.rawValue,
             URLError.serverCertificateHasUnknownRoot.rawValue,
             URLError.serverCertificateNotYetValid.rawValue,
             URLError.clientCertificateRejected.rawValue,
             URLError.clientCertificateRequired.rawValue:
            return .tlsFailure(code: nsError.code)
        default:
            return .unreachable(code: nsError.code)
        }
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

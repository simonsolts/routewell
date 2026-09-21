import Foundation

/// Limits applied to a single HTTP request.
public struct HTTPRequestLimits: Sendable, Equatable {
    public var deadline: Duration
    public var maxResponseBytes: Int

    public init(deadline: Duration = .seconds(15), maxResponseBytes: Int = 4 * 1024 * 1024) {
        self.deadline = deadline
        self.maxResponseBytes = maxResponseBytes
    }
}

/// Every way a request through `HTTPTransport` can fail. No case carries a
/// full URL: UI strings must not echo attacker- or typo-controlled text back
/// verbatim unless it came from the user's own settings field.
public enum TransportError: Error, Equatable, Sendable {
    /// The `URLError.Code` raw value; covers cannotConnectToHost, dnsLookupFailed,
    /// notConnectedToInternet, networkConnectionLost.
    case unreachable(code: Int)
    case timedOut
    case cancelled
    /// The host portion of the redirect's Location header, never the full URL.
    case redirectRefused(to: String?)
    case responseTooLarge(limit: Int)
    case untrustedServer(TrustDecision)
    case tlsFailure(code: Int)
    case invalidResponse
    /// Reserved. No `URLError` code reliably means the user denied Local
    /// Network permission, so `URLSessionTransport` never throws this case.
    /// The UI gives guidance from `.unreachable`/`.timedOut` instead.
    case localNetworkDenied
}

/// A minimal HTTP transport. Chunk 09 backends talk to routers through this
/// protocol so tests can substitute a stub instead of real sockets.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, limits: HTTPRequestLimits) async throws -> (Data, HTTPURLResponse)
}

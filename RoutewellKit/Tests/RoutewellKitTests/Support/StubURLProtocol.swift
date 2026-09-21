import Foundation
import os

/// Intercepts every request made through a session configured with this
/// protocol class and serves a canned response. Never touches the network.
final class StubURLProtocol: URLProtocol {
    struct Behavior: Sendable {
        var statusCode = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Simulates a server that never responds, to exercise the deadline path.
        var neverCompletes = false
    }

    private static let behavior = OSAllocatedUnfairLock<Behavior?>(initialState: nil)

    static func setBehavior(_ behavior: Behavior) {
        Self.behavior.withLock { $0 = behavior }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let behavior = Self.behavior.withLock({ $0 }), let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if behavior.neverCompletes {
            // Deliberately never call back into the client; the caller's
            // deadline is what ends this request.
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: behavior.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: behavior.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: behavior.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

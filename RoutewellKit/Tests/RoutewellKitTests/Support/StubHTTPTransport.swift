import Foundation
@testable import RoutewellKit

/// A scriptable `HTTPTransport` for tests. Shared with chunk 09.
actor StubHTTPTransport: HTTPTransport {
    struct Recorded: Sendable {
        let request: URLRequest
        let body: Data?
    }

    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private var log: [Recorded] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest, limits: HTTPRequestLimits) async throws -> (Data, HTTPURLResponse) {
        log.append(Recorded(request: request, body: request.httpBody))
        return try await handler(request)
    }

    func recorded() -> [Recorded] { log }

    static func response(_ status: Int, url: URL, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

import Foundation
import Testing
@testable import RoutewellKit

/// Every test here drives the shared `StubURLProtocol` behavior, which is
/// process-global state (URLProtocol registration is class-based, not
/// instance-based). `.serialized` keeps tests from racing each other's
/// `setBehavior` calls.
@Suite(.serialized)
struct URLSessionTransportTests {
    private func makeTransport() -> URLSessionTransport {
        URLSessionTransport(trustStore: InMemoryEndpointTrustStore(), protocolClasses: [StubURLProtocol.self])
    }

    private func makeRequest(_ url: URL = URL(string: "https://router.lan/")!) -> URLRequest {
        URLRequest(url: url)
    }

    @Test func sendReturnsBodyOnSuccess() async throws {
        StubURLProtocol.setBehavior(.init(statusCode: 200, body: Data("ok".utf8)))
        let transport = makeTransport()
        defer { transport.invalidate() }

        let (data, response) = try await transport.send(makeRequest(), limits: HTTPRequestLimits())
        #expect(data == Data("ok".utf8))
        #expect(response.statusCode == 200)
    }

    @Test func redirectIsRefusedAndReportsTargetHost() async throws {
        StubURLProtocol.setBehavior(.init(statusCode: 302, headers: ["Location": "http://evil.example/steal"]))
        let transport = makeTransport()
        defer { transport.invalidate() }

        await #expect(throws: TransportError.redirectRefused(to: "evil.example")) {
            _ = try await transport.send(makeRequest(), limits: HTTPRequestLimits())
        }
    }

    @Test func oversizeResponseIsRejected() async throws {
        let oversized = Data(repeating: 0x41, count: 2048)
        StubURLProtocol.setBehavior(.init(statusCode: 200, body: oversized))
        let transport = makeTransport()
        defer { transport.invalidate() }

        await #expect(throws: TransportError.responseTooLarge(limit: 1024)) {
            _ = try await transport.send(makeRequest(), limits: HTTPRequestLimits(deadline: .seconds(15), maxResponseBytes: 1024))
        }
    }

    @Test func slowResponseTimesOutWithinTheDeadline() async throws {
        StubURLProtocol.setBehavior(.init(neverCompletes: true))
        let transport = makeTransport()
        defer { transport.invalidate() }

        let start = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.send(makeRequest(), limits: HTTPRequestLimits(deadline: .milliseconds(200)))
        }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func cancellingTheCallingTaskCancelsTheRequest() async throws {
        StubURLProtocol.setBehavior(.init(neverCompletes: true))
        let transport = makeTransport()
        defer { transport.invalidate() }

        let task = Task {
            try await transport.send(makeRequest(), limits: HTTPRequestLimits(deadline: .seconds(10)))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation to fail the request")
        } catch is CancellationError {
            // acceptable
        } catch TransportError.cancelled {
            // acceptable
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

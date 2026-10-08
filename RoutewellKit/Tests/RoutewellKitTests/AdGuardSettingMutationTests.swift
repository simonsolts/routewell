import Foundation
import Testing
@testable import RoutewellKit

/// A synchronous, lock-protected virtual clock. `AdGuardSettingExecutor`
/// needs a plain `@Sendable () -> Date` clock (not actor-isolated), so this
/// is a small class with one manually-synchronized property rather than an
/// actor. All access in these tests happens from a single virtual-time
/// driven sequence; the lock exists only so the type can honestly claim
/// `Sendable` without an `@unchecked` escape hatch.
private final class VirtualClock: Sendable {
    private nonisolated(unsafe) var currentDate: Date
    private let lock = NSLock()

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        currentDate = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return currentDate
    }

    func advance(by duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        currentDate = currentDate.addingTimeInterval(seconds)
    }

    /// Used as the executor's injected `sleep`. It never really waits; it
    /// advances virtual time instantly. It still honors cancellation the
    /// way `Task.sleep` would, so tests can prove the executor tolerates a
    /// cancelled sleep during verification of an already-dispatched write.
    func sleep(_ duration: Duration) async throws {
        advance(by: duration)
        try Task.checkCancellation()
    }
}

private func statusBody(enabled: Bool?, disabledDurationMs: Int?) -> Data {
    var object: [String: Any] = [:]
    if let enabled { object["protection_enabled"] = enabled }
    if let disabledDurationMs { object["protection_disabled_duration"] = disabledDurationMs }
    return try! JSONSerialization.data(withJSONObject: object)
}

/// Scripts a sequence of GET (`control/status`) and POST
/// (`control/protection`) responses. The last entry in each list repeats
/// forever once the list is exhausted, so "status keeps saying X" scenarios
/// don't need to know exactly how many times the executor will poll.
private actor Script {
    enum Read {
        case ok(enabled: Bool?, durationMs: Int?)
        case httpStatus(Int)
        case transportTimeout
    }
    enum Write {
        case ok
        case httpStatus(Int)
        case transportTimeout
    }

    private var reads: [Read]
    private var writes: [Write]
    private(set) var postBodies: [Data] = []
    private(set) var getCount = 0
    private(set) var postCount = 0

    init(reads: [Read], writes: [Write] = [.ok]) {
        self.reads = reads
        self.writes = writes
    }

    func nextRead() -> Read {
        getCount += 1
        guard !reads.isEmpty else { return .httpStatus(500) }
        if reads.count > 1 { return reads.removeFirst() }
        return reads[0]
    }

    func nextWrite(body: Data) -> Write {
        postCount += 1
        postBodies.append(body)
        guard !writes.isEmpty else { return .ok }
        if writes.count > 1 { return writes.removeFirst() }
        return writes[0]
    }
}

private func makeTransport(_ script: Script) -> StubHTTPTransport {
    StubHTTPTransport { request in
        let url = request.url!
        if request.httpMethod == "GET" {
            switch await script.nextRead() {
            case .ok(let enabled, let durationMs):
                return (statusBody(enabled: enabled, disabledDurationMs: durationMs), StubHTTPTransport.response(200, url: url))
            case .httpStatus(let code):
                return (Data(), StubHTTPTransport.response(code, url: url))
            case .transportTimeout:
                throw TransportError.timedOut
            }
        } else {
            switch await script.nextWrite(body: request.httpBody ?? Data()) {
            case .ok:
                return (Data(), StubHTTPTransport.response(200, url: url))
            case .httpStatus(let code):
                return (Data(), StubHTTPTransport.response(code, url: url))
            case .transportTimeout:
                throw TransportError.timedOut
            }
        }
    }
}

private func makeClient(_ transport: StubHTTPTransport) -> AdGuardClient {
    makeClient(transport, credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }))
}

private func makeClient(_ transport: StubHTTPTransport, credentials: any AdGuardCredentialProvider) -> AdGuardClient {
    AdGuardClient(
        baseURL: URL(string: "http://192.168.8.1:3000/")!,
        credentials: credentials,
        transport: transport
    )
}

/// Succeeds for the first two `authorizationHeaders()` calls (the
/// before-state read and the initial POST) and throws on every call after
/// that (the retry after 401/403).
private actor SucceedsTwiceThenFailsCredentials: AdGuardCredentialProvider {
    private var callCount = 0

    func authorizationHeaders() async throws -> [String: String] {
        callCount += 1
        if callCount <= 2 { return ["Authorization": "Basic xyz"] }
        throw CredentialError.missing
    }

    func handleUnauthorized() async -> Bool { true }
}

/// Throws on the second `authorizationHeaders()` call: the before-state
/// read succeeds, but `setProtection`'s own initial header fetch fails.
private actor FailsOnSecondCallCredentials: AdGuardCredentialProvider {
    private var callCount = 0

    func authorizationHeaders() async throws -> [String: String] {
        callCount += 1
        if callCount == 1 { return ["Authorization": "Basic xyz"] }
        throw CredentialError.missing
    }

    func handleUnauthorized() async -> Bool { false }
}

/// The "reach the deadline after exactly one read" policy: a 1ms deadline
/// and 1ms poll interval mean the verify loop performs exactly one read
/// before giving up, whether or not it matched.
private var oneShotPolicy: AdGuardSettingVerifyPolicy {
    var policy = AdGuardSettingVerifyPolicy()
    policy.deadline = .milliseconds(1)
    policy.pollInterval = .milliseconds(1)
    return policy
}

@Suite struct AdGuardSettingMutationTests {
    @Test func enableHappyPathVerifiesOnFirstRead() async throws {
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.enable), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.protection(.enabled)))
        #expect(report.dispatched == true)
        let recorded = await transport.recorded()
        #expect(recorded.filter { $0.request.httpMethod == "POST" }.count == 1)
        #expect(recorded.filter { $0.request.httpMethod == "GET" }.count == 2) // before-state + one verify read
    }

    @Test func pauseVerifiedOnThirdPoll() async throws {
        let script = Script(reads: [
            .ok(enabled: true, durationMs: nil),           // before-state
            .ok(enabled: false, durationMs: 60_000),        // verify poll 1: not yet
            .ok(enabled: false, durationMs: 60_000),        // verify poll 2: not yet
            .ok(enabled: false, durationMs: 10 * 60_000),   // verify poll 3: matches pause(10m)
        ])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.pause(.seconds(600))), availability: .running)
        guard case .verifiedSuccess(.protection(.paused)) = report.outcome else {
            Issue.record("expected verifiedSuccess(.paused), got \(report.outcome)")
            return
        }
        let getCount = await script.getCount
        #expect(getCount == 4) // before-state + 3 polls
    }

    @Test func disableMismatchWithoutRecovery() async throws {
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)]) // always "enabled"
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.disable), availability: .running)
        #expect(report.outcome == .verifiedMismatch(expected: .protection(.disabled), actual: .protection(.enabled)))
        let recorded = await transport.recorded()
        #expect(recorded.filter { $0.request.httpMethod == "POST" }.count == 1)
    }

    @Test func disableMatchesWhenDurationFieldIsMissingEntirely() async throws {
        // AdGuard Home may omit `protection_disabled_duration` altogether
        // when protection is disabled indefinitely, rather than sending 0.
        let script = Script(reads: [
            .ok(enabled: true, durationMs: nil), // before-state
            .ok(enabled: false, durationMs: nil), // verify: disabled, no duration field at all
        ])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.disable), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.protection(.disabled)))
        let recorded = await transport.recorded()
        #expect(recorded.filter { $0.request.httpMethod == "GET" }.count == 2)
    }

    /// `resync`: a verified mismatch reports what AdGuard Home says and
    /// sends nothing more (chunk 10's executor sent the old state back).
    @Test func mismatchSendsNoSecondWrite() async throws {
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.disable), availability: .running)
        #expect(report.outcome == .verifiedMismatch(expected: .protection(.disabled), actual: .protection(.enabled)))
        let postCount = await script.postCount
        #expect(postCount == 1)
    }

    @Test func conflictingExternalEditDetected() async throws {
        // Before-state enabled; intent disable; status shows paused 300s.
        let script = Script(reads: [
            .ok(enabled: true, durationMs: nil),      // before-state
            .ok(enabled: false, durationMs: 300_000), // verify: paused, matches neither
        ])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.disable), availability: .running)
        #expect(report.outcome == .conflictingExternalEdit(actual: .protection(.paused(until: clock.now().addingTimeInterval(300)))))
        let recorded = await transport.recorded()
        #expect(recorded.filter { $0.request.httpMethod == "POST" }.count == 1)
    }

    @Test func postTimeoutThenStatusShowsIntendedStateIsVerifiedSuccess() async throws {
        let script = Script(
            reads: [
                .ok(enabled: true, durationMs: nil), // before-state
                .ok(enabled: false, durationMs: 0),  // verify: disabled, matches
            ],
            writes: [.transportTimeout]
        )
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.disable), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.protection(.disabled)))
        #expect(report.dispatched == true)
        let postCount = await script.postCount
        #expect(postCount == 1)
    }

    @Test func postTimeoutAndEveryStatusReadFailsIsUnknownAfterDispatch() async throws {
        let script = Script(
            reads: [
                .ok(enabled: true, durationMs: nil), // before-state succeeds
                .httpStatus(500),                     // every verify read fails
            ],
            writes: [.transportTimeout]
        )
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.disable), availability: .running)
        #expect(report.outcome == .unknownAfterDispatch)
        #expect(report.dispatched == true)
        let postCount = await script.postCount
        #expect(postCount == 1)
    }

    @Test func retryCredentialFailureAfter401IsRejectedWithDispatchedTrueAndOnePOST() async throws {
        let transport = StubHTTPTransport { request in
            if request.httpMethod == "GET" {
                return (statusBody(enabled: true, disabledDurationMs: nil), StubHTTPTransport.response(200, url: request.url!))
            }
            return (Data(), StubHTTPTransport.response(401, url: request.url!))
        }
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport, credentials: SucceedsTwiceThenFailsCredentials())), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.enable), availability: .running)
        #expect(report.outcome == .rejected(.preconditionFailed("AdGuard Home refused the login")))
        #expect(report.dispatched == true)
        let recorded = await transport.recorded()
        #expect(recorded.filter { $0.request.httpMethod == "POST" }.count == 1)
    }

    @Test func credentialFailureBeforeAnyPOSTIsRejectedWithDispatchedFalse() async throws {
        let transport = StubHTTPTransport { request in
            if request.httpMethod == "GET" {
                return (statusBody(enabled: true, disabledDurationMs: nil), StubHTTPTransport.response(200, url: request.url!))
            }
            return (Data(), StubHTTPTransport.response(200, url: request.url!))
        }
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport, credentials: FailsOnSecondCallCredentials())), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.protection(.enable), availability: .running)
        #expect(report.outcome == .rejected(.preconditionFailed("credential unavailable")))
        #expect(report.dispatched == false)
        let recorded = await transport.recorded()
        #expect(recorded.filter { $0.request.httpMethod == "POST" }.isEmpty)
    }

    @Test func pauseOutOfRangeIsRejectedAsInvalidIntent() async throws {
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        for duration in [Duration.zero, .seconds(48 * 60 * 60 + 1)] {
            let report = await executor.run(.protection(.pause(duration)), availability: .running)
            guard case .rejected(.invalidIntent) = report.outcome else {
                Issue.record("expected rejected(.invalidIntent), got \(report.outcome)")
                return
            }
            #expect(report.dispatched == false)
        }
        let recorded = await transport.recorded()
        #expect(recorded.isEmpty)
    }

    @Test func concurrentRunsNeverInterleaveOnTheWire() async throws {
        let state = StatefulAdGuardState()
        let transport = StubHTTPTransport { request in
            if request.httpMethod == "GET" {
                let (enabled, duration) = await state.read()
                return (statusBody(enabled: enabled, disabledDurationMs: duration), StubHTTPTransport.response(200, url: request.url!))
            } else {
                let object = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let enabled = object?["enabled"] as? Bool ?? true
                let duration = object?["duration"] as? Int ?? 0
                await state.write(enabled: enabled, duration: duration)
                return (Data(), StubHTTPTransport.response(200, url: request.url!))
            }
        }
        let clock = VirtualClock()
        let gate = MutationGate()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: gate,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )

        async let first = executor.run(.protection(.enable), availability: .running)
        async let second = executor.run(.protection(.disable), availability: .running)
        let (firstReport, secondReport) = await (first, second)

        #expect(firstReport.outcome == .verifiedSuccess(.protection(.enabled)))
        #expect(secondReport.outcome == .verifiedSuccess(.protection(.disabled)))

        let recorded = await transport.recorded()
        let methods = recorded.map { $0.request.httpMethod }
        #expect(methods == ["GET", "POST", "GET", "GET", "POST", "GET"])

        // The two POSTs must be for different intents (never coalesced or
        // reordered), proving the two operations did not interleave.
        let postIndices = recorded.enumerated().filter { $0.element.request.httpMethod == "POST" }.map(\.offset)
        #expect(postIndices == [1, 4])
        let firstPostBody = recorded[1].body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let secondPostBody = recorded[4].body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(firstPostBody?["enabled"] as? Bool != secondPostBody?["enabled"] as? Bool)
    }

    @Test func cancelWhileWaitingOnGateIsRejectedWithZeroPOSTs() async throws {
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let gate = MutationGate()
        let heldToken = try await gate.acquire() // occupy the gate so the executor must queue

        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: gate,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )

        let task = Task { await executor.run(.protection(.enable), availability: .running) }
        try await Task.sleep(for: .milliseconds(50)) // let it start waiting on the gate
        task.cancel()
        let report = await task.value

        guard case .rejected(.preconditionFailed) = report.outcome else {
            Issue.record("expected rejected(.preconditionFailed), got \(report.outcome)")
            return
        }
        #expect(report.dispatched == false)
        let recorded = await transport.recorded()
        #expect(recorded.isEmpty)

        await gate.release(heldToken)
    }

    @Test func cancelAfterDispatchStillCompletesVerification() async throws {
        let signal = Signal()
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let innerTransport = makeTransport(script)
        let transport = StubHTTPTransport { request in
            if request.httpMethod == "POST" {
                await signal.fire()
            }
            return try await innerTransport.send(request, limits: .init())
        }
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )

        let task = Task { await executor.run(.protection(.enable), availability: .running) }
        await signal.wait()
        task.cancel()
        let report = await task.value

        #expect(report.outcome == .verifiedSuccess(.protection(.enabled)))
        #expect(report.dispatched == true)
    }

    // MARK: Chunk 17: availability and the three switches

    @Test func writesAreRejectedBeforeAnyRequestUnlessRunning() async throws {
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let transport = makeTransport(script)
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate())
        for availability in [AdGuardAvailability.cached, .unreachable(.notAnswering(.timeout)), .off, .unknown] {
            for intent in [AdGuardSettingIntent.protection(.enable), .feature(.parental, enabled: true)] {
                let report = await executor.run(intent, availability: availability)
                #expect(report.outcome == .rejected(.preconditionFailed("AdGuard Home is not running.")))
                #expect(!report.dispatched)
            }
        }
        #expect(await transport.recorded().isEmpty)
    }

    @Test func safeBrowsingOnPostsEnableWithoutBodyAndVerifies() async throws {
        let server = FeatureServer()
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate())
        let report = await executor.run(.feature(.safeBrowsing, enabled: true), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.feature(true)))
        #expect(report.dispatched)
        let requests = await server.transport.recorded().map { "\($0.request.httpMethod!) \($0.request.url!.path)" }
        #expect(requests == ["GET /control/safebrowsing/status", "POST /control/safebrowsing/enable", "GET /control/safebrowsing/status"])
        #expect(await server.transport.recorded()[1].body == nil)
    }

    @Test func parentalOffPostsDisable() async throws {
        let server = FeatureServer(parental: true)
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate())
        let report = await executor.run(.feature(.parental, enabled: false), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.feature(false)))
        let paths = await server.transport.recorded().map { $0.request.url!.path }
        #expect(paths.contains("/control/parental/disable"))
    }

    /// The engine flags go back exactly as read; only `enabled` changes.
    @Test func safeSearchPutsTheReadSettingsWithEnabledChanged() async throws {
        let server = FeatureServer()
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate())
        let report = await executor.run(.feature(.safeSearch, enabled: true), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.feature(true)))
        let put = try #require(await server.transport.recorded().first { $0.request.httpMethod == "PUT" })
        #expect(put.request.url!.path == "/control/safesearch/settings")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(put.body))
        #expect(body == FeatureServer.safeSearch(enabled: true))
    }

    @Test func switchAlreadyInStateSendsNothing() async throws {
        let server = FeatureServer(parental: true)
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate())
        let report = await executor.run(.feature(.parental, enabled: true), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.feature(true)))
        #expect(!report.dispatched)
        #expect(await server.transport.recorded().count == 1)
    }

    /// `resync`: AdGuard Home keeps the old value; the outcome says so and
    /// no second write is sent.
    @Test func switchThatDoesNotChangeIsMismatchWithOneWrite() async throws {
        let server = FeatureServer(stuck: true)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.feature(.parental, enabled: true), availability: .running)
        #expect(report.outcome == .verifiedMismatch(expected: .feature(true), actual: .feature(false)))
        let writes = await server.transport.recorded().filter { $0.request.httpMethod != "GET" }
        #expect(writes.count == 1)
    }

    /// "Filter requests" (user, chunk 17): `POST control/filtering/config`
    /// with the interval sent back as read.
    @Test func filterRequestsPostsTheConfigWithTheIntervalAsRead() async throws {
        let server = FilteringServer(enabled: true, interval: 72)
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate())
        let report = await executor.run(.filtering(enabled: false), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.feature(false)))
        let post = try #require(await server.transport.recorded().first { $0.request.httpMethod == "POST" })
        #expect(post.request.url!.path == "/control/filtering/config")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(post.body))
        #expect(body == .object(["enabled": .bool(false), "interval": .number(72)]))
    }

    @Test func filterRequestsAlreadyInStateSendsNothing() async throws {
        let server = FilteringServer(enabled: true, interval: 24)
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate())
        let report = await executor.run(.filtering(enabled: true), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.feature(true)))
        #expect(!report.dispatched)
        #expect(await server.transport.recorded().count == 1)
    }

    /// Without the interval, Routewell cannot send the config back unchanged.
    @Test func filterRequestsWithoutAnIntervalSendsNothing() async throws {
        let server = FilteringServer(enabled: true, interval: nil)
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate())
        let report = await executor.run(.filtering(enabled: false), availability: .running)
        #expect(report.outcome == .rejected(.preconditionFailed("AdGuard Home did not send its list update interval.")))
        #expect(!report.dispatched)
        #expect(await server.transport.recorded().allSatisfy { $0.request.httpMethod == "GET" })
    }

    @Test func filterRequestsThatDoesNotChangeIsMismatchWithOneWrite() async throws {
        let server = FilteringServer(enabled: true, interval: 24, stuck: true)
        let clock = VirtualClock()
        let executor = AdGuardSettingExecutor(
            transport: LiveAdGuardSettingTransport(adGuard: makeClient(server.transport)), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.filtering(enabled: false), availability: .running)
        #expect(report.outcome == .verifiedMismatch(expected: .feature(false), actual: .feature(true)))
        #expect(await server.transport.recorded().filter { $0.request.httpMethod == "POST" }.count == 1)
    }

    @Test func switchStatusReadFailureIsRejectedWithoutWrite() async throws {
        let transport = StubHTTPTransport { request in (Data(), StubHTTPTransport.response(500, url: request.url!)) }
        let executor = AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: makeClient(transport)), gate: MutationGate())
        let report = await executor.run(.feature(.safeBrowsing, enabled: true), availability: .running)
        #expect(report.outcome == .rejected(.preconditionFailed("status unavailable")))
        #expect(!report.dispatched)
        #expect(await transport.recorded().count == 1)
    }

}

private actor StatefulAdGuardState {
    private var enabled = true
    private var durationMs = 0

    func read() -> (Bool, Int) { (enabled, durationMs) }
    func write(enabled: Bool, duration: Int) {
        self.enabled = enabled
        self.durationMs = duration
    }
}

private actor Signal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// AdGuard Home's three switch endpoints in memory. `stuck` accepts writes
/// and changes nothing.
private final class FeatureServer: Sendable {
    let transport: StubHTTPTransport

    static func safeSearch(enabled: Bool) -> JSONValue {
        .object(["enabled": .bool(enabled), "bing": .bool(true), "duckduckgo": .bool(false), "ecosia": .bool(true),
                 "google": .bool(true), "pixabay": .bool(false), "yandex": .bool(true), "youtube": .bool(false)])
    }

    init(parental: Bool = false, stuck: Bool = false) {
        let state = FeatureState(parental: parental)
        transport = StubHTTPTransport { request in
            let url = request.url!
            let path = url.path
            if request.httpMethod == "GET" {
                let body = try JSONEncoder().encode(await state.status(path))
                return (body, StubHTTPTransport.response(200, url: url))
            }
            if !stuck { await state.apply(path: path, body: request.httpBody) }
            return (Data(), StubHTTPTransport.response(200, url: url))
        }
    }
}

private actor FeatureState {
    var safeBrowsing = false
    var parental: Bool
    var safeSearch = FeatureServer.safeSearch(enabled: false)

    init(parental: Bool) { self.parental = parental }

    func status(_ path: String) -> JSONValue {
        switch path {
        case "/control/safebrowsing/status": .object(["enabled": .bool(safeBrowsing)])
        case "/control/parental/status": .object(["enabled": .bool(parental), "sensitivity": .number(13)])
        default: safeSearch
        }
    }

    func apply(path: String, body: Data?) {
        switch path {
        case "/control/safebrowsing/enable": safeBrowsing = true
        case "/control/safebrowsing/disable": safeBrowsing = false
        case "/control/parental/enable": parental = true
        case "/control/parental/disable": parental = false
        case "/control/safesearch/settings":
            if let body, let value = try? JSONDecoder().decode(JSONValue.self, from: body) { safeSearch = value }
        default: break
        }
    }
}

/// `control/filtering/status` and `/config` in memory.
private final class FilteringServer: Sendable {
    let transport: StubHTTPTransport

    init(enabled: Bool, interval: Int?, stuck: Bool = false) {
        let state = FilteringState(enabled: enabled, interval: interval)
        transport = StubHTTPTransport { request in
            let url = request.url!
            if request.httpMethod == "POST", !stuck, let body = request.httpBody,
               let value = try? JSONDecoder().decode(JSONValue.self, from: body), let enabled = value["enabled"]?.bool {
                await state.set(enabled)
            }
            if request.httpMethod == "POST" { return (Data(), StubHTTPTransport.response(200, url: url)) }
            return (try JSONEncoder().encode(await state.status()), StubHTTPTransport.response(200, url: url))
        }
    }
}

private actor FilteringState {
    var enabled: Bool
    let interval: Int?

    init(enabled: Bool, interval: Int?) {
        self.enabled = enabled
        self.interval = interval
    }

    func set(_ value: Bool) { enabled = value }

    func status() -> JSONValue {
        var object: [String: JSONValue] = ["enabled": .bool(enabled), "filters": .array([]), "whitelist_filters": .null]
        if let interval { object["interval"] = .number(Double(interval)) }
        return .object(object)
    }
}

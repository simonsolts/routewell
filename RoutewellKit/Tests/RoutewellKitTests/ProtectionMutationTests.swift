import Foundation
import Testing
@testable import RoutewellKit

/// A synchronous, lock-protected virtual clock. `ProtectionMutationExecutor`
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
private var oneShotPolicy: ProtectionVerifyPolicy {
    var policy = ProtectionVerifyPolicy()
    policy.deadline = .milliseconds(1)
    policy.pollInterval = .milliseconds(1)
    return policy
}

@Suite struct ProtectionMutationTests {
    @Test func enableHappyPathVerifiesOnFirstRead() async throws {
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.enable, allowRecovery: false)
        #expect(report.outcome == .verifiedSuccess(.enabled))
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.pause(.seconds(600)), allowRecovery: false)
        guard case .verifiedSuccess(.paused) = report.outcome else {
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.disable, allowRecovery: false)
        #expect(report.outcome == .verifiedMismatch(expected: .disabled, actual: .enabled))
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.disable, allowRecovery: false)
        #expect(report.outcome == .verifiedSuccess(.disabled))
        let recorded = await transport.recorded()
        #expect(recorded.filter { $0.request.httpMethod == "GET" }.count == 2)
    }

    @Test func disableMismatchWithRecoveryRestoresAndVerifies() async throws {
        // Before-state and every verify read say "enabled": the disable
        // never took effect. Recovery re-enables (already true) and
        // verifies it — succeeds on the very first recovery read.
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.disable, allowRecovery: true)
        #expect(report.outcome == .verifiedRecovery(restored: .enabled))
        let postCount = await script.postCount
        #expect(postCount == 2) // the original disable write + the recovery write
    }

    @Test func recoveryWrite500ReportsRecoveryFailed() async throws {
        // Before-state and the primary verify read both say "enabled":
        // disable never took effect. The recovery write itself 500s, and
        // by the time we read back, an external edit has left protection
        // paused — the recovery is not verified.
        let script = Script(
            reads: [
                .ok(enabled: true, durationMs: nil),           // before-state
                .ok(enabled: true, durationMs: nil),           // primary verify read (still enabled -> mismatch)
                .ok(enabled: false, durationMs: 300_000),       // recovery verify read (paused, not enabled)
            ],
            writes: [.ok, .httpStatus(500)]
        )
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.disable, allowRecovery: true)
        guard case .recoveryFailed(let expected, let actual) = report.outcome else {
            Issue.record("expected recoveryFailed, got \(report.outcome)")
            return
        }
        #expect(expected == .enabled)
        #expect(actual == .paused(until: clock.now().addingTimeInterval(300)))
        let postCount = await script.postCount
        #expect(postCount == 2)
    }

    @Test func conflictingExternalEditDetected() async throws {
        // Before-state enabled; intent disable; status shows paused 300s.
        let script = Script(reads: [
            .ok(enabled: true, durationMs: nil),      // before-state
            .ok(enabled: false, durationMs: 300_000), // verify: paused, matches neither
        ])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.disable, allowRecovery: false)
        #expect(report.outcome == .conflictingExternalEdit(actual: .paused(until: clock.now().addingTimeInterval(300))))
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.disable, allowRecovery: false)
        #expect(report.outcome == .verifiedSuccess(.disabled))
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(), policy: oneShotPolicy,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.disable, allowRecovery: false)
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport, credentials: SucceedsTwiceThenFailsCredentials()), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.enable, allowRecovery: false)
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport, credentials: FailsOnSecondCallCredentials()), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.enable, allowRecovery: false)
        #expect(report.outcome == .rejected(.preconditionFailed("credential unavailable")))
        #expect(report.dispatched == false)
        let recorded = await transport.recorded()
        #expect(recorded.filter { $0.request.httpMethod == "POST" }.isEmpty)
    }

    @Test func pauseOutOfRangeIsRejectedAsInvalidIntent() async throws {
        let script = Script(reads: [.ok(enabled: true, durationMs: nil)])
        let transport = makeTransport(script)
        let clock = VirtualClock()
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let report = await executor.run(.pause(.seconds(10)), allowRecovery: false)
        guard case .rejected(.invalidIntent) = report.outcome else {
            Issue.record("expected rejected(.invalidIntent), got \(report.outcome)")
            return
        }
        #expect(report.dispatched == false)
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: gate,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )

        async let first = executor.run(.enable, allowRecovery: false)
        async let second = executor.run(.disable, allowRecovery: false)
        let (firstReport, secondReport) = await (first, second)

        #expect(firstReport.outcome == .verifiedSuccess(.enabled))
        #expect(secondReport.outcome == .verifiedSuccess(.disabled))

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

        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: gate,
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )

        let task = Task { await executor.run(.enable, allowRecovery: false) }
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
        let executor = ProtectionMutationExecutor(
            adGuard: makeClient(transport), gate: MutationGate(),
            clock: { clock.now() }, sleep: { try await clock.sleep($0) }
        )

        let task = Task { await executor.run(.enable, allowRecovery: false) }
        await signal.wait()
        task.cancel()
        let report = await task.value

        #expect(report.outcome == .verifiedSuccess(.enabled))
        #expect(report.dispatched == true)
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

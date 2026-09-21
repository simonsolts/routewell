import Foundation

/// What the caller wants AdGuard's protection setting to become.
public enum ProtectionIntent: Sendable, Equatable {
    case enable
    case disable
    /// 1 minute ... 24 hours. Out-of-range values fail `validate()`.
    case pause(Duration)

    /// The exact wire shape for `POST control/protection`.
    public var wire: (enabled: Bool, durationMilliseconds: Int) {
        switch self {
        case .enable:
            return (true, 0)
        case .disable:
            return (false, 0)
        case .pause(let duration):
            return (false, Self.milliseconds(from: duration))
        }
    }

    public func validate() -> MutationRejection? {
        switch self {
        case .enable, .disable:
            return nil
        case .pause(let duration):
            if duration < .seconds(60) || duration > .seconds(24 * 60 * 60) {
                return .invalidIntent("Pause duration must be between 1 minute and 24 hours")
            }
            return nil
        }
    }

    static func milliseconds(from duration: Duration) -> Int {
        let components = duration.components
        let fromSeconds = components.seconds * 1000
        let fromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(fromSeconds + fromAttoseconds)
    }
}

/// Timing knobs for verifying a protection write. All virtual-clock driven
/// so tests never wait in real time.
public struct ProtectionVerifyPolicy: Sendable, Equatable {
    public var deadline: Duration = .seconds(8)
    public var pollInterval: Duration = .milliseconds(500)
    /// The observed remaining pause duration may be shorter than requested
    /// by up to this much (time elapses between dispatch and read-back).
    public var pauseTolerance: Duration = .seconds(30)

    public init() {}
}

/// Runs one Protection mutation end to end: gate → before-state → dispatch
/// once → verify with a bounded deadline → optional single recovery.
public struct ProtectionMutationExecutor: Sendable {
    private let adGuard: AdGuardClient
    private let gate: MutationGate
    private let policy: ProtectionVerifyPolicy
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: SessionEventLog?

    public init(
        adGuard: AdGuardClient,
        gate: MutationGate,
        policy: ProtectionVerifyPolicy = .init(),
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: SessionEventLog? = nil
    ) {
        self.adGuard = adGuard
        self.gate = gate
        self.policy = policy
        self.clock = clock
        self.sleep = sleep
        self.log = log
    }

    public func run(_ intent: ProtectionIntent, allowRecovery: Bool) async -> MutationReport<ProtectionState> {
        let startedAt = clock()

        if let rejection = intent.validate() {
            return report(.rejected(rejection), dispatched: false, startedAt: startedAt, failure: nil)
        }

        let token: MutationGateToken
        do {
            token = try await gate.acquire()
        } catch {
            // A cancelled waiter never acquires the gate, so there is
            // nothing to release here.
            return report(
                .rejected(.preconditionFailed("Cancelled before dispatch")),
                dispatched: false, startedAt: startedAt, failure: nil
            )
        }

        if Task.isCancelled {
            await gate.release(token)
            return report(
                .rejected(.preconditionFailed("Cancelled before dispatch")),
                dispatched: false, startedAt: startedAt, failure: nil
            )
        }

        let (outcome, dispatched, failure) = await performMutation(intent, allowRecovery: allowRecovery)
        await gate.release(token)
        await log?.record(LogEvent(
            level: failure == nil ? .info : .warning,
            kind: .session,
            message: "protection mutation finished \(outcomeName(outcome)) dispatched=\(dispatched)"
        ))
        return report(outcome, dispatched: dispatched, startedAt: startedAt, failure: failure)
    }

    // MARK: - Sequence (gate already held)

    private func performMutation(
        _ intent: ProtectionIntent, allowRecovery: Bool
    ) async -> (MutationOutcome<ProtectionState>, Bool, RefreshFailureCategory?) {
        let beforeResponse: AdGuardStatusResponse
        do {
            beforeResponse = try await adGuard.status()
        } catch {
            return (.rejected(.preconditionFailed("status unavailable")), false, failureCategory(for: error))
        }
        let beforeState = protectionState(from: beforeResponse, now: clock())

        let wire = intent.wire
        do {
            try await adGuard.setProtection(enabled: wire.enabled, durationMilliseconds: wire.durationMilliseconds)
        } catch AdGuardClientError.credentialUnavailable {
            // No request was ever sent; nothing ambiguous happened.
            return (.rejected(.preconditionFailed("credential unavailable")), false, .authentication)
        } catch AdGuardClientError.unauthorized {
            // A POST reached the server and was rejected as unauthorized
            // (including the single re-dispatch after a 401/403, if that
            // also failed). AdGuard Home never applies a write it rejects
            // with 401/403, so this is not ambiguous the way a timeout or
            // lost response is: there is nothing to verify. Report it as
            // dispatched (a request was sent) but not applied.
            return (.rejected(.preconditionFailed("AdGuard Home refused the login")), true, .authentication)
        } catch {
            // Timeout, lost response, non-2xx after the retry, etc: we
            // cannot tell whether the router applied the write. Treat the
            // write as dispatched and let verification decide.
        }

        let deadline = clock().addingTimeInterval(durationToTimeInterval(policy.deadline))
        let poll = await pollUntilMatch(deadline: deadline) { self.matchesIntent(intent, response: $0) }

        if let matched = poll.matched {
            return (.verifiedSuccess(protectionState(from: matched, now: clock())), true, nil)
        }

        guard let last = poll.last else {
            return (.unknownAfterDispatch, true, poll.failure)
        }

        let actualState = protectionState(from: last, now: clock())
        let intendedState = intendedState(for: intent, now: clock())

        if actualState == beforeState {
            if allowRecovery, beforeState == .enabled || beforeState == .disabled {
                return await performRecovery(beforeState: beforeState)
            }
            return (.verifiedMismatch(expected: intendedState, actual: actualState), true, nil)
        }

        return (.conflictingExternalEdit(actual: actualState), true, nil)
    }

    private func performRecovery(
        beforeState: ProtectionState
    ) async -> (MutationOutcome<ProtectionState>, Bool, RefreshFailureCategory?) {
        let recoveryIntent: ProtectionIntent = beforeState == .enabled ? .enable : .disable
        let wire = recoveryIntent.wire
        do {
            try await adGuard.setProtection(enabled: wire.enabled, durationMilliseconds: wire.durationMilliseconds)
        } catch AdGuardClientError.unauthorized {
            // Same reasoning as the primary write's unauthorized case: a
            // 401/403 is a definitive rejection, not an ambiguous outcome,
            // so there is nothing to verify.
            return (.recoveryFailed(expected: beforeState, actual: nil), true, .authentication)
        } catch {
            // Same ambiguity as the primary write: still verify.
        }

        let deadline = clock().addingTimeInterval(durationToTimeInterval(policy.deadline))
        let poll = await pollUntilMatch(deadline: deadline) { self.matchesIntent(recoveryIntent, response: $0) }

        if let matched = poll.matched {
            return (.verifiedRecovery(restored: protectionState(from: matched, now: clock())), true, nil)
        }

        let actual = poll.last.map { protectionState(from: $0, now: clock()) }
        return (.recoveryFailed(expected: beforeState, actual: actual), true, poll.failure)
    }

    // MARK: - Polling

    private func pollUntilMatch(
        deadline: Date,
        matches: @Sendable (AdGuardStatusResponse) -> Bool
    ) async -> (matched: AdGuardStatusResponse?, last: AdGuardStatusResponse?, failure: RefreshFailureCategory?) {
        var last: AdGuardStatusResponse?
        var lastFailure: RefreshFailureCategory?

        while clock() < deadline {
            do {
                let response = try await adGuard.status()
                last = response
                lastFailure = nil
                if matches(response) {
                    return (response, response, nil)
                }
            } catch {
                lastFailure = failureCategory(for: error)
            }
            // `try?`: a cancelled sleep must not stop verification of an
            // already-dispatched write. We simply loop again immediately.
            try? await sleep(policy.pollInterval)
        }

        return (nil, last, lastFailure)
    }

    // MARK: - Mapping

    private func protectionState(from response: AdGuardStatusResponse, now: Date) -> ProtectionState {
        switch response.protectionEnabled {
        case true:
            return .enabled
        case false:
            if let duration = response.protectionDisabledDurationMilliseconds, duration > 0 {
                return .paused(until: now.addingTimeInterval(TimeInterval(duration) / 1000))
            }
            return .disabled
        case nil:
            return .unknown
        }
    }

    private func intendedState(for intent: ProtectionIntent, now: Date) -> ProtectionState {
        switch intent {
        case .enable:
            return .enabled
        case .disable:
            return .disabled
        case .pause(let duration):
            return .paused(until: now.addingTimeInterval(durationToTimeInterval(duration)))
        }
    }

    private func matchesIntent(_ intent: ProtectionIntent, response: AdGuardStatusResponse) -> Bool {
        switch intent {
        case .enable:
            return response.protectionEnabled == true
        case .disable:
            // AdGuard Home may omit `protection_disabled_duration` entirely
            // when protection is disabled indefinitely; treat a missing
            // field the same as 0, not as "still has a duration".
            return response.protectionEnabled == false && (response.protectionDisabledDurationMilliseconds ?? 0) == 0
        case .pause(let duration):
            guard response.protectionEnabled == false,
                  let observedMs = response.protectionDisabledDurationMilliseconds, observedMs > 0 else {
                return false
            }
            let requestedMs = ProtectionIntent.milliseconds(from: duration)
            let toleranceMs = ProtectionIntent.milliseconds(from: policy.pauseTolerance)
            return observedMs <= requestedMs && observedMs >= requestedMs - toleranceMs
        }
    }

    private func failureCategory(for error: Error) -> RefreshFailureCategory {
        switch error {
        case AdGuardClientError.transport(let transportError):
            switch transportError {
            case .timedOut: return .timeout
            default: return .network
            }
        case AdGuardClientError.unauthorized:
            return .authentication
        case AdGuardClientError.httpStatus:
            return .unavailable
        case AdGuardClientError.malformedResponse:
            return .malformedResponse
        case AdGuardClientError.credentialUnavailable:
            return .authentication
        default:
            return .unavailable
        }
    }

    private func outcomeName(_ outcome: MutationOutcome<ProtectionState>) -> String {
        switch outcome {
        case .rejected: return "rejected"
        case .verifiedSuccess: return "verifiedSuccess"
        case .verifiedMismatch: return "verifiedMismatch"
        case .verifiedRecovery: return "verifiedRecovery"
        case .recoveryFailed: return "recoveryFailed"
        case .conflictingExternalEdit: return "conflictingExternalEdit"
        case .unknownAfterDispatch: return "unknownAfterDispatch"
        }
    }

    private func report(
        _ outcome: MutationOutcome<ProtectionState>, dispatched: Bool, startedAt: Date, failure: RefreshFailureCategory?
    ) -> MutationReport<ProtectionState> {
        MutationReport(outcome: outcome, dispatched: dispatched, startedAt: startedAt, finishedAt: clock(), failure: failure)
    }
}

private func durationToTimeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

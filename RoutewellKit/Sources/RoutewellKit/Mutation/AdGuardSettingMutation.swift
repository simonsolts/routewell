import Foundation

/// What the caller wants AdGuard's protection setting to become.
public enum ProtectionIntent: Sendable, Equatable {
    case enable
    case disable
    /// More than 0 and at most 48 hours: the Pause menu runs from 30
    /// seconds to "until tomorrow" at 08:00 (at most 32 hours).
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
            if Self.milliseconds(from: duration) <= 0 || duration > .seconds(48 * 60 * 60) {
                return .invalidIntent("Pause duration must be more than 0 and at most 48 hours")
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

/// A change to a setting inside AdGuard Home (architecture 04): protection
/// on, off, or paused, and the three Protection switches.
public enum AdGuardSettingIntent: Sendable, Equatable {
    case protection(ProtectionIntent)
    case feature(AdGuardFeature, enabled: Bool)

    /// Writes run only while AdGuard Home runs; the read-only UI is not the
    /// only guard.
    public func validate(_ availability: AdGuardAvailability) -> MutationRejection? {
        guard availability == .running else { return .preconditionFailed("AdGuard Home is not running.") }
        if case .protection(let intent) = self { return intent.validate() }
        return nil
    }
}

/// What AdGuard Home reported after a setting write.
public enum AdGuardSettingState: Sendable, Equatable {
    case protection(ProtectionState)
    /// A switch; `nil` when the status did not say.
    case feature(Bool?)
}

/// The calls a setting write needs. Live: AdGuard Home's own API.
public protocol AdGuardSettingTransport: Sendable {
    func readStatus() async throws -> AdGuardStatusResponse
    /// The feature's status object as AdGuard Home sent it (`enabled`, and
    /// for Safe Search the engine flags).
    func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue
    func write(_ write: AdGuardWrite) async throws
}

/// Runs one setting write. `nil` from `RouterBackend.adGuardSettings` means
/// the profile has no AdGuard Home connection.
public protocol AdGuardSettingControl: Sendable {
    func run(_ intent: AdGuardSettingIntent, availability: AdGuardAvailability) async -> MutationReport<AdGuardSettingState>
}

/// Timing knobs for verifying a setting write. All virtual-clock driven
/// so tests never wait in real time.
public struct AdGuardSettingVerifyPolicy: Sendable, Equatable {
    public var deadline: Duration = .seconds(8)
    public var pollInterval: Duration = .milliseconds(500)
    /// The observed remaining pause may be shorter than requested by up to
    /// this much (time passes between dispatch and read-back).
    public var pauseTolerance: Duration = .seconds(30)

    public init() {}
}

/// Gate → availability check → before-state (a fresh read of only the
/// setting) → dispatch once → bounded verify. Every setting write is
/// `resync`: a mismatch reports what AdGuard Home says and nothing is sent
/// again. Generalised from chunk 10's `ProtectionMutationExecutor`, which
/// sent the old state back after a mismatch.
public struct AdGuardSettingExecutor: AdGuardSettingControl {
    private let transport: any AdGuardSettingTransport
    private let gate: MutationGate
    private let policy: AdGuardSettingVerifyPolicy
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: SessionEventLog?

    public init(
        transport: any AdGuardSettingTransport,
        gate: MutationGate,
        policy: AdGuardSettingVerifyPolicy = .init(),
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: SessionEventLog? = nil
    ) {
        self.transport = transport
        self.gate = gate
        self.policy = policy
        self.clock = clock
        self.sleep = sleep
        self.log = log
    }

    private typealias Step = (outcome: MutationOutcome<AdGuardSettingState>, dispatched: Bool, failure: RefreshFailureCategory?)

    public func run(_ intent: AdGuardSettingIntent, availability: AdGuardAvailability) async -> MutationReport<AdGuardSettingState> {
        let startedAt = clock()
        if let rejection = intent.validate(availability) {
            return report((.rejected(rejection), false, nil), startedAt: startedAt)
        }
        let token: MutationGateToken
        do {
            token = try await gate.acquire()
        } catch {
            // A cancelled waiter never acquires the gate, so there is
            // nothing to release here.
            return report((.rejected(.preconditionFailed("Cancelled before dispatch")), false, nil), startedAt: startedAt)
        }
        if Task.isCancelled {
            await gate.release(token)
            return report((.rejected(.preconditionFailed("Cancelled before dispatch")), false, nil), startedAt: startedAt)
        }
        let step: Step
        switch intent {
        case .protection(let protection): step = await performProtection(protection)
        case .feature(let feature, let enabled): step = await performFeature(feature, enabled: enabled)
        }
        await gate.release(token)
        await log?.record(LogEvent(
            level: step.failure == nil ? .info : .warning, kind: .session,
            message: "adguard setting mutation finished \(Self.name(step.outcome)) dispatched=\(step.dispatched)"
        ))
        return report(step, startedAt: startedAt)
    }

    // MARK: Protection (gate held)

    private func performProtection(_ intent: ProtectionIntent) async -> Step {
        let before: AdGuardStatusResponse
        do {
            before = try await transport.readStatus()
        } catch {
            return (.rejected(.preconditionFailed("status unavailable")), false, Self.category(for: error))
        }
        let beforeState = Self.protectionState(from: before, now: clock())

        let wire = intent.wire
        if let stop = await dispatch(.protection(enabled: wire.enabled, durationMilliseconds: wire.durationMilliseconds)) {
            return stop
        }

        let poll = await poll { try await transport.readStatus() } matches: { matches(intent, response: $0) }
        if let matched = poll.matched {
            return (.verifiedSuccess(.protection(Self.protectionState(from: matched, now: clock()))), true, nil)
        }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        let actual = Self.protectionState(from: last, now: clock())
        if Self.sameKind(actual, beforeState) {
            let intended = Self.intendedState(for: intent, now: clock())
            return (.verifiedMismatch(expected: .protection(intended), actual: .protection(actual)), true, nil)
        }
        // Neither the old state nor the asked one: someone else changed it.
        return (.conflictingExternalEdit(actual: .protection(actual)), true, nil)
    }

    // MARK: Switches (gate held)

    private func performFeature(_ feature: AdGuardFeature, enabled: Bool) async -> Step {
        let before: JSONValue
        do {
            before = try await transport.readFeature(feature)
        } catch {
            return (.rejected(.preconditionFailed("status unavailable")), false, Self.category(for: error))
        }
        if before["enabled"]?.bool == enabled { return (.verifiedSuccess(.feature(enabled)), false, nil) }

        let write: AdGuardWrite
        if feature == .safeSearch {
            // The engine flags go back exactly as read.
            guard var settings = before.object else {
                return (.rejected(.preconditionFailed("AdGuard Home did not send its Safe Search settings.")), false, .malformedResponse)
            }
            settings["enabled"] = .bool(enabled)
            write = .safeSearchSettings(.object(settings))
        } else {
            write = .feature(feature, enabled: enabled)
        }
        if let stop = await dispatch(write) { return stop }

        let poll = await poll { try await transport.readFeature(feature) } matches: { $0["enabled"]?.bool == enabled }
        if poll.matched != nil { return (.verifiedSuccess(.feature(enabled)), true, nil) }
        guard let last = poll.last else { return (.unknownAfterDispatch, true, poll.failure) }
        return (.verifiedMismatch(expected: .feature(enabled), actual: .feature(last["enabled"]?.bool)), true, nil)
    }

    // MARK: Dispatch and verify

    /// Sends the write once. Returns a final step when nothing was sent or
    /// AdGuard Home refused the sign-in; `nil` means verify.
    private func dispatch(_ write: AdGuardWrite) async -> Step? {
        do {
            try await transport.write(write)
            return nil
        } catch AdGuardClientError.credentialUnavailable {
            // No request was ever sent; nothing ambiguous happened.
            return (.rejected(.preconditionFailed("credential unavailable")), false, .authentication)
        } catch AdGuardClientError.unauthorized {
            // A request reached the server and was rejected as unauthorized
            // (including the single re-dispatch after a 401/403). AdGuard
            // Home never applies a write it rejects with 401/403, so there
            // is nothing to verify; it still counts as dispatched.
            return (.rejected(.preconditionFailed("AdGuard Home refused the login")), true, .authentication)
        } catch {
            // Timeout, lost response, non-2xx after the retry: the write may
            // have applied. Verification decides.
            return nil
        }
    }

    private func poll<Value: Sendable>(
        read: () async throws -> Value, matches: (Value) -> Bool
    ) async -> (matched: Value?, last: Value?, failure: RefreshFailureCategory?) {
        let deadline = clock().addingTimeInterval(Self.seconds(policy.deadline))
        var last: Value?
        var lastFailure: RefreshFailureCategory?
        while clock() < deadline {
            do {
                let value = try await read()
                last = value
                lastFailure = nil
                if matches(value) { return (value, value, nil) }
            } catch {
                lastFailure = Self.category(for: error)
            }
            // `try?`: a cancelled sleep must not stop verification of an
            // already-dispatched write. We simply loop again immediately.
            try? await sleep(policy.pollInterval)
        }
        return (nil, last, lastFailure)
    }

    // MARK: Mapping

    static func protectionState(from response: AdGuardStatusResponse, now: Date) -> ProtectionState {
        switch response.protectionEnabled {
        case true?:
            return .enabled
        case false?:
            if let duration = response.protectionDisabledDurationMilliseconds, duration > 0 {
                return .paused(until: now.addingTimeInterval(TimeInterval(duration) / 1000))
            }
            return .disabled
        case nil:
            return .unknown
        }
    }

    private static func sameKind(_ lhs: ProtectionState, _ rhs: ProtectionState) -> Bool {
        switch (lhs, rhs) {
        case (.enabled, .enabled), (.disabled, .disabled), (.paused, .paused), (.unknown, .unknown): true
        default: false
        }
    }

    private static func intendedState(for intent: ProtectionIntent, now: Date) -> ProtectionState {
        switch intent {
        case .enable: .enabled
        case .disable: .disabled
        case .pause(let duration): .paused(until: now.addingTimeInterval(seconds(duration)))
        }
    }

    private func matches(_ intent: ProtectionIntent, response: AdGuardStatusResponse) -> Bool {
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

    static func category(for error: Error) -> RefreshFailureCategory {
        switch error {
        case let error as AdGuardClientError: LiveRouterBackend.category(for: error)
        case let error as TransportError: LiveRouterBackend.category(for: error)
        default: .unavailable
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func name(_ outcome: MutationOutcome<AdGuardSettingState>) -> String {
        switch outcome {
        case .rejected: "rejected"
        case .verifiedSuccess: "verifiedSuccess"
        case .verifiedMismatch: "verifiedMismatch"
        case .verifiedRecovery: "verifiedRecovery"
        case .recoveryFailed: "recoveryFailed"
        case .conflictingExternalEdit: "conflictingExternalEdit"
        case .unknownAfterDispatch: "unknownAfterDispatch"
        }
    }

    private func report(_ step: Step, startedAt: Date) -> MutationReport<AdGuardSettingState> {
        MutationReport(outcome: step.outcome, dispatched: step.dispatched, startedAt: startedAt, finishedAt: clock(), failure: step.failure)
    }
}

/// The live calls: AdGuard Home's own API.
public struct LiveAdGuardSettingTransport: AdGuardSettingTransport {
    let adGuard: AdGuardClient

    public init(adGuard: AdGuardClient) { self.adGuard = adGuard }

    public func readStatus() async throws -> AdGuardStatusResponse { try await adGuard.status() }
    public func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue {
        try await adGuard.read(.status(of: feature))
    }
    public func write(_ write: AdGuardWrite) async throws { try await adGuard.write(write) }
}

import Foundation

/// A change to the AdGuard Home service on the router.
public enum AdGuardServiceIntent: Sendable, Equatable {
    /// Turn On, from the empty state (with the radio choice) or the
    /// read-only strip (with the last saved Handle DNS setting).
    case turnOn(handlesDNS: Bool)
    /// Stop… and the AdGuard Home switch turned off.
    case turnOff
    case setHandlesDNS(Bool)
    /// Off, then on, with the current Handle DNS setting.
    case restart

    /// Turn On is the one write allowed while AdGuard Home is not running.
    public func validate(_ availability: AdGuardAvailability) -> MutationRejection? {
        switch self {
        case .turnOn:
            return availability == .off || availability == .cached ? nil : .preconditionFailed("AdGuard Home is not off.")
        case .turnOff, .setHandlesDNS, .restart:
            return availability == .running ? nil : .preconditionFailed("AdGuard Home is not running.")
        }
    }
}

/// What the router and AdGuard Home reported after a service write. `nil`
/// fields were not read or not reported.
public struct AdGuardServiceState: Sendable, Equatable {
    public var enabled: Bool?
    public var handlesDNS: Bool?
    /// AdGuard Home answered `control/status` within the bounded wait.
    public var answering: Bool?

    public init(enabled: Bool? = nil, handlesDNS: Bool? = nil, answering: Bool? = nil) {
        self.enabled = enabled
        self.handlesDNS = handlesDNS
        self.answering = answering
    }

    init(_ config: AdGuardRouterConfig, answering: Bool? = nil) {
        self.init(enabled: config.enabled, handlesDNS: config.handlesDNS, answering: answering)
    }
}

/// The three calls a service write needs. Live: router RPC `adguardhome
/// get_config` and `set_config`, and AdGuard's `control/status`.
public protocol AdGuardServiceTransport: Sendable {
    func readConfig() async throws -> AdGuardRouterConfig
    /// `set_config`. `handlesDNS` `nil` leaves `dns_enabled` out. Returns the
    /// reply's `err_code`, if the router named one.
    func writeConfig(enabled: Bool, handlesDNS: Bool?) async throws -> Int?
    func readStatus() async throws -> AdGuardStatusResponse
    /// False when the profile has no AdGuard Home connection: writes are
    /// verified with the router's `get_config` only.
    var canReadStatus: Bool { get }
}

public extension AdGuardServiceTransport {
    var canReadStatus: Bool { true }
}

/// Runs one AdGuard Home service write. `beforeDispatch` runs only for
/// `turnOff`, after the gate is held and before the write, with the fresh
/// status (when AdGuard Home answered) and config: the final archive sync.
public protocol AdGuardServiceControl: Sendable {
    func run(
        _ intent: AdGuardServiceIntent,
        availability: AdGuardAvailability,
        beforeDispatch: @escaping @Sendable (AdGuardServiceReading) async -> Void
    ) async -> MutationReport<AdGuardServiceState>
}

/// Timing for verifying a service write. Virtual-clock driven in tests.
public struct AdGuardServiceVerifyPolicy: Sendable, Equatable {
    /// How long `get_config` may take to show the new setting.
    public var configDeadline: Duration = .seconds(15)
    /// How long AdGuard Home may take to answer after it is switched on.
    public var answerDeadline: Duration = .seconds(30)
    public var pollInterval: Duration = .seconds(1)

    public init() {}
}

/// Gate → availability check → before-state (`get_config`) → dispatch once →
/// bounded verify. Turn On, Stop, and Handle DNS are `resync`: a mismatch
/// reports what the router says and nothing is sent again. Restart is
/// `none`: off, then on, and verification alone decides.
public struct AdGuardServiceExecutor: AdGuardServiceControl {
    private let transport: any AdGuardServiceTransport
    private let gate: MutationGate
    private let policy: AdGuardServiceVerifyPolicy
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: SessionEventLog?

    public init(
        transport: any AdGuardServiceTransport,
        gate: MutationGate,
        policy: AdGuardServiceVerifyPolicy = .init(),
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

    private typealias Step = (outcome: MutationOutcome<AdGuardServiceState>, dispatched: Bool, failure: RefreshFailureCategory?)

    public func run(
        _ intent: AdGuardServiceIntent,
        availability: AdGuardAvailability,
        beforeDispatch: @escaping @Sendable (AdGuardServiceReading) async -> Void = { _ in }
    ) async -> MutationReport<AdGuardServiceState> {
        let startedAt = clock()
        if let rejection = intent.validate(availability) {
            return report((.rejected(rejection), false, nil), startedAt: startedAt)
        }
        let token: MutationGateToken
        do {
            token = try await gate.acquire()
        } catch {
            return report((.rejected(.preconditionFailed("Cancelled before dispatch")), false, nil), startedAt: startedAt)
        }
        if Task.isCancelled {
            await gate.release(token)
            return report((.rejected(.preconditionFailed("Cancelled before dispatch")), false, nil), startedAt: startedAt)
        }
        let step = await perform(intent, beforeDispatch: beforeDispatch)
        await gate.release(token)
        await log?.record(LogEvent(
            level: step.failure == nil ? .info : .warning, kind: .session,
            message: "adguard service mutation finished \(Self.name(step.outcome)) dispatched=\(step.dispatched)"
        ))
        return report(step, startedAt: startedAt)
    }

    // MARK: Sequence (gate held)

    private func perform(
        _ intent: AdGuardServiceIntent,
        beforeDispatch: @Sendable (AdGuardServiceReading) async -> Void
    ) async -> Step {
        let before: AdGuardRouterConfig
        do {
            before = try await transport.readConfig()
        } catch {
            return (.rejected(.preconditionFailed("The router did not say whether AdGuard Home is on.")), false, Self.category(for: error))
        }

        switch intent {
        case .turnOn(let handlesDNS):
            guard before.enabled == false else {
                return (.rejected(.preconditionFailed("AdGuard Home is already on.")), false, nil)
            }
            let expected = AdGuardServiceState(enabled: true, handlesDNS: handlesDNS, answering: true)
            if let stop = await dispatch(enabled: true, handlesDNS: handlesDNS, expected: expected) { return stop }
            return await verifyOn(handlesDNS: handlesDNS, expected: expected)

        case .turnOff:
            guard before.enabled == true else {
                return (.rejected(.preconditionFailed("AdGuard Home is already off.")), false, nil)
            }
            // The final sync: the freshest status, if AdGuard Home answers.
            var answer: AdGuardServiceReading.Answer = .notConfigured
            if transport.canReadStatus {
                do { answer = .answered(try await transport.readStatus()) }
                catch { answer = .failed(Self.category(for: error)) }
            }
            await beforeDispatch(AdGuardServiceReading(config: .success(before), answer: answer, observedAt: clock()))
            let expected = AdGuardServiceState(enabled: false, handlesDNS: before.handlesDNS)
            if let stop = await dispatch(enabled: false, handlesDNS: before.handlesDNS, expected: expected) { return stop }
            return await verifyConfig(expected: expected) { $0.enabled == false }

        case .setHandlesDNS(let value):
            guard before.enabled == true else {
                return (.rejected(.preconditionFailed("AdGuard Home is off.")), false, nil)
            }
            let expected = AdGuardServiceState(enabled: true, handlesDNS: value)
            if before.handlesDNS == value { return (.verifiedSuccess(AdGuardServiceState(before)), false, nil) }
            if let stop = await dispatch(enabled: true, handlesDNS: value, expected: expected) { return stop }
            return await verifyConfig(expected: expected) { $0.enabled == true && $0.handlesDNS == value }

        case .restart:
            guard before.enabled == true else {
                return (.rejected(.preconditionFailed("AdGuard Home is off.")), false, nil)
            }
            let off = AdGuardServiceState(enabled: false, handlesDNS: before.handlesDNS)
            if let stop = await dispatch(enabled: false, handlesDNS: before.handlesDNS, expected: off) { return stop }
            let stopped = await verifyConfig(expected: off) { $0.enabled == false }
            switch stopped.outcome {
            case .verifiedSuccess, .unknownAfterDispatch:
                // Off, or not known: switching on is what the person asked
                // for either way, so it is sent.
                break
            default:
                // The router kept AdGuard Home on: nothing more is sent.
                return stopped
            }
            // `dispatch` above already returned for a refused off write
            // (an `err_code`), even when the read after it failed: a router
            // that refused "off" is not sent "on".
            let expected = AdGuardServiceState(enabled: true, handlesDNS: before.handlesDNS, answering: true)
            if let stop = await dispatch(enabled: true, handlesDNS: before.handlesDNS, expected: expected) { return stop }
            return await verifyOn(handlesDNS: before.handlesDNS, expected: expected)
        }
    }

    /// Sends `set_config` once. Returns a final step when the router refused
    /// it or nothing was sent; `nil` means verify.
    private func dispatch(enabled: Bool, handlesDNS: Bool?, expected: AdGuardServiceState) async -> Step? {
        do {
            guard let code = try await transport.writeConfig(enabled: enabled, handlesDNS: handlesDNS) else { return nil }
            // The router answered with an error code. Its setting decides.
            await log?.record(LogEvent(level: .warning, kind: .session, message: "adguardhome set_config err_code \(code)"))
            guard let actual = try? await transport.readConfig() else { return (.unknownAfterDispatch, true, nil) }
            if actual.enabled == expected.enabled, expected.handlesDNS == nil || actual.handlesDNS == expected.handlesDNS {
                return nil
            }
            if code == 1 {
                // GL.iNet: "Other DNS not closed".
                return (.rejected(.preconditionFailed(Self.otherDNSMessage)), true, nil)
            }
            return (.verifiedMismatch(expected: expected, actual: AdGuardServiceState(actual)), true, nil)
        } catch GLiNetRPCError.credentialUnavailable {
            return (.rejected(.preconditionFailed("The router password is not available.")), false, .authentication)
        } catch GLiNetRPCError.loginPaused {
            return (.rejected(.preconditionFailed("The router paused sign-in.")), false, .authentication)
        } catch GLiNetRPCError.accessDenied {
            return (.rejected(.preconditionFailed("The router refused the sign-in.")), true, .authentication)
        } catch GLiNetRPCError.methodNotFound {
            return (.rejected(.capabilityUnavailable), true, .unavailable)
        } catch GLiNetRPCError.invalidParameters {
            // The `set_config` params are not confirmed: say so plainly.
            return (.rejected(.preconditionFailed("The router did not accept the settings Routewell sent.")), true, .malformedResponse)
        } catch {
            // Lost answer or timeout: the write may have applied. Verify.
            return nil
        }
    }

    /// `get_config` shows the setting, then AdGuard Home answers.
    private func verifyOn(handlesDNS: Bool?, expected: AdGuardServiceState) async -> Step {
        let configured = await verifyConfig(expected: expected) { config in
            config.enabled == true && (handlesDNS == nil || config.handlesDNS == handlesDNS)
        }
        guard case .verifiedSuccess(var state) = configured.outcome else { return configured }
        // Without an AdGuard Home connection the router's setting is all
        // Routewell can check.
        guard transport.canReadStatus else { return configured }
        let deadline = clock().addingTimeInterval(Self.seconds(policy.answerDeadline))
        var lastFailure: RefreshFailureCategory?
        while true {
            do {
                _ = try await transport.readStatus()
                state.answering = true
                return (.verifiedSuccess(state), true, nil)
            } catch {
                lastFailure = Self.category(for: error)
            }
            guard clock() < deadline else { break }
            try? await sleep(policy.pollInterval)
        }
        state.answering = false
        return (.verifiedMismatch(expected: expected, actual: state), true, lastFailure)
    }

    /// Polls `get_config` until `matches`, within the config deadline.
    private func verifyConfig(expected: AdGuardServiceState, matches: (AdGuardRouterConfig) -> Bool) async -> Step {
        let deadline = clock().addingTimeInterval(Self.seconds(policy.configDeadline))
        var last: AdGuardRouterConfig?
        var lastFailure: RefreshFailureCategory?
        while true {
            do {
                let config = try await transport.readConfig()
                last = config
                lastFailure = nil
                if matches(config) { return (.verifiedSuccess(AdGuardServiceState(config)), true, nil) }
            } catch {
                lastFailure = Self.category(for: error)
            }
            guard clock() < deadline else { break }
            // `try?`: a cancelled sleep must not stop verifying a sent write.
            try? await sleep(policy.pollInterval)
        }
        guard let last else { return (.unknownAfterDispatch, true, lastFailure) }
        return (.verifiedMismatch(expected: expected, actual: AdGuardServiceState(last)), true, nil)
    }

    // MARK: Mapping

    public static let otherDNSMessage = "The router says another DNS setting is on. Turn it off in the router's settings, then try again."

    static func category(for error: Error) -> RefreshFailureCategory {
        switch error {
        case let error as GLiNetRPCError: LiveRouterBackend.category(for: error)
        case let error as AdGuardClientError: LiveRouterBackend.category(for: error)
        case let error as TransportError: LiveRouterBackend.category(for: error)
        default: .unavailable
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func name(_ outcome: MutationOutcome<AdGuardServiceState>) -> String {
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

    private func report(_ step: Step, startedAt: Date) -> MutationReport<AdGuardServiceState> {
        MutationReport(outcome: step.outcome, dispatched: step.dispatched, startedAt: startedAt, finishedAt: clock(), failure: step.failure)
    }
}

/// The live calls: router RPC for the setting, AdGuard's own API for the
/// answer. `set_config` params are `{"enabled", "dns_enabled"}`.
public struct LiveAdGuardServiceTransport: AdGuardServiceTransport {
    let rpc: GLiNetRPCClient
    /// `nil` when the profile has no AdGuard Home connection.
    let adGuard: AdGuardClient?

    public init(rpc: GLiNetRPCClient, adGuard: AdGuardClient?) {
        self.rpc = rpc
        self.adGuard = adGuard
    }

    public func readConfig() async throws -> AdGuardRouterConfig {
        AdGuardRouterConfig.parse(try await rpc.call(.init(object: "adguardhome", method: "get_config", params: .object([:]))))
    }

    public func writeConfig(enabled: Bool, handlesDNS: Bool?) async throws -> Int? {
        var params: [String: JSONValue] = ["enabled": .bool(enabled)]
        if let handlesDNS { params["dns_enabled"] = .bool(handlesDNS) }
        let reply = try await rpc.call(.init(object: "adguardhome", method: "set_config", params: .object(params)))
        return Self.errorCode(reply)
    }

    public func readStatus() async throws -> AdGuardStatusResponse {
        guard let adGuard else { throw AdGuardClientError.credentialUnavailable }
        return try await adGuard.status()
    }

    public var canReadStatus: Bool { adGuard != nil }

    /// A non-zero `err_code` in the reply. `null` and `{}` are success.
    static func errorCode(_ reply: JSONValue) -> Int? {
        guard let code = reply["err_code"]?.int, code != 0 else { return nil }
        return code
    }
}

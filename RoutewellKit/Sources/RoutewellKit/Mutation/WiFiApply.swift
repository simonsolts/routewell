import Foundation

/// The progress trail of an apply.
public enum WiFiApplyStep: Sendable, Equatable {
    case sending, restarting, reconnecting, checking
}

/// What the router reported after an apply: the slots the plan touched and
/// the main subnet's isolation.
public struct WiFiApplyState: Sendable, Equatable {
    public var slots: [WiFiSlotState]
    public var isolate: Bool?

    public init(slots: [WiFiSlotState] = [], isolate: Bool? = nil) {
        self.slots = slots
        self.isolate = isolate
    }
}

/// The calls an apply needs. Live: router RPC.
public protocol WiFiApplyTransport: Sendable {
    /// `wifi get_config` joined with `get_status`.
    func readWireless() async throws -> WirelessStatus
    /// `vlan_subnet get_subnets`.
    func readSubnets() async throws -> [SubnetPolicy]
    /// `wifi get_status`: answers once the router is back.
    func readRadioStates() async throws -> [WirelessBand: RadioState]
    /// One write. Returns the reply's `err_code`, if the router named one.
    func send(_ call: WiFiCall) async throws -> Int?
}

/// Runs one Wi-Fi apply. `nil` from `RouterBackend.wifiControl` means the
/// router has no Wi-Fi writes.
public protocol WiFiControl: Sendable {
    func apply(_ plan: WiFiApplyPlan, progress: @escaping @Sendable (WiFiApplyStep) async -> Void) async -> MutationReport<WiFiApplyState>
}

/// Timing for an apply. Virtual-clock driven in tests.
public struct WiFiApplyPolicy: Sendable, Equatable {
    /// GL's own UI waits this long after `set_config` before it reads.
    public var settle: Duration = .seconds(5)
    public var pollInterval: Duration = .seconds(2)
    /// How long the router may stay out of reach after a restart.
    public var reconnectWindow: Duration = .seconds(90)
    /// How long the read-back may take to show every change.
    public var verifyDeadline: Duration = .seconds(30)

    public init() {}
}

/// Gate → before-read (only what the plan touches) → one call at a time →
/// reconnect wait → verify. Recovery class `resync`: a mismatch reports what
/// the router has, and nothing is sent again, because a second write drops
/// the devices again.
public struct WiFiApplyExecutor: WiFiControl {
    private let transport: any WiFiApplyTransport
    private let gate: MutationGate
    private let policy: WiFiApplyPolicy
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: SessionEventLog?

    public init(
        transport: any WiFiApplyTransport,
        gate: MutationGate,
        policy: WiFiApplyPolicy = .init(),
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

    private typealias Step = (outcome: MutationOutcome<WiFiApplyState>, dispatched: Bool, failure: RefreshFailureCategory?)

    public func apply(_ plan: WiFiApplyPlan, progress: @escaping @Sendable (WiFiApplyStep) async -> Void = { _ in }) async -> MutationReport<WiFiApplyState> {
        let startedAt = clock()
        guard !plan.isEmpty else { return report((.rejected(.invalidIntent("No changes")), false, nil), startedAt: startedAt) }
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
        let step = await perform(plan, progress: progress)
        await gate.release(token)
        await log?.record(LogEvent(
            level: step.failure == nil ? .info : .warning, kind: .session,
            message: "wifi apply finished \(Self.name(step.outcome)) dispatched=\(step.dispatched) calls=\(plan.steps.count)"
        ))
        return report(step, startedAt: startedAt)
    }

    // MARK: Sequence (gate held)

    private func perform(_ plan: WiFiApplyPlan, progress: @Sendable (WiFiApplyStep) async -> Void) async -> Step {
        let touchesNetworks = plan.steps.contains { $0.before != nil }
        var calls = plan.calls
        do {
            let wireless = touchesNetworks ? try await transport.readWireless() : nil
            let subnets = plan.subnetBefore != nil ? try await transport.readSubnets() : nil
            let current = Self.state(plan, wireless: wireless, subnets: subnets)
            if let wireless {
                let slots = WiFiSlotState.slots(wireless)
                for step in plan.steps {
                    guard let before = step.before else { continue }
                    if slots[before.interface] != before { return (.conflictingExternalEdit(actual: current), false, nil) }
                }
            }
            if let before = plan.subnetBefore {
                guard let main = subnets?.first(where: { $0.name == "main" }), main.isolate == before.isolate else {
                    return (.conflictingExternalEdit(actual: current), false, nil)
                }
                // The other fields go back as read now, not as the sheet saw them.
                calls = calls.map { call in
                    if case .subnet(_, let isolate) = call { .subnet(main, isolate: isolate) } else { call }
                }
            }
        } catch {
            return (.rejected(.preconditionFailed("The router did not send its Wi-Fi settings.")), false, FailureMapping.category(for: error))
        }

        await progress(.sending)
        var lost = false
        for (index, call) in calls.enumerated() {
            let first = index == 0
            do {
                guard let code = try await transport.send(call) else { continue }
                await log?.record(LogEvent(level: .warning, kind: .session, message: "\(call) err_code \(code)"))
                if first { return (.rejected(.preconditionFailed(Self.refusedMessage(code))), true, nil) }
                break
            } catch GLiNetRPCError.credentialUnavailable where first {
                return (.rejected(.preconditionFailed("The router password is not available.")), false, .authentication)
            } catch GLiNetRPCError.loginPaused where first {
                return (.rejected(.preconditionFailed("The router paused sign-in.")), false, .authentication)
            } catch GLiNetRPCError.accessDenied where first {
                return (.rejected(.preconditionFailed("The router refused the sign-in.")), true, .authentication)
            } catch GLiNetRPCError.methodNotFound where first {
                return (.rejected(.capabilityUnavailable), true, .unavailable)
            } catch GLiNetRPCError.invalidParameters where first {
                return (.rejected(.preconditionFailed("The router did not accept the settings Routewell sent.")), true, .malformedResponse)
            } catch {
                // No answer: the call may have applied and dropped this Mac.
                // Nothing more is sent.
                await log?.record(LogEvent(level: .warning, kind: .session, message: "\(call) reply lost"))
                lost = true
                break
            }
        }

        await progress(.restarting)
        try? await sleep(policy.settle)
        if plan.thisMac.drops || lost {
            await progress(.reconnecting)
            guard await waitForRouter() else { return (.unknownAfterDispatch, true, .network) }
        }
        await progress(.checking)
        return await verify(plan, calls: calls)
    }

    /// Polls `get_status` until it answers, within the reconnect window.
    private func waitForRouter() async -> Bool {
        let deadline = clock().addingTimeInterval(Self.seconds(policy.reconnectWindow))
        while true {
            if (try? await transport.readRadioStates()) != nil { return true }
            guard clock() < deadline else { return false }
            // `try?`: a cancelled sleep must not stop waiting for a sent write.
            try? await sleep(policy.pollInterval)
        }
    }

    /// Every changed field equal, and the changed radios up. A radio whose
    /// changed networks are all turned off may report no state.
    private func verify(_ plan: WiFiApplyPlan, calls: [WiFiCall]) async -> Step {
        let expected = Self.expected(calls)
        let bands = Set(plan.steps.compactMap(\.scope.band))
        let staysOn = Set(plan.steps.compactMap { step in
            if case .network(let slot, _) = step.call, slot.enabled == true { step.scope.band } else { nil }
        })
        let deadline = clock().addingTimeInterval(Self.seconds(policy.verifyDeadline))
        var last: WiFiApplyState?
        var lastFailure: RefreshFailureCategory?
        while true {
            do {
                let wireless = expected.slots.isEmpty ? nil : try await transport.readWireless()
                let subnets = expected.isolate == nil ? nil : try await transport.readSubnets()
                let actual = Self.state(plan, wireless: wireless, subnets: subnets)
                last = actual
                lastFailure = nil
                let up = bands.allSatisfy { band in
                    switch wireless?.radio(band)?.state {
                    case .ready?, .cac?: true
                    case nil: !staysOn.contains(band)
                    default: false
                    }
                }
                if actual == expected, up { return (.verifiedSuccess(actual), true, nil) }
            } catch {
                lastFailure = FailureMapping.category(for: error)
            }
            guard clock() < deadline else { break }
            try? await sleep(policy.pollInterval)
        }
        guard let last else { return (.unknownAfterDispatch, true, lastFailure) }
        return (.verifiedMismatch(expected: expected, actual: last), true, nil)
    }

    // MARK: State

    /// The touched slots as the router has them, in plan order.
    static func state(_ plan: WiFiApplyPlan, wireless: WirelessStatus?, subnets: [SubnetPolicy]?) -> WiFiApplyState {
        let slots = wireless.map(WiFiSlotState.slots) ?? [:]
        return WiFiApplyState(
            slots: plan.steps.compactMap { $0.before.flatMap { slots[$0.interface] } },
            isolate: plan.subnetBefore == nil ? nil : subnets?.first { $0.name == "main" }?.isolate)
    }

    static func expected(_ calls: [WiFiCall]) -> WiFiApplyState {
        var state = WiFiApplyState()
        for call in calls {
            switch call {
            case .network(let slot, _): state.slots.append(slot)
            case .subnet(_, let isolate): state.isolate = isolate
            }
        }
        return state
    }

    // MARK: Mapping

    public static func refusedMessage(_ code: Int) -> String {
        "The router refused the change (code \(code)). Nothing was changed."
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func name(_ outcome: MutationOutcome<WiFiApplyState>) -> String {
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

    private func report(_ step: Step, startedAt: Date) -> MutationReport<WiFiApplyState> {
        MutationReport(outcome: step.outcome, dispatched: step.dispatched, startedAt: startedAt, finishedAt: clock(), failure: step.failure)
    }
}

/// The live calls: `wifi set_config` per network and `vlan_subnet
/// set_fixed_subnet`, with the shapes GL's own web UI sends.
public struct LiveWiFiApplyTransport: WiFiApplyTransport {
    let rpc: GLiNetRPCClient

    public init(rpc: GLiNetRPCClient) {
        self.rpc = rpc
    }

    public func readWireless() async throws -> WirelessStatus {
        let config = try await rpc.call(LiveWiFiService.config)
        let status = try? await rpc.call(LiveWiFiService.status)
        guard let wireless = WirelessParser.parse(config: config, status: status) else { throw GLiNetRPCError.malformedResponse }
        return wireless
    }

    public func readSubnets() async throws -> [SubnetPolicy] {
        guard let subnets = SubnetParser.parse(try await rpc.call(LiveWiFiService.subnets)) else { throw GLiNetRPCError.malformedResponse }
        return subnets
    }

    public func readRadioStates() async throws -> [WirelessBand: RadioState] {
        let status = try await rpc.call(LiveWiFiService.status)
        var states: [WirelessBand: RadioState] = [:]
        for radio in status["res"]?.array ?? [] {
            guard let band = WirelessBand.parse(radio["band"]?.string), let state = RadioState.parse(radio["state"]?.string) else { continue }
            states[band] = state
        }
        return states
    }

    public func send(_ call: WiFiCall) async throws -> Int? {
        LiveAdGuardServiceTransport.errorCode(try await rpc.call(Self.rpcCall(call)))
    }

    static func rpcCall(_ call: WiFiCall) -> GLiNetRPCCall {
        switch call {
        case .network: GLiNetRPCCall(object: "wifi", method: "set_config", params: call.params)
        case .subnet: GLiNetRPCCall(object: "vlan_subnet", method: "set_fixed_subnet", params: call.params)
        }
    }
}

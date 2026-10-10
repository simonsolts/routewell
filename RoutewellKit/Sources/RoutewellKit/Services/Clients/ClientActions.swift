import Foundation

/// How the router runs Ping and Wake for one client. RouterPilot has no
/// client-scoped RPC for either; it runs both over SSH
/// (`RouterManager.Operations.cs:21-105`). `rpc` stays for a router that
/// offers one later, and for the mock.
public enum ClientActionMechanism: String, Sendable, Equatable {
    case rpc, ssh
    /// SSH would work, but the profile has no SSH set up.
    case sshRequired
}

/// One ping from the router to a client.
public struct PingResult: Sendable, Equatable {
    public let transmitted: Int
    public let received: Int
    public let averageMilliseconds: Double?

    public init(transmitted: Int, received: Int, averageMilliseconds: Double? = nil) {
        self.transmitted = transmitted
        self.received = received
        self.averageMilliseconds = averageMilliseconds
    }

    public var replied: Bool { received > 0 }
}

public enum WakeResult: Sendable, Equatable {
    /// The router sent the magic packet. Whether the device wakes is not
    /// observable here.
    case sent
}

/// Ping is a read; Wake is a write with recovery class `none` whose verifier
/// is the tool's own output. A `nil` service on the
/// backend means the buttons are hidden.
public protocol ClientActionsService: Sendable {
    var mechanism: ClientActionMechanism { get }
    /// Throws only `CancellationError`.
    func ping(_ address: IPv4Literal) async throws -> Result<PingResult, RefreshFailureCategory>
    func wake(_ mac: MACAddress) async -> MutationReport<WakeResult>
}

/// Parses BusyBox and iputils ping summaries. A missing summary line is
/// `nil`, never "no reply".
public enum PingOutputParser {
    public static func parse(_ output: String) -> PingResult? {
        let counts = /(\d+) packets transmitted, (\d+) (?:packets )?received/
        guard let match = output.firstMatch(of: counts),
              let transmitted = Int(match.1), let received = Int(match.2) else { return nil }
        let summary = /min\/avg\/max(?:\/(?:mdev|stddev))? = [0-9.]+\/([0-9.]+)\//
        let average = output.firstMatch(of: summary).flatMap { Double($0.1) }
        return PingResult(transmitted: transmitted, received: received, averageMilliseconds: received > 0 ? average : nil)
    }
}

/// Runs one allow-listed SSH command on the router. `LiveSSHCommandRunner`
/// is the live one; the live backend has none until SSH is set up.
public protocol SSHCommandRunning: Sendable {
    func run(_ command: SSHCommand, limits: ProcessLimits) async throws -> ProcessResult
    /// Sends `input` on stdin. Only for a command that `takesInput`.
    func run(_ command: SSHCommand, input: Data, limits: ProcessLimits) async throws -> ProcessResult
}

public extension SSHCommandRunning {
    func run(_ command: SSHCommand, input: Data, limits: ProcessLimits) async throws -> ProcessResult {
        throw SSHFailure.configurationFailed
    }
}

/// Ping and Wake over SSH. Wake holds the router's `MutationGate` from
/// dispatch to verification, like every other write.
public struct SSHClientActions: ClientActionsService {
    private let runner: any SSHCommandRunning
    private let gate: MutationGate
    private let clock: @Sendable () -> Date
    public static let limits = ProcessLimits(deadline: .seconds(15), maxOutputBytes: 16 * 1024)
    /// The rejection reason when the router has neither `etherwake` nor `wol`.
    public static let wakeToolMissing = "No Wake-on-LAN tool on the router"

    public init(runner: any SSHCommandRunning, gate: MutationGate, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.runner = runner
        self.gate = gate
        self.clock = clock
    }

    public var mechanism: ClientActionMechanism { .ssh }

    public func ping(_ address: IPv4Literal) async throws -> Result<PingResult, RefreshFailureCategory> {
        let result: ProcessResult
        do {
            result = try await runner.run(.pingClient(address), limits: Self.limits)
        } catch {
            try Self.rethrowIfCancelled(error)
            return .failure(Self.category(for: error))
        }
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        guard let parsed = PingOutputParser.parse(output) else { return .failure(.malformedResponse) }
        return .success(parsed)
    }

    public func wake(_ mac: MACAddress) async -> MutationReport<WakeResult> {
        let startedAt = clock()
        let token: MutationGateToken
        do { token = try await gate.acquire() } catch {
            return report(.rejected(.preconditionFailed("Cancelled before dispatch")), dispatched: false, startedAt: startedAt, failure: nil)
        }
        defer { Task { await gate.release(token) } }
        if Task.isCancelled {
            return report(.rejected(.preconditionFailed("Cancelled before dispatch")), dispatched: false, startedAt: startedAt, failure: nil)
        }
        // No before-state exists: the router keeps nothing for a wake packet.
        let result: ProcessResult
        do {
            result = try await runner.run(.wakeClient(mac), limits: Self.limits)
        } catch ProcessRunnerError.launchFailed {
            // `ssh` itself did not start, so nothing reached the router.
            return report(.rejected(.preconditionFailed("SSH did not start")), dispatched: false, startedAt: startedAt, failure: .network)
        } catch let failure as SSHFailure where failure.beforeCommand {
            // Refused before the remote command ran: no packet was sent.
            return report(.rejected(.preconditionFailed(failure.message)), dispatched: false, startedAt: startedAt, failure: failure.category)
        } catch {
            return report(.unknownAfterDispatch, dispatched: true, startedAt: startedAt, failure: Self.category(for: error))
        }
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        if output.contains(SSHCommand.wakeToolMissingMarker) {
            return report(.rejected(.preconditionFailed(Self.wakeToolMissing)), dispatched: true, startedAt: startedAt, failure: nil)
        }
        let lowered = output.lowercased()
        let failed = ["not found", "error", "invalid", "usage"].contains { lowered.contains($0) }
        guard result.exitStatus == 0, !failed else {
            return report(.unknownAfterDispatch, dispatched: true, startedAt: startedAt, failure: .unavailable)
        }
        return report(.verifiedSuccess(.sent), dispatched: true, startedAt: startedAt, failure: nil)
    }

    private func report(_ outcome: MutationOutcome<WakeResult>, dispatched: Bool, startedAt: Date, failure: RefreshFailureCategory?) -> MutationReport<WakeResult> {
        MutationReport(outcome: outcome, dispatched: dispatched, startedAt: startedAt, finishedAt: clock(), failure: failure)
    }

    private static func rethrowIfCancelled(_ error: any Error) throws {
        if error is CancellationError || (error as? ProcessRunnerError) == .cancelled || Task.isCancelled { throw CancellationError() }
    }

    private static func category(for error: any Error) -> RefreshFailureCategory {
        if let failure = error as? SSHFailure { return failure.category }
        switch error as? ProcessRunnerError {
        case .timedOut?: return .timeout
        case .outputLimitExceeded?: return .malformedResponse
        case .launchFailed?, .cancelled?, nil: return .network
        }
    }
}

/// The live answer until SSH is set up for the profile: the buttons show,
/// and pressing one explains that SSH is needed. Nothing is sent.
public struct SSHRequiredClientActions: ClientActionsService {
    public init() {}
    public var mechanism: ClientActionMechanism { .sshRequired }

    public func ping(_ address: IPv4Literal) async throws -> Result<PingResult, RefreshFailureCategory> {
        .failure(.unavailable)
    }

    public func wake(_ mac: MACAddress) async -> MutationReport<WakeResult> {
        let now = Date()
        return MutationReport(outcome: .rejected(.capabilityUnavailable), dispatched: false, startedAt: now, finishedAt: now, failure: nil)
    }
}

extension SSHFailure {
    /// True when the failure happened before the remote command could run:
    /// no connection, no trust, or no login.
    var beforeCommand: Bool {
        switch self {
        case .authenticationFailed, .connectionFailed, .networkFailed, .configurationFailed, .hostKeyNotTrusted, .hostKeyChanged: true
        case .timedOut, .commandFailed, .other: false
        }
    }
}

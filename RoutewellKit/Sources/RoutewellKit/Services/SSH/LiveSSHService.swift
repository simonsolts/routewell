import Foundation

/// The live `SSHService`: fixed `SSHCommand`s through one router's
/// `SSHCommandRunning`, which runs one operation at a time. The Ethernet
/// interface set comes from the router's own enumeration and is read again
/// when an interface goes away.
public actor LiveSSHService: SSHService {
    private let runner: any SSHCommandRunning
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone
    private var interfaces: [NetworkInterfaceName]?

    /// RouterPilot's 20 s per-command timeout; 256 KiB covers 250 log lines.
    public static let limits = ProcessLimits(deadline: .seconds(20), maxOutputBytes: 256 * 1024)

    public init(runner: any SSHCommandRunning, clock: @Sendable @escaping () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.runner = runner
        self.clock = clock
        self.timeZone = timeZone
    }

    public func check() async throws -> SSHProbeResult {
        let now = clock()
        switch try await read(.systemBoard) {
        case .success(let output):
            guard let board = SystemBoardParser.parse(output.stdout) else {
                // The command ran but the reply was not the expected JSON.
                return SSHProbeResult(capability: Capability(observedAt: now), failure: .other("malformed board"))
            }
            return SSHProbeResult(capability: Capability(.supported, evidence: .successfulResponse, observedAt: now), board: board)
        case .failure(let failure):
            return SSHProbeResult(capability: Self.capability(for: failure, at: now), failure: failure)
        }
    }

    /// Timeouts and an unreachable network are not evidence either way.
    static func capability(for failure: SSHFailure, at date: Date) -> Capability {
        switch failure {
        case .timedOut, .networkFailed, .other: Capability(observedAt: date)
        case .authenticationFailed, .connectionFailed, .configurationFailed, .hostKeyNotTrusted, .hostKeyChanged, .commandFailed:
            Capability(.unsupported, evidence: .sshProbeFailed(String(describing: failure)), observedAt: date)
        }
    }

    public func ports() async throws -> AreaRefreshResult<RouterPortsStatus> {
        let attemptedAt = clock()
        let names: [NetworkInterfaceName]
        if let interfaces {
            names = interfaces
        } else {
            switch try await read(.networkInterfaces) {
            case .failure(let failure): return .failure(failure.category, attemptedAt: attemptedAt)
            case .success(let output):
                names = InterfaceParser.parseEnumeration(output.stdout).filter(\.isEthernetPort).map(\.name).sorted()
                interfaces = names
            }
        }
        guard !names.isEmpty else {
            interfaces = nil
            return .success(RouterPortsStatus(), observedAt: attemptedAt, source: .routerSSH)
        }
        switch try await read(.interfaceTelemetry(names)) {
        case .failure(let failure):
            return .failure(failure.category, attemptedAt: attemptedAt)
        case .success(let output):
            let parsed = InterfaceParser.parseTelemetry(output.stdout, names: names)
            if !parsed.missing.isEmpty { interfaces = nil }
            return .success(parsed.status, observedAt: attemptedAt, source: .routerSSH)
        }
    }

    public func storage() async throws -> AreaRefreshResult<StorageStatus> {
        let attemptedAt = clock()
        var status = StorageStatus()
        var failures: [SSHFailure] = []

        switch try await read(.rootFilesystem) {
        case .success(let output): status.root = DiskFreeParser.parseRoot(output.stdout).map(Observed.value) ?? .unknown
        case .failure(let failure): failures.append(failure)
        }
        let diskFree = try await read(.diskUsage)
        let mounts = try await read(.mountTable)
        switch (diskFree, mounts) {
        case (.success(let disk), .success(let table)):
            status.external = .value(MountTableParser.externalVolumes(diskFree: disk.stdout, mounts: table.stdout))
        case (.failure(let failure), _), (_, .failure(let failure)):
            failures.append(failure)
        }
        switch try await read(.sambaShares) {
        case .success(let output): status.samba = .value(SambaSharesParser.parse(output.stdout))
        case .failure(let failure): failures.append(failure)
        }

        if case .unknown = status.root, case .unknown = status.external, case .unknown = status.samba, let failure = failures.first {
            return .failure(failure.category, attemptedAt: attemptedAt)
        }
        return .success(status, observedAt: attemptedAt, source: .routerSSH)
    }

    public func logTail() async throws -> AreaRefreshResult<RouterLogTail> {
        let attemptedAt = clock()
        switch try await read(.logTail) {
        case .success(let output): return .success(LogReadParser.parse(output.stdout, timeZone: timeZone), observedAt: attemptedAt, source: .routerSSH)
        case .failure(let failure): return .failure(failure.category, attemptedAt: attemptedAt)
        }
    }

    public func adGuardProcess() async throws -> Observed<Int> {
        switch try await read(.adGuardProcess, allowedExitStatuses: [0, 1]) {
        case .success(let output): ProcessIDParser.adGuardProcessID(output.stdout, stderr: output.stderr, exitStatus: output.exitStatus)
        case .failure: .unknown
        }
    }

    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let exitStatus: Int32
    }

    /// Runs one command. Cancellation propagates; every other failure is a
    /// typed result. A remote exit status outside `allowedExitStatuses` fails.
    private func read(_ command: SSHCommand, allowedExitStatuses: Set<Int32> = [0]) async throws -> Result<Output, SSHFailure> {
        do {
            let result = try await runner.run(command, limits: Self.limits)
            guard allowedExitStatuses.contains(result.exitStatus) else { return .failure(.commandFailed(exitStatus: result.exitStatus)) }
            return .success(Output(stdout: String(decoding: result.stdout, as: UTF8.self),
                                   stderr: String(decoding: result.stderr, as: UTF8.self), exitStatus: result.exitStatus))
        } catch let failure as SSHFailure {
            if Task.isCancelled { throw CancellationError() }
            return .failure(failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch ProcessRunnerError.cancelled {
            throw CancellationError()
        } catch ProcessRunnerError.timedOut {
            return .failure(.timedOut)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return .failure(.other(error is ProcessRunnerError ? "process" : "unknown"))
        }
    }
}

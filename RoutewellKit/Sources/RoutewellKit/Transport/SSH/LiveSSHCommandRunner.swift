import Darwin
import Foundation

/// Everything one router's SSH runner needs: a validated target and a
/// key-only identity. There is no password anywhere in this type.
public struct SSHConnection: Sendable, Equatable {
    public let target: SSHTarget
    public let identity: SSHIdentity
    /// Required with `.agent`, from `SSHAgentLocator`.
    public let agentSocket: URL?

    public init(target: SSHTarget, identity: SSHIdentity, agentSocket: URL? = nil) {
        self.target = target
        self.identity = identity
        self.agentSocket = agentSocket
    }
}

/// Finds a usable SSH agent: `SSH_AUTH_SOCK` must name an existing socket.
public enum SSHAgentLocator {
    public static func socket(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment["SSH_AUTH_SOCK"], path.hasPrefix("/") else { return nil }
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// The live `SSHCommandRunning`: `/usr/bin/ssh` through `ProcessRunning`,
/// with the Routewell-owned `known_hosts`, strict host key checking, and a
/// key file or agent. One operation runs at a time per router; the next one
/// waits its turn. Nothing runs until a host key is trusted, and a changed
/// host key fails the operation (`ssh` itself refuses it).
public actor LiveSSHCommandRunner: SSHCommandRunning {
    private let connection: SSHConnection
    private let hostKeys: SSHHostKeyStore
    private let processes: any ProcessRunning
    /// One SSH operation in flight per router.
    private let queue = MutationGate()

    public init(connection: SSHConnection, hostKeys: SSHHostKeyStore, processes: any ProcessRunning = ProcessRunner()) {
        self.connection = connection
        self.hostKeys = hostKeys
        self.processes = processes
    }

    /// Throws `SSHFailure`, `ProcessRunnerError.launchFailed` (nothing was
    /// sent), `ProcessRunnerError.outputLimitExceeded`, or `CancellationError`.
    public func run(_ command: SSHCommand, limits: ProcessLimits) async throws -> ProcessResult {
        guard !command.takesInput else { throw SSHFailure.configurationFailed }
        return try await queued(command, input: nil, limits: limits)
    }

    public func run(_ command: SSHCommand, input: Data, limits: ProcessLimits) async throws -> ProcessResult {
        guard command.takesInput else { throw SSHFailure.configurationFailed }
        return try await queued(command, input: input, limits: limits)
    }

    private func queued(_ command: SSHCommand, input: Data?, limits: ProcessLimits) async throws -> ProcessResult {
        let token = try await queue.acquire()
        do {
            let result = try await perform(command, input: input, limits: limits)
            await queue.release(token)
            return result
        } catch {
            await queue.release(token)
            throw error
        }
    }

    private func perform(_ command: SSHCommand, input: Data?, limits: ProcessLimits) async throws -> ProcessResult {
        let target = connection.target
        let stored = try? await hostKeys.storedKeyLine(host: target.host, port: target.port)
        guard stored != nil else { throw SSHFailure.hostKeyNotTrusted }
        let plan: SSHLaunchPlan
        do {
            plan = try SSHLauncher.plan(target: target, identity: connection.identity, knownHostsFile: hostKeys.knownHostsFile,
                                        command: command, agentSocket: connection.agentSocket)
        } catch {
            throw SSHFailure.configurationFailed
        }
        try Task.checkCancellation()
        let result: ProcessResult
        do {
            if let input {
                result = try await processes.run(executable: plan.executable, arguments: plan.arguments, environment: [:], input: input, limits: limits)
            } else {
                result = try await processes.run(executable: plan.executable, arguments: plan.arguments, environment: [:], limits: limits)
            }
        } catch ProcessRunnerError.timedOut {
            throw SSHFailure.timedOut
        } catch ProcessRunnerError.cancelled {
            throw CancellationError()
        }
        return try SSHResultClassifier.check(result)
    }
}

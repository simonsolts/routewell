import Darwin
import Foundation
import os

public struct ProcessLimits: Sendable, Equatable {
    public var deadline: Duration
    public var maxOutputBytes: Int
    public var terminationGrace: Duration

    public init(deadline: Duration = .seconds(20), maxOutputBytes: Int = 1 << 20, terminationGrace: Duration = .seconds(2)) {
        self.deadline = deadline
        self.maxOutputBytes = maxOutputBytes
        self.terminationGrace = terminationGrace
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let exitStatus: Int32
    public let stdout: Data
    public let stderr: Data
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case cancelled
    case outputLimitExceeded
}

/// A single-resolution box: the first `resolve` wins, later ones are ignored, and
/// `wait` returns that value to every caller (immediately if already resolved).
/// The lock guards state that is written from arbitrary dispatch queues
/// (readability handlers, the termination handler) and read from async code.
private final class OneShotSignal<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuations: [CheckedContinuation<Value, Never>] = []
        var value: Value?
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.withLock { state in
                if let value = state.value {
                    continuation.resume(returning: value)
                } else {
                    state.continuations.append(continuation)
                }
            }
        }
    }

    func resolve(_ value: Value) {
        let continuations: [CheckedContinuation<Value, Never>] = lock.withLock { state in
            guard state.value == nil else { return [] }
            state.value = value
            let waiting = state.continuations
            state.continuations = []
            return waiting
        }
        for continuation in continuations { continuation.resume(returning: value) }
    }
}

/// Accumulates bytes from one pipe up to a byte limit. Appends beyond the limit are
/// dropped and the stream is marked truncated; the caller is told to stop reading and
/// terminate the process.
private final class StreamCollector: Sendable {
    private struct State: Sendable {
        var data = Data()
        var truncated = false
    }
    private let limit: Int
    private let lock: OSAllocatedUnfairLock<State>

    init(limit: Int) {
        self.limit = limit
        self.lock = OSAllocatedUnfairLock(initialState: State())
    }

    /// Returns false once the limit has been exceeded.
    func append(_ chunk: Data) -> Bool {
        lock.withLock { state in
            if state.truncated { return false }
            let remaining = limit - state.data.count
            if chunk.count > remaining {
                if remaining > 0 { state.data.append(chunk.prefix(remaining)) }
                state.truncated = true
                return false
            }
            state.data.append(chunk)
            return true
        }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.withLock { ($0.data, $0.truncated) }
    }
}

private enum RaceWinner: Sendable, Equatable {
    case exitedNormally
    case limitExceeded
    case timedOut
    case cancelled
}

/// Runs one child process with a byte-limited, deadline-bound lifetime.
///
/// The actor holds no mutable state of its own: each `run` call creates its own
/// process, pipes, and signal boxes, so nothing needs to survive across the
/// `await` points inside a single call. Cross-thread communication (readability
/// handlers and the termination handler run on GCD queues, not on this actor)
/// goes through `OneShotSignal`/`StreamCollector`, which are lock-protected and
/// `Sendable` without `@unchecked`.
public actor ProcessRunner {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        limits: ProcessLimits = .init()
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var childEnvironment = environment
        if childEnvironment["PATH"] == nil { childEnvironment["PATH"] = "/usr/bin:/bin" }
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = StreamCollector(limit: limits.maxOutputBytes)
        let stderrCollector = StreamCollector(limit: limits.maxOutputBytes)
        let stdoutEOF = OneShotSignal<Void>()
        let stderrEOF = OneShotSignal<Void>()
        let exitStatus = OneShotSignal<Int32>()
        let first = OneShotSignal<RaceWinner>()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stdoutEOF.resolve(())
                return
            }
            if !stdoutCollector.append(chunk) { first.resolve(.limitExceeded) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stderrEOF.resolve(())
                return
            }
            if !stderrCollector.append(chunk) { first.resolve(.limitExceeded) }
        }
        process.terminationHandler = { proc in
            exitStatus.resolve(proc.terminationStatus)
            first.resolve(.exitedNormally)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: limits.deadline)
            first.resolve(.timedOut)
        }

        let winner = await withTaskCancellationHandler {
            await first.wait()
        } onCancel: {
            first.resolve(.cancelled)
        }
        timeoutTask.cancel()

        if winner != .exitedNormally {
            Self.terminateForcefully(process, grace: limits.terminationGrace)
        }
        let status = await exitStatus.wait()
        await stdoutEOF.wait()
        await stderrEOF.wait()

        switch winner {
        case .exitedNormally:
            let (out, outTruncated) = stdoutCollector.snapshot()
            let (err, errTruncated) = stderrCollector.snapshot()
            return ProcessResult(exitStatus: status, stdout: out, stderr: err, stdoutTruncated: outTruncated, stderrTruncated: errTruncated)
        case .limitExceeded:
            throw ProcessRunnerError.outputLimitExceeded
        case .timedOut:
            throw ProcessRunnerError.timedOut
        case .cancelled:
            throw ProcessRunnerError.cancelled
        }
    }

    /// SIGTERM, then SIGKILL after `grace` if the process is still alive. Runs on its
    /// own unstructured task so `run` can keep waiting on `exitStatus` while this
    /// escalates; it touches only `process`, which is safe to signal from any thread.
    private static func terminateForcefully(_ process: Process, grace: Duration) {
        guard process.isRunning else { return }
        process.terminate()
        Task {
            try? await Task.sleep(for: grace)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

import Darwin
import Foundation
import Testing
@testable import RoutewellKit

private func scratchPIDFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("routewell-processrunner-\(UUID()).pid")
}

private func isRunning(pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

private enum PIDFileError: Error { case neverAppeared }

/// Polls for the PID a helper script writes to `file` before doing its real work, so
/// tests can confirm the process is gone after `ProcessRunner` kills it.
private func readPID(from file: URL) async throws -> pid_t {
    for _ in 0..<200 {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PIDFileError.neverAppeared
}

private let shell = URL(fileURLWithPath: "/bin/sh")

@Test func successCapturesExitStatusAndStdout() async throws {
    let runner = ProcessRunner()
    let result = try await runner.run(executable: shell, arguments: ["-c", "echo hello"])
    #expect(result.exitStatus == 0)
    #expect(result.stdout == Data("hello\n".utf8))
    #expect(result.stdoutTruncated == false)
    #expect(result.stderr.isEmpty)
}

@Test func nonzeroExitPropagatesStatusAndCapturesStderr() async throws {
    let runner = ProcessRunner()
    let result = try await runner.run(executable: shell, arguments: ["-c", "echo oops 1>&2; exit 7"])
    #expect(result.exitStatus == 7)
    #expect(result.stderr == Data("oops\n".utf8))
}

@Test func largeOutputWithinLimitIsFullyReadOnBothStreams() async throws {
    let runner = ProcessRunner()
    let script = "head -c 2097152 /dev/zero; exec head -c 2097152 /dev/zero 1>&2"
    let result = try await runner.run(
        executable: shell,
        arguments: ["-c", script],
        limits: ProcessLimits(maxOutputBytes: 4 * 1024 * 1024)
    )
    #expect(result.exitStatus == 0)
    #expect(result.stdout.count == 2 * 1024 * 1024)
    #expect(result.stderr.count == 2 * 1024 * 1024)
    #expect(result.stdoutTruncated == false)
    #expect(result.stderrTruncated == false)
}

@Test func outputBeyondLimitThrowsAndKillsProcess() async throws {
    let runner = ProcessRunner()
    let pidFile = scratchPIDFile()
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let script = "echo $$ > \(pidFile.path); head -c 2097152 /dev/zero; exec head -c 2097152 /dev/zero 1>&2"
    await #expect(throws: ProcessRunnerError.outputLimitExceeded) {
        _ = try await runner.run(
            executable: shell,
            arguments: ["-c", script],
            limits: ProcessLimits(maxOutputBytes: 64 * 1024)
        )
    }
    let pid = try await readPID(from: pidFile)
    #expect(isRunning(pid: pid) == false)
}

@Test func delayedExitTimesOutWithinOneSecondAndKillsProcess() async throws {
    let runner = ProcessRunner()
    let pidFile = scratchPIDFile()
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let script = "echo $$ > \(pidFile.path); exec sleep 5"
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: ProcessRunnerError.timedOut) {
        _ = try await runner.run(
            executable: shell,
            arguments: ["-c", script],
            limits: ProcessLimits(deadline: .milliseconds(300), terminationGrace: .milliseconds(200))
        )
    }
    #expect(clock.now - start < .seconds(1))
    let pid = try await readPID(from: pidFile)
    #expect(isRunning(pid: pid) == false)
}

@Test func cancellingTheCallerThrowsCancelledAndKillsProcess() async throws {
    let runner = ProcessRunner()
    let pidFile = scratchPIDFile()
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let script = "echo $$ > \(pidFile.path); exec sleep 5"
    let task = Task {
        try await runner.run(executable: shell, arguments: ["-c", script], limits: ProcessLimits(terminationGrace: .milliseconds(200)))
    }
    let pid = try await readPID(from: pidFile)
    task.cancel()
    await #expect(throws: ProcessRunnerError.cancelled) { try await task.value }
    #expect(isRunning(pid: pid) == false)
}

@Test func environmentIsNotInheritedFromParent() async throws {
    let runner = ProcessRunner()
    let result = try await runner.run(executable: shell, arguments: ["-c", "echo HOME=$HOME"])
    #expect(result.stdout == Data("HOME=\n".utf8))
}

@Test func explicitEnvironmentIsPassedThrough() async throws {
    let runner = ProcessRunner()
    let result = try await runner.run(
        executable: shell,
        arguments: ["-c", "echo HOME=$HOME"],
        environment: ["HOME": "/tmp/explicit"]
    )
    #expect(result.stdout == Data("HOME=/tmp/explicit\n".utf8))
}

@Test func launchFailureIsReported() async throws {
    let runner = ProcessRunner()
    await #expect(throws: ProcessRunnerError.self) {
        _ = try await runner.run(executable: URL(fileURLWithPath: "/nonexistent/binary"), arguments: [])
    }
}

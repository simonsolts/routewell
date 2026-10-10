import Foundation

/// Records allow-listed live reads for fixtures. Calls that are not
/// read-only are refused before anything is sent.
struct LiveFixtureRecorder: FixtureRecordableBackend {
    let rpc: GLiNetRPCClient
    let adGuard: AdGuardClient?
    let sshRunner: (any SSHCommandRunning)?

    func recordFixture(_ call: FixtureCall) async -> JSONValue {
        guard FixtureRecordingPlan.isReadOnly(call) else {
            return .object(["error": .object(["category": .string("unsafe call")])])
        }
        switch call.transport {
        case .rpc:
            guard let object = call.object else { return .object(["error": .string("invalid call")]) }
            return await rpc.recordRead(.init(object: object, method: call.method, params: .object([:])))
        case .adGuard:
            guard let adGuard else { return .object(["error": .object(["category": .string("not configured")])]) }
            return await adGuard.recordRead(path: call.method)
        case .ssh:
            // SSH output is text; `recordSSHFixture` records it.
            return .object(["error": .string("invalid call")])
        }
    }

    /// One allow-listed SSH read as text: a `# exit status` header, stdout,
    /// and stderr as `#` lines. The telemetry read first enumerates the
    /// interfaces and reads every valid name, so the review can check the
    /// Ethernet filter. The AdGuard command line is cut after the program path.
    func recordSSHFixture(_ call: FixtureCall) async -> String? {
        guard call.transport == .ssh, FixtureRecordingPlan.isReadOnly(call), let sshRunner else { return nil }
        do {
            let command: SSHCommand
            if call.method == FixtureRecordingPlan.interfaceTelemetryKey {
                let listing = try await sshRunner.run(.networkInterfaces, limits: LiveSSHService.limits)
                let names = InterfaceParser.parseEnumeration(String(decoding: listing.stdout, as: UTF8.self)).map(\.name)
                command = .interfaceTelemetry(names)
            } else if let fixed = FixtureRecordingPlan.sshReads[call.method] {
                command = fixed
            } else {
                return nil
            }
            let result = try await sshRunner.run(command, limits: LiveSSHService.limits)
            var stdout = String(decoding: result.stdout, as: UTF8.self)
            if command == .adGuardProcess {
                stdout = stdout.split(whereSeparator: \.isNewline)
                    .map { $0.split(separator: " ").prefix(2).joined(separator: " ") }.joined(separator: "\n")
            }
            let stderr = String(decoding: result.stderr, as: UTF8.self).split(whereSeparator: \.isNewline).map { "# stderr: \($0)" }
            return (["# exit status: \(result.exitStatus)", stdout] + stderr).joined(separator: "\n")
        } catch let failure as SSHFailure {
            return "# failure: \(failure)"
        } catch {
            return "# failure: \(type(of: error))"
        }
    }
}

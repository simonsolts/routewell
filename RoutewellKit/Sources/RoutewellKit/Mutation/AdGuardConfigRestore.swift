import Foundation

/// Reads and replaces AdGuard Home's `config.yaml`. Live: SSH.
public protocol AdGuardConfigFileTransport: Sendable {
    func readConfigFile() async throws -> Data
    func writeConfigFile(_ data: Data) async throws
}

/// What AdGuard Home did with a restored file.
public struct AdGuardRestoreState: Sendable, Equatable {
    /// The file reached the router.
    public var written: Bool
    /// `control/status` answered after the start.
    public var answering: Bool
    /// `dns_info` has the file's DNS values; `nil` when it was not read.
    public var dnsMatches: Bool?

    public init(written: Bool, answering: Bool, dnsMatches: Bool?) {
        self.written = written
        self.answering = answering
        self.dnsMatches = dnsMatches
    }

    public var isRestored: Bool { written && answering && dnsMatches == true }
}

public enum AdGuardBackupFailure: Error, Sendable, Equatable {
    case notRunning
    case unreadable(RefreshFailureCategory)
    /// The router sent something that is not an AdGuard Home config.
    case notConfigFile
}

/// Back Up Now and Restore…, behind `RouterBackend.adGuardBackups`. `nil`
/// without SSH or without an AdGuard Home connection.
public protocol AdGuardBackupControl: Sendable {
    /// Reads `config.yaml` under the router's gate. A read: nothing changes.
    func readConfig(availability: AdGuardAvailability) async -> Result<AdGuardConfigFile, AdGuardBackupFailure>
    /// `saveCurrent` keeps the file on the router before anything is sent;
    /// `false` stops the restore.
    func restore(_ file: AdGuardConfigFile, availability: AdGuardAvailability,
                 saveCurrent: @escaping @Sendable (AdGuardConfigFile) async -> Bool) async -> MutationReport<AdGuardRestoreState>
}

public struct AdGuardRestorePolicy: Sendable, Equatable {
    /// How long `get_config` may take to show AdGuard Home off.
    public var configDeadline: Duration = .seconds(15)
    /// How long AdGuard Home may take to answer after the start.
    public var answerDeadline: Duration = .seconds(30)
    /// How long `dns_info` may take to show the file's values.
    public var settingsDeadline: Duration = .seconds(10)
    public var pollInterval: Duration = .seconds(1)

    public init() {}
}

/// Restore is `snapshotRestore`: the file on the router is saved first;
/// AdGuard Home is stopped, the chosen file written, and AdGuard Home
/// started. When it does not answer with the file's DNS values, the saved
/// file goes back the same way.
public struct AdGuardBackupExecutor: AdGuardBackupControl {
    private let files: any AdGuardConfigFileTransport
    private let service: any AdGuardServiceTransport
    private let settings: any AdGuardSettingTransport
    private let gate: MutationGate
    private let policy: AdGuardRestorePolicy
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: SessionEventLog?

    public init(
        files: any AdGuardConfigFileTransport,
        service: any AdGuardServiceTransport,
        settings: any AdGuardSettingTransport,
        gate: MutationGate,
        policy: AdGuardRestorePolicy = .init(),
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: SessionEventLog? = nil
    ) {
        self.files = files
        self.service = service
        self.settings = settings
        self.gate = gate
        self.policy = policy
        self.clock = clock
        self.sleep = sleep
        self.log = log
    }

    private typealias Step = (outcome: MutationOutcome<AdGuardRestoreState>, dispatched: Bool, failure: RefreshFailureCategory?)

    public func readConfig(availability: AdGuardAvailability) async -> Result<AdGuardConfigFile, AdGuardBackupFailure> {
        guard availability == .running else { return .failure(.notRunning) }
        guard let token = try? await gate.acquire() else { return .failure(.unreadable(.unavailable)) }
        let result = await readCurrent()
        await gate.release(token)
        return result
    }

    private func readCurrent() async -> Result<AdGuardConfigFile, AdGuardBackupFailure> {
        do {
            guard let file = AdGuardConfigFile(try await files.readConfigFile()) else { return .failure(.notConfigFile) }
            return .success(file)
        } catch {
            return .failure(.unreadable(FailureMapping.category(for: error)))
        }
    }

    public func restore(_ file: AdGuardConfigFile, availability: AdGuardAvailability,
                        saveCurrent: @escaping @Sendable (AdGuardConfigFile) async -> Bool) async -> MutationReport<AdGuardRestoreState> {
        let startedAt = clock()
        guard availability == .running else {
            return report((.rejected(.preconditionFailed("AdGuard Home is not running.")), false, nil), startedAt: startedAt)
        }
        guard let token = try? await gate.acquire() else {
            return report((.rejected(.preconditionFailed("Cancelled before dispatch")), false, nil), startedAt: startedAt)
        }
        if Task.isCancelled {
            await gate.release(token)
            return report((.rejected(.preconditionFailed("Cancelled before dispatch")), false, nil), startedAt: startedAt)
        }
        let step = await perform(file, saveCurrent: saveCurrent)
        await gate.release(token)
        await log?.record(LogEvent(level: step.failure == nil ? .info : .warning, kind: .session,
                                   message: "adguard restore finished dispatched=\(step.dispatched)"))
        return report(step, startedAt: startedAt)
    }

    // MARK: Sequence (gate held)

    private func perform(_ file: AdGuardConfigFile, saveCurrent: @Sendable (AdGuardConfigFile) async -> Bool) async -> Step {
        let current: AdGuardConfigFile
        switch await readCurrent() {
        case .success(let value): current = value
        case .failure(.unreadable(let category)):
            return (.rejected(.preconditionFailed(Self.notBackedUp)), false, category)
        case .failure:
            return (.rejected(.preconditionFailed(Self.notBackedUp)), false, .malformedResponse)
        }
        guard await saveCurrent(current) else { return (.rejected(.preconditionFailed(Self.notSaved)), false, nil) }
        let before: AdGuardRouterConfig
        do {
            before = try await service.readConfig()
        } catch {
            return (.rejected(.preconditionFailed("The router did not say whether AdGuard Home is on.")), false, FailureMapping.category(for: error))
        }
        guard before.enabled == true else { return (.rejected(.preconditionFailed("AdGuard Home is off.")), false, nil) }
        let expected = AdGuardRestoreState(written: true, answering: true, dnsMatches: true)

        guard let applied = await apply(file, handlesDNS: before.handlesDNS) else {
            // Not stopped, so nothing was written. Make sure it runs.
            _ = try? await service.writeConfig(enabled: true, handlesDNS: before.handlesDNS)
            let answering = await waitForAnswer()
            return (.verifiedMismatch(expected: expected, actual: AdGuardRestoreState(written: false, answering: answering, dnsMatches: nil)),
                    true, nil)
        }
        if applied.isRestored { return (.verifiedSuccess(applied), true, nil) }

        await log?.record(LogEvent(level: .warning, kind: .session, message: "adguard restore did not verify; putting the saved file back"))
        guard let restored = await apply(current, handlesDNS: before.handlesDNS), restored.isRestored else {
            return (.recoveryFailed(expected: expected, actual: applied), true, nil)
        }
        return (.verifiedRecovery(restored: restored), true, nil)
    }

    /// Stop, write, start, verify. `nil` when AdGuard Home did not stop:
    /// nothing was written then.
    private func apply(_ file: AdGuardConfigFile, handlesDNS: Bool?) async -> AdGuardRestoreState? {
        do {
            _ = try await service.writeConfig(enabled: false, handlesDNS: handlesDNS)
        } catch GLiNetRPCError.credentialUnavailable, GLiNetRPCError.accessDenied, GLiNetRPCError.loginPaused,
                GLiNetRPCError.methodNotFound, GLiNetRPCError.invalidParameters {
            return nil
        } catch {
            // The answer was lost: the read decides.
        }
        guard await poll({ try await service.readConfig() }, deadline: policy.configDeadline, matches: { $0.enabled == false }).matched != nil else {
            return nil
        }
        var written = true
        do {
            try await files.writeConfigFile(file.data)
        } catch {
            written = false
        }
        _ = try? await service.writeConfig(enabled: true, handlesDNS: handlesDNS)
        guard await waitForAnswer() else { return AdGuardRestoreState(written: written, answering: false, dnsMatches: nil) }
        let dns = await poll({ try await settings.readDNS() }, deadline: policy.settingsDeadline, matches: file.dns.matches)
        return AdGuardRestoreState(written: written, answering: true, dnsMatches: dns.matched != nil ? true : dns.last.map { _ in false })
    }

    private func waitForAnswer() async -> Bool {
        await poll({ try await settings.readStatus() }, deadline: policy.answerDeadline, matches: { _ in true }).matched != nil
    }

    private func poll<Value: Sendable>(_ read: () async throws -> Value, deadline: Duration,
                                       matches: (Value) -> Bool) async -> (matched: Value?, last: Value?) {
        let end = clock().addingTimeInterval(Self.seconds(deadline))
        var last: Value?
        while true {
            if let value = try? await read() {
                last = value
                if matches(value) { return (value, value) }
            }
            guard clock() < end else { return (nil, last) }
            // `try?`: a cancelled sleep must not stop verifying a sent write.
            try? await sleep(policy.pollInterval)
        }
    }

    // MARK: Mapping

    static let notBackedUp = "Routewell could not read the current settings, so nothing was restored."
    static let notSaved = "Routewell could not save a backup of the current settings, so nothing was restored."

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func report(_ step: Step, startedAt: Date) -> MutationReport<AdGuardRestoreState> {
        MutationReport(outcome: step.outcome, dispatched: step.dispatched, startedAt: startedAt, finishedAt: clock(), failure: step.failure)
    }
}

/// `config.yaml` over SSH. The bytes never reach a log.
public struct SSHAdGuardConfigFileTransport: AdGuardConfigFileTransport {
    let runner: any SSHCommandRunning
    static let limits = ProcessLimits(deadline: .seconds(20), maxOutputBytes: AdGuardConfigFile.maximumBytes)

    public init(runner: any SSHCommandRunning) { self.runner = runner }

    public func readConfigFile() async throws -> Data {
        let result = try await runner.run(.readAdGuardConfig, limits: Self.limits)
        guard result.exitStatus == 0 else { throw SSHFailure.commandFailed(exitStatus: result.exitStatus) }
        return result.stdout
    }

    public func writeConfigFile(_ data: Data) async throws {
        let result = try await runner.run(.writeAdGuardConfig, input: data, limits: Self.limits)
        guard result.exitStatus == 0 else { throw SSHFailure.commandFailed(exitStatus: result.exitStatus) }
    }
}

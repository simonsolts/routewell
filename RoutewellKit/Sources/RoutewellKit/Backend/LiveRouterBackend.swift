import Foundation

/// What a live profile needs to reach the router and, optionally, an AdGuard
/// Home instance behind it. `adGuardBaseURL` is derived by the caller (same
/// host as the router, `adGuard.port`, and whatever scheme the person chose)
/// rather than assembled here, since the scheme/username fields it depends on
/// live on `AdGuardSettings` only from chunk 08 onward.
public struct LiveBackendConfiguration: Sendable {
    public var routerEndpoint: RouterEndpoint
    /// `nil` means no AdGuard Home instance is configured for this profile;
    /// the AdGuard area then always reports `.unavailable`.
    public var adGuard: AdGuardSettings?
    public var adGuardBaseURL: URL?

    public init(routerEndpoint: RouterEndpoint, adGuard: AdGuardSettings? = nil, adGuardBaseURL: URL? = nil) {
        self.routerEndpoint = routerEndpoint
        self.adGuard = adGuard
        self.adGuardBaseURL = adGuardBaseURL
    }
}

/// The result of "Test connection": enough to show "Connected: <model>,
/// firmware <version>" without waiting on a full overview refresh.
public struct RouterProbe: Sendable, Equatable {
    public var model: String?
    public var firmware: String?
    public var hostname: String?

    public init(model: String? = nil, firmware: String? = nil, hostname: String? = nil) {
        self.model = model
        self.firmware = firmware
        self.hostname = hostname
    }
}

/// A certificate seen while running one `overview()` attempt, along with
/// where it was seen. Only the first one encountered is ever surfaced to a
/// person: `overview()` shows at most one trust prompt per call.
private struct UntrustedSignal: Sendable {
    let host: String
    let port: Int
    let decision: TrustDecision
}

/// A `RouterBackend` backed by the real GL.iNet router and (optionally) a
/// real AdGuard Home instance. `overview()` fetches `system.get_status`
/// exactly once and shares it across the router, internet, and clients
/// areas; each area otherwise catches its own errors so one area's failure
/// never discards another's data.
public actor LiveRouterBackend: RouterBackend, FixtureRecordableBackend, AdGuardHomeStateReading {
    private let configuration: LiveBackendConfiguration
    private let rpc: GLiNetRPCClient
    private let adGuardClient: AdGuardClient?
    private let trustStore: any EndpointTrustStore
    private let trustPrompt: any TrustPromptHandler
    private let clock: @Sendable () -> Date
    private let log: SessionEventLog?
    private let sshRunner: (any SSHCommandRunning)?

    /// One `AdGuardSettingExecutor`, backed by the router's one
    /// `MutationGate`, shared across every call for the lifetime of this
    /// backend instance — never rebuilt per call, so "one mutation in
    /// flight per router" actually holds. `nil` when no AdGuard Home
    /// instance is configured.
    public nonisolated let adGuardSettings: (any AdGuardSettingControl)?
    /// AdGuard Home › Overview's reads. `nil` without AdGuard Home.
    public nonisolated let adGuardOverview: (any AdGuardOverviewService)?
    /// Reads the client inventory only when the Clients screen asks for it;
    /// `overview()` keeps its own client count.
    public nonisolated let clients: (any ClientsService)?
    /// Read on demand by the Clients details pane. `nil` without AdGuard Home.
    public nonisolated let queryLog: (any QueryLogService)?
    /// Ping and Wake run over SSH; there is no client-scoped RPC. Without an
    /// SSH runner (SSH is not set up) the buttons explain that.
    public nonisolated let clientActions: (any ClientActionsService)?
    /// Ports, Storage, Logs, and the AdGuard process ID. `nil` without an
    /// SSH runner, so nothing attempts SSH.
    public nonisolated let ssh: (any SSHService)?
    /// Wi-Fi, SQM, and the firmware check for the Router screen.
    public nonisolated let router: (any RouterService)?
    /// Turn On, Stop, Handle DNS, Restart (chunk 16), under the same gate as
    /// Protection and Wake. Without an AdGuard Home connection, writes are
    /// verified with the router's setting only.
    public nonisolated let adGuardService: (any AdGuardServiceControl)?
    /// The config file over SSH, the restart over RPC, the checks over
    /// AdGuard Home's API, under the same gate.
    public nonisolated let adGuardBackups: (any AdGuardBackupControl)?

    public init(
        configuration: LiveBackendConfiguration,
        rpc: GLiNetRPCClient,
        adGuard: AdGuardClient?,
        trustStore: any EndpointTrustStore,
        trustPrompt: any TrustPromptHandler,
        clock: @Sendable @escaping () -> Date = { Date() },
        log: SessionEventLog? = nil,
        sshRunner: (any SSHCommandRunning)? = nil
    ) {
        self.configuration = configuration
        self.rpc = rpc
        self.adGuardClient = adGuard
        self.trustStore = trustStore
        self.trustPrompt = trustPrompt
        self.clock = clock
        self.log = log
        self.clients = LiveClientsService(rpc: rpc, adGuard: adGuard, clock: clock)
        self.queryLog = adGuard.map { LiveQueryLogService(adGuard: $0, clock: clock) }
        self.router = LiveRouterService(rpc: rpc, clock: clock)
        // One gate per router, shared by every write this backend runs.
        let gate = MutationGate()
        self.clientActions = sshRunner.map { SSHClientActions(runner: $0, gate: gate, clock: clock) } ?? SSHRequiredClientActions()
        self.ssh = sshRunner.map { LiveSSHService(runner: $0, clock: clock) }
        self.sshRunner = sshRunner
        self.adGuardSettings = adGuard.map {
            AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: $0), gate: gate, clock: clock, log: log)
        }
        self.adGuardOverview = adGuard.map { LiveAdGuardOverviewService(adGuard: $0, clock: clock) }
        self.adGuardService = AdGuardServiceExecutor(
            transport: LiveAdGuardServiceTransport(rpc: rpc, adGuard: adGuard), gate: gate, clock: clock, log: log
        )
        if let sshRunner, let adGuard {
            self.adGuardBackups = AdGuardBackupExecutor(
                files: SSHAdGuardConfigFileTransport(runner: sshRunner),
                service: LiveAdGuardServiceTransport(rpc: rpc, adGuard: adGuard),
                settings: LiveAdGuardSettingTransport(adGuard: adGuard), gate: gate, clock: clock, log: log)
        } else {
            self.adGuardBackups = nil
        }
    }

    // MARK: RouterBackend

    public func recordFixture(_ call: FixtureCall) async -> JSONValue {
        guard FixtureRecordingPlan.isReadOnly(call) else {
            return .object(["error": .object(["category": .string("unsafe call")])])
        }
        switch call.transport {
        case .rpc:
            guard let object = call.object else { return .object(["error": .string("invalid call")]) }
            return await rpc.recordRead(.init(object: object, method: call.method, params: .object([:])))
        case .adGuard:
            guard let adGuardClient else { return .object(["error": .object(["category": .string("not configured")])]) }
            return await adGuardClient.recordRead(path: call.method)
        case .ssh:
            // SSH output is text; `recordSSHFixture` records it.
            return .object(["error": .string("invalid call")])
        }
    }

    /// One allow-listed SSH read as text: a `# exit status` header, stdout,
    /// and stderr as `#` lines. The telemetry read first enumerates the
    /// interfaces and reads every valid name, so the review can check the
    /// Ethernet filter. The AdGuard command line is cut after the program path.
    public func recordSSHFixture(_ call: FixtureCall) async -> String? {
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

    public func overview() async throws -> OverviewRefreshResult {
        let attempt1 = try await runAreas()
        guard let signal = attempt1.untrusted else {
            return attempt1.result
        }

        let approved = await trustPrompt.requestTrust(host: signal.host, port: signal.port, decision: signal.decision)
        guard approved else {
            await log?.record(LogEvent(level: .warning, kind: .transport, message: "trust refused \(signal.host)"))
            let now = clock()
            return OverviewRefreshResult(
                router: .failure(.network, attemptedAt: now),
                internet: .failure(.network, attemptedAt: now),
                adGuard: .failure(.network, attemptedAt: now),
                clients: .failure(.network, attemptedAt: now)
            )
        }

        do {
            try await trustStore.approve(
                TrustedEndpoint(host: signal.host, port: signal.port, fingerprint: signal.decision.leafFingerprint, approvedAt: clock())
            )
        } catch {
            await log?.record(LogEvent(level: .warning, kind: .transport, message: "trust approval not saved \(signal.host)"))
        }

        // At most one prompt per overview(): whatever the retry finds is final.
        let attempt2 = try await runAreas()
        return attempt2.result
    }

    /// For "Test connection": logs in and reads `system.get_info`.
    public func probe() async throws -> RouterProbe {
        do {
            return try await performProbe()
        } catch let error as GLiNetRPCError {
            guard case .transport(.untrustedServer(let decision)) = error else { throw error }
            let approved = await trustPrompt.requestTrust(host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port, decision: decision)
            guard approved else { throw error }
            try await trustStore.approve(
                TrustedEndpoint(host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port, fingerprint: decision.leafFingerprint, approvedAt: clock())
            )
            return try await performProbe()
        }
    }

    private func performProbe() async throws -> RouterProbe {
        let info = try await rpc.call(.init(object: "system", method: "get_info", params: .object([:])))
        let boardInfo = info["board_info"]
        return RouterProbe(
            model: boardInfo?["model"]?.string ?? info["model"]?.string,
            firmware: info["firmware_version"]?.string,
            hostname: boardInfo?["hostname"]?.string
        )
    }

    /// Onboarding's Finish row: one `adguardhome.get_config` read.
    public func adGuardHomeEnabled() async -> Observed<Bool> {
        do {
            let config = try await rpc.call(.init(object: "adguardhome", method: "get_config", params: .object([:])))
            return Self.adGuardHomeEnabled(config: config)
        } catch {
            return .unknown
        }
    }

    /// `enabled` from `adguardhome.get_config` `[verified live]`; Unknown when absent.
    public static func adGuardHomeEnabled(config: JSONValue) -> Observed<Bool> {
        config["enabled"]?.bool.map(Observed.value) ?? .unknown
    }

    // MARK: One overview attempt

    private func runAreas() async throws -> (result: OverviewRefreshResult, untrusted: UntrustedSignal?) {
        let attemptedAt = clock()

        async let statusOutcome = rpc.checkedCall(.init(object: "system", method: "get_status", params: .object([:])))
        async let infoOutcome = rpc.checkedCall(.init(object: "system", method: "get_info", params: .object([:])))
        async let cableOutcome = rpc.checkedCall(.init(object: "cable", method: "get_status", params: .object([:])))
        async let clientListOutcome = rpc.checkedCall(.clientList)
        async let adGuardOutcome = fetchAdGuardArea(attemptedAt: attemptedAt)

        let status = try await statusOutcome
        let info = try await infoOutcome
        let cable = try await cableOutcome
        let clientList = try await clientListOutcome
        let adGuard = try await adGuardOutcome

        let router = routerAreaResult(status: status, info: info, attemptedAt: attemptedAt)
        let internet = internetAreaResult(status: status, cable: cable, attemptedAt: attemptedAt)
        let clients = clientsAreaResult(status: status, clientList: clientList, attemptedAt: attemptedAt)

        let signal = router.untrusted ?? internet.untrusted ?? clients.untrusted ?? adGuard.untrusted

        let result = OverviewRefreshResult(
            router: router.result,
            internet: internet.result,
            adGuard: adGuard.result,
            clients: clients.result,
            adGuardService: adGuard.reading
        )
        return (result, signal)
    }

    /// The AdGuard area, and the service reading the AdGuard Home screen
    /// decides its state from. `get_config` is read even without an AdGuard
    /// Home connection, so the screen can say AdGuard Home is on.
    private func fetchAdGuardArea(attemptedAt: Date) async throws -> (result: AreaRefreshResult<AdGuardStatus>, untrusted: UntrustedSignal?, reading: AdGuardServiceReading) {
        let configResult: Result<JSONValue, GLiNetRPCError>
        do {
            configResult = .success(try await rpc.call(.init(object: "adguardhome", method: "get_config", params: .object([:]))))
        } catch let error as GLiNetRPCError {
            try Self.rethrowIfCancelled(error)
            configResult = .failure(error)
        }

        switch configResult {
        case .failure(let error):
            let reading = AdGuardServiceReading(config: .failure(Self.category(for: error)), observedAt: attemptedAt)
            return (.failure(Self.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: adGuardHostPort.host, port: adGuardHostPort.port), reading)
        case .success(let configJSON):
            let config = AdGuardRouterConfig.parse(configJSON)
            var reading = AdGuardServiceReading(config: .success(config), observedAt: attemptedAt)
            // "enabled" false (or missing/unreadable) means AdGuard Home is not
            // running on the router right now, not that Routewell failed to
            // reach it: the area stays `.unavailable`, never a network failure.
            guard config.enabled == true else {
                return (.failure(.unavailable, attemptedAt: attemptedAt), nil, reading)
            }
            guard configuration.adGuard != nil, let adGuardClient else {
                reading.answer = .notConfigured
                return (.failure(.unavailable, attemptedAt: attemptedAt), nil, reading)
            }
            do {
                let status = try await adGuardClient.status()
                reading.answer = .answered(status)
                var stats: AdGuardStatsResponse?
                do {
                    stats = try await adGuardClient.stats()
                } catch let error as AdGuardClientError {
                    try Self.rethrowIfCancelled(error)
                    switch error {
                    case .unauthorized, .credentialUnavailable:
                        // Unlike a missing stats window, a stats auth failure means
                        // the whole AdGuard session is bad: fail the area instead of
                        // reporting a misleadingly successful, counter-less status.
                        reading.answer = .failed(Self.category(for: error))
                        return (.failure(Self.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: adGuardHostPort.host, port: adGuardHostPort.port), reading)
                    case .transport, .httpStatus, .malformedResponse:
                        stats = nil // best-effort: a missing stats window never fails the area
                    }
                }
                var mapped = AdGuardClient.adGuardStatus(status: status, stats: stats, now: clock())
                mapped.handlesClientRequests = config.handlesDNS.map(Observed.value) ?? .unknown
                return (.success(mapped, observedAt: attemptedAt, source: .adGuardAPI), nil, reading)
            } catch let error as AdGuardClientError {
                try Self.rethrowIfCancelled(error)
                reading.answer = .failed(Self.category(for: error))
                return (.failure(Self.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: adGuardHostPort.host, port: adGuardHostPort.port), reading)
            }
        }
    }

    // MARK: Combining the shared status with each area's own fetch

    private func routerAreaResult(
        status: Result<JSONValue, GLiNetRPCError>,
        info: Result<JSONValue, GLiNetRPCError>,
        attemptedAt: Date
    ) -> (result: AreaRefreshResult<RouterStatus>, untrusted: UntrustedSignal?) {
        switch status {
        case .failure(let error):
            return (.failure(Self.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port))
        case .success(let statusJSON):
            let infoJSON: JSONValue?
            var untrusted: UntrustedSignal?
            switch info {
            case .success(let json):
                infoJSON = json
            case .failure(let error):
                infoJSON = nil // best-effort: router.hostname/model/firmware simply stay nil
                untrusted = Self.untrustedSignal(for: error, host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port)
            }
            let parsed = GLiNetStatusParser.routerStatus(getStatus: statusJSON, getInfo: infoJSON)
            return (.success(parsed, observedAt: attemptedAt, source: .routerRPC), untrusted)
        }
    }

    private func internetAreaResult(
        status: Result<JSONValue, GLiNetRPCError>,
        cable: Result<JSONValue, GLiNetRPCError>,
        attemptedAt: Date
    ) -> (result: AreaRefreshResult<InternetStatus>, untrusted: UntrustedSignal?) {
        switch status {
        case .failure(let error):
            return (.failure(Self.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port))
        case .success(let statusJSON):
            let cableJSON: JSONValue?
            var untrusted: UntrustedSignal?
            switch cable {
            case .success(let json):
                cableJSON = json
            case .failure(let error):
                cableJSON = nil // best-effort: publicAddress/gateway/dns simply stay nil
                untrusted = Self.untrustedSignal(for: error, host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port)
            }
            let parsed = GLiNetStatusParser.internetStatus(getStatus: statusJSON, cableStatus: cableJSON)
            return (.success(parsed, observedAt: attemptedAt, source: .routerRPC), untrusted)
        }
    }

    private func clientsAreaResult(
        status: Result<JSONValue, GLiNetRPCError>,
        clientList: Result<JSONValue, GLiNetRPCError>,
        attemptedAt: Date
    ) -> (result: AreaRefreshResult<ClientStatus>, untrusted: UntrustedSignal?) {
        switch clientList {
        case .success(let clientListJSON):
            let parsed = GLiNetStatusParser.clientStatus(getStatus: nil, clientList: clientListJSON)
            return (.success(parsed, observedAt: attemptedAt, source: .routerRPC), nil)
        case .failure(let clientListError):
            switch status {
            case .success(let statusJSON):
                // clients.get_list failed on its own, but the shared get_status
                // succeeded: fall back to its totals rather than losing the area.
                let parsed = GLiNetStatusParser.clientStatus(getStatus: statusJSON, clientList: nil)
                return (.success(parsed, observedAt: attemptedAt, source: .routerRPC), nil)
            case .failure(let statusError):
                let untrusted = Self.untrustedSignal(for: clientListError, host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port)
                    ?? Self.untrustedSignal(for: statusError, host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port)
                return (.failure(Self.category(for: clientListError), attemptedAt: attemptedAt), untrusted)
            }
        }
    }

    // MARK: AdGuard host/port

    private var adGuardHostPort: (host: String, port: Int) {
        if let url = configuration.adGuardBaseURL, let host = url.host {
            return (host, url.port ?? (url.scheme == "https" ? 443 : 80))
        }
        return (configuration.routerEndpoint.host, configuration.adGuard?.port ?? 3000)
    }

    // MARK: Error → category mapping

    static func category(for error: GLiNetRPCError) -> RefreshFailureCategory {
        switch error {
        case .transport(let transportError):
            return category(for: transportError)
        case .httpStatus, .malformedResponse, .invalidParameters, .rpcError, .unsupportedAlgorithm, .unsupportedHashMethod:
            return .malformedResponse
        case .accessDenied, .loginPaused, .credentialUnavailable:
            return .authentication
        case .methodNotFound:
            return .unavailable
        }
    }

    static func category(for error: AdGuardClientError) -> RefreshFailureCategory {
        switch error {
        case .transport(let transportError):
            return category(for: transportError)
        case .unauthorized:
            return .authentication
        case .httpStatus, .malformedResponse:
            return .malformedResponse
        case .credentialUnavailable:
            return .authentication
        }
    }

    static func category(for error: TransportError) -> RefreshFailureCategory {
        switch error {
        case .timedOut:
            return .timeout
        case .unreachable, .redirectRefused, .tlsFailure, .localNetworkDenied:
            return .network
        case .cancelled:
            // Defensive only: every call site checks `rethrowIfCancelled` first
            // and throws `CancellationError` instead of reaching this mapping.
            return .network
        case .untrustedServer:
            // Only reached after a refused trust prompt; an approved one is
            // resolved by retrying the whole overview instead of mapping here.
            return .network
        case .responseTooLarge, .invalidResponse:
            return .malformedResponse
        }
    }

    /// Real task cancellation through `URLSessionTransport` surfaces as
    /// `TransportError.cancelled`, not Swift's `CancellationError` — without
    /// this, a cancelled refresh would be reported as a `.network` failure
    /// instead of the cancellation propagating out of `overview()`/`probe()`.
    /// `Task.isCancelled` is checked too, in case cancellation ever surfaces
    /// as some other error instead.
    static func rethrowIfCancelled(_ error: GLiNetRPCError) throws {
        if isCancelled(error) || Task.isCancelled { throw CancellationError() }
    }

    static func rethrowIfCancelled(_ error: AdGuardClientError) throws {
        if isCancelled(error) || Task.isCancelled { throw CancellationError() }
    }

    /// One AdGuard Home read as a result. Cancellation propagates.
    static func adGuardResult<Value: Sendable>(_ read: @Sendable () async throws -> Value) async throws -> Result<Value, RefreshFailureCategory> {
        do {
            return .success(try await read())
        } catch let error as AdGuardClientError {
            try rethrowIfCancelled(error)
            return .failure(category(for: error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.unavailable)
        }
    }

    private static func isCancelled(_ error: GLiNetRPCError) -> Bool {
        if case .transport(.cancelled) = error { return true }
        return false
    }

    private static func isCancelled(_ error: AdGuardClientError) -> Bool {
        if case .transport(.cancelled) = error { return true }
        return false
    }

    private static func untrustedSignal(for error: GLiNetRPCError, host: String, port: Int) -> UntrustedSignal? {
        guard case .transport(.untrustedServer(let decision)) = error else { return nil }
        return UntrustedSignal(host: host, port: port, decision: decision)
    }

    private static func untrustedSignal(for error: AdGuardClientError, host: String, port: Int) -> UntrustedSignal? {
        guard case .transport(.untrustedServer(let decision)) = error else { return nil }
        return UntrustedSignal(host: host, port: port, decision: decision)
    }
}

extension GLiNetRPCClient {
    /// One call as a result. Cancellation propagates.
    func checkedCall(_ call: GLiNetRPCCall) async throws -> Result<JSONValue, GLiNetRPCError> {
        do {
            return .success(try await self.call(call))
        } catch let error as GLiNetRPCError {
            try LiveRouterBackend.rethrowIfCancelled(error)
            return .failure(error)
        }
    }
}

extension GLiNetRPCCall {
    static let clientList = GLiNetRPCCall(object: "clients", method: "get_list", params: .object([:]))
}

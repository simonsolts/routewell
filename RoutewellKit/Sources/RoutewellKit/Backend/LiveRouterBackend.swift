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
public actor LiveRouterBackend: RouterBackend {
    private let configuration: LiveBackendConfiguration
    private let rpc: GLiNetRPCClient
    private let adGuardClient: AdGuardClient?
    private let trustStore: any EndpointTrustStore
    private let trustPrompt: any TrustPromptHandler
    private let clock: @Sendable () -> Date
    private let log: SessionEventLog?

    public init(
        configuration: LiveBackendConfiguration,
        rpc: GLiNetRPCClient,
        adGuard: AdGuardClient?,
        trustStore: any EndpointTrustStore,
        trustPrompt: any TrustPromptHandler,
        clock: @Sendable @escaping () -> Date = { Date() },
        log: SessionEventLog? = nil
    ) {
        self.configuration = configuration
        self.rpc = rpc
        self.adGuardClient = adGuard
        self.trustStore = trustStore
        self.trustPrompt = trustPrompt
        self.clock = clock
        self.log = log
    }

    // MARK: RouterBackend

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
                TrustedEndpoint(host: signal.host, port: signal.port, fingerprint: Self.leafFingerprint(signal.decision), approvedAt: clock())
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
                TrustedEndpoint(host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port, fingerprint: Self.leafFingerprint(decision), approvedAt: clock())
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

    // MARK: One overview attempt

    private func runAreas() async throws -> (result: OverviewRefreshResult, untrusted: UntrustedSignal?) {
        let attemptedAt = clock()

        async let statusOutcome = fetchSharedStatus()
        async let infoOutcome = fetchInfo()
        async let cableOutcome = fetchCable()
        async let clientListOutcome = fetchClientList()
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
            clients: clients.result
        )
        return (result, signal)
    }

    // MARK: Shared and per-area fetches (each catches only its own RPC/AdGuard error type;
    // cancellation and any other error propagate to the caller unmodified)

    private func fetchSharedStatus() async throws -> Result<JSONValue, GLiNetRPCError> {
        do {
            return .success(try await rpc.call(.init(object: "system", method: "get_status", params: .object([:]))))
        } catch let error as GLiNetRPCError {
            return .failure(error)
        }
    }

    private func fetchInfo() async throws -> Result<JSONValue, GLiNetRPCError> {
        do {
            return .success(try await rpc.call(.init(object: "system", method: "get_info", params: .object([:]))))
        } catch let error as GLiNetRPCError {
            return .failure(error)
        }
    }

    private func fetchCable() async throws -> Result<JSONValue, GLiNetRPCError> {
        do {
            return .success(try await rpc.call(.init(object: "cable", method: "get_status", params: .object([:]))))
        } catch let error as GLiNetRPCError {
            return .failure(error)
        }
    }

    private func fetchClientList() async throws -> Result<JSONValue, GLiNetRPCError> {
        do {
            return .success(try await rpc.call(.init(object: "clients", method: "get_list", params: .object([:]))))
        } catch let error as GLiNetRPCError {
            return .failure(error)
        }
    }

    private func fetchAdGuardArea(attemptedAt: Date) async throws -> (result: AreaRefreshResult<AdGuardStatus>, untrusted: UntrustedSignal?) {
        guard configuration.adGuard != nil, let adGuardClient else {
            return (.failure(.unavailable, attemptedAt: attemptedAt), nil)
        }

        let configResult: Result<JSONValue, GLiNetRPCError>
        do {
            configResult = .success(try await rpc.call(.init(object: "adguardhome", method: "get_config", params: .object([:]))))
        } catch let error as GLiNetRPCError {
            configResult = .failure(error)
        }

        switch configResult {
        case .failure(let error):
            return (.failure(Self.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: adGuardHostPort.host, port: adGuardHostPort.port))
        case .success(let configJSON):
            guard configJSON["enabled"]?.bool == true else {
                return (.failure(.unavailable, attemptedAt: attemptedAt), nil)
            }
            do {
                let status = try await adGuardClient.status()
                var stats: AdGuardStatsResponse?
                do {
                    stats = try await adGuardClient.stats()
                } catch let error as AdGuardClientError {
                    stats = nil
                    _ = error // best-effort: a missing stats window never fails the area
                }
                let mapped = AdGuardClient.adGuardStatus(status: status, stats: stats, now: clock())
                return (.success(mapped, observedAt: attemptedAt, source: .adGuardAPI), nil)
            } catch let error as AdGuardClientError {
                return (.failure(Self.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: adGuardHostPort.host, port: adGuardHostPort.port))
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

    private static func category(for error: GLiNetRPCError) -> RefreshFailureCategory {
        switch error {
        case .transport(let transportError):
            return category(for: transportError)
        case .httpStatus, .malformedResponse, .invalidParameters, .rpcError, .unsupportedAlgorithm, .unsupportedHashMethod:
            return .malformedResponse
        case .accessDenied, .credentialUnavailable:
            return .authentication
        case .methodNotFound:
            return .unavailable
        }
    }

    private static func category(for error: AdGuardClientError) -> RefreshFailureCategory {
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

    private static func category(for error: TransportError) -> RefreshFailureCategory {
        switch error {
        case .timedOut:
            return .timeout
        case .unreachable, .redirectRefused, .tlsFailure, .cancelled, .localNetworkDenied:
            return .network
        case .untrustedServer:
            // Only reached after a refused trust prompt; an approved one is
            // resolved by retrying the whole overview instead of mapping here.
            return .network
        case .responseTooLarge, .invalidResponse:
            return .malformedResponse
        }
    }

    private static func untrustedSignal(for error: GLiNetRPCError, host: String, port: Int) -> UntrustedSignal? {
        guard case .transport(.untrustedServer(let decision)) = error else { return nil }
        return UntrustedSignal(host: host, port: port, decision: decision)
    }

    private static func untrustedSignal(for error: AdGuardClientError, host: String, port: Int) -> UntrustedSignal? {
        guard case .transport(.untrustedServer(let decision)) = error else { return nil }
        return UntrustedSignal(host: host, port: port, decision: decision)
    }

    private static func leafFingerprint(_ decision: TrustDecision) -> CertificateFingerprint {
        switch decision {
        case .trusted:
            preconditionFailure("a trusted decision never reaches the trust prompt")
        case .untrustedNew(let fingerprint):
            return fingerprint
        case .untrustedChanged(_, let actual):
            return actual
        }
    }
}

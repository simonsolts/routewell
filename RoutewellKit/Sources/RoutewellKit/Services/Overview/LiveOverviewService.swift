import Foundation

/// A certificate seen while running one `overview()` attempt, along with
/// where it was seen. Only the first one encountered is ever surfaced to a
/// person: `overview()` shows at most one trust prompt per call.
private struct UntrustedSignal: Sendable {
    let host: String
    let port: Int
    let decision: TrustDecision
}

/// The Overview reads. One attempt fetches `system.get_status` exactly
/// once and shares it across the router, internet, and clients areas; each
/// area otherwise catches its own errors so one area's failure never
/// discards another's data. A certificate that is not trusted yet asks for
/// trust at most once per call.
struct LiveOverviewService: Sendable {
    let configuration: LiveBackendConfiguration
    let rpc: GLiNetRPCClient
    let adGuard: AdGuardClient?
    let trustStore: any EndpointTrustStore
    let trustPrompt: any TrustPromptHandler
    let clock: @Sendable () -> Date
    let log: SessionEventLog?

    func overview() async throws -> OverviewRefreshResult {
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
            try FailureMapping.rethrowIfCancelled(error)
            configResult = .failure(error)
        }

        switch configResult {
        case .failure(let error):
            let reading = AdGuardServiceReading(config: .failure(FailureMapping.category(for: error)), observedAt: attemptedAt)
            return (.failure(FailureMapping.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: adGuardHostPort.host, port: adGuardHostPort.port), reading)
        case .success(let configJSON):
            let config = AdGuardRouterConfig.parse(configJSON)
            var reading = AdGuardServiceReading(config: .success(config), observedAt: attemptedAt)
            // "enabled" false (or missing/unreadable) means AdGuard Home is not
            // running on the router right now, not that Routewell failed to
            // reach it: the area stays `.unavailable`, never a network failure.
            guard config.enabled == true else {
                return (.failure(.unavailable, attemptedAt: attemptedAt), nil, reading)
            }
            guard configuration.adGuard != nil, let adGuardClient = adGuard else {
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
                    try FailureMapping.rethrowIfCancelled(error)
                    switch error {
                    case .unauthorized, .credentialUnavailable:
                        // Unlike a missing stats window, a stats auth failure means
                        // the whole AdGuard session is bad: fail the area instead of
                        // reporting a misleadingly successful, counter-less status.
                        reading.answer = .failed(FailureMapping.category(for: error))
                        return (.failure(FailureMapping.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: adGuardHostPort.host, port: adGuardHostPort.port), reading)
                    case .transport, .httpStatus, .malformedResponse:
                        stats = nil // best-effort: a missing stats window never fails the area
                    }
                }
                var mapped = AdGuardClient.adGuardStatus(status: status, stats: stats, now: clock())
                mapped.handlesClientRequests = config.handlesDNS.map(Observed.value) ?? .unknown
                return (.success(mapped, observedAt: attemptedAt, source: .adGuardAPI), nil, reading)
            } catch let error as AdGuardClientError {
                try FailureMapping.rethrowIfCancelled(error)
                reading.answer = .failed(FailureMapping.category(for: error))
                return (.failure(FailureMapping.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: adGuardHostPort.host, port: adGuardHostPort.port), reading)
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
            return (.failure(FailureMapping.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port))
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
            return (.failure(FailureMapping.category(for: error), attemptedAt: attemptedAt), Self.untrustedSignal(for: error, host: configuration.routerEndpoint.host, port: configuration.routerEndpoint.port))
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
                return (.failure(FailureMapping.category(for: clientListError), attemptedAt: attemptedAt), untrusted)
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

    // MARK: Trust prompt

    private static func untrustedSignal(for error: GLiNetRPCError, host: String, port: Int) -> UntrustedSignal? {
        guard case .transport(.untrustedServer(let decision)) = error else { return nil }
        return UntrustedSignal(host: host, port: port, decision: decision)
    }

    private static func untrustedSignal(for error: AdGuardClientError, host: String, port: Int) -> UntrustedSignal? {
        guard case .transport(.untrustedServer(let decision)) = error else { return nil }
        return UntrustedSignal(host: host, port: port, decision: decision)
    }
}

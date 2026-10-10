import Foundation
import RoutewellKit

extension AppEnvironment {
    /// Settings › Router › Test Connection for the saved live profile, or
    /// `nil` without one. The router and AdGuard Home checks use throwaway
    /// clients, so they test the saved address and Keychain passwords, not the
    /// running session. A certificate prompt shows on `trustPromptController`,
    /// the Settings window's own. `onProbe` gets what the router reported.
    func connectionTest(trustPromptController: TrustPromptController,
                        onProbe: @escaping @MainActor (RouterProbe) -> Void) -> ConnectionTest? {
        guard model.mode == .live, let profile = persistence.selectedProfile, let endpoint = profile.liveEndpoint else { return nil }
        let credentials = self.credentials
        let routerCredential = profile.credential
        let adGuardCredential = CredentialReference(profileID: profile.id, endpoint: profile.endpoint, kind: .adGuardPassword)
        let routerPassword: @Sendable () async throws -> String = { try await Self.readPassword(credentials, routerCredential) }
        let adGuardPassword: @Sendable () async throws -> String = { try await Self.readPassword(credentials, adGuardCredential) }
        let username = profile.username
        let adGuardSettings = profile.adGuard
        return ConnectionTest(
            router: { [weak self] in
                await self?.checkRouter(endpoint: endpoint, username: username, password: routerPassword,
                                        trustPromptController: trustPromptController, onProbe: onProbe) ?? .failed(.noResponse)
            },
            sshEnabled: profile.ssh?.enabled == true,
            ssh: { [weak self] in await self?.reprobeSSH() ?? SSHProbeResult(capability: Capability()) },
            adGuardConfigured: adGuardSettings != nil,
            adGuardEnabled: { [weak self] in await self?.adGuardHomeEnabled() ?? .unknown },
            adGuardStatus: { [weak self] in
                guard let self, let adGuardSettings else { return .noResponse }
                return await self.checkAdGuardStatus(endpoint: endpoint, username: username, settings: adGuardSettings,
                                                      routerPassword: routerPassword, adGuardPassword: adGuardPassword,
                                                      trustPromptController: trustPromptController)
            }
        )
    }

    /// `adguardhome get_config` `enabled` through the running session.
    func adGuardHomeEnabled() async -> Observed<Bool> {
        guard let lease = model.session.lease, let reader = lease.backend as? AdGuardHomeStateReading else { return .unknown }
        let value = await reader.adGuardHomeEnabled()
        return model.session.expectedToken == lease.token ? value : .unknown
    }

    /// Probes SSH once more through the session and waits for the result.
    func reprobeSSH(timeout: Duration = .seconds(45)) async -> SSHProbeResult {
        guard model.sshConfigured else { return SSHProbeResult(capability: Capability(), failure: .configurationFailed) }
        refresh.reprobeSSH()
        return await waitForSSHProbe(timeout: timeout)
    }

    /// The refresh controller probes SSH once per new session lease. This
    /// waits for that result instead of starting a second connection.
    func waitForSSHProbe(timeout: Duration) async -> SSHProbeResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, !Task.isCancelled {
            if model.session.isReady, let probe = model.sshProbe { return probe }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return SSHProbeResult(capability: Capability(), failure: .timedOut)
    }

    /// Signs in, then times one more `system get_info`: the round trip.
    private func checkRouter(endpoint: RouterEndpoint, username: String, password: @escaping @Sendable () async throws -> String,
                             trustPromptController: TrustPromptController,
                             onProbe: @MainActor (RouterProbe) -> Void) async -> RouterCheck {
        let transport = transportFactory(trust.store)
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: username, password: password, transport: transport, log: logging.eventLog)
        let backend = LiveRouterBackend(configuration: LiveBackendConfiguration(routerEndpoint: endpoint), rpc: rpc, adGuard: nil,
                                        trustStore: trust.store, trustPrompt: TrustPromptAdapter(controller: trustPromptController),
                                        log: logging.eventLog)
        do {
            _ = try await backend.probe()
            let clock = ContinuousClock()
            let start = clock.now
            let probe = try await backend.probe()
            let check = RouterCheck.responded(after: clock.now - start)
            onProbe(probe)
            return check
        } catch let error as GLiNetRPCError {
            return .failed(ConnectionCheckFailure(error))
        } catch {
            return .failed(.noResponse)
        }
    }

    /// `control/status` with the saved AdGuard Home settings. With the
    /// router's own login, a throwaway `GLiNetRPCClient` signs in first, so an
    /// untrusted router certificate is asked about here; `AdGuardClient`
    /// would only see that login fail as `credentialUnavailable`.
    private func checkAdGuardStatus(endpoint: RouterEndpoint, username: String, settings: AdGuardSettings,
                                    routerPassword: @escaping @Sendable () async throws -> String,
                                    adGuardPassword: @escaping @Sendable () async throws -> String,
                                    trustPromptController: TrustPromptController) async -> ConnectionCheckFailure? {
        let transport = transportFactory(trust.store)
        let baseURL = Self.adGuardBaseURL(host: endpoint.host, settings: settings)
        let adGuardPort = baseURL.port ?? (settings.useHTTPS ? 443 : 80)
        let provider: any AdGuardCredentialProvider
        if settings.useRouterCredentials {
            let rpc = GLiNetRPCClient(endpoint: endpoint, username: username, password: routerPassword, transport: transport, log: logging.eventLog)
            do {
                try await establishTrustedSession(rpc, host: endpoint.host, port: endpoint.port, trustPromptController: trustPromptController)
            } catch let error as GLiNetRPCError {
                return ConnectionCheckFailure(error)
            } catch {
                return .noResponse
            }
            provider = RouterTokenAdGuardCredentials(session: rpc)
        } else {
            provider = BasicAdGuardCredentials(username: settings.username, password: adGuardPassword)
        }
        let client = AdGuardClient(baseURL: baseURL, credentials: provider, transport: transport, log: logging.eventLog)
        do {
            _ = try await requestAdGuardStatus(client, host: baseURL.host ?? endpoint.host, port: adGuardPort, trustPromptController: trustPromptController)
            return nil
        } catch let error as AdGuardClientError {
            return ConnectionCheckFailure(error)
        } catch let error as GLiNetRPCError {
            return ConnectionCheckFailure(error)
        } catch {
            return .noResponse
        }
    }

    /// Forces a login so an untrusted router certificate is caught and
    /// prompted for here — before `RouterTokenAdGuardCredentials` reuses this
    /// same `rpc` and would otherwise see the login failure only as
    /// `AdGuardClientError.credentialUnavailable`, with no certificate to show.
    private func establishTrustedSession(
        _ rpc: GLiNetRPCClient, host: String, port: Int, trustPromptController: TrustPromptController
    ) async throws {
        do {
            _ = try await rpc.sessionID()
        } catch GLiNetRPCError.transport(.untrustedServer(let decision)) {
            let approved = await trustPromptController.present(TrustPromptRequest(host: host, port: port, decision: decision))
            guard approved else { throw GLiNetRPCError.transport(.untrustedServer(decision)) }
            await trust.approve(TrustedEndpoint(host: host, port: port, fingerprint: decision.leafFingerprint, approvedAt: Date()))
            _ = try await rpc.sessionID()
        }
    }

    /// Same shape as `establishTrustedSession`, for the AdGuard Home host
    /// itself (only reached when `AdGuardClient`'s own transport — not a
    /// router-login lookup — hits an untrusted certificate).
    private func requestAdGuardStatus(
        _ client: AdGuardClient, host: String, port: Int, trustPromptController: TrustPromptController
    ) async throws -> AdGuardStatusResponse {
        do {
            return try await client.status()
        } catch AdGuardClientError.transport(.untrustedServer(let decision)) {
            let approved = await trustPromptController.present(TrustPromptRequest(host: host, port: port, decision: decision))
            guard approved else { throw AdGuardClientError.transport(.untrustedServer(decision)) }
            await trust.approve(TrustedEndpoint(host: host, port: port, fingerprint: decision.leafFingerprint, approvedAt: Date()))
            return try await client.status()
        }
    }
}

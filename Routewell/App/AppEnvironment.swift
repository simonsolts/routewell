import Foundation
import Observation
import RoutewellKit
#if DEBUG
import RoutewellMock
#endif

@MainActor @Observable
final class AppEnvironment {
    let model: AppModel
    let refresh: RefreshController
    let persistence: PersistenceController
    let logging: LoggingController
    let trust: TrustController
    let trustPrompt = TrustPromptController()
    private let credentials: any CredentialStore
    /// Builds one `HTTPTransport` for a lease, given the trust store it
    /// should validate certificates against. Called once per built live
    /// backend, never in `.mock` mode.
    private let transportFactory: (any EndpointTrustStore) -> any HTTPTransport
    private var setup: Task<Void, Never>?
    #if DEBUG
    private var mockBackend: MockRouterBackend?
    #endif
    /// Set when `transportFactory` was actually called. Tests use this to
    /// prove mock mode never constructs a live transport.
    private(set) var transportFactoryWasUsed = false

    static let mockProfiles = ["Home mock", "Travel mock"]
    static let mockScenarios = ["healthy", "partial", "offline", "stale", "slow"]

    init(model: AppModel, backend: (any RouterBackend)?, store: AtomicJSONStore? = nil,
         credentials: any CredentialStore = InMemoryCredentialStore(),
         transportFactory: @escaping (any EndpointTrustStore) -> any HTTPTransport = { URLSessionTransport(trustStore: $0) }) {
        self.model = model
        self.credentials = credentials
        self.transportFactory = transportFactory
        self.logging = LoggingController(model: model)
        self.refresh = RefreshController(model: model, logging: logging)
        self.persistence = PersistenceController(model: model, store: store, credentials: credentials)
        self.trust = TrustController(atomicStore: store, mode: model.mode)
        #if DEBUG
        mockBackend = backend as? MockRouterBackend
        #endif
        setup = Task { [weak self] in
            guard let self else { return }
            await persistence.load()
            await trust.load()
            // `liveEndpoint != nil` alone is enough here: `PersistenceController
            // .addLiveProfile` now saves the Keychain secret before it ever
            // appends or persists the profile, so a saved live profile always
            // has a password. A defensive `credentials.read(...)` on every
            // launch was considered and skipped as unnecessary Keychain I/O.
            model.setHasLiveEndpoint(persistence.selectedProfile?.liveEndpoint != nil)
            logging.record(kind: .session, message: "Application session started")
            if let backend, let profile = persistence.selectedProfile {
                #if DEBUG
                if store != nil, model.mode == .mock {
                    let restored = MockRouterBackend(hostname: profile.endpoint == "mock://home" ? "flint-demo" : "travel-demo")
                    mockBackend = restored
                    await model.session.switchProfile(profile.name, model: model, refresh: refresh) {
                        SessionLease(token: $0, backend: restored)
                    }.value
                    return
                }
                #endif
                await model.session.switchProfile(profile.name, model: model, refresh: refresh) {
                    SessionLease(token: $0, backend: backend)
                }.value
                return
            }
            if model.mode == .live, let profile = persistence.selectedProfile, profile.liveEndpoint != nil,
               let liveBackend = self.makeLiveBackend(for: profile) {
                await model.session.switchProfile(profile.name, model: model, refresh: refresh) {
                    SessionLease(token: $0, backend: liveBackend)
                }.value
            }
        }
    }

    func waitUntilReady() async { await setup?.value }

    func switchMockProfile(_ profile: String) {
        #if DEBUG
        guard model.mode == .mock,
              let saved = persistence.profiles.profiles.first(where: { $0.name == profile }) else { return }
        persistence.select(saved.id)
        installMock(profile: profile, scenarioID: model.mockScenarioID)
        #endif
    }

    func selectMockProfile(_ id: UUID) {
        guard !persistence.credentialBusy else { return }
        persistence.select(id)
        activateSelectedProfile()
    }

    func addMockProfile() {
        persistence.addMockProfile()
        activateSelectedProfile()
    }

    func deleteMockProfile() async {
        if await persistence.deleteSelectedProfile() { activateSelectedProfile() }
    }

    private func activateSelectedProfile() {
        #if DEBUG
        guard model.mode == .mock else { return }
        if let profile = persistence.selectedProfile {
            installMock(profile: profile.name, scenarioID: model.mockScenarioID)
        } else {
            model.session.disconnect(model: model, refresh: refresh)
        }
        #endif
    }

    func switchMockScenario(_ scenarioID: String) {
        #if DEBUG
        guard model.mode == .mock, Self.mockScenarios.contains(scenarioID) else { return }
        model.mockScenarioID = scenarioID
        let scenario = MockRouterBackend.Scenario(rawValue: scenarioID) ?? .healthy
        setup = Task { [weak self] in
            guard let self, let backend = self.mockBackend else { return }
            await backend.setScenario(scenario)
            self.refresh.refreshNow()
        }
        #endif
    }

    #if DEBUG
    private func installMock(profile: String, scenarioID: String) {
        let hostname = profile == Self.mockProfiles[0] ? "flint-demo" : "travel-demo"
        let scenario = MockRouterBackend.Scenario(rawValue: scenarioID) ?? .healthy
        let backend = MockRouterBackend(scenario: scenario, hostname: hostname)
        mockBackend = backend
        setup = model.session.switchProfile(profile, model: model, refresh: refresh) {
            SessionLease(token: $0, backend: backend)
        }
    }
    #endif

    /// Saves a live router profile from `SetupScreen`, stores its password in
    /// the credential store, and selects it. Returns false if either step fails.
    /// On success, also installs the live backend and starts its first
    /// refresh through the normal session-lease path.
    func saveLiveRouterProfile(endpoint: RouterEndpoint, username: String, password: Data, plainHTTPAcknowledged: Bool) async -> Bool {
        let profile = RouterProfile(
            name: endpoint.displayString,
            liveEndpoint: endpoint,
            username: username,
            plainHTTPAcknowledged: plainHTTPAcknowledged,
            adGuard: AdGuardSettings()
        )
        let saved = await persistence.addLiveProfile(profile, password: password)
        guard saved else { return false }
        model.setHasLiveEndpoint(true)
        reconnectLiveSession()
        return true
    }

    /// Rebuilds the live session from whatever is currently the saved
    /// profile: a new session revision, a fresh `LiveRouterBackend` from
    /// `makeLiveBackend(for:)`, then one refresh through the normal
    /// lease-ready path. Every mutation to a saved live profile — address,
    /// username, AdGuard settings, AdGuard credential, or router password —
    /// must call this afterwards. Without it, the old backend's password
    /// closures keep pointing at whatever `CredentialReference` they closed
    /// over at construction time, which a changed address or a deleted/
    /// replaced Keychain item can leave dangling.
    func reconnectLiveSession() {
        guard model.mode == .live, let profile = persistence.selectedProfile, profile.liveEndpoint != nil else { return }
        guard let liveBackend = makeLiveBackend(for: profile) else { return }
        setup = model.session.switchProfile(profile.name, model: model, refresh: refresh) {
            SessionLease(token: $0, backend: liveBackend)
        }
    }

    /// Router tab mutations that must reconnect the live session afterwards.

    @discardableResult
    func updateLiveAddress(_ endpoint: RouterEndpoint) async -> Bool {
        let saved = await persistence.updateLiveAddress(endpoint)
        if saved { reconnectLiveSession() }
        return saved
    }

    func updateLiveUsername(_ username: String) {
        persistence.updateLiveUsername(username)
        reconnectLiveSession()
    }

    @discardableResult
    func changeLivePassword(_ password: Data) async -> Bool {
        let saved = await persistence.changeLivePassword(password)
        if saved { reconnectLiveSession() }
        return saved
    }

    /// AdGuard Home tab mutations that must reconnect the live session afterwards.

    func updateAdGuardSettings(_ settings: AdGuardSettings) {
        persistence.updateAdGuardSettings(settings)
        reconnectLiveSession()
    }

    @discardableResult
    func saveAdGuardPassword(_ password: Data) async -> Bool {
        let saved = await persistence.saveAdGuardPassword(password)
        if saved { reconnectLiveSession() }
        return saved
    }

    /// The construction point for a live backend: one `HTTPTransport` per
    /// lease (via `transportFactory`, given the trust store it should
    /// validate against), a `GLiNetRPCClient` whose password closure reads
    /// the Keychain at call time, and — when the profile has AdGuard Home
    /// configured — an `AdGuardClient` using either the router's own login
    /// or a separate AdGuard Home account.
    private func makeLiveBackend(for profile: RouterProfile) -> (any RouterBackend)? {
        guard let endpoint = profile.liveEndpoint else { return nil }
        transportFactoryWasUsed = true
        let transport = transportFactory(trust.store)
        let credentials = self.credentials
        let routerCredential = CredentialReference(profileID: profile.id, endpoint: profile.endpoint, kind: .routerPassword)
        let rpc = GLiNetRPCClient(
            endpoint: endpoint,
            username: profile.username,
            password: { try await Self.readPassword(credentials, routerCredential) },
            transport: transport,
            log: logging.eventLog
        )

        var configuration = LiveBackendConfiguration(routerEndpoint: endpoint, adGuard: profile.adGuard)
        var adGuardClient: AdGuardClient?
        if let adGuardSettings = profile.adGuard {
            let baseURL = Self.adGuardBaseURL(host: endpoint.host, settings: adGuardSettings)
            configuration.adGuardBaseURL = baseURL
            let provider: any AdGuardCredentialProvider
            if adGuardSettings.useRouterCredentials {
                provider = RouterTokenAdGuardCredentials(session: rpc)
            } else {
                let adGuardCredential = CredentialReference(profileID: profile.id, endpoint: profile.endpoint, kind: .adGuardPassword)
                provider = BasicAdGuardCredentials(username: adGuardSettings.username) {
                    try await Self.readPassword(credentials, adGuardCredential)
                }
            }
            adGuardClient = AdGuardClient(baseURL: baseURL, credentials: provider, transport: transport, log: logging.eventLog)
        }

        return LiveRouterBackend(
            configuration: configuration,
            rpc: rpc,
            adGuard: adGuardClient,
            trustStore: trust.store,
            trustPrompt: TrustPromptAdapter(controller: trustPrompt),
            log: logging.eventLog
        )
    }

    private static func readPassword(_ store: any CredentialStore, _ reference: CredentialReference) async throws -> String {
        let data = try await store.read(reference)
        return String(decoding: data, as: UTF8.self)
    }

    /// `\(scheme)://\(host, bracketed if IPv6):\(port)/`, same host as the
    /// router endpoint.
    static func adGuardBaseURL(host: String, settings: AdGuardSettings) -> URL {
        let hostToken = host.contains(":") ? "[\(host)]" : host
        let scheme = settings.useHTTPS ? "https" : "http"
        return URL(string: "\(scheme)://\(hostToken):\(settings.port)/")!
    }

    /// Where "Test connection" reads its password from: the Setup screen has
    /// a form field with nothing saved yet; Settings tests the address/username
    /// currently typed but reads the already-saved password from Keychain.
    enum ConnectionTestPassword {
        case literal(String)
        case keychain(CredentialReference)
    }

    /// "Test connection": builds a throwaway `LiveRouterBackend` from the
    /// given values (never the saved profile) and probes it. Never installs
    /// anything into the session. `trustPromptController` is the caller's own
    /// local controller (each Test Connection button owns one and shows its
    /// sheet on its own window) — never the shared `trustPrompt` that
    /// `MainWindow` uses for refresh-time prompts, so a probe run from the
    /// Settings or Setup window never pops a sheet on the wrong window. The
    /// certificate itself is still checked against, and an approval still
    /// stored in, the one real `trust.store`: only which window asks is local.
    func testRouterConnection(
        endpoint: RouterEndpoint, username: String, password: ConnectionTestPassword,
        trustPromptController: TrustPromptController
    ) async -> String {
        let transport = transportFactory(trust.store)
        let credentials = self.credentials
        let passwordProvider: @Sendable () async throws -> String
        switch password {
        case .literal(let value):
            passwordProvider = { value }
        case .keychain(let reference):
            passwordProvider = { try await Self.readPassword(credentials, reference) }
        }
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: username, password: passwordProvider, transport: transport, log: logging.eventLog)
        let backend = LiveRouterBackend(
            configuration: LiveBackendConfiguration(routerEndpoint: endpoint),
            rpc: rpc,
            adGuard: nil,
            trustStore: trust.store,
            trustPrompt: TrustPromptAdapter(controller: trustPromptController),
            log: logging.eventLog
        )
        do {
            let probe = try await backend.probe()
            return "Connected: \(probe.model ?? "Unknown model"), firmware \(probe.firmware ?? "Unknown")"
        } catch let error as GLiNetRPCError {
            return Self.connectionTestMessage(for: error)
        } catch {
            return "Could not connect. Try again."
        }
    }

    /// "Test connection" for the AdGuard Home tab: probes only `control/status`,
    /// never the router RPC areas. When the profile uses the router's own
    /// login, a throwaway `GLiNetRPCClient` supplies the session token — its
    /// own untrusted-certificate prompt (on the router's host) is resolved
    /// first, via `trustPromptController`, before it is handed to the AdGuard
    /// client, since `AdGuardClient` itself only sees that login as an opaque
    /// `credentialUnavailable` and cannot recover the certificate decision.
    func testAdGuardConnection(
        routerEndpoint: RouterEndpoint,
        username: String,
        routerPassword: ConnectionTestPassword,
        adGuardSettings: AdGuardSettings,
        adGuardPassword: ConnectionTestPassword,
        trustPromptController: TrustPromptController
    ) async -> String {
        let transport = transportFactory(trust.store)
        let baseURL = Self.adGuardBaseURL(host: routerEndpoint.host, settings: adGuardSettings)
        let adGuardPort = baseURL.port ?? (adGuardSettings.useHTTPS ? 443 : 80)
        let credentials = self.credentials

        func passwordProvider(for source: ConnectionTestPassword) -> @Sendable () async throws -> String {
            switch source {
            case .literal(let value): return { value }
            case .keychain(let reference): return { try await Self.readPassword(credentials, reference) }
            }
        }

        let provider: any AdGuardCredentialProvider
        if adGuardSettings.useRouterCredentials {
            let rpc = GLiNetRPCClient(
                endpoint: routerEndpoint, username: username,
                password: passwordProvider(for: routerPassword), transport: transport, log: logging.eventLog
            )
            do {
                try await establishTrustedSession(rpc, host: routerEndpoint.host, port: routerEndpoint.port, trustPromptController: trustPromptController)
            } catch let error as GLiNetRPCError {
                return Self.connectionTestMessage(for: error)
            } catch {
                return "Could not connect. Try again."
            }
            provider = RouterTokenAdGuardCredentials(session: rpc)
        } else {
            provider = BasicAdGuardCredentials(username: adGuardSettings.username, password: passwordProvider(for: adGuardPassword))
        }

        let client = AdGuardClient(baseURL: baseURL, credentials: provider, transport: transport, log: logging.eventLog)
        do {
            let status = try await requestAdGuardStatus(client, host: baseURL.host ?? routerEndpoint.host, port: adGuardPort, trustPromptController: trustPromptController)
            return "Connected: AdGuard Home \(status.version ?? "Unknown version")."
        } catch let error as AdGuardClientError {
            return Self.connectionTestMessage(for: error)
        } catch let error as GLiNetRPCError {
            return Self.connectionTestMessage(for: error)
        } catch {
            return "Could not connect. Try again."
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
            try? await trust.store.approve(TrustedEndpoint(host: host, port: port, fingerprint: Self.leafFingerprint(decision), approvedAt: Date()))
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
            try? await trust.store.approve(TrustedEndpoint(host: host, port: port, fingerprint: Self.leafFingerprint(decision), approvedAt: Date()))
            return try await client.status()
        }
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

    private static func connectionTestMessage(for error: AdGuardClientError) -> String {
        switch error {
        case .transport(.untrustedServer):
            return "Connection cancelled. The certificate was not trusted."
        case .unauthorized, .credentialUnavailable:
            return "AdGuard Home refused the login. Check the username and password."
        case .transport(let transportError):
            return connectionTestCategory(for: transportError).failureCategory.message
        case .httpStatus, .malformedResponse:
            return RefreshFailureCategory.malformedResponse.failureCategory.message
        }
    }

    private static func connectionTestMessage(for error: GLiNetRPCError) -> String {
        switch error {
        case .transport(.untrustedServer):
            // Only reached when the prompt was declined: an approved one
            // retries `performProbe()` and either succeeds or throws a
            // different error.
            return "Connection cancelled. The certificate was not trusted."
        case .accessDenied, .credentialUnavailable:
            return "The router refused the login. Check the username and password."
        case .transport(let transportError):
            return connectionTestCategory(for: transportError).failureCategory.message
        case .httpStatus, .malformedResponse, .invalidParameters, .rpcError, .unsupportedAlgorithm, .unsupportedHashMethod:
            return RefreshFailureCategory.malformedResponse.failureCategory.message
        case .methodNotFound:
            return RefreshFailureCategory.unavailable.failureCategory.message
        }
    }

    private static func connectionTestCategory(for error: TransportError) -> RefreshFailureCategory {
        switch error {
        case .timedOut: .timeout
        case .unreachable, .redirectRefused, .tlsFailure, .cancelled, .localNetworkDenied, .untrustedServer: .network
        case .responseTooLarge, .invalidResponse: .malformedResponse
        }
    }

    static func configured(
        variables: [String: String] = ProcessInfo.processInfo.environment,
        persist: Bool = false,
        transportFactory: @escaping (any EndpointTrustStore) -> any HTTPTransport = { URLSessionTransport(trustStore: $0) }
    ) -> AppEnvironment {
        let store: AtomicJSONStore? = persist ? AtomicJSONStore(directory:
            URL.applicationSupportDirectory.appendingPathComponent("Routewell", isDirectory: true)) : nil
        let credentials: any CredentialStore = persist ? KeychainCredentialStore() : InMemoryCredentialStore()
        #if DEBUG
        let allowsMock = true
        #else
        let allowsMock = false
        #endif
        let mode = BackendMode.resolve(variables["ROUTEWELL_BACKEND"], allowsMock: allowsMock)
        #if DEBUG
        if mode == .mock {
            return AppEnvironment(model: AppModel(mode: mode), backend: MockRouterBackend(), store: store, credentials: credentials)
        }
        #endif
        return AppEnvironment(model: AppModel(mode: mode), backend: nil, store: store, credentials: credentials, transportFactory: transportFactory)
    }
}

/// Hops `TrustPromptHandler.requestTrust` into `TrustPromptController` on the
/// main actor. `TrustPromptController` is `@MainActor` and `Sendable`
/// (every access to its state is already actor-serialized), so holding a
/// reference to it here needs no extra synchronization.
private struct TrustPromptAdapter: TrustPromptHandler {
    let controller: TrustPromptController

    func requestTrust(host: String, port: Int, decision: TrustDecision) async -> Bool {
        await controller.present(TrustPromptRequest(host: host, port: port, decision: decision))
    }
}

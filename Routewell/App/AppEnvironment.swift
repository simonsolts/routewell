import Foundation
import AppKit
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
    let mutation: MutationController
    let clients: ClientsController
    let clientDNS: ClientDNSController
    let clientActions: ClientActionsController
    let router: RouterController
    let sshSetup: SSHSetupController
    let trustPrompt = TrustPromptController()
    let onboarding = OnboardingController()
    /// Decided before bootstrap from the files on disk, so the right window
    /// opens at launch and the main window never flashes before onboarding.
    /// `MainWindow` and `OnboardingWindow` correct a wrong guess after bootstrap.
    let launchShowsOnboarding: Bool
    private let sshKeyAccess = SSHKeyFileAccess()
    /// Starts `/usr/bin/ssh` for the live SSH runner. Tests pass a fake.
    private let processRunner: any ProcessRunning
    private let credentials: any CredentialStore
    /// Builds one `HTTPTransport` for a lease, given the trust store it
    /// should validate certificates against. Called once per built live
    /// backend, never in `.mock` mode.
    private let transportFactory: (any EndpointTrustStore) -> any HTTPTransport
    private var setup: Task<Void, Never>?
    #if DEBUG
    private var mockBackend: MockRouterBackend?
    private(set) var mockClientsScenario: MockClientsService.Scenario = .newDevices
    private(set) var mockClientActionsMechanism: ClientActionMechanism? = .ssh
    private(set) var mockSQMBehavior: MockRouterService.SQMBehavior = .unavailable
    private(set) var mockFirmwareBehavior: MockRouterService.FirmwareBehavior = .unableToCheck
    private(set) var mockSSHScenario: MockSSHService.Scenario = .populated
    #endif
    /// Set when `transportFactory` was actually called. Tests use this to
    /// prove mock mode never constructs a live transport.
    private(set) var transportFactoryWasUsed = false

    static let mockProfiles = ["Home mock", "Travel mock"]
    static let mockScenarios = ["healthy", "partial", "offline", "stale", "slow"]

    init(model: AppModel, backend: (any RouterBackend)?, store: AtomicJSONStore? = nil,
         credentials: any CredentialStore = InMemoryCredentialStore(),
         registry: DeviceRegistry? = nil,
         presence: PresenceLog? = nil,
         sshDirectory: URL? = nil,
         hostKeyScanner: any SSHHostKeyScanning = LiveSSHHostKeyScanner(),
         processRunner: any ProcessRunning = ProcessRunner(),
         launchShowsOnboarding: Bool? = nil,
         transportFactory: @escaping (any EndpointTrustStore) -> any HTTPTransport = { URLSessionTransport(trustStore: $0) }) {
        self.model = model
        self.launchShowsOnboarding = launchShowsOnboarding ?? (model.mode == .live)
        self.credentials = credentials
        self.transportFactory = transportFactory
        self.processRunner = processRunner
        // Routewell's own `known_hosts`: Application Support when the app
        // persists, otherwise a fresh temporary folder (previews and tests).
        let hostKeysDirectory = sshDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("routewell-ssh-\(UUID().uuidString)", isDirectory: true)
        self.sshSetup = SSHSetupController(hostKeys: SSHHostKeyStore(directory: hostKeysDirectory), scanner: hostKeyScanner)
        self.logging = LoggingController(model: model)
        let deviceRegistry = registry ?? Self.makeRegistry(mode: model.mode, store: store)
        let presenceLog = presence ?? Self.makePresence(mode: model.mode, store: store)
        self.clients = ClientsController(model: model, registry: deviceRegistry, presence: presenceLog, logging: logging)
        self.refresh = RefreshController(model: model, logging: logging, registry: deviceRegistry, presence: presenceLog)
        self.clientDNS = ClientDNSController(model: model)
        self.clientActions = ClientActionsController(model: model)
        // Mock baselines stay in memory; live ones use `snapshots.json`.
        self.router = RouterController(model: model, baselines: UpgradeBaselineStore(store: model.mode == .live ? store : nil))
        self.persistence = PersistenceController(model: model, store: store, credentials: credentials)
        self.trust = TrustController(atomicStore: store, mode: model.mode)
        self.mutation = MutationController(model: model, refresh: refresh)
        #if DEBUG
        mockBackend = backend as? MockRouterBackend
        #endif
        sshSetup.save = { [weak self] settings in self?.updateSSHSettings(settings) }
        onboarding.environment = self
        router.routerURL = { [weak self] in
            guard let self, self.model.mode == .live else { return nil }
            return self.persistence.selectedProfile?.liveEndpoint?.url
        }
        setup = Task { [weak self] in
            guard let self else { return }
            await persistence.load()
            await trust.load()
            await clients.load()
            await router.load()
            // Onboarding saves the profile at sign-in. One that never reached
            // Finish is removed, so onboarding starts empty again.
            if model.mode == .live {
                for profile in persistence.profiles.profiles where profile.liveEndpoint != nil && !profile.setupComplete {
                    await forgetRouter(profile.id)
                }
                // A run that quit after Trust Certificate but before sign-in
                // left a pin for a host no profile uses. Skipped when the
                // profiles could not be read (a newer app's file): their
                // pins are still needed.
                if persistence.errors[.profiles] == nil {
                    let hosts = Set(persistence.profiles.profiles.compactMap { $0.liveEndpoint?.host })
                    for pin in trust.trusted where !hosts.contains(pin.host) {
                        await trust.revoke(host: pin.host, port: pin.port)
                    }
                }
            }
            // A live profile always has a password: `PersistenceController
            // .addLiveProfile` saves the Keychain secret before the profile.
            updateNeedsSetup()
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

    /// Mock sessions keep device history in memory, seeded so the mockups'
    /// "3 new devices" state appears. Live sessions use `devices.json` when
    /// the app persists, and memory otherwise (previews and tests).
    private static func makeRegistry(mode: BackendMode, store: AtomicJSONStore?) -> DeviceRegistry {
        #if DEBUG
        if mode == .mock {
            return DeviceRegistry(store: nil, initial: MockClientsService.seedRegistry(now: .now))
        }
        #endif
        return DeviceRegistry(store: mode == .live ? store : nil)
    }

    /// Mock sessions keep presence in memory, seeded so Availability shows
    /// history. Live sessions use `presence.json` when the app persists.
    private static func makePresence(mode: BackendMode, store: AtomicJSONStore?) -> PresenceLog {
        #if DEBUG
        if mode == .mock {
            return PresenceLog(store: nil, initial: MockClientsService.seedPresence(now: .now))
        }
        #endif
        return PresenceLog(store: mode == .live ? store : nil)
    }

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
    /// DEBUG-only dev tool: selects which outcome the mock Protection
    /// service produces on its next `setProtection` call.
    func setMockProtectionBehavior(_ behavior: MockRouterBackend.ProtectionBehavior) {
        guard model.mode == .mock, let mockBackend else { return }
        Task { await mockBackend.setProtectionBehavior(behavior) }
    }

    func setMockFeatureBehavior(_ behavior: MockRouterBackend.FeatureBehavior, for area: DataArea) {
        guard model.mode == .mock, let mockBackend else { return }
        Task {
            await mockBackend.setFeatureBehavior(behavior, for: area)
            refresh.refreshNow()
        }
    }

    /// `nil` hides Ping and Wake.
    func setMockClientActions(_ mechanism: ClientActionMechanism?) {
        guard model.mode == .mock, let mockBackend else { return }
        mockClientActionsMechanism = mechanism
        mockBackend.mockClientActions.setMechanism(mechanism)
        clientActions.mechanismChanged()
    }

    func setMockSQMBehavior(_ behavior: MockRouterService.SQMBehavior) {
        guard model.mode == .mock, let mockBackend else { return }
        mockSQMBehavior = behavior
        Task {
            await mockBackend.mockRouter.setSQMBehavior(behavior)
            refresh.refreshNow()
        }
    }

    func setMockFirmwareBehavior(_ behavior: MockRouterService.FirmwareBehavior) {
        guard model.mode == .mock, let mockBackend else { return }
        mockFirmwareBehavior = behavior
        Task { await mockBackend.mockRouter.setFirmwareBehavior(behavior) }
    }

    /// Chunk 15: SSH off, probe pending, fails, times out, host key
    /// changed, or populated. The probe runs again for the new scenario.
    func setMockSSHScenario(_ scenario: MockSSHService.Scenario) {
        guard model.mode == .mock, let mockBackend else { return }
        mockSSHScenario = scenario
        mockBackend.mockSSH.setScenario(scenario)
        refresh.reprobeSSH()
        refresh.refreshNow()
    }

    func setMockClientsScenario(_ scenario: MockClientsService.Scenario) {
        guard model.mode == .mock, let mockBackend else { return }
        mockClientsScenario = scenario
        Task {
            await mockBackend.setClientsScenario(scenario)
            refresh.refreshNow()
        }
    }

    func recordFixtures() {
        guard model.mode == .live, let lease = model.session.lease,
              lease.backend is LiveRouterBackend else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder for live router responses with private values replaced by examples"
        panel.prompt = "Record Fixtures"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let session = model.session.routerSession
        Task {
            do {
                let count = try await FixtureRecorder().record(session: session, lease: lease, to: directory)
                let sshNote = lease.backend.ssh == nil
                    ? " SSH is not set up, so the SSH commands were skipped. Set up SSH in Settings › Router, then record again."
                    : " SSH output is text: addresses, quoted names, and key fingerprints are replaced, but log lines can hold other private text."
                let alert = NSAlert()
                alert.messageText = "Fixtures recorded"
                alert.informativeText = "Recorded \(count) read-only calls from the connected live router. Example addresses and names are privacy aliases, not mock responses.\(sshNote) Check _recording-manifest.json and review the files before committing."
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Fixture recording stopped"
                alert.informativeText = "The session changed or a file could not be written."
                alert.runModal()
            }
        }
    }
    #endif

    #if DEBUG
    private func installMock(profile: String, scenarioID: String) {
        let hostname = profile == Self.mockProfiles[0] ? "flint-demo" : "travel-demo"
        let scenario = MockRouterBackend.Scenario(rawValue: scenarioID) ?? .healthy
        let backend = MockRouterBackend(scenario: scenario, hostname: hostname)
        backend.mockClientActions.setMechanism(mockClientActionsMechanism)
        backend.mockSSH.setScenario(mockSSHScenario)
        mockBackend = backend
        let clientsScenario = mockClientsScenario
        let sqm = mockSQMBehavior
        let firmware = mockFirmwareBehavior
        setup = model.session.switchProfile(profile, model: model, refresh: refresh) {
            await backend.setClientsScenario(clientsScenario)
            await backend.mockRouter.setSQMBehavior(sqm)
            await backend.mockRouter.setFirmwareBehavior(firmware)
            return SessionLease(token: $0, backend: backend)
        }
    }
    #endif

    /// `needsSetup` follows the selected profile: live and finished, or not.
    func updateNeedsSetup() {
        guard let profile = persistence.selectedProfile else { model.setHasLiveEndpoint(false); return }
        model.setHasLiveEndpoint(profile.liveEndpoint != nil && profile.setupComplete)
    }

    // MARK: Onboarding (chunk 15A)

    /// Sign-in for onboarding: a throwaway client checks the password with the
    /// certificate the person just trusted. A changed certificate is never
    /// prompted for here; it comes back as `untrustedServer`.
    func onboardingSignIn(endpoint: RouterEndpoint, password: String) async throws -> RouterProbe {
        let transport = transportFactory(trust.store)
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: SSHSettings().user, password: { password },
                                  transport: transport, log: logging.eventLog)
        let backend = LiveRouterBackend(configuration: LiveBackendConfiguration(routerEndpoint: endpoint), rpc: rpc, adGuard: nil,
                                        trustStore: trust.store, trustPrompt: RefusingTrustPrompt(), log: logging.eventLog)
        return try await backend.probe()
    }

    /// Saves the signed-in router, still unfinished, and starts its session,
    /// so the SSH steps can probe through it. `needsSetup` stays true.
    func saveOnboardedProfile(name: String, endpoint: RouterEndpoint, password: Data) async -> UUID? {
        let profile = RouterProfile(name: name, liveEndpoint: endpoint, username: SSHSettings().user,
                                    adGuard: AdGuardSettings(), setupComplete: false)
        guard await persistence.addLiveProfile(profile, password: password) else { return nil }
        reconnectLiveSession()
        await waitUntilReady()
        return profile.id
    }

    /// Onboarding's Finish: the profile is complete, so the main window opens.
    func completeSetup(_ id: UUID, name: String) async -> Bool {
        guard await persistence.completeSetup(id, name: name) else { return false }
        updateNeedsSetup()
        return true
    }

    /// Removes a router and everything Routewell keeps for it on this Mac:
    /// the profile, its Keychain items, its certificate pin, its SSH host key,
    /// and its key bookmark (part of the profile). Nothing is sent to the router.
    func forgetRouter(_ id: UUID) async {
        guard let profile = persistence.profiles.profiles.first(where: { $0.id == id }) else { return }
        if persistence.selectedProfile?.id == id {
            model.session.disconnect(model: model, refresh: refresh)
            _ = sshKeyAccess.activate(nil)
        }
        if let endpoint = profile.liveEndpoint {
            await trust.revoke(host: endpoint.host, port: endpoint.port)
            try? await sshSetup.hostKeys.revoke(host: endpoint.host, port: profile.ssh?.port ?? SSHSettings().port)
        }
        await persistence.removeProfile(id)
        updateNeedsSetup()
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
        guard mutation.inFlight == nil else {
            logging.record(kind: .session, message: "Reconnect refused: a Protection change is running")
            return
        }
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

    /// Settings › Router › SSH. A new session revision builds a backend
    /// with or without the SSH runner; with it, the probe runs once.
    func updateSSHSettings(_ settings: SSHSettings) {
        guard model.mode == .live, persistence.selectedProfile?.ssh != settings else { return }
        persistence.updateSSHSettings(settings)
        reconnectLiveSession()
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
            log: logging.eventLog,
            sshRunner: makeSSHRunner(for: profile, host: endpoint.host)
        )
    }

    /// The live SSH runner, only when the profile switched SSH on (which
    /// needed a trusted host key). Without one, Ping, Wake, Ports, Storage,
    /// and Logs report that SSH is needed, and nothing attempts SSH.
    /// It also opens the key file's bookmark on every build, even with SSH
    /// off, so switching SSH on after a relaunch can read the key.
    private func makeSSHRunner(for profile: RouterProfile, host: String) -> (any SSHCommandRunning)? {
        if let refreshed = sshKeyAccess.activate(profile.ssh) {
            persistence.updateSSHSettings(refreshed)
        }
        guard let settings = profile.ssh, settings.enabled, let identity = settings.identity,
              identity != .agent || sshSetup.agentAllowed,
              let target = try? SSHTarget(host: host, port: settings.port, user: settings.user) else { return nil }
        let connection = SSHConnection(target: target, identity: identity,
                                       agentSocket: identity == .agent ? SSHAgentLocator.socket() : nil)
        return LiveSSHCommandRunner(connection: connection, hostKeys: sshSetup.hostKeys, processes: processRunner)
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
        case .loginPaused:
            return "The router paused sign-in after too many incorrect passwords. Try again in a few minutes."
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

    /// The launch guess: onboarding unless the saved, selected profile is a
    /// finished live router. Reads the file without loading the store.
    static func peekNeedsSetup(in directory: URL) -> Bool {
        guard let saved = AtomicJSONStore.peek(ProfileSettings.self, from: .profiles, in: directory) else { return true }
        let selected = saved.profiles.first { $0.id == saved.selectedID } ?? saved.profiles.first
        return !(selected?.liveEndpoint != nil && selected?.setupComplete == true)
    }

    static func configured(
        variables: [String: String] = ProcessInfo.processInfo.environment,
        persist: Bool = false,
        transportFactory: @escaping (any EndpointTrustStore) -> any HTTPTransport = { URLSessionTransport(trustStore: $0) }
    ) -> AppEnvironment {
        let store: AtomicJSONStore? = persist ? AtomicJSONStore(directory:
            URL.applicationSupportDirectory.appendingPathComponent("Routewell", isDirectory: true)) : nil
        let credentials: any CredentialStore = persist ? KeychainCredentialStore() : InMemoryCredentialStore()
        let sshDirectory: URL? = persist ? URL.applicationSupportDirectory
            .appendingPathComponent("Routewell", isDirectory: true).appendingPathComponent("ssh", isDirectory: true) : nil
        #if DEBUG
        let allowsMock = true
        #else
        let allowsMock = false
        #endif
        let mode = BackendMode.resolve(variables["ROUTEWELL_BACKEND"], allowsMock: allowsMock)
        #if DEBUG
        if mode == .mock {
            let mockScenario = variables["ROUTEWELL_ONBOARDING"].flatMap(MockOnboardingScenario.init(rawValue:))
            let environment = AppEnvironment(model: AppModel(mode: mode), backend: MockRouterBackend(), store: store, credentials: credentials,
                                             launchShowsOnboarding: mockScenario != nil)
            environment.onboarding.launchMockScenario = mockScenario
            return environment
        }
        #endif
        let directory = URL.applicationSupportDirectory.appendingPathComponent("Routewell", isDirectory: true)
        let launchShowsOnboarding = !persist || Self.peekNeedsSetup(in: directory)
        return AppEnvironment(model: AppModel(mode: mode), backend: nil, store: store, credentials: credentials,
                              sshDirectory: sshDirectory, launchShowsOnboarding: launchShowsOnboarding, transportFactory: transportFactory)
    }
}

/// Never prompts. Onboarding shows the fingerprint on its own step first.
private struct RefusingTrustPrompt: TrustPromptHandler {
    func requestTrust(host: String, port: Int, decision: TrustDecision) async -> Bool { false }
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

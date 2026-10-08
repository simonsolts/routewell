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
    let adGuard: AdGuardController
    let clients: ClientsController
    let clientDNS: ClientDNSController
    let clientActions: ClientActionsController
    let router: RouterController
    let sshSetup: SSHSetupController
    let trustPrompt = TrustPromptController()
    let onboarding = OnboardingController()
    /// Settings › Router (chunk 15B).
    @ObservationIgnored private(set) lazy var liveRouterSettings = LiveRouterSettingsServices(environment: self)
    #if DEBUG
    /// Keeps the mock scenarios while the Settings window opens and closes.
    @ObservationIgnored private(set) lazy var mockRouterSettings = MockRouterSettingsServices(environment: self)
    #endif
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
    private(set) var mockAdGuardScenario: MockAdGuardScenario = .running
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
         dataDirectory: URL? = nil,
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
        // Mock copies stay in memory; live ones use `adguard/<profile>/archive.json`.
        self.adGuard = AdGuardController(model: model, refresh: refresh,
                                         store: AdGuardArchiveStore(root: model.mode == .live ? dataDirectory : nil))
        #if DEBUG
        mockBackend = backend as? MockRouterBackend
        #endif
        sshSetup.save = { [weak self] settings in self?.updateSSHSettings(settings) }
        adGuard.profileID = { [weak self] in self?.persistence.selectedProfile?.id }
        refresh.onAdGuardReading = { [weak self] reading, token in await self?.adGuard.observe(reading, token: token) }
        refresh.onAdGuardOverview = { [weak self] lease in try await self?.adGuard.refreshOverview(using: lease) }
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
        installMock(profile: saved, scenarioID: model.mockScenarioID)
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
            installMock(profile: profile, scenarioID: model.mockScenarioID)
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

    /// Chunk 17: the writes the mock AdGuard Home received, for tests.
    func mockAdGuardWrites() async -> [AdGuardWrite] {
        await mockBackend?.mockAdGuard.writes ?? []
    }

    /// Chunk 16: the router's AdGuard Home setting and the saved copy.
    func setMockAdGuardScenario(_ scenario: MockAdGuardScenario) {
        guard model.mode == .mock, let mockBackend else { return }
        mockAdGuardScenario = scenario
        Task {
            await mockBackend.mockAdGuard.setScenario(scenario)
            await adGuard.replaceArchive(scenario.seedArchive(now: .now))
            refresh.refreshNow()
        }
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
    /// The first mock profile keeps its hostname when it is renamed.
    private func installMock(profile: RouterProfile, scenarioID: String) {
        let hostname = profile.endpoint == "mock://home" ? "flint-demo" : "travel-demo"
        let scenario = MockRouterBackend.Scenario(rawValue: scenarioID) ?? .healthy
        let backend = MockRouterBackend(scenario: scenario, hostname: hostname)
        backend.mockClientActions.setMechanism(mockClientActionsMechanism)
        backend.mockSSH.setScenario(mockSSHScenario)
        mockBackend = backend
        let clientsScenario = mockClientsScenario
        let sqm = mockSQMBehavior
        let firmware = mockFirmwareBehavior
        let adGuardScenario = mockAdGuardScenario
        setup = model.session.switchProfile(profile.name, model: model, refresh: refresh) {
            await backend.mockAdGuard.setScenario(adGuardScenario)
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
    /// its key bookmark (part of the profile), and its saved AdGuard Home
    /// copy. Nothing is sent to the router.
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
        await adGuard.removeArchive(profile: id)
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
        guard !adGuard.isWriting else {
            logging.record(kind: .session, message: "Reconnect refused: an AdGuard Home change is running")
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

    /// Settings › Router › Name: a label only, in live and mock mode. The
    /// session is not rebuilt.
    func renameRouter(_ name: String) {
        persistence.renameSelectedProfile(name)
    }

    /// Settings › Router › HTTPS certificate › Forget…: removes the pin for
    /// this address, then rebuilds the session so the next connection asks
    /// again. Nothing is sent to the router before the person confirms.
    func forgetCertificate() async {
        guard model.mode == .live, let endpoint = persistence.selectedProfile?.liveEndpoint else { return }
        await trust.revoke(host: endpoint.host, port: endpoint.port)
        reconnectLiveSession()
    }

    /// Settings › Router › Start Setup Again…: removes the router from this
    /// Mac only, then opens onboarding. In mock mode nothing is removed and
    /// the mock assistant opens.
    func startSetupAgain() async {
        #if DEBUG
        if model.mode == .mock {
            onboarding.startMock(.found)
            return
        }
        #endif
        if let profile = persistence.selectedProfile, profile.liveEndpoint != nil {
            await forgetRouter(profile.id)
        }
        onboarding.start()
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

    // MARK: Test Connection (chunk 15B)

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
            await trust.approve(TrustedEndpoint(host: host, port: port, fingerprint: Self.leafFingerprint(decision), approvedAt: Date()))
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
            await trust.approve(TrustedEndpoint(host: host, port: port, fingerprint: Self.leafFingerprint(decision), approvedAt: Date()))
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
                              sshDirectory: sshDirectory, dataDirectory: persist ? directory : nil,
                              launchShowsOnboarding: launchShowsOnboarding, transportFactory: transportFactory)
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

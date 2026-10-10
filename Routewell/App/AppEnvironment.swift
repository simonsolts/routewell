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
    let filters: AdGuardFiltersController
    let dns: AdGuardDNSController
    let instance: AdGuardInstanceController
    let clients: ClientsController
    let clientDNS: ClientDNSController
    let queryLog: QueryLogController
    let clientActions: ClientActionsController
    let router: RouterController
    let sshSetup: SSHSetupController
    let trustPrompt = TrustPromptController()
    let onboarding = OnboardingController()
    /// Settings › Router.
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
    let credentials: any CredentialStore
    /// Builds one `HTTPTransport` for a lease, given the trust store it
    /// should validate certificates against. Called once per built live
    /// backend, never in `.mock` mode.
    let transportFactory: (any EndpointTrustStore) -> any HTTPTransport
    var setup: Task<Void, Never>?
    #if DEBUG
    var mockBackend: MockRouterBackend?
    var mockClientsScenario: MockClientsService.Scenario = .newDevices
    var mockClientActionsMechanism: ClientActionMechanism? = .ssh
    var mockSQMBehavior: MockRouterService.SQMBehavior = .unavailable
    var mockFirmwareBehavior: MockRouterService.FirmwareBehavior = .unableToCheck
    var mockSSHScenario: MockSSHService.Scenario = .populated
    var mockAdGuardScenario: MockAdGuardScenario = .running
    /// The "Empty" Query Log: AdGuard Home answers with no entries.
    var mockQueryLogEmpty = false
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
        self.queryLog = QueryLogController(model: model)
        self.clientActions = ClientActionsController(model: model)
        // Mock baselines stay in memory; live ones use `snapshots.json`.
        self.router = RouterController(model: model, baselines: UpgradeBaselineStore(store: model.mode == .live ? store : nil))
        self.persistence = PersistenceController(model: model, store: store, credentials: credentials)
        self.trust = TrustController(atomicStore: store, mode: model.mode)
        // Mock copies stay in memory; live ones use `adguard/<profile>/archive.json`.
        self.adGuard = AdGuardController(model: model, refresh: refresh,
                                         store: AdGuardArchiveStore(root: model.mode == .live ? dataDirectory : nil))
        self.filters = AdGuardFiltersController(adGuard: adGuard)
        self.dns = AdGuardDNSController(adGuard: adGuard)
        // Mock backups stay in memory; live ones use `adguard/<profile>/backups/`.
        self.instance = AdGuardInstanceController(model: model, adGuard: adGuard, refresh: refresh,
                                                  store: AdGuardBackupStore(root: model.mode == .live ? dataDirectory : nil))
        #if DEBUG
        mockBackend = backend as? MockRouterBackend
        #endif
        sshSetup.save = { [weak self] settings in self?.updateSSHSettings(settings) }
        adGuard.profileID = { [weak self] in self?.persistence.selectedProfile?.id }
        instance.profileID = { [weak self] in self?.persistence.selectedProfile?.id }
        persistence.onSelectionChange = { [weak self] in
            self?.filters.reset()
            self?.dns.reset()
            self?.instance.reset()
        }
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

    /// `needsSetup` follows the selected profile: live and finished, or not.
    func updateNeedsSetup() {
        guard let profile = persistence.selectedProfile else { model.setHasLiveEndpoint(false); return }
        model.setHasLiveEndpoint(profile.liveEndpoint != nil && profile.setupComplete)
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
        await instance.removeBackups(profile: id)
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

    static func readPassword(_ store: any CredentialStore, _ reference: CredentialReference) async throws -> String {
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

/// Hops `TrustPromptHandler.requestTrust` into `TrustPromptController` on the
/// main actor. `TrustPromptController` is `@MainActor` and `Sendable`
/// (every access to its state is already actor-serialized), so holding a
/// reference to it here needs no extra synchronization.
struct TrustPromptAdapter: TrustPromptHandler {
    let controller: TrustPromptController

    func requestTrust(host: String, port: Int, decision: TrustDecision) async -> Bool {
        await controller.present(TrustPromptRequest(host: host, port: port, decision: decision))
    }
}

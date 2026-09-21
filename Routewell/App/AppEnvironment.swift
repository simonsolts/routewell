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
    private var setup: Task<Void, Never>?
    #if DEBUG
    private var mockBackend: MockRouterBackend?
    #endif
    /// Set by `configured` when `transportFactory` was actually called. Tests
    /// use this to prove mock mode never constructs a live transport.
    private(set) var transportFactoryWasUsed = false
    /// The transport built for `.live` mode, kept for chunk 09's
    /// `LiveRouterBackend` to use. Never built in `.mock` mode.
    private(set) var liveTransport: (any HTTPTransport)?

    static let mockProfiles = ["Home mock", "Travel mock"]
    static let mockScenarios = ["healthy", "partial", "offline", "stale", "slow"]

    init(model: AppModel, backend: (any RouterBackend)?, store: AtomicJSONStore? = nil,
         credentials: any CredentialStore = InMemoryCredentialStore()) {
        self.model = model
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
    func saveLiveRouterProfile(endpoint: RouterEndpoint, username: String, password: Data, plainHTTPAcknowledged: Bool) async -> Bool {
        let profile = RouterProfile(
            name: endpoint.displayString,
            liveEndpoint: endpoint,
            username: username,
            plainHTTPAcknowledged: plainHTTPAcknowledged
        )
        let saved = await persistence.addLiveProfile(profile, password: password)
        if saved {
            model.setHasLiveEndpoint(true)
        }
        return saved
    }

    /// The construction point for a live backend. Returns nil in this chunk:
    /// `.live` mode has no backend yet, so the refresh path stays a no-op and
    /// the UI shows setup guidance instead of an error. Chunk 09 fills this in
    /// with a real `LiveRouterBackend` built from `profile` and a transport.
    static func makeLiveBackend(for profile: RouterProfile) -> (any RouterBackend)? {
        nil
    }

    static func configured(
        variables: [String: String] = ProcessInfo.processInfo.environment,
        persist: Bool = false,
        transportFactory: @escaping () -> any HTTPTransport = { URLSessionTransport(trustStore: InMemoryEndpointTrustStore()) }
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
        let environment = AppEnvironment(model: AppModel(mode: mode), backend: nil, store: store, credentials: credentials)
        if mode == .live {
            // Built once here and kept on `environment.liveTransport` so
            // chunk 09's `LiveRouterBackend` can reuse it instead of building
            // its own; mock mode never reaches this branch.
            environment.liveTransport = transportFactory()
            environment.transportFactoryWasUsed = true
        }
        return environment
    }
}

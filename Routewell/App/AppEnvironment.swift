import Foundation
import RoutewellKit
#if DEBUG
import RoutewellMock
#endif

@MainActor
final class AppEnvironment {
    let model: AppModel
    let refresh: RefreshController
    private var setup: Task<Void, Never>?
    #if DEBUG
    private var mockBackend: MockRouterBackend?
    #endif

    static let mockProfiles = ["Home mock", "Travel mock"]
    static let mockScenarios = ["healthy", "partial", "offline", "stale", "slow"]

    init(model: AppModel, backend: (any RouterBackend)?) {
        self.model = model
        self.refresh = RefreshController(model: model)
        #if DEBUG
        mockBackend = backend as? MockRouterBackend
        #endif
        if let backend {
            setup = model.session.switchProfile(Self.mockProfiles[0], model: model, refresh: refresh) {
                SessionLease(token: $0, backend: backend)
            }
        }
    }

    func waitUntilReady() async { await setup?.value }

    func switchMockProfile(_ profile: String) {
        #if DEBUG
        guard model.mode == .mock, Self.mockProfiles.contains(profile) else { return }
        installMock(profile: profile, scenarioID: model.mockScenarioID)
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

    static func configured(variables: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        #if DEBUG
        let allowsMock = true
        #else
        let allowsMock = false
        #endif
        let mode = BackendMode.resolve(variables["ROUTEWELL_BACKEND"], allowsMock: allowsMock)
        #if DEBUG
        if mode == .mock {
            return AppEnvironment(model: AppModel(mode: mode), backend: MockRouterBackend())
        }
        #endif
        return AppEnvironment(model: AppModel(mode: mode), backend: nil)
    }
}

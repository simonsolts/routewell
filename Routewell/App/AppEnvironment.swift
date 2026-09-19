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

    static let mockProfiles = ["Home mock", "Travel mock"]

    init(model: AppModel, backend: (any RouterBackend)?) {
        self.model = model
        self.refresh = RefreshController(model: model)
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
        let hostname = profile == Self.mockProfiles[0] ? "flint-demo" : "travel-demo"
        setup = model.session.switchProfile(profile, model: model, refresh: refresh) {
            SessionLease(token: $0, backend: MockRouterBackend(hostname: hostname))
        }
        #endif
    }

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

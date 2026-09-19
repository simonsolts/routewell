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

/// Manual refresh only in this increment. App-owned so reopening cannot duplicate it.
@MainActor
final class RefreshController {
    private let model: AppModel
    private var task: Task<Void, Never>?

    var isAvailable: Bool { model.session.isReady }

    init(model: AppModel) {
        self.model = model
    }

    func cancelForSwitch() {
        task?.cancel()
        task = nil
    }

    func loadIfNeeded() {
        if model.snapshot == nil { refreshNow() }
    }

    @discardableResult
    func refreshNow() -> Task<Void, Never>? {
        if let task { return task }
        guard isAvailable, let lease = model.session.lease else { return nil }
        let delay = model.slowMockRefresh
        model.accept(.busy(true), token: lease.token)
        task = Task {
            defer {
                model.accept(.busy(false), token: lease.token)
                if model.session.expectedToken == lease.token { task = nil }
            }
            do {
                if delay { try await Task.sleep(for: .seconds(5)) }
                let snapshot = try await model.session.routerSession.overview(using: lease)
                model.accept(.snapshot(snapshot), token: lease.token)
            } catch is CancellationError {
                // Cancellation isn't a connection failure.
            } catch {
                model.accept(.failure, token: lease.token)
            }
        }
        return task
    }

    func waitForRefresh() async { await task?.value }
}

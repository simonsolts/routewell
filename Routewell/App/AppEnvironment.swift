import Foundation
import RoutewellKit
#if DEBUG
import RoutewellMock
#endif

@MainActor
final class AppEnvironment {
    let model: AppModel
    let refresh: RefreshController

    init(model: AppModel, backend: (any RouterBackend)?) {
        self.model = model
        self.refresh = RefreshController(model: model, backend: backend)
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
    private let backend: (any RouterBackend)?
    private var task: Task<Void, Never>?

    var isAvailable: Bool { backend != nil }

    init(model: AppModel, backend: (any RouterBackend)?) {
        self.model = model
        self.backend = backend
    }

    func loadIfNeeded() {
        if model.snapshot == nil { refreshNow() }
    }

    func refreshNow() {
        guard task == nil, let backend else { return }
        model.isRefreshing = true
        model.refreshFailed = false
        task = Task {
            defer {
                model.isRefreshing = false
                task = nil
            }
            do {
                let snapshot = try await backend.overview()
                try Task.checkCancellation()
                model.snapshot = snapshot
            } catch is CancellationError {
                // Cancellation isn't a connection failure.
            } catch {
                model.refreshFailed = true
            }
        }
    }

    func waitForRefresh() async { await task?.value }
}

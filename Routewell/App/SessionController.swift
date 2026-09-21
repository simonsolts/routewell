import Observation
import RoutewellKit

@MainActor @Observable
final class SessionController {
    private(set) var expectedToken: SessionToken?
    private(set) var switching = false
    private(set) var lease: SessionLease?
    private(set) var setupFailed = false
    let routerSession = RouterSession()
    private var revision: UInt64 = 0

    var isReady: Bool { !switching && lease?.token == expectedToken && lease != nil }

    func disconnect(model: AppModel, refresh: RefreshController) {
        revision += 1
        expectedToken = nil
        lease = nil
        switching = false
        setupFailed = false
        refresh.cancelForSwitch()
        model.clearSession()
    }

    @discardableResult
    func switchProfile(
        _ profileID: String, model: AppModel, refresh: RefreshController,
        build: @escaping @Sendable (SessionToken) async throws -> SessionLease
    ) -> Task<Void, Never> {
        // Invalidate presentation and cancel old work before the first suspension.
        revision += 1
        let token = SessionToken(profileID: profileID, revision: revision)
        expectedToken = token
        switching = true
        lease = nil
        setupFailed = false
        model.clearSession()
        refresh.cancelForSwitch()
        return Task {
            do {
                try await routerSession.beginRevision(token)
                let candidate = try await build(token)
                guard expectedToken == token else { return }
                try await routerSession.installLease(candidate)
                guard expectedToken == token else { return }
                lease = candidate
                switching = false
                refresh.sessionReady()
            } catch {
                guard expectedToken == token else { return }
                switching = false
                setupFailed = true
            }
        }
    }
}

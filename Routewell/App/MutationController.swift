import Foundation
import Observation
import RoutewellKit

/// Runs one Protection mutation at a time against the active session lease.
/// Owns the UI-facing `inFlight`/`lastReport` state for `ProtectionScreen`;
/// also applies each report to `AppModel` (gated by session token there) so
/// other screens can see the last attempt.
@MainActor @Observable
final class MutationController {
    private let model: AppModel
    private let refresh: RefreshController
    private(set) var inFlight: ProtectionIntent?
    private(set) var lastReport: MutationReport<ProtectionState>?

    init(model: AppModel, refresh: RefreshController) {
        self.model = model
        self.refresh = refresh
    }

    /// Never restores a pause with a guessed remaining time: recovery is
    /// only meaningful for the reversible enable/disable setting.
    func setProtection(_ intent: ProtectionIntent) {
        guard inFlight == nil else { return }
        guard let lease = model.session.lease else { return }
        let allowRecovery: Bool
        switch intent {
        case .enable, .disable: allowRecovery = true
        case .pause: allowRecovery = false
        }
        inFlight = intent
        Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            let report: MutationReport<ProtectionState>
            do {
                report = try await self.model.session.routerSession.setProtection(
                    using: lease, intent: intent, allowRecovery: allowRecovery
                )
            } catch {
                // A stale lease after completion: the write may have
                // happened, but the caller must never re-send. Displayed
                // exactly like `.rejected(.staleSession)`.
                report = MutationReport(
                    outcome: .rejected(.staleSession),
                    dispatched: false, startedAt: startedAt, finishedAt: Date(), failure: nil
                )
            }
            self.lastReport = report
            self.model.accept(.mutation(report), token: lease.token)
            self.inFlight = nil
            if case .rejected = report.outcome {
                // A rejected op made no write; nothing changed to refresh.
            } else {
                self.refresh.refreshNow()
            }
        }
    }
}

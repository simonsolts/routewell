import Foundation
import Observation
import RoutewellKit

/// AdGuard Home › Instance: the backups of AdGuard Home's config for the
/// selected router, Back Up Now, Export…, Restore…, and the Data section's
/// writes. Backups are read and restored over SSH.
@MainActor @Observable
final class AdGuardInstanceController {
    enum Activity: Equatable { case backingUp, restoring }

    private let model: AppModel
    private let adGuard: AdGuardController
    private let refresh: RefreshController
    private let store: AdGuardBackupStore
    @ObservationIgnored var profileID: () -> UUID? = { nil }

    private(set) var backups: [AdGuardBackup] = []
    private var loadedProfile: UUID?
    var selection: AdGuardBackup.ID?
    private(set) var activity: Activity?
    /// The last backup or restore problem; `nil` after a success.
    private(set) var message: String?

    init(model: AppModel, adGuard: AdGuardController, refresh: RefreshController, store: AdGuardBackupStore) {
        self.model = model
        self.adGuard = adGuard
        self.refresh = refresh
        self.store = store
    }

    /// Another router: its list is not this one's.
    func reset() {
        backups = []
        loadedProfile = nil
        selection = nil
        message = nil
    }

    /// Start Setup Again: the backups go with the router.
    func removeBackups(profile: UUID) async {
        await store.remove(profile: profile)
        if profile == profileID() || profileID() == nil { reset() }
    }

    /// Reads the list once per router, and again after each change.
    func load(force: Bool = false) async {
        guard let profile = profileID(), force || loadedProfile != profile else { return }
        let list = await store.backups(for: profile)
        guard profile == profileID() else { return }
        backups = list
        loadedProfile = profile
    }

    var selected: AdGuardBackup? { backups.first { $0.id == selection } }

    /// Back up and restore need SSH, a running AdGuard Home, and no other write.
    var canChange: Bool {
        model.sshConfigured && adGuard.availability == .running && activity == nil && !adGuard.isWriting && model.session.isReady
    }

    func backUp() {
        guard canChange, let lease = model.session.lease, let profile = profileID() else { return }
        let availability = adGuard.availability
        let version = adGuard.status?.version
        activity = .backingUp
        message = nil
        Task {
            defer { self.activity = nil }
            guard let result = try? await self.model.session.routerSession.readAdGuardConfig(using: lease, availability: availability),
                  lease.token == self.model.session.expectedToken else { return }
            switch result {
            case .success(let file):
                do {
                    let backup = try await self.store.save(file, kind: .manual, version: version, for: profile)
                    await self.load(force: true)
                    self.selection = backup.id
                } catch {
                    self.message = AdGuardInstancePresentation.notSaved
                }
            case .failure(let failure):
                self.message = AdGuardInstancePresentation.backupFailureText(failure)
            }
        }
    }

    /// Export…: `false` when the copy could not be written.
    func export(_ backup: AdGuardBackup, to destination: URL) async -> Bool {
        guard let profile = profileID() else { return false }
        do {
            try await store.export(backup, for: profile, to: destination)
            return true
        } catch {
            message = AdGuardInstancePresentation.exportFailed
            return false
        }
    }

    func restore(_ backup: AdGuardBackup) {
        guard canChange, let lease = model.session.lease, let profile = profileID() else { return }
        let store = store
        let availability = adGuard.availability
        let version = adGuard.status?.version
        activity = .restoring
        message = nil
        Task {
            defer { self.activity = nil }
            let file: AdGuardConfigFile
            do {
                file = try await store.file(backup, for: profile)
            } catch {
                self.message = AdGuardInstancePresentation.backupMissing
                return
            }
            let report: MutationReport<AdGuardRestoreState>
            do {
                report = try await self.model.session.routerSession.restoreAdGuardConfig(
                    using: lease, file: file, availability: availability
                ) { current in
                    (try? await store.save(current, kind: .beforeRestore, version: version, for: profile)) != nil
                }
            } catch {
                // The session changed: the new session reads AdGuard Home afresh.
                return
            }
            await self.load(force: true)
            guard lease.token == self.model.session.expectedToken else { return }
            self.message = AdGuardInstancePresentation.restoreText(report.outcome)
            self.refresh.refreshNow()
        }
    }

    // MARK: Data

    func setRetention(_ kind: AdGuardDataKind, milliseconds: Int) {
        adGuard.runSetting(.retention(kind, milliseconds: milliseconds))
    }

    func clear(_ kind: AdGuardDataKind) {
        adGuard.runSetting(.clearData(kind))
    }
}

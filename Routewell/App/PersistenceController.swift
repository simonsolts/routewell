import Foundation
import Observation
import RoutewellKit

@MainActor @Observable
final class PersistenceController {
    private(set) var profiles: ProfileSettings
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var errors: [StoreFile: String] = [:]
    private(set) var recoveryNotice: String?
    private(set) var credentialMessage: String?
    private(set) var credentialBusy = false
    private let store: AtomicJSONStore?
    private let credentials: any CredentialStore
    private let model: AppModel
    private var revision: UInt64 = 0
    private var pending: Task<Void, Never>?

    var selectedProfile: RouterProfile? { profiles.profiles.first { $0.id == profiles.selectedID } }
    var status: String {
        if isLoading { return "Loading saved settings…" }
        if !errors.isEmpty { return errors.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value).joined(separator: " ") }
        if isSaving { return "Saving…" }
        return store == nil ? "Settings are temporary in this preview or test." : "Settings and profiles saved on this Mac."
    }

    init(model: AppModel, store: AtomicJSONStore?, credentials: any CredentialStore) {
        self.model = model
        self.store = store
        self.credentials = credentials
        profiles = ProfileSettings(profiles: AppEnvironment.mockProfiles.enumerated().map {
            RouterProfile(name: $0.element, endpoint: "mock://\($0.offset == 0 ? "home" : "travel")")
        })
    }

    func load() async {
        if let store {
            do {
                if let saved = try await store.load(AppSettings.self, from: .settings) {
                    model.showInMenuBar = saved.showInMenuBar
                    model.refreshIntervalSeconds = [15, 30, 60].contains(saved.refreshIntervalSeconds) ? saved.refreshIntervalSeconds : 30
                    model.pauseWhenHidden = saved.pauseWhenHidden
                    model.showStatusBar = saved.showStatusBar
                }
            } catch { report(error, file: .settings) }
            do {
                if let saved = try await store.load(ProfileSettings.self, from: .profiles) {
                    profiles = saved
                    if !saved.profiles.contains(where: { $0.id == saved.selectedID }) {
                        profiles.selectedID = saved.profiles.first?.id
                    }
                }
            } catch { report(error, file: .profiles) }
        }
        isLoading = false
        model.persistenceSettingsChanged = { [weak self] in self?.scheduleSave() }
        // Persist initial profile IDs before any credential can be created.
        await flush()
    }

    func select(_ id: UUID) {
        guard !credentialBusy, profiles.profiles.contains(where: { $0.id == id }) else { return }
        profiles.selectedID = id
        credentialMessage = nil
        scheduleSave()
    }

    func addMockProfile() {
        guard !credentialBusy else { return }
        let id = UUID()
        let profile = RouterProfile(id: id, name: "Mock \(profiles.profiles.count + 1)", endpoint: "mock://\(id.uuidString.lowercased())")
        profiles.profiles.append(profile)
        profiles.selectedID = id
        credentialMessage = nil
        scheduleSave()
    }

    /// Saves the password first, then appends, selects, and persists the
    /// profile. If the credential save fails, nothing is added: a selected
    /// live profile must never exist without its password, or the next
    /// launch would treat the router as configured with no way to reach it.
    @discardableResult
    func addLiveProfile(_ profile: RouterProfile, password: Data) async -> Bool {
        guard !credentialBusy else { return false }
        credentialBusy = true
        defer { credentialBusy = false }
        credentialMessage = nil
        do {
            try await credentials.save(password, for: profile.credential)
        } catch {
            credentialMessage = credentialError(error)
            return false
        }
        profiles.profiles.append(profile)
        profiles.selectedID = profile.id
        await flush()
        guard errors[.profiles] == nil else {
            credentialMessage = "Router password saved, but the router could not be saved. Try again."
            return false
        }
        credentialMessage = "Router password saved in Keychain."
        return true
    }

    @discardableResult
    func deleteSelectedProfile() async -> Bool {
        guard let profile = selectedProfile, !credentialBusy else { return false }
        credentialBusy = true
        defer { credentialBusy = false }
        do {
            // If JSON fails afterwards, retrying deletion is safe: Keychain delete is idempotent.
            try await credentials.delete(profile.credential)
            profiles.profiles.removeAll { $0.id == profile.id }
            profiles.selectedID = profiles.profiles.first?.id
            credentialMessage = "Mock profile credentials removed."
            await flush()
            return true
        } catch { credentialMessage = credentialError(error); return false }
    }

    enum CredentialAction { case save(Data), check, delete }
    func credential(_ action: CredentialAction) async {
        guard let profile = selectedProfile, !credentialBusy else { return }
        credentialBusy = true
        defer { credentialBusy = false }
        do {
            switch action {
            case .save(let data):
                await flush()
                guard errors[.profiles] == nil else {
                    credentialMessage = "Save the profile successfully before storing its mock credential."
                    return
                }
                try await credentials.save(data, for: profile.credential)
                credentialMessage = "Mock credential saved in Keychain."
            case .check:
                _ = try await credentials.read(profile.credential)
                credentialMessage = "Mock credential is present in Keychain."
            case .delete:
                try await credentials.delete(profile.credential)
                credentialMessage = "Mock credential deleted."
            }
        } catch { credentialMessage = credentialError(error) }
    }

    /// Re-parses and saves a new address for the selected live profile. The
    /// address is part of the profile's credential reference, so the stored
    /// secret is migrated to the new reference before the old one is removed.
    /// Mirrors `addLiveProfile`'s ordering: the new credential is saved and
    /// the in-memory profile is updated before `flush()`; the old credential
    /// is only deleted after a successful flush, and a failed flush restores
    /// the in-memory profile and best-effort removes the new credential, so
    /// the on-disk profile never points at a deleted credential.
    @discardableResult
    func updateLiveAddress(_ endpoint: RouterEndpoint) async -> Bool {
        guard let old = selectedProfile, old.liveEndpoint != nil, !credentialBusy,
              let index = profiles.profiles.firstIndex(where: { $0.id == old.id }) else { return false }
        credentialBusy = true
        defer { credentialBusy = false }
        let rebuilt = RouterProfile(
            id: old.id, name: old.name, liveEndpoint: endpoint, username: old.username,
            plainHTTPAcknowledged: old.plainHTTPAcknowledged, adGuard: old.adGuard, ssh: old.ssh
        )
        do {
            let secret = try await credentials.read(old.credential)
            try await credentials.save(secret, for: rebuilt.credential)
        } catch {
            credentialMessage = credentialError(error)
            return false
        }
        profiles.profiles[index] = rebuilt
        await flush()
        guard errors[.profiles] == nil else {
            profiles.profiles[index] = old
            try? await credentials.delete(rebuilt.credential)
            credentialMessage = "Router address could not be saved. Try again."
            return false
        }
        try? await credentials.delete(old.credential)
        return true
    }

    func updateLiveUsername(_ username: String) {
        guard var profile = selectedProfile, profile.liveEndpoint != nil,
              let index = profiles.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profile.username = username
        profiles.profiles[index] = profile
        scheduleSave()
    }

    func updateAdGuardSettings(_ settings: AdGuardSettings) {
        guard var profile = selectedProfile, profile.liveEndpoint != nil,
              let index = profiles.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profile.adGuard = settings
        profiles.profiles[index] = profile
        scheduleSave()
    }

    @discardableResult
    func changeLivePassword(_ password: Data) async -> Bool {
        guard let profile = selectedProfile, profile.liveEndpoint != nil, !credentialBusy else { return false }
        credentialBusy = true
        defer { credentialBusy = false }
        do {
            try await credentials.save(password, for: profile.credential)
            credentialMessage = "Router password updated in Keychain."
            return true
        } catch {
            credentialMessage = credentialError(error)
            return false
        }
    }

    func scheduleSave() {
        guard !isLoading else { return }
        pending?.cancel()
        revision += 1
        isSaving = store != nil
        let current = revision
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            await self.save(revision: current)
        }
    }

    func flush() async {
        guard !isLoading else { return }
        pending?.cancel()
        revision += 1
        await save(revision: revision)
    }

    private func save(revision current: UInt64) async {
        guard let store else { isSaving = false; return }
        let settings = model.persistedSettings
        let profiles = profiles
        isSaving = true
        // `.trust` is owned by `TrustController`, which writes through
        // `PersistentEndpointTrustStore` directly with its own revision.
        for file: StoreFile in [.settings, .profiles] {
            do {
                switch file {
                case .settings: try await store.save(settings, to: file, revision: current)
                case .profiles: try await store.save(profiles, to: file, revision: current)
                case .trust: break
                }
                if current == revision { errors[file] = nil }
            } catch { if current == revision { report(error, file: file) } }
        }
        if current == revision { isSaving = false }
    }

    private func report(_ error: any Error, file: StoreFile) {
        let name = file.rawValue.capitalized
        switch error as? StoreError {
        case .corrupt:
            recoveryNotice = "Damaged \(file.rawValue) were preserved in a recovery file. Defaults are now in use."
        case .futureSchema:
            errors[file] = "\(name) were written by a newer app. The original file is untouched; changes cannot be saved."
        default:
            errors[file] = "\(name) could not be read or saved. Changes may be temporary. Check storage access and retry."
        }
    }

    private func credentialError(_ error: any Error) -> String {
        (error as? CredentialError ?? .unexpected).message
    }
}

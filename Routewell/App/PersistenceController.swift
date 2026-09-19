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
        for file in StoreFile.allCases {
            do {
                switch file {
                case .settings: try await store.save(settings, to: file, revision: current)
                case .profiles: try await store.save(profiles, to: file, revision: current)
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

import Foundation
import Testing
import RoutewellKit
@testable import Routewell

@MainActor @Test func settingsAndProfilesSurviveRelaunchWithoutSecretsInJSON() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = InMemoryCredentialStore()
    let model = AppModel(mode: .mock)
    let persistence = PersistenceController(model: model, store: AtomicJSONStore(directory: directory), credentials: fake)
    await persistence.load()
    model.showInMenuBar = false
    model.refreshIntervalSeconds = 15
    model.refreshIntervalSeconds = 60
    model.pauseWhenHidden = false
    model.showStatusBar = false
    persistence.addMockProfile()
    let selected = try #require(persistence.selectedProfile)
    let secret = Data("CANARY-never-in-JSON".utf8)
    await persistence.credential(.save(secret))
    await persistence.flush()
    let restoredModel = AppModel(mode: .mock)
    let restored = PersistenceController(model: restoredModel, store: AtomicJSONStore(directory: directory), credentials: fake)
    await restored.load()
    #expect(restoredModel.persistedSettings == model.persistedSettings)
    #expect(restored.selectedProfile == selected)
    #expect(try await fake.read(selected.credential) == secret)
    for file in ["settings.json", "profiles.json"] {
        #expect(!(try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)).contains("CANARY"))
    }
    #expect(await restored.deleteSelectedProfile())
    await #expect(throws: CredentialError.missing) { try await fake.read(selected.credential) }
}

@MainActor @Test func profileDeletionFailureKeepsProfileAndOtherCredentials() async throws {
    let fake = InMemoryCredentialStore()
    let persistence = PersistenceController(model: AppModel(mode: .mock), store: nil, credentials: fake)
    await persistence.load()
    let selected = try #require(persistence.selectedProfile)
    let unrelated = CredentialReference(profileID: selected.id, endpoint: "mock://unrelated")
    try await fake.save(Data("keep".utf8), for: unrelated)
    await fake.setFailure(.accessDenied)
    #expect(await persistence.deleteSelectedProfile() == false)
    #expect(persistence.selectedProfile == selected)
    #expect(persistence.credentialMessage == CredentialError.accessDenied.message)
    await fake.setFailure(nil)
    #expect(await persistence.deleteSelectedProfile())
    #expect(try await fake.read(unrelated) == Data("keep".utf8))
}

@MainActor @Test(arguments: CredentialError.allCases) func credentialErrorsHaveSafeUIMessage(error: CredentialError) async {
    let fake = InMemoryCredentialStore()
    let persistence = PersistenceController(model: AppModel(mode: .mock), store: nil, credentials: fake)
    await persistence.load()
    await fake.setFailure(error)
    await persistence.credential(.check)
    #expect(persistence.credentialMessage == error.message)
    #expect(!persistence.credentialBusy)
}

@MainActor @Test func failedCredentialSaveAddsNoLiveProfile() async throws {
    let fake = InMemoryCredentialStore()
    let persistence = PersistenceController(model: AppModel(mode: .live), store: nil, credentials: fake)
    await persistence.load()
    let countBefore = persistence.profiles.profiles.count
    let selectedBefore = persistence.selectedProfile
    await fake.setFailure(.accessDenied)
    let endpoint = try RouterEndpoint.parse("192.168.8.1")
    let profile = RouterProfile(name: endpoint.displayString, liveEndpoint: endpoint)
    let saved = await persistence.addLiveProfile(profile, password: Data("secret".utf8))
    #expect(!saved)
    #expect(persistence.profiles.profiles.count == countBefore)
    #expect(!persistence.profiles.profiles.contains { $0.id == profile.id })
    #expect(persistence.selectedProfile == selectedBefore)
    #expect(persistence.credentialMessage == CredentialError.accessDenied.message)
    await fake.setFailure(nil)
    await #expect(throws: CredentialError.missing) { try await fake.read(profile.credential) }
}

@MainActor @Test func updateLiveAddressFailureRestoresProfileAndKeepsOldCredential() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = InMemoryCredentialStore()
    let failSwitch = FlushFailSwitch()
    let store = AtomicJSONStore(directory: directory, beforeCommit: {
        if failSwitch.shouldFail { throw StoreError.writeFailed }
    })
    let persistence = PersistenceController(model: AppModel(mode: .live), store: store, credentials: fake)
    await persistence.load()
    let oldEndpoint = try RouterEndpoint.parse("192.168.8.1")
    let profile = RouterProfile(name: oldEndpoint.displayString, liveEndpoint: oldEndpoint)
    let secret = Data("old-secret".utf8)
    #expect(await persistence.addLiveProfile(profile, password: secret))
    let selected = try #require(persistence.selectedProfile)

    failSwitch.shouldFail = true
    let newEndpoint = try RouterEndpoint.parse("192.168.8.2")
    let updated = await persistence.updateLiveAddress(newEndpoint)

    #expect(!updated)
    #expect(persistence.selectedProfile == selected)
    #expect(try await fake.read(selected.credential) == secret)
    await #expect(throws: CredentialError.missing) { try await fake.read(RouterProfile(
        id: selected.id, name: selected.name, liveEndpoint: newEndpoint
    ).credential) }
}

private final class FlushFailSwitch: @unchecked Sendable {
    var shouldFail = false
}

@MainActor @Test func persistenceFailureIsVisibleAndPreventsOrphanCredential() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fake = InMemoryCredentialStore()
    let store = AtomicJSONStore(directory: directory, beforeCommit: { throw StoreError.writeFailed })
    let persistence = PersistenceController(model: AppModel(mode: .mock), store: store, credentials: fake)
    await persistence.load()
    #expect(!persistence.errors.isEmpty)
    await persistence.credential(.save(Data("must-not-save".utf8)))
    let selected = try #require(persistence.selectedProfile)
    await #expect(throws: CredentialError.missing) { try await fake.read(selected.credential) }
    #expect(!persistence.isSaving)
}

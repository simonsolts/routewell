import Foundation
import Testing
@testable import RoutewellKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("routewell-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func firstSaveReplaceAndRelaunch() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AtomicJSONStore(directory: directory)
    #expect(try await store.load(AppSettings.self, from: .settings) == nil)
    var settings = AppSettings()
    try await store.save(settings, to: .settings, revision: 1)
    settings.refreshIntervalSeconds = 60
    try await store.save(settings, to: .settings, revision: 2)
    let relaunched = AtomicJSONStore(directory: directory)
    #expect(try await relaunched.load(AppSettings.self, from: .settings) == settings)
}

@Test func concurrentWritesKeepNewestRevision() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AtomicJSONStore(directory: directory)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for revision in 1...100 {
            group.addTask { try await store.save(revision, to: .settings, revision: UInt64(revision)) }
        }
        try await group.waitForAll()
    }
    #expect(try await store.load(Int.self, from: .settings) == 100)
    #expect(try await store.save(0, to: .settings, revision: 1) == false)
}

@Test func malformedJSONPreservesOriginalForRecovery() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data("broken-original".utf8)
    try bytes.write(to: directory.appendingPathComponent("settings.json"))
    let store = AtomicJSONStore(directory: directory)
    await #expect(throws: StoreError.corrupt) { try await store.load(AppSettings.self, from: .settings) }
    try await store.save(AppSettings(), to: .settings, revision: 1)
    let recovery = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("recovery") })
    #expect(try Data(contentsOf: recovery) == bytes)
}

@Test func futureSchemaIsNeverOverwritten() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("settings.json")
    let bytes = Data(#"{"version":999,"value":{"future":true}}"#.utf8)
    try bytes.write(to: target)
    let store = AtomicJSONStore(directory: directory)
    await #expect(throws: StoreError.futureSchema) { try await store.load(AppSettings.self, from: .settings) }
    await #expect(throws: StoreError.futureSchema) { try await store.save(AppSettings(), to: .settings, revision: 1) }
    #expect(try Data(contentsOf: target) == bytes)
}

@Test func failedWriteKeepsOldDataAndCleansTemporaryFile() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await AtomicJSONStore(directory: directory).save(1, to: .settings, revision: 1)
    let store = AtomicJSONStore(directory: directory, beforeCommit: { throw StoreError.writeFailed })
    await #expect(throws: StoreError.writeFailed) { try await store.save(2, to: .settings, revision: 2) }
    #expect(try await store.load(Int.self, from: .settings) == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["settings.json"])
}

@Test func orphanTemporaryFileIsIgnoredAndCleaned() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let orphan = directory.appendingPathComponent(".settings-orphan.tmp")
    try Data("partial".utf8).write(to: orphan)
    let store = AtomicJSONStore(directory: directory)
    #expect(try await store.load(Int.self, from: .settings) == nil)
    try await store.save(42, to: .settings, revision: 1)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(try await store.load(Int.self, from: .settings) == 42)
}

@Test func credentialsAreIsolatedByProfileAndEndpoint() async throws {
    let store = InMemoryCredentialStore()
    let first = CredentialReference(profileID: UUID(), endpoint: "mock://first")
    let otherEndpoint = CredentialReference(profileID: first.profileID, endpoint: "mock://other")
    let otherProfile = CredentialReference(profileID: UUID(), endpoint: first.endpoint)
    for reference in [first, otherEndpoint, otherProfile] { try await store.save(Data("initial".utf8), for: reference) }
    try await store.save(Data("updated".utf8), for: first)
    #expect(try await store.read(first) == Data("updated".utf8))
    try await store.delete(first)
    try await store.delete(first)
    await #expect(throws: CredentialError.missing) { try await store.read(first) }
    for reference in [otherEndpoint, otherProfile] { #expect(try await store.read(reference) == Data("initial".utf8)) }
}

@Test(arguments: CredentialError.allCases) func fakeCredentialFailures(error: CredentialError) async {
    let store = InMemoryCredentialStore()
    await store.setFailure(error)
    let reference = CredentialReference(profileID: UUID(), endpoint: "mock://test")
    await #expect(throws: error) { try await store.read(reference) }
    await #expect(throws: error) { try await store.save(Data(), for: reference) }
    await #expect(throws: error) { try await store.delete(reference) }
}

@Test func oldShapeProfileJSONDecodesWithDefaults() throws {
    let id = UUID()
    let json = """
    {
        "id": "\(id.uuidString)",
        "name": "Home mock",
        "endpoint": "mock://home",
        "credential": {"profileID": "\(id.uuidString)", "endpoint": "mock://home", "kind": "mockPassword"}
    }
    """
    let profile = try JSONDecoder().decode(RouterProfile.self, from: Data(json.utf8))
    #expect(profile.id == id)
    #expect(profile.name == "Home mock")
    #expect(profile.endpoint == "mock://home")
    #expect(profile.liveEndpoint == nil)
    #expect(profile.username == "admin")
    #expect(profile.plainHTTPAcknowledged == false)
    #expect(profile.adGuard == nil)
    #expect(profile.ssh == nil)
}

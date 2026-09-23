import Foundation
import Synchronization
import Testing
@testable import RoutewellKit

@Suite struct DeviceRegistryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func client(_ suffix: Int, online: Bool = true, ip: String? = nil) -> Client {
        Client(mac: MACAddress(String(format: "AA:00:00:00:00:%02X", suffix))!, ip: ip, hostname: "device-\(suffix)", online: .value(online))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("routewell-registry-\(UUID().uuidString)")
    }

    @Test func firstListIsBaselineWithoutEvents() async throws {
        let registry = DeviceRegistry(store: nil)
        let first = try await registry.observe([client(1), client(2, online: false)], at: start)
        #expect(first.baselineEstablished)
        #expect(first.newDevices.isEmpty)
        #expect(first.state.records.count == 2)
        #expect(first.state.awaitingReview.isEmpty)
        #expect(first.state.records[client(2).mac]?.lastSeen == nil)
        #expect(first.state.records[client(1).mac]?.lastSeen == start)
    }

    @Test func emptyListDoesNotSetTheBaseline() async throws {
        let registry = DeviceRegistry(store: nil)
        let empty = try await registry.observe([], at: start)
        #expect(!empty.state.baselineEstablished)
        let first = try await registry.observe([client(1)], at: start)
        #expect(first.baselineEstablished)
        #expect(first.newDevices.isEmpty)
    }

    @Test func eachNeverSeenMACProducesExactlyOneEvent() async throws {
        let registry = DeviceRegistry(store: nil)
        _ = try await registry.observe([client(1)], at: start)
        let second = try await registry.observe([client(1), client(2), client(3, online: false)], at: start.addingTimeInterval(30))
        #expect(second.newDevices.map(\.mac) == [client(2).mac, client(3).mac])
        #expect(second.state.awaitingReview.count == 2)
        let third = try await registry.observe([client(1), client(2), client(3)], at: start.addingTimeInterval(60))
        #expect(third.newDevices.isEmpty)
        // Leaving and coming back is not new either.
        _ = try await registry.observe([client(1)], at: start.addingTimeInterval(90))
        let fifth = try await registry.observe([client(1), client(2)], at: start.addingTimeInterval(120))
        #expect(fifth.newDevices.isEmpty)
    }

    /// The registry is on disk before an event is returned. A failed save
    /// returns no event and keeps the MAC unseen, so it is reported once later.
    @Test func registrySavesBeforeTheEventFires() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failNextCommit = LockedFlag()
        let store = AtomicJSONStore(directory: directory) {
            if failNextCommit.take() { throw CocoaError(.fileWriteUnknown) }
        }
        let registry = DeviceRegistry(store: store)
        _ = try await registry.observe([client(1)], at: start)

        failNextCommit.set()
        let failed = try await registry.observe([client(1), client(2)], at: start.addingTimeInterval(30))
        #expect(failed.newDevices.isEmpty)
        #expect(failed.saveFailure == .writeFailed)
        #expect(failed.state.records[client(2).mac] == nil)

        let saved = try await registry.observe([client(1), client(2)], at: start.addingTimeInterval(60))
        #expect(saved.newDevices.map(\.mac) == [client(2).mac])
        // What the event reports is already in devices.json.
        let reloaded = try await AtomicJSONStore(directory: directory).load(DeviceRegistryState.self, from: .devices)
        #expect(reloaded?.records[client(2).mac]?.awaitingReview == true)
    }

    @Test func restartAfterAnEventDoesNotRepeatIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = DeviceRegistry(store: AtomicJSONStore(directory: directory))
        _ = try await registry.observe([client(1)], at: start)
        let event = try await registry.observe([client(1), client(2)], at: start.addingTimeInterval(30))
        #expect(event.newDevices.count == 1)

        let restarted = DeviceRegistry(store: AtomicJSONStore(directory: directory))
        #expect(await restarted.load() == .loaded)
        let after = try await restarted.observe([client(1), client(2)], at: start.addingTimeInterval(60))
        #expect(after.newDevices.isEmpty)
        #expect(after.state.awaitingReview.map(\.mac) == [client(2).mac])
    }

    @Test func markReviewedClearsTheFlagAndPersists() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = DeviceRegistry(store: AtomicJSONStore(directory: directory))
        _ = try await registry.observe([client(1)], at: start)
        _ = try await registry.observe([client(1), client(2)], at: start.addingTimeInterval(30))
        #expect(await registry.markReviewed(client(2).mac))
        #expect(await registry.snapshot().awaitingReview.isEmpty)
        let restarted = DeviceRegistry(store: AtomicJSONStore(directory: directory))
        _ = await restarted.load()
        #expect(await restarted.snapshot().awaitingReview.isEmpty)
    }

    @Test func lastSeenIsSavedAtMostEveryInterval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commits = LockedCounter()
        let store = AtomicJSONStore(directory: directory) { commits.increment() }
        let registry = DeviceRegistry(store: store, lastSeenSaveInterval: 600)
        _ = try await registry.observe([client(1)], at: start)
        #expect(commits.value == 1)
        _ = try await registry.observe([client(1)], at: start.addingTimeInterval(30))
        #expect(commits.value == 1)
        #expect(await registry.snapshot().records[client(1).mac]?.lastSeen == start.addingTimeInterval(30))
        _ = try await registry.observe([client(1)], at: start.addingTimeInterval(700))
        #expect(commits.value == 2)
        _ = try await registry.observe([client(1, ip: "198.51.100.9")], at: start.addingTimeInterval(710))
        #expect(commits.value == 3)
    }

    @Test func futureSchemaBlocksSavingAndEvents() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"value":{}}"#.utf8).write(to: directory.appendingPathComponent("devices.json"))
        let registry = DeviceRegistry(store: AtomicJSONStore(directory: directory))
        #expect(await registry.load() == .blocked(.futureSchema))
        let observed = try await registry.observe([client(1)], at: start)
        #expect(observed.saveFailure == .futureSchema)
        #expect(!observed.state.baselineEstablished)
    }

    @Test func recordDecodingToleratesMissingAndUnknownFields() throws {
        let json = #"{"baselineEstablished":true,"records":[{"mac":"aa:00:00:00:00:01","firstSeen":0,"category":"toaster"}]}"#
        let state = try JSONDecoder().decode(DeviceRegistryState.self, from: Data(json.utf8))
        let record = try #require(state.records[MACAddress("AA0000000001")!])
        #expect(record.category == nil)
        #expect(!record.favourite && !record.awaitingReview && record.notes.isEmpty)
        let encoded = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(DeviceRegistryState.self, from: encoded) == state)
    }
}

final class LockedFlag: Sendable {
    private let state = Mutex(false)
    func set() { state.withLock { $0 = true } }
    func take() -> Bool { state.withLock { value in defer { value = false }; return value } }
}

final class LockedCounter: Sendable {
    private let state = Mutex(0)
    func increment() { state.withLock { $0 += 1 } }
    var value: Int { state.withLock { $0 } }
}

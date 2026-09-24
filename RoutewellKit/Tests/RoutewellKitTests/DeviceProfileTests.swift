import Foundation
import Testing
@testable import RoutewellKit

@Suite struct DeviceProfileTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let device = MACAddress("AA:00:00:00:00:01")!

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("routewell-profile-\(UUID().uuidString)")
    }

    private func knownRegistry(store: AtomicJSONStore?) async throws -> DeviceRegistry {
        let registry = DeviceRegistry(store: store)
        _ = try await registry.observe([Client(mac: device, hostname: "device-1", online: .value(false))], at: start)
        return registry
    }

    @Test func saveProfilePersistsLocallyAndReloads() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try await knownRegistry(store: AtomicJSONStore(directory: directory))
        let savedAt = start.addingTimeInterval(60)
        let report = await registry.edit(device, .save(userName: "  Simon’s iPhone ", category: .phone, notes: "Work phone.\n"), at: savedAt)
        let expected = DeviceProfile(userName: "Simon’s iPhone", category: .phone, notes: "Work phone.", personalisedAt: savedAt)
        #expect(report.outcome == .verifiedSuccess(expected) && report.dispatched)

        let reloaded = DeviceRegistry(store: AtomicJSONStore(directory: directory))
        #expect(await reloaded.load() == .loaded)
        #expect(await reloaded.snapshot().records[device]?.profile == expected)
    }

    @Test func switchesSaveOnTheirOwnAndClearResetsEverything() async throws {
        let registry = try await knownRegistry(store: nil)
        _ = await registry.edit(device, .save(userName: "Printer", category: .printer, notes: "Upstairs"), at: start)
        #expect(await registry.edit(device, .setFavourite(true), at: start).outcome == .verifiedSuccess(
            DeviceProfile(userName: "Printer", category: .printer, notes: "Upstairs", favourite: true, personalisedAt: start)))
        _ = await registry.edit(device, .setMonitored(true), at: start)
        let cleared = await registry.edit(device, .clear, at: start)
        #expect(cleared.outcome == .verifiedSuccess(DeviceProfile()))
        let record = try #require(await registry.snapshot().records[device])
        #expect(record.lastHostname == "device-1")
    }

    @Test func blankNameMeansNoNameAndUnchangedEditsDoNotSave() async throws {
        let registry = try await knownRegistry(store: nil)
        let report = await registry.edit(device, .save(userName: "   ", category: nil, notes: ""), at: start)
        #expect(report.outcome == .verifiedSuccess(DeviceProfile(personalisedAt: start)))
        let again = await registry.edit(device, .setFavourite(false), at: start)
        #expect(!again.dispatched)
    }

    @Test func invalidOrUnknownEditsAreRejectedBeforeDispatch() async throws {
        let registry = try await knownRegistry(store: nil)
        let long = await registry.edit(device, .save(userName: String(repeating: "x", count: 65), category: nil, notes: ""), at: start)
        guard case .rejected(.invalidIntent) = long.outcome else { Issue.record("expected invalid intent"); return }
        #expect(!long.dispatched)
        let unknown = await registry.edit(MACAddress("AA:00:00:00:00:09")!, .setFavourite(true), at: start)
        guard case .rejected(.preconditionFailed) = unknown.outcome else { Issue.record("expected precondition"); return }
    }

    @Test func aFailedSaveIsUnknownAndKeepsTheOldProfile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = LockedFlag()
        let registry = try await knownRegistry(store: AtomicJSONStore(directory: directory, beforeCommit: {
            if failing.take() { throw CocoaError(.fileWriteUnknown) }
        }))
        failing.set()
        let report = await registry.edit(device, .setFavourite(true), at: start)
        #expect(report.outcome == .unknownAfterDispatch && report.dispatched)
        #expect(await registry.snapshot().records[device]?.favourite == false)
    }

    @Test func forgetIsBlockedWhileOnlineOrUnknown() async throws {
        let registry = try await knownRegistry(store: nil)
        for online in [Observed<Bool>.value(true), .unknown] {
            let report = await registry.forget(device, online: online, at: start)
            guard case .rejected(.preconditionFailed) = report.outcome else { Issue.record("expected rejection"); return }
            #expect(!report.dispatched)
        }
        #expect(await registry.snapshot().records[device] != nil)
    }

    @Test func forgetRemovesTheRecordAndThisDevicesPresenceOnly() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try await knownRegistry(store: AtomicJSONStore(directory: directory))
        let other = MACAddress("AA:00:00:00:00:02")!
        let presence = PresenceLog(store: AtomicJSONStore(directory: directory))
        await presence.record([device: .offline, other: .online], at: start)
        let report = await DeviceForgetting(registry: registry, presence: presence).run(device, online: .value(false), at: start)
        #expect(report.outcome == .verifiedSuccess(device))
        #expect(await registry.snapshot().records[device] == nil)
        #expect(await presence.history(for: device) == nil)
        #expect(await presence.history(for: other) != nil)
        let reloaded = try await AtomicJSONStore(directory: directory).load(DeviceRegistryState.self, from: .devices)
        #expect(reloaded?.records[device] == nil)
    }

    @Test func aForgottenDeviceTheRouterStillListsIsNotNew() async throws {
        let registry = try await knownRegistry(store: nil)
        _ = await registry.forget(device, online: .value(false), at: start)
        let again = try await registry.observe([Client(mac: device, hostname: "device-1", online: .value(false))], at: start.addingTimeInterval(30))
        #expect(again.newDevices.isEmpty)
        #expect(again.state.records[device]?.awaitingReview == false)
        let stranger = MACAddress("AA:00:00:00:00:03")!
        let next = try await registry.observe([Client(mac: stranger, online: .value(true))], at: start.addingTimeInterval(60))
        #expect(next.newDevices.map(\.mac) == [stranger])
    }

    @Test func personalisedDateDecodesFromOlderFilesAsNone() throws {
        let json = #"{"baselineEstablished":true,"records":[{"mac":"aa:00:00:00:00:01","firstSeen":0}]}"#
        let state = try JSONDecoder().decode(DeviceRegistryState.self, from: Data(json.utf8))
        #expect(state.records[device]?.personalisedAt == nil)
    }
}

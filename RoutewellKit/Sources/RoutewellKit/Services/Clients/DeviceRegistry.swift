import Foundation

/// A device seen for the first time after the baseline.
public struct NewDeviceEvent: Sendable, Equatable {
    public let mac: MACAddress
    public let firstSeen: Date
}

public struct DeviceObservation: Sendable, Equatable {
    public let state: DeviceRegistryState
    /// Delivered only after `devices.json` holds the new records.
    public let newDevices: [NewDeviceEvent]
    public let baselineEstablished: Bool
    /// Set when the save failed. The registry then keeps its last saved state,
    /// so an unsaved new device is found again, and reported once, later.
    public let saveFailure: StoreError?
}

/// How a local store file loaded at launch.
public enum LocalStoreLoad: Sendable, Equatable {
    case empty, loaded
    /// A damaged file was moved aside; defaults are in use.
    case recovered
    /// The file cannot be read or is from a newer app; saving is blocked.
    case blocked(StoreError)
}

public typealias DeviceRegistryLoad = LocalStoreLoad

/// Owns `devices.json` (decision 8). New-device rule: the first non-empty
/// client list is recorded as the baseline with no events; after that, each
/// never-seen MAC produces exactly one event, and the registry is saved
/// before that event is returned (RouterPilot's crash-safe ordering).
public actor DeviceRegistry {
    private let store: AtomicJSONStore?
    private var state: DeviceRegistryState
    /// What `devices.json` holds now. `nil` store means memory only (mock
    /// scenarios, previews, tests), where every change counts as saved.
    private var saved: DeviceRegistryState
    private var revision: UInt64 = 0
    /// Last-seen times are saved at most this often per device, so a normal
    /// refresh does not rewrite the file every 30 seconds.
    private let lastSeenSaveInterval: TimeInterval
    /// Serializes read-modify-save sequences across the save's suspension, so
    /// two calls can never both treat one MAC as new, and a review flag
    /// cleared during an observation is not written back.
    private let gate = MutationGate()
    /// Devices forgotten in this app session. If the router still lists one,
    /// it comes back as a plain known device, not as a new one.
    private var forgotten: Set<MACAddress> = []

    public init(store: AtomicJSONStore?, initial: DeviceRegistryState = .init(), lastSeenSaveInterval: TimeInterval = 600) {
        self.store = store
        state = initial
        saved = initial
        self.lastSeenSaveInterval = lastSeenSaveInterval
    }

    public func snapshot() -> DeviceRegistryState { state }

    public func load() async -> DeviceRegistryLoad {
        guard let store else { return .empty }
        do {
            guard let value = try await store.load(DeviceRegistryState.self, from: .devices) else { return .empty }
            state = value
            saved = value
            return .loaded
        } catch StoreError.corrupt {
            return .recovered
        } catch let error as StoreError {
            return .blocked(error)
        } catch {
            return .blocked(.readFailed)
        }
    }

    /// Throws only `CancellationError`, before any change is made.
    public func observe(_ clients: [Client], at now: Date) async throws -> DeviceObservation {
        let token = try await gate.acquire()
        defer { Task { await gate.release(token) } }
        var next = state
        var events: [NewDeviceEvent] = []
        let baselineNow = !next.baselineEstablished && !clients.isEmpty
        for client in clients {
            var record = next.records[client.mac] ?? DeviceRecord(mac: client.mac, firstSeen: now)
            if next.records[client.mac] == nil, next.baselineEstablished, !forgotten.contains(client.mac) {
                record.awaitingReview = true
                events.append(NewDeviceEvent(mac: client.mac, firstSeen: now))
            }
            if let ip = client.ip { record.lastIP = ip }
            if let hostname = client.hostname { record.lastHostname = hostname }
            if let routerName = client.routerName { record.lastRouterName = routerName }
            if client.online == .value(true) { record.lastSeen = now }
            next.records[client.mac] = record
        }
        if baselineNow { next.baselineEstablished = true }

        guard needsSave(next) else {
            state = next
            return DeviceObservation(state: next, newDevices: events, baselineEstablished: baselineNow, saveFailure: nil)
        }
        if let failure = await persist(next) {
            state = saved
            return DeviceObservation(state: saved, newDevices: [], baselineEstablished: false, saveFailure: failure)
        }
        return DeviceObservation(state: next, newDevices: events, baselineEstablished: baselineNow, saveFailure: nil)
    }

    /// Clears the review flag after the person opens the device from the
    /// review sheet. Returns false if the change could not be saved.
    @discardableResult
    public func markReviewed(_ mac: MACAddress) async -> Bool {
        guard let token = try? await gate.acquire() else { return false }
        defer { Task { await gate.release(token) } }
        guard var record = state.records[mac], record.awaitingReview else { return true }
        record.awaitingReview = false
        var next = state
        next.records[mac] = record
        return await persist(next) == nil
    }

    /// Edits one device's profile, recovery class `none`: gate, before-state
    /// (the record), one save, then a read-back of the saved record. A failed
    /// save keeps the old record and reports `unknownAfterDispatch`.
    public func edit(_ mac: MACAddress, _ edit: DeviceProfileEdit, at now: Date) async -> MutationReport<DeviceProfile> {
        if let rejection = edit.validate() {
            return Self.report(.rejected(rejection), dispatched: false, startedAt: now, failure: nil)
        }
        guard let token = try? await gate.acquire() else {
            return Self.report(.rejected(.preconditionFailed("Cancelled before dispatch")), dispatched: false, startedAt: now, failure: nil)
        }
        defer { Task { await gate.release(token) } }
        guard var record = state.records[mac] else {
            return Self.report(.rejected(.preconditionFailed("Device is not known")), dispatched: false, startedAt: now, failure: nil)
        }
        let intended = edit.applied(to: record.profile, at: now)
        guard intended != record.profile else {
            return Self.report(.verifiedSuccess(intended), dispatched: false, startedAt: now, failure: nil)
        }
        record.apply(intended)
        var next = state
        next.records[mac] = record
        if await persist(next) != nil {
            return Self.report(.unknownAfterDispatch, dispatched: true, startedAt: now, failure: .unavailable)
        }
        guard let saved = state.records[mac]?.profile else {
            return Self.report(.unknownAfterDispatch, dispatched: true, startedAt: now, failure: nil)
        }
        let outcome: MutationOutcome<DeviceProfile> = saved == intended ? .verifiedSuccess(saved) : .verifiedMismatch(expected: intended, actual: saved)
        return Self.report(outcome, dispatched: true, startedAt: now, failure: nil)
    }

    /// Removes one device record, recovery class `none`. Rejected unless the
    /// latest client list shows the device offline or no longer lists it.
    public func forget(_ mac: MACAddress, online: Observed<Bool>, at now: Date) async -> MutationReport<MACAddress> {
        guard online == .value(false) else {
            return Self.report(.rejected(.preconditionFailed("Device is online or its state is unknown")), dispatched: false, startedAt: now, failure: nil)
        }
        guard let token = try? await gate.acquire() else {
            return Self.report(.rejected(.preconditionFailed("Cancelled before dispatch")), dispatched: false, startedAt: now, failure: nil)
        }
        defer { Task { await gate.release(token) } }
        guard state.records[mac] != nil else {
            return Self.report(.rejected(.preconditionFailed("Device is not known")), dispatched: false, startedAt: now, failure: nil)
        }
        var next = state
        next.records[mac] = nil
        if await persist(next) != nil {
            return Self.report(.unknownAfterDispatch, dispatched: true, startedAt: now, failure: .unavailable)
        }
        forgotten.insert(mac)
        let outcome: MutationOutcome<MACAddress> = state.records[mac] == nil ? .verifiedSuccess(mac) : .unknownAfterDispatch
        return Self.report(outcome, dispatched: true, startedAt: now, failure: nil)
    }

    private static func report<Value>(_ outcome: MutationOutcome<Value>, dispatched: Bool, startedAt: Date, failure: RefreshFailureCategory?) -> MutationReport<Value> {
        MutationReport(outcome: outcome, dispatched: dispatched, startedAt: startedAt, finishedAt: Date(), failure: failure)
    }

    /// Saves `next` and makes it current, or leaves both states untouched.
    private func persist(_ next: DeviceRegistryState) async -> StoreError? {
        guard let store else {
            state = next
            saved = next
            return nil
        }
        revision += 1
        do {
            try await store.save(next, to: .devices, revision: revision)
            state = next
            saved = next
            return nil
        } catch let error as StoreError {
            return error
        } catch {
            return .writeFailed
        }
    }

    private func needsSave(_ next: DeviceRegistryState) -> Bool {
        guard next.baselineEstablished == saved.baselineEstablished, next.records.count == saved.records.count else { return true }
        for (mac, record) in next.records {
            guard let old = saved.records[mac] else { return true }
            var comparable = record
            comparable.lastSeen = old.lastSeen
            if comparable != old { return true }
            switch (old.lastSeen, record.lastSeen) {
            case (nil, .some): return true
            case (let before?, let after?) where after.timeIntervalSince(before) >= lastSeenSaveInterval: return true
            default: continue
            }
        }
        return false
    }
}

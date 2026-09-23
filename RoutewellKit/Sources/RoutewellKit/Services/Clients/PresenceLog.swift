import Foundation

/// Owns `presence.json`: one sample per refresh per MAC, kept as runs of
/// equal state, 7-day retention, bounded per device and in device count.
/// Samples exist only while Routewell runs; the time between two samples
/// further apart than `continuity` is unknown, and so is all time before a
/// launch, a sleep, or a session switch (`interrupt()`).
public actor PresenceLog {
    public static let retention: TimeInterval = 7 * 86_400
    /// Three times the slowest refresh cadence (60 s), so one late refresh
    /// does not break a run.
    public static let continuity: TimeInterval = 180
    public static let maxRunsPerDevice = 2_016
    public static let maxDevices = 512

    private let store: AtomicJSONStore?
    private var state: PresenceLogState
    private var revision: UInt64 = 0
    /// A run extension alone saves at most this often, so a normal refresh
    /// does not rewrite the file every 30 seconds.
    private let extensionSaveInterval: TimeInterval
    private var lastSave: Date?
    private var dirty = false
    /// The last save's failure, kept until a save succeeds.
    private var lastFailure: StoreError?

    public init(store: AtomicJSONStore?, initial: PresenceLogState = .init(), extensionSaveInterval: TimeInterval = 300) {
        self.store = store
        state = initial
        self.extensionSaveInterval = extensionSaveInterval
    }

    public func snapshot() -> PresenceLogState { state }

    public func history(for mac: MACAddress) -> PresenceHistory? { state.devices[mac] }

    public func load() async -> LocalStoreLoad {
        guard let store else { return .empty }
        do {
            guard let value = try await store.load(PresenceLogState.self, from: .presence) else { return .empty }
            // Decoding already closes every history: the app was not running.
            state = value
            return .loaded
        } catch StoreError.corrupt {
            return .recovered
        } catch let error as StoreError {
            return .blocked(error)
        } catch {
            return .blocked(.readFailed)
        }
    }

    /// What one successful client list says about each device: listed
    /// clients with their online flag, and remembered devices the router no
    /// longer lists as offline.
    public static func samples(listed: [MACAddress: Observed<Bool>], known: some Sequence<MACAddress>) -> [MACAddress: PresenceState] {
        var result: [MACAddress: PresenceState] = [:]
        for mac in known { result[mac] = .offline }
        for (mac, online) in listed {
            switch online {
            case .value(true): result[mac] = .online
            case .value(false): result[mac] = .offline
            case .unavailable, .unknown: result[mac] = .unknown
            }
        }
        return result
    }

    /// Records one refresh. Devices not in `samples` stop being sampled, so
    /// their history closes. Returns the save failure, if any; the samples
    /// stay in memory and the next record retries the save.
    @discardableResult
    public func record(_ samples: [MACAddress: PresenceState], at now: Date) async -> StoreError? {
        var structural = false
        for (mac, sample) in samples {
            var history = state.devices[mac] ?? PresenceHistory()
            // A sample no newer than the last one (a repeated or late result)
            // adds nothing and would break the time order.
            if let last = history.runs.last, now <= last.end { continue }
            if history.open, var last = history.runs.last, last.state == sample,
               now.timeIntervalSince(last.end) <= Self.continuity {
                last.end = now
                last.observations += 1
                history.runs[history.runs.count - 1] = last
            } else {
                let continuous = history.open && history.runs.last.map { now.timeIntervalSince($0.end) <= Self.continuity } == true
                history.runs.append(PresenceRun(start: now, end: now, state: sample, afterGap: !continuous))
                structural = true
            }
            history.open = true
            state.devices[mac] = history
        }
        for mac in state.devices.keys where samples[mac] == nil && state.devices[mac]?.open == true {
            state.devices[mac]?.open = false
        }
        if trim(now: now) { structural = true }
        dirty = true
        let due = lastSave.map { now.timeIntervalSince($0) >= extensionSaveInterval } ?? true
        guard structural || due else { return lastFailure }
        return await persist(at: now)
    }

    /// Closes every history: Routewell stops sampling (sleep, stop, or a
    /// session switch), so the time until the next sample is unknown.
    public func interrupt() {
        for mac in state.devices.keys { state.devices[mac]?.open = false }
    }

    /// Removes one device's presence rows ("Clear History…" and Forget).
    public func clear(_ mac: MACAddress, at now: Date) async -> StoreError? {
        guard let previous = state.devices[mac] else { return nil }
        state.devices[mac] = nil
        dirty = true
        if let failure = await persist(at: now) {
            // A clear that did not reach the file is undone, so the screen
            // never shows history as gone while it is still on disk.
            if state.devices[mac] == nil { state.devices[mac] = previous }
            return failure
        }
        return nil
    }

    /// "Clear History…" for one device, recovery class `none`: one save, then
    /// a read-back that the rows are gone.
    public func clearHistory(_ mac: MACAddress, at now: Date) async -> MutationReport<MACAddress> {
        let dispatched = state.devices[mac] != nil
        if await clear(mac, at: now) != nil {
            return MutationReport(outcome: .unknownAfterDispatch, dispatched: true, startedAt: now, finishedAt: Date(), failure: .unavailable)
        }
        let outcome: MutationOutcome<MACAddress> = state.devices[mac] == nil ? .verifiedSuccess(mac) : .unknownAfterDispatch
        return MutationReport(outcome: outcome, dispatched: dispatched, startedAt: now, finishedAt: Date(), failure: nil)
    }

    /// Saves pending samples now, for example before the app quits.
    @discardableResult
    public func flush(at now: Date) async -> StoreError? {
        guard dirty else { return nil }
        return await persist(at: now)
    }

    private func persist(at now: Date) async -> StoreError? {
        guard let store else {
            dirty = false
            lastSave = now
            return nil
        }
        revision += 1
        do {
            try await store.save(state, to: .presence, revision: revision)
            dirty = false
            lastSave = now
            lastFailure = nil
        } catch let error as StoreError {
            lastFailure = error
        } catch {
            lastFailure = .writeFailed
        }
        return lastFailure
    }

    /// Applies retention and both size bounds. Returns true when anything
    /// was removed.
    private func trim(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var changed = false
        for (mac, var history) in state.devices {
            let before = history.runs.count
            history.runs.removeAll { $0.end < cutoff }
            if var first = history.runs.first, first.start < cutoff {
                first.start = cutoff
                history.runs[0] = first
            }
            if history.runs.count > Self.maxRunsPerDevice {
                history.runs.removeFirst(history.runs.count - Self.maxRunsPerDevice)
            }
            if history.runs.count != before { changed = true }
            state.devices[mac] = history.runs.isEmpty ? nil : history
        }
        if state.devices.count > Self.maxDevices {
            let oldest = state.devices
                .sorted { ($0.value.lastObserved ?? .distantPast, $0.key) < ($1.value.lastObserved ?? .distantPast, $1.key) }
                .prefix(state.devices.count - Self.maxDevices)
            for (mac, _) in oldest { state.devices[mac] = nil }
            changed = true
        }
        return changed
    }
}

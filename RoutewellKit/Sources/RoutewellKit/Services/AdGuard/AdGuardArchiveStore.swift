import Foundation

/// The saved copy of AdGuard Home's data for one router (architecture 05).
/// One section per read, each with the date it was saved. Chunk 16 saves the
/// service status and the router config; chunk 17 adds the Overview's stats
/// (per range), stats config, switches, and blocklists, and the DNS
/// settings. A section is replaced only by a newer successful read while
/// AdGuard Home runs. New sections are optional, so a chunk 16 file still
/// loads.
public struct AdGuardArchive: Sendable, Equatable, Codable {
    public struct Section<Value: Sendable & Equatable & Codable>: Sendable, Equatable, Codable {
        public var savedAt: Date
        public var value: Value

        public init(savedAt: Date, value: Value) {
            self.savedAt = savedAt
            self.value = value
        }
    }

    /// `control/status`: version, start time, protection state.
    public var status: Section<AdGuardStatusResponse>?
    /// `adguardhome get_config`: the last Handle DNS setting while running.
    public var config: Section<AdGuardRouterConfig>?

    /// `control/stats`, one section per range the Overview showed, keyed
    /// by `AdGuardStatsRange.rawValue`.
    public var stats: [String: Section<AdGuardStats>]?
    /// `control/stats/config`: the retention.
    public var statsConfig: Section<AdGuardStatsConfig>?
    /// The three Protection switches.
    public var protection: Section<ProtectionOptions>?
    /// `control/filtering/status`: the lists behind the Blocklists row.
    public var filtering: Section<AdGuardFilteringStatus>?
    /// `control/dns_info`: the DNS tab.
    public var dns: Section<AdGuardDNSSettings>?

    public init(status: Section<AdGuardStatusResponse>? = nil, config: Section<AdGuardRouterConfig>? = nil,
                stats: [String: Section<AdGuardStats>]? = nil, statsConfig: Section<AdGuardStatsConfig>? = nil,
                protection: Section<ProtectionOptions>? = nil, filtering: Section<AdGuardFilteringStatus>? = nil,
                dns: Section<AdGuardDNSSettings>? = nil) {
        self.status = status
        self.config = config
        self.stats = stats
        self.statsConfig = statsConfig
        self.protection = protection
        self.filtering = filtering
        self.dns = dns
    }

    public var isEmpty: Bool {
        status == nil && config == nil && (stats ?? [:]).isEmpty && statsConfig == nil && protection == nil && filtering == nil && dns == nil
    }

    /// The newest section's date: the age the read-only strip shows.
    public var savedAt: Date? {
        ([status?.savedAt, config?.savedAt, statsConfig?.savedAt, protection?.savedAt, filtering?.savedAt, dns?.savedAt]
            + (stats ?? [:]).values.map(\.savedAt)).compactMap { $0 }.max()
    }

    /// The saved stats for one range.
    public func stats(for range: AdGuardStatsRange) -> Section<AdGuardStats>? { stats?[range.rawValue] }
}

/// `adguard/<profile UUID>/archive.json` under the app's data folder, with
/// `AtomicJSONStore` rules. Without a root folder (mock sessions, tests) the
/// archive lives in memory only. Memory changes only after the file is
/// written, so the screen never shows a copy that a relaunch would lose.
public actor AdGuardArchiveStore {
    /// A section is saved at most this often, unless the save is forced
    /// (the final sync before Stop).
    public static let minimumInterval: TimeInterval = 60

    private let root: URL?
    private let beforeCommit: @Sendable () throws -> Void
    private var archives: [UUID: AdGuardArchive] = [:]
    private var loaded: Set<UUID> = []
    private var stores: [UUID: AtomicJSONStore] = [:]
    private var revisions: [UUID: UInt64] = [:]
    /// Bumped by `remove`, so a save that was waiting on the file when the
    /// router was removed does not bring its copy back.
    private var generations: [UUID: Int] = [:]

    /// `beforeCommit` is for tests: it runs inside each file write.
    public init(root: URL?, beforeCommit: @escaping @Sendable () throws -> Void = {}) {
        self.root = root
        self.beforeCommit = beforeCommit
    }

    /// `<root>/adguard/<profile UUID>`.
    public static func folder(root: URL, profile: UUID) -> URL {
        root.appendingPathComponent("adguard", isDirectory: true)
            .appendingPathComponent(profile.uuidString, isDirectory: true)
    }

    /// The saved copy, or `nil` when there is none. A damaged file is moved
    /// aside by the store and reads as none; a newer app's file reads as
    /// none and blocks saving for this launch.
    public func archive(for profile: UUID) async -> AdGuardArchive? {
        if !loaded.contains(profile), let store = store(for: profile) {
            loaded.insert(profile)
            if let value = try? await store.load(AdGuardArchive.self, from: .archive) {
                archives[profile] = value
            }
        }
        guard let archive = archives[profile], !archive.isEmpty else { return nil }
        return archive
    }

    /// Saves the sections a running read gives. Nothing is saved unless the
    /// router says AdGuard Home is on and AdGuard Home answered. Returns the
    /// store error, if the file could not be written.
    @discardableResult
    public func save(_ reading: AdGuardServiceReading, for profile: UUID, force: Bool = false) async -> StoreError? {
        guard case .success(let config) = reading.config, config.enabled == true,
              let status = reading.status else { return nil }
        let generation = generations[profile, default: 0]
        var next = await archive(for: profile) ?? AdGuardArchive()
        let at = reading.observedAt
        var changed = false
        if force || Self.isDue(next.status?.savedAt, at: at) {
            next.status = .init(savedAt: at, value: status)
            changed = true
        }
        if force || Self.isDue(next.config?.savedAt, at: at) {
            next.config = .init(savedAt: at, value: config)
            changed = true
        }
        guard changed else { return nil }
        return await commit(next, for: profile, generation: generation)
    }

    /// Saves the parts of an Overview read that succeeded. The caller reads
    /// only while AdGuard Home runs. Stats are saved per range; a reply that
    /// did not honour `recent` (it may cover the whole retention) is not
    /// saved at all, so the copy never labels it with the wrong range.
    @discardableResult
    public func save(_ overview: AdGuardOverviewReading, for profile: UUID, force: Bool = false) async -> StoreError? {
        let generation = generations[profile, default: 0]
        var next = await archive(for: profile) ?? AdGuardArchive()
        let at = overview.observedAt
        var changed = false
        if case .success(let stats) = overview.stats, overview.rangeHonoured {
            let key = overview.range.rawValue
            if force || Self.isDue(next.stats?[key]?.savedAt, at: at) {
                next.stats = (next.stats ?? [:]).merging([key: .init(savedAt: at, value: stats)]) { $1 }
                changed = true
            }
        }
        if case .success(let config) = overview.statsConfig, force || Self.isDue(next.statsConfig?.savedAt, at: at) {
            next.statsConfig = .init(savedAt: at, value: config)
            changed = true
        }
        if case .success(let options) = overview.protection, force || Self.isDue(next.protection?.savedAt, at: at) {
            // A switch whose own read failed keeps its saved value.
            var merged = options
            for feature in AdGuardFeature.allCases where merged[feature] == nil {
                merged[feature] = next.protection?.value[feature]
            }
            next.protection = .init(savedAt: at, value: merged)
            changed = true
        }
        if case .success(let filtering) = overview.filtering, force || Self.isDue(next.filtering?.savedAt, at: at) {
            next.filtering = .init(savedAt: at, value: filtering)
            changed = true
        }
        if case .success(let dns) = overview.dns, force || Self.isDue(next.dns?.savedAt, at: at) {
            next.dns = .init(savedAt: at, value: dns)
            changed = true
        }
        guard changed else { return nil }
        return await commit(next, for: profile, generation: generation)
    }

    /// Replaces the whole copy. Mock scenarios seed it; `nil` removes it from
    /// memory and disk.
    @discardableResult
    public func replace(_ archive: AdGuardArchive?, for profile: UUID) async -> StoreError? {
        guard let archive, !archive.isEmpty else { await remove(profile: profile); return nil }
        loaded.insert(profile)
        return await commit(archive, for: profile, generation: generations[profile, default: 0])
    }

    /// Start Setup Again and profile removal: the whole folder goes.
    public func remove(profile: UUID) async {
        generations[profile, default: 0] += 1
        archives[profile] = nil
        stores[profile] = nil
        loaded.insert(profile)
        guard let root else { return }
        try? FileManager.default.removeItem(at: Self.folder(root: root, profile: profile))
    }

    private static func isDue(_ savedAt: Date?, at date: Date) -> Bool {
        guard let savedAt else { return true }
        return date.timeIntervalSince(savedAt) >= minimumInterval
    }

    private func store(for profile: UUID) -> AtomicJSONStore? {
        guard let root else { return nil }
        if let store = stores[profile] { return store }
        let store = AtomicJSONStore(directory: Self.folder(root: root, profile: profile), beforeCommit: beforeCommit)
        stores[profile] = store
        return store
    }

    private func commit(_ next: AdGuardArchive, for profile: UUID, generation: Int) async -> StoreError? {
        guard generations[profile, default: 0] == generation else { return nil }
        guard let store = store(for: profile) else { archives[profile] = next; return nil }
        let revision = (revisions[profile] ?? 0) + 1
        revisions[profile] = revision
        do {
            let written = try await store.save(next, to: .archive, revision: revision)
            guard generations[profile, default: 0] == generation else {
                // Removed while this write waited: the file goes too.
                if let root { try? FileManager.default.removeItem(at: Self.folder(root: root, profile: profile)) }
                return nil
            }
            // A newer write already landed; this one was dropped.
            if written { archives[profile] = next }
            return nil
        } catch let error as StoreError {
            return error
        } catch {
            return .writeFailed
        }
    }
}

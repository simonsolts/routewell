import Foundation

/// The saved copy of AdGuard Home's data for one router (architecture 05).
/// One section per read, each with the date it was saved. Chunk 16 saves the
/// service status and the router config; later chunks add their sections.
/// A section is replaced only by a newer successful read while AdGuard Home
/// runs.
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

    public init(status: Section<AdGuardStatusResponse>? = nil, config: Section<AdGuardRouterConfig>? = nil) {
        self.status = status
        self.config = config
    }

    public var isEmpty: Bool { status == nil && config == nil }

    /// The newest section's date: the age the read-only strip shows.
    public var savedAt: Date? { [status?.savedAt, config?.savedAt].compactMap { $0 }.max() }
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
    private var archives: [UUID: AdGuardArchive] = [:]
    private var loaded: Set<UUID> = []
    private var stores: [UUID: AtomicJSONStore] = [:]
    private var revisions: [UUID: UInt64] = [:]

    public init(root: URL?) {
        self.root = root
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
        return await commit(next, for: profile)
    }

    /// Replaces the whole copy. Mock scenarios seed it; `nil` removes it from
    /// memory and disk.
    @discardableResult
    public func replace(_ archive: AdGuardArchive?, for profile: UUID) async -> StoreError? {
        guard let archive, !archive.isEmpty else { await remove(profile: profile); return nil }
        loaded.insert(profile)
        return await commit(archive, for: profile)
    }

    /// Start Setup Again and profile removal: the whole folder goes.
    public func remove(profile: UUID) async {
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
        let store = AtomicJSONStore(directory: Self.folder(root: root, profile: profile))
        stores[profile] = store
        return store
    }

    private func commit(_ next: AdGuardArchive, for profile: UUID) async -> StoreError? {
        guard let store = store(for: profile) else { archives[profile] = next; return nil }
        let revision = (revisions[profile] ?? 0) + 1
        revisions[profile] = revision
        do {
            try await store.save(next, to: .archive, revision: revision)
            archives[profile] = next
            return nil
        } catch let error as StoreError {
            return error
        } catch {
            return .writeFailed
        }
    }
}

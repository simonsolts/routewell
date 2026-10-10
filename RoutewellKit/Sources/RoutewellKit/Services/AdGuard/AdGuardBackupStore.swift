import Foundation

/// `adguard/<profile UUID>/backups/` under the app's data folder: for each
/// backup, `<id>.yaml` (the router's `config.yaml`) and `<id>.json` (its
/// `AdGuardBackup` record). The YAML holds password hashes: mode 0600, file
/// protection on, never logged. Without a root folder (mock sessions, tests)
/// the backups live in memory only.
public actor AdGuardBackupStore {
    public enum Failure: Error, Sendable, Equatable { case writeFailed, missing }

    private let root: URL?
    private var memory: [UUID: [(record: AdGuardBackup, data: Data)]] = [:]

    public init(root: URL?) {
        self.root = root
    }

    public static func folder(root: URL, profile: UUID) -> URL {
        AdGuardArchiveStore.folder(root: root, profile: profile).appendingPathComponent("backups", isDirectory: true)
    }

    /// Newest first. A record without its file is left out.
    public func backups(for profile: UUID) -> [AdGuardBackup] {
        guard let root else { return (memory[profile] ?? []).map(\.record).sorted { $0.createdAt > $1.createdAt } }
        let folder = Self.folder(root: root, profile: profile)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasSuffix(".json") }.compactMap { name -> AdGuardBackup? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let record = try? decoder.decode(AdGuardBackup.self, from: data),
                  FileManager.default.fileExists(atPath: Self.fileURL(folder, record.id).path) else { return nil }
            return record
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Saves the file first, then its record, so a listed backup always has
    /// its file.
    public func save(_ file: AdGuardConfigFile, kind: AdGuardBackup.Kind, version: String?, for profile: UUID,
                     at date: Date = Date()) throws(Failure) -> AdGuardBackup {
        let record = AdGuardBackup(createdAt: date, kind: kind, size: file.data.count, version: version)
        guard let root else {
            memory[profile, default: []].append((record, file.data))
            return record
        }
        let folder = Self.folder(root: root, profile: profile)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Self.writeSecret(file.data, to: Self.fileURL(folder, record.id))
            try Self.writeSecret(encoder.encode(record), to: folder.appendingPathComponent("\(record.id.uuidString).json"))
        } catch {
            try? FileManager.default.removeItem(at: Self.fileURL(folder, record.id))
            throw .writeFailed
        }
        return record
    }

    /// The saved `config.yaml`, checked again before it is used.
    public func file(_ backup: AdGuardBackup, for profile: UUID) throws(Failure) -> AdGuardConfigFile {
        let data: Data?
        if let root {
            data = try? Data(contentsOf: Self.fileURL(Self.folder(root: root, profile: profile), backup.id))
        } else {
            data = memory[profile]?.first { $0.record.id == backup.id }?.data
        }
        guard let data, let file = AdGuardConfigFile(data) else { throw .missing }
        return file
    }

    /// Export…: a copy where the person chose. The copy is theirs.
    public func export(_ backup: AdGuardBackup, for profile: UUID, to destination: URL) throws(Failure) {
        let file = try file(backup, for: profile)
        do { try file.data.write(to: destination, options: .atomic) } catch { throw .writeFailed }
    }

    /// Profile removal deletes the folder with the archive; this clears memory.
    public func remove(profile: UUID) {
        memory[profile] = nil
        guard let root else { return }
        try? FileManager.default.removeItem(at: Self.folder(root: root, profile: profile))
    }

    private static func fileURL(_ folder: URL, _ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).yaml")
    }

    private static func writeSecret(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

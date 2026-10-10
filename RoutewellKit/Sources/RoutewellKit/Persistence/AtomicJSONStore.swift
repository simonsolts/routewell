import Foundation

public enum StoreFile: String, Sendable, CaseIterable {
    case settings, profiles, trust, devices, presence, snapshots
    /// `adguard/<profile UUID>/archive.json`, in its own per-profile store.
    case archive
}

public enum StoreError: Error, Equatable, Sendable {
    case corrupt, futureSchema, readFailed, writeFailed
}

/// One owner per directory. File operations never suspend within the actor.
/// Atomic replacement guarantees visibility, not power-loss durability.
public actor AtomicJSONStore {
    private struct Envelope<Value: Codable>: Codable {
        let version: Int
        let value: Value
    }
    private struct Header: Decodable { let version: Int }
    private let directory: URL
    private var revisions: [StoreFile: UInt64] = [:]
    private var blocked: [StoreFile: StoreError] = [:]
    private let beforeCommit: @Sendable () throws -> Void

    public init(directory: URL, beforeCommit: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory
        self.beforeCommit = beforeCommit
    }

    public func load<Value: Codable & Sendable>(_ type: Value.Type, from file: StoreFile) throws -> Value? {
        let url = destination(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { blocked[file] = .readFailed; throw StoreError.readFailed }
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.version <= 1 else { blocked[file] = .futureSchema; throw StoreError.futureSchema }
            guard header.version == 1 else { throw StoreError.corrupt }
            return try decoder.decode(Envelope<Value>.self, from: data).value
        } catch StoreError.futureSchema { throw StoreError.futureSchema }
        catch {
            // Preserve the exact original before allowing defaults to be saved.
            do {
                try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("\(file.rawValue).recovery-\(UUID().uuidString).json"))
            } catch { blocked[file] = .readFailed; throw StoreError.readFailed }
            throw StoreError.corrupt
        }
    }

    /// A synchronous read with no side effects, for decisions that must be
    /// made before the store loads (which window opens at launch). A missing,
    /// damaged, or newer file reads as `nil`; `load` still handles it later.
    public nonisolated static func peek<Value: Codable & Sendable>(_ type: Value.Type, from file: StoreFile, in directory: URL) -> Value? {
        let url = directory.appendingPathComponent(file.rawValue).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url),
              let header = try? JSONDecoder().decode(Header.self, from: data), header.version == 1 else { return nil }
        return try? JSONDecoder().decode(Envelope<Value>.self, from: data).value
    }

    /// Explicit revisions prevent an older, late-arriving save replacing newer data.
    @discardableResult
    public func save<Value: Codable & Sendable>(_ value: Value, to file: StoreFile, revision: UInt64) throws -> Bool {
        if let error = blocked[file] { throw error }
        if let latest = revisions[file], revision <= latest { return false }
        let manager = FileManager.default
        let temp = directory.appendingPathComponent(".\(file.rawValue)-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temp) }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Orphan temp files are never read or promoted. Remove only our names.
            for orphan in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where orphan.lastPathComponent.hasPrefix(".\(file.rawValue)-") && orphan.pathExtension == "tmp" {
                try? manager.removeItem(at: orphan)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Envelope(version: 1, value: value)).write(to: temp)
            try beforeCommit()
            let target = destination(file)
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: temp)
            } else {
                try manager.moveItem(at: temp, to: target)
            }
            revisions[file] = revision
            return true
        } catch { throw StoreError.writeFailed }
    }

    private func destination(_ file: StoreFile) -> URL {
        directory.appendingPathComponent(file.rawValue).appendingPathExtension("json")
    }
}

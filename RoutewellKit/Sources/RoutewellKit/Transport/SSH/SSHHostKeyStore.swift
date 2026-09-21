import CryptoKit
import Foundation

/// A Routewell-owned `known_hosts` file. Never passed to the system ssh config;
/// `SSHLauncher` always points `-o UserKnownHostsFile` at this exact file with
/// `StrictHostKeyChecking=yes`.
public actor SSHHostKeyStore {
    public enum StoreError: Error, Equatable, Sendable { case readFailed, writeFailed }

    private let directory: URL
    private let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("known_hosts")
    }

    public nonisolated var knownHostsFile: URL { fileURL }

    /// Reads the known_hosts file and returns the line matching `[host]:port`
    /// (or bare `host` when `port == 22`), if any.
    public func storedKeyLine(host: String, port: Int) throws -> String? {
        let prefixes = matchPrefixes(host: host, port: port)
        for line in try existingLines() where prefixes.contains(where: line.hasPrefix) {
            return line
        }
        return nil
    }

    /// Replaces any existing line for this host:port with `keyLine`. Atomic write,
    /// file mode 0600.
    public func approve(host: String, port: Int, keyLine: String) throws {
        var lines = try existingLines()
        let prefixes = matchPrefixes(host: host, port: port)
        lines.removeAll { line in prefixes.contains(where: line.hasPrefix) }
        lines.append(keyLine)
        try write(lines)
    }

    public func revoke(host: String, port: Int) throws {
        var lines = try existingLines()
        let prefixes = matchPrefixes(host: host, port: port)
        lines.removeAll { line in prefixes.contains(where: line.hasPrefix) }
        try write(lines)
    }

    private func existingLines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text: String
        do { text = try String(contentsOf: fileURL, encoding: .utf8) }
        catch { throw StoreError.readFailed }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func write(_ lines: [String]) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temp = directory.appendingPathComponent(".known_hosts-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temp) }
            let content = lines.map { $0 + "\n" }.joined()
            try Data(content.utf8).write(to: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: fileURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { throw StoreError.writeFailed }
    }

    private func matchPrefixes(host: String, port: Int) -> [String] {
        port == 22 ? ["[\(host)]:22 ", "\(host) "] : ["[\(host)]:\(port) "]
    }
}

/// One candidate host key line parsed from `ssh-keyscan` output, with its
/// locally-computed fingerprint.
public struct SSHHostKeyCandidate: Sendable, Equatable {
    public let keyLine: String
    public let fingerprintSHA256: String
}

public enum SSHHostKeyScanner {
    /// Plans `ssh-keyscan -p <port> -T 10 -t ed25519,ecdsa,rsa -- <host>`.
    public static func plan(host: String, port: Int) -> SSHLaunchPlan {
        SSHLaunchPlan(
            executable: URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
            arguments: ["-p", "\(port)", "-T", "10", "-t", "ed25519,ecdsa,rsa", "--", host]
        )
    }

    /// Parses `ssh-keyscan` output lines (`host algorithm base64key`, comments
    /// starting with `#` skipped) into candidates. Each fingerprint is computed
    /// locally: SHA-256 over the base64-decoded key blob, then unpadded base64,
    /// prefixed "SHA256:" — the same format `ssh-keygen -lf` prints.
    public static func parse(_ output: Data, host: String, port: Int) -> [SSHHostKeyCandidate] {
        guard let text = String(data: output, encoding: .utf8) else { return [] }
        var candidates: [SSHHostKeyCandidate] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let keyBlob = Data(base64Encoded: String(fields[2])) else { continue }
            let digest = SHA256.hash(data: keyBlob)
            let unpadded = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
            candidates.append(SSHHostKeyCandidate(keyLine: line, fingerprintSHA256: "SHA256:\(unpadded)"))
        }
        return candidates
    }
}

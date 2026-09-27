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

    public init(keyLine: String, fingerprintSHA256: String) {
        self.keyLine = keyLine
        self.fingerprintSHA256 = fingerprintSHA256
    }

    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`, …
    public var algorithm: String { fields.count >= 2 ? fields[1] : "" }
    /// The base64 key blob.
    public var key: String { fields.count >= 3 ? fields[2] : "" }
    private var fields: [String] { keyLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }

    /// The `known_hosts` host field ssh looks up: bare host on port 22,
    /// `[host]:port` otherwise.
    public static func hostToken(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// The same key line with the host field ssh expects for `host:port`.
    public func normalized(host: String, port: Int) -> String {
        "\(Self.hostToken(host: host, port: port)) \(algorithm) \(key)"
    }

    /// Parses one `host algorithm base64key` line; `nil` when the key is not base64.
    public init?(keyLine line: String) {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3, let keyBlob = Data(base64Encoded: String(fields[2])) else { return nil }
        let digest = SHA256.hash(data: keyBlob)
        let unpadded = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        self.init(keyLine: line, fingerprintSHA256: "SHA256:\(unpadded)")
    }
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
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
            .compactMap(SSHHostKeyCandidate.init(keyLine:))
    }
}

/// Fetches candidate host keys without credentials. Tests use a fake; the
/// live scanner runs `ssh-keyscan` only when a person switches SSH on.
public protocol SSHHostKeyScanning: Sendable {
    func scan(host: String, port: Int) async throws(SSHFailure) -> [SSHHostKeyCandidate]
}

public struct LiveSSHHostKeyScanner: SSHHostKeyScanning {
    private let processes: any ProcessRunning

    public init(processes: any ProcessRunning = ProcessRunner()) { self.processes = processes }

    public func scan(host: String, port: Int) async throws(SSHFailure) -> [SSHHostKeyCandidate] {
        guard SSHHostValidation.isValidHost(host), (1...65535).contains(port) else { throw .configurationFailed }
        let plan = SSHHostKeyScanner.plan(host: host, port: port)
        let result: ProcessResult
        do {
            result = try await processes.run(executable: plan.executable, arguments: plan.arguments, environment: [:],
                                             limits: ProcessLimits(deadline: .seconds(15), maxOutputBytes: 64 * 1024))
        } catch ProcessRunnerError.timedOut {
            throw .timedOut
        } catch {
            throw .other("ssh-keyscan")
        }
        let candidates = SSHHostKeyScanner.parse(result.stdout, host: host, port: port)
        guard !candidates.isEmpty else {
            let failure = SSHResultClassifier.classify(stderr: String(decoding: result.stderr, as: UTF8.self))
            throw failure == .other("ssh") ? .connectionFailed : failure
        }
        return candidates
    }
}

/// What a scan found, compared with the trusted key for the same router.
public enum SSHHostKeyEvaluation: Sendable, Equatable {
    /// No key is trusted yet: show this fingerprint and ask.
    case new(SSHHostKeyCandidate)
    /// The router presented the trusted key.
    case matches(SSHHostKeyCandidate)
    /// The router presented a different key. Always rejected.
    case changed(trustedFingerprint: String, presented: SSHHostKeyCandidate)
}

public enum SSHHostKeyDecision: Sendable, Equatable {
    case trusted
    case rejected
}

/// Trust-on-first-use, then pin (`SshHostKeyTrustService.cs:34-136`).
public enum SSHHostKeyTrust {
    /// Ed25519 first, then ECDSA, then RSA.
    public static func preferred(_ candidates: [SSHHostKeyCandidate]) -> SSHHostKeyCandidate? {
        func rank(_ candidate: SSHHostKeyCandidate) -> Int {
            if candidate.algorithm == "ssh-ed25519" { return 0 }
            if candidate.algorithm.hasPrefix("ecdsa-") { return 1 }
            if candidate.algorithm == "ssh-rsa" { return 2 }
            return 3
        }
        return candidates.min { rank($0) < rank($1) }
    }

    public static func evaluate(_ candidates: [SSHHostKeyCandidate], trustedKeyLine: String?) -> SSHHostKeyEvaluation? {
        guard let trustedKeyLine, let trusted = SSHHostKeyCandidate(keyLine: trustedKeyLine) else {
            return preferred(candidates).map(SSHHostKeyEvaluation.new)
        }
        if let match = candidates.first(where: { $0.algorithm == trusted.algorithm && $0.key == trusted.key }) {
            return .matches(match)
        }
        guard let presented = candidates.first(where: { $0.algorithm == trusted.algorithm }) ?? preferred(candidates) else { return nil }
        return .changed(trustedFingerprint: trusted.fingerprintSHA256, presented: presented)
    }

    /// The person's answer counts only for a new key. A changed key is
    /// always rejected for this connection, whatever the answer.
    public static func decide(_ evaluation: SSHHostKeyEvaluation, approved: Bool) -> SSHHostKeyDecision {
        switch evaluation {
        case .matches: .trusted
        case .new: approved ? .trusted : .rejected
        case .changed: .rejected
        }
    }

    /// Stores `candidate` as the one trusted key for `host:port`. Used for an
    /// approved new key, and for an explicit "Replace Trusted Key" that never
    /// retries the rejected connection.
    public static func store(_ candidate: SSHHostKeyCandidate, host: String, port: Int, in store: SSHHostKeyStore) async throws {
        try await store.approve(host: host, port: port, keyLine: candidate.normalized(host: host, port: port))
    }
}

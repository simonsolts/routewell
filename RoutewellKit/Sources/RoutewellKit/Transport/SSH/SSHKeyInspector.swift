import Foundation

/// What Routewell found in a file the person chose as their SSH key.
public enum SSHKeyInspection: Sendable, Equatable {
    /// A private key with no passphrase. `kind` is the display name of the key
    /// type: "ED25519", "ECDSA", "RSA", "DSA", or nil when the format does not
    /// say (for example unencrypted PKCS#8 `BEGIN PRIVATE KEY`).
    case usable(kind: String?)
    /// Protected by a passphrase, which Routewell cannot use.
    case passphraseProtected
    /// A public key (for example the `.pub` file), not the private key.
    case publicKey
    /// Not a private key Routewell recognises, or empty.
    case notAKey
    /// The file could not be read (missing, no access, or over the size limit).
    case unreadable
}

public extension SSHKeyInspection {
    /// "ED25519 private key", "RSA private key", or "Private key" when `kind`
    /// is nil. Only meaningful for `.usable`.
    var displayType: String {
        if case .usable(let kind?) = self { return "\(kind) private key" }
        return "Private key"
    }
}

/// Reads a chosen key file locally and says if `ssh` can use it. The sandbox
/// has no SSH agent, so a key with a passphrase cannot work. Nothing here
/// decrypts or keeps key material.
public enum SSHKeyInspector {
    /// Largest file read: 64 KiB. Private keys are far smaller.
    public static let maxBytes = 64 * 1024

    public static func inspect(_ data: Data) -> SSHKeyInspection {
        guard let text = String(data: data, encoding: .utf8) else { return .notAKey }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return .notAKey }

        if isPublicKey(first) { return .publicKey }
        guard let label = armourLabel(first, prefix: "-----BEGIN ") else { return .notAKey }
        let end = "-----END \(label)-----"
        guard let endIndex = lines.lastIndex(of: end), endIndex > 0 else { return .notAKey }
        let body = Array(lines[1..<endIndex])
        guard !body.isEmpty else { return .notAKey }

        switch label {
        case "OPENSSH PRIVATE KEY": return inspectOpenSSH(base64: body.joined())
        case "RSA PRIVATE KEY": return inspectPEM(body, kind: "RSA")
        case "EC PRIVATE KEY": return inspectPEM(body, kind: "ECDSA")
        case "DSA PRIVATE KEY": return inspectPEM(body, kind: "DSA")
        case "ENCRYPTED PRIVATE KEY": return .passphraseProtected
        case "PRIVATE KEY": return .usable(kind: nil)
        case "SSH2 PUBLIC KEY", "PUBLIC KEY", "RSA PUBLIC KEY": return .publicKey
        default: return .notAKey
        }
    }

    /// Reads at most `maxBytes + 1` bytes. A longer file is `.unreadable`.
    public static func inspect(fileAt url: URL) -> SSHKeyInspection {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            guard data.count <= maxBytes else { return .unreadable }
            return inspect(data)
        } catch {
            return .unreadable
        }
    }

    // MARK: - Armour

    /// The text between the prefix and the closing dashes of an armour line.
    private static func armourLabel(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix), line.hasSuffix("-----"),
              line.count > prefix.count + 5 else { return nil }
        return String(line.dropFirst(prefix.count).dropLast(5))
    }

    private static let publicKeyTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ssh-dss",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    /// A one-line public key starts with a key type and a space.
    private static func isPublicKey(_ line: String) -> Bool {
        guard let type = line.split(whereSeparator: \.isWhitespace).first else { return false }
        return line.count > type.count && publicKeyTypes.contains(String(type))
    }

    // MARK: - PEM

    /// A PEM key is encrypted when it has a `Proc-Type: 4,ENCRYPTED` or
    /// `DEK-Info:` header line.
    private static func inspectPEM(_ body: [String], kind: String) -> SSHKeyInspection {
        let encrypted = body.contains {
            ($0.hasPrefix("Proc-Type:") && $0.contains("ENCRYPTED")) || $0.hasPrefix("DEK-Info:")
        }
        return encrypted ? .passphraseProtected : .usable(kind: kind)
    }

    // MARK: - OpenSSH new format

    private static let openSSHMagic = Array("openssh-key-v1\0".utf8)

    private static func inspectOpenSSH(base64: String) -> SSHKeyInspection {
        guard let decoded = Data(base64Encoded: base64) else { return .notAKey }
        var reader = BinaryReader(Array(decoded))
        guard reader.bytes(openSSHMagic.count) == openSSHMagic,
              let cipher = reader.string(),
              reader.string() != nil,  // kdfname
              reader.string() != nil,  // kdfoptions
              let keyCount = reader.uint32(), keyCount >= 1,
              let publicBlob = reader.string() else { return .notAKey }
        var blob = BinaryReader(publicBlob)
        guard let type = blob.string() else { return .notAKey }

        if cipher != Array("none".utf8) { return .passphraseProtected }
        return .usable(kind: String(bytes: type, encoding: .utf8).flatMap(kindName))
    }

    private static func kindName(_ type: String) -> String? {
        switch type {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case "sk-ssh-ed25519@openssh.com": "ED25519-SK"
        case "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK"
        case _ where type.hasPrefix("ecdsa-sha2-"): "ECDSA"
        default: nil
        }
    }
}

/// Bounds-checked reader for the SSH wire format. Every read returns nil
/// instead of going past the end.
private struct BinaryReader {
    private let data: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.data = bytes }

    mutating func uint32() -> UInt32? {
        guard let b = bytes(4) else { return nil }
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// uint32 big-endian length, then that many bytes.
    mutating func string() -> [UInt8]? {
        guard let length = uint32() else { return nil }
        return bytes(Int(length))
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, count <= data.count - offset else { return nil }
        defer { offset += count }
        return Array(data[offset..<offset + count])
    }
}

import CryptoKit
import Foundation

/// The `challenge` result GL.iNet's router returns before login: which
/// crypt algorithm and salt to hash the password with, plus a nonce that
/// binds the login hash to this specific challenge.
public struct GLiNetChallenge: Sendable, Equatable {
    public let alg: Int
    public let salt: String
    public let nonce: String
    public let hashMethod: String?

    public init(alg: Int, salt: String, nonce: String, hashMethod: String?) {
        self.alg = alg
        self.salt = salt
        self.nonce = nonce
        self.hashMethod = hashMethod
    }

    /// Decodes a `challenge` RPC result. `alg` may arrive as an int or as a
    /// numeric string; every other field must be present as a string.
    public init(result: JSONValue) throws(GLiNetRPCError) {
        guard let alg = result["alg"]?.int else { throw .malformedResponse }
        guard let salt = result["salt"]?.string else { throw .malformedResponse }
        guard let nonce = result["nonce"]?.string else { throw .malformedResponse }
        self.alg = alg
        self.salt = salt
        self.nonce = nonce
        self.hashMethod = result["hash-method"]?.string
    }
}

/// Computes the login hash GL.iNet's `login` RPC expects: a Unix-crypt of
/// the password with the challenge's algorithm and salt, then a digest of
/// `username:crypt:nonce` using the challenge's hash method.
public enum GLiNetLoginHasher {
    public static func loginHash(username: String, password: String, challenge: GLiNetChallenge) throws(GLiNetRPCError) -> String {
        let salt = sanitizedSalt(challenge.salt)

        let crypt: String
        switch challenge.alg {
        case 1: crypt = UnixCrypt.md5Crypt(password: password, salt: salt)
        case 5: crypt = UnixCrypt.sha256Crypt(password: password, salt: salt)
        case 6: crypt = UnixCrypt.sha512Crypt(password: password, salt: salt)
        default: throw .unsupportedAlgorithm(challenge.alg)
        }

        let material = Data("\(username):\(crypt):\(challenge.nonce)".utf8)
        switch challenge.hashMethod {
        case nil, "md5":
            return hexDigest(Insecure.MD5.hash(data: material))
        case "sha256":
            return hexDigest(SHA256.hash(data: material))
        case "sha512":
            return hexDigest(SHA512.hash(data: material))
        case let other?:
            throw .unsupportedHashMethod(other)
        }
    }

    /// Trims CR/LF and leading/trailing `$` from a salt the router sent us.
    private static func sanitizedSalt(_ salt: String) -> String {
        var trimmed = salt.trimmingCharacters(in: .init(charactersIn: "\r\n"))
        while trimmed.hasPrefix("$") { trimmed.removeFirst() }
        while trimmed.hasSuffix("$") { trimmed.removeLast() }
        return trimmed
    }

    private static func hexDigest<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

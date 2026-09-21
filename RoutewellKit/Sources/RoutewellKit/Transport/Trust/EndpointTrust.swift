import CryptoKit
import Foundation

/// A SHA-256 hash of a DER-encoded certificate.
public struct CertificateFingerprint: Sendable, Hashable, Codable {
    public let sha256: Data

    public init(sha256: Data) throws {
        guard sha256.count == 32 else { throw CertificateFingerprintError.invalidLength }
        self.sha256 = sha256
    }

    public init(derEncodedCertificate: Data) {
        let digest = SHA256.hash(data: derEncodedCertificate)
        sha256 = Data(digest)
    }

    /// "AB:CD:...:EF" — uppercase hex pairs separated by colons.
    public var display: String {
        sha256.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public enum CertificateFingerprintError: Error, Equatable, Sendable {
    case invalidLength
}

/// A certificate a person has explicitly approved for one router address.
public struct TrustedEndpoint: Sendable, Hashable, Codable {
    public let host: String
    public let port: Int
    public let fingerprint: CertificateFingerprint
    public let approvedAt: Date

    public init(host: String, port: Int, fingerprint: CertificateFingerprint, approvedAt: Date) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.approvedAt = approvedAt
    }
}

public protocol EndpointTrustStore: Sendable {
    func trusted(host: String, port: Int) async -> TrustedEndpoint?
    /// Replaces any existing entry for the same host:port.
    func approve(_ endpoint: TrustedEndpoint) async throws
    func revoke(host: String, port: Int) async throws
    func all() async -> [TrustedEndpoint]
}

private func trustKey(host: String, port: Int) -> String { "\(host):\(port)" }

public actor InMemoryEndpointTrustStore: EndpointTrustStore {
    private var entries: [String: TrustedEndpoint]

    public init(_ initial: [TrustedEndpoint] = []) {
        entries = Dictionary(uniqueKeysWithValues: initial.map { (trustKey(host: $0.host, port: $0.port), $0) })
    }

    public func trusted(host: String, port: Int) async -> TrustedEndpoint? {
        entries[trustKey(host: host, port: port)]
    }

    public func approve(_ endpoint: TrustedEndpoint) async throws {
        entries[trustKey(host: endpoint.host, port: endpoint.port)] = endpoint
    }

    public func revoke(host: String, port: Int) async throws {
        entries.removeValue(forKey: trustKey(host: host, port: port))
    }

    public func all() async -> [TrustedEndpoint] { Array(entries.values) }
}

public actor PersistentEndpointTrustStore: EndpointTrustStore {
    private let store: AtomicJSONStore
    private var entries: [String: TrustedEndpoint]
    private var revision: UInt64 = 0

    public init(store: AtomicJSONStore) async throws {
        self.store = store
        let loaded = try await store.load([TrustedEndpoint].self, from: .trust) ?? []
        entries = Dictionary(uniqueKeysWithValues: loaded.map { (trustKey(host: $0.host, port: $0.port), $0) })
    }

    public func trusted(host: String, port: Int) async -> TrustedEndpoint? {
        entries[trustKey(host: host, port: port)]
    }

    public func approve(_ endpoint: TrustedEndpoint) async throws {
        entries[trustKey(host: endpoint.host, port: endpoint.port)] = endpoint
        try await persist()
    }

    public func revoke(host: String, port: Int) async throws {
        entries.removeValue(forKey: trustKey(host: host, port: port))
        try await persist()
    }

    public func all() async -> [TrustedEndpoint] { Array(entries.values) }

    private func persist() async throws {
        revision += 1
        try await store.save(Array(entries.values), to: .trust, revision: revision)
    }
}

/// The outcome of comparing a live certificate against the system trust
/// evaluation and any previously approved fingerprint. A mismatch never trusts.
public enum TrustDecision: Sendable, Equatable {
    case trusted
    case untrustedNew(CertificateFingerprint)
    case untrustedChanged(expected: CertificateFingerprint, actual: CertificateFingerprint)
}

public enum TrustEvaluator {
    /// - Parameters:
    ///   - systemTrustSucceeded: the result of ordinary SecTrust evaluation.
    ///   - leaf: the fingerprint of the leaf certificate presented by the server.
    ///   - stored: any previously approved fingerprint for this host:port.
    public static func decide(systemTrustSucceeded: Bool, leaf: CertificateFingerprint, stored: TrustedEndpoint?) -> TrustDecision {
        if systemTrustSucceeded { return .trusted }
        guard let stored else { return .untrustedNew(leaf) }
        guard stored.fingerprint == leaf else {
            return .untrustedChanged(expected: stored.fingerprint, actual: leaf)
        }
        return .trusted
    }
}

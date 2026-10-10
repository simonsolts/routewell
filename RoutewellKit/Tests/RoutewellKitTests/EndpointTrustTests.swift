import Foundation
import Testing
@testable import RoutewellKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("routewell-trust-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fingerprint(_ byte: UInt8) -> CertificateFingerprint {
    try! CertificateFingerprint(sha256: Data(repeating: byte, count: 32))
}

@Test func fingerprintRequiresThirtyTwoBytes() {
    #expect(throws: CertificateFingerprintError.invalidLength) { try CertificateFingerprint(sha256: Data([1, 2, 3])) }
}

@Test func fingerprintDisplayIsUppercaseColonSeparatedHex() {
    let fp = try! CertificateFingerprint(sha256: Data([0xAB, 0xCD, 0xEF] + Array(repeating: 0, count: 29)))
    #expect(fp.display.hasPrefix("AB:CD:EF:"))
    #expect(fp.display.count == 32 * 3 - 1)
}

@Test func fingerprintFromDEREncodedCertificateIsDeterministic() {
    let der = Data("not a real certificate".utf8)
    let first = CertificateFingerprint(derEncodedCertificate: der)
    let second = CertificateFingerprint(derEncodedCertificate: der)
    #expect(first == second)
    #expect(first.sha256.count == 32)
}

@Test func evaluatorTrustsWhenSystemTrustSucceeds() {
    let decision = TrustEvaluator.decide(systemTrustSucceeded: true, leaf: fingerprint(1), stored: nil)
    #expect(decision == .trusted)
}

@Test func evaluatorFlagsUnknownCertificateWhenSystemTrustFails() {
    let decision = TrustEvaluator.decide(systemTrustSucceeded: false, leaf: fingerprint(1), stored: nil)
    #expect(decision == .untrustedNew(fingerprint(1)))
}

@Test func evaluatorTrustsMatchingStoredFingerprint() {
    let stored = TrustedEndpoint(host: "router.lan", port: 443, fingerprint: fingerprint(1), approvedAt: Date())
    let decision = TrustEvaluator.decide(systemTrustSucceeded: false, leaf: fingerprint(1), stored: stored)
    #expect(decision == .trusted)
}

@Test func evaluatorFlagsChangedFingerprintNeverTrusts() {
    let stored = TrustedEndpoint(host: "router.lan", port: 443, fingerprint: fingerprint(1), approvedAt: Date())
    let decision = TrustEvaluator.decide(systemTrustSucceeded: false, leaf: fingerprint(2), stored: stored)
    #expect(decision == .untrustedChanged(expected: fingerprint(1), actual: fingerprint(2)))
}

enum TrustStoreKind: CaseIterable, Sendable {
    case inMemory, persistent
}

/// `reopen` reads a persistent store's file again.
private func trustStore(_ kind: TrustStoreKind) async throws -> (store: any EndpointTrustStore, reopen: () async throws -> any EndpointTrustStore, directory: URL?) {
    switch kind {
    case .inMemory:
        let store = InMemoryEndpointTrustStore()
        return (store, { store }, nil)
    case .persistent:
        let directory = try temporaryDirectory()
        let open = { try await PersistentEndpointTrustStore(store: AtomicJSONStore(directory: directory)) as any EndpointTrustStore }
        return (try await open(), open, directory)
    }
}

@Test(arguments: TrustStoreKind.allCases)
func storeApprovesReplacesAndRevokes(kind: TrustStoreKind) async throws {
    let (store, reopen, directory) = try await trustStore(kind)
    defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
    let entry = TrustedEndpoint(host: "router.lan", port: 443, fingerprint: fingerprint(1), approvedAt: Date())
    #expect(await store.trusted(host: "router.lan", port: 443) == nil)
    try await store.approve(entry)
    #expect(try await reopen().trusted(host: "router.lan", port: 443) == entry)

    let replacement = TrustedEndpoint(host: "router.lan", port: 443, fingerprint: fingerprint(2), approvedAt: Date())
    try await store.approve(replacement)
    #expect(await store.all() == [replacement])
    #expect(try await reopen().all() == [replacement])

    try await store.revoke(host: "router.lan", port: 443)
    #expect(await store.trusted(host: "router.lan", port: 443) == nil)
    #expect(try await reopen().all().isEmpty)
}

@Test func persistentStoreApproveKeepsOldValueWhenSaveFails() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = TrustedEndpoint(host: "router.lan", port: 443, fingerprint: fingerprint(1), approvedAt: Date())
    try await AtomicJSONStore(directory: directory).save([original], to: .trust, revision: 1)

    let failingStore = AtomicJSONStore(directory: directory, beforeCommit: { throw StoreError.writeFailed })
    let store = try await PersistentEndpointTrustStore(store: failingStore)
    #expect(await store.trusted(host: "router.lan", port: 443) == original)

    let replacement = TrustedEndpoint(host: "router.lan", port: 443, fingerprint: fingerprint(2), approvedAt: Date())
    await #expect(throws: StoreError.writeFailed) { try await store.approve(replacement) }
    #expect(await store.trusted(host: "router.lan", port: 443) == original)
    #expect(await store.all() == [original])

    // The failed write must not have reached disk either.
    let reloaded = try await PersistentEndpointTrustStore(store: AtomicJSONStore(directory: directory))
    #expect(await reloaded.all() == [original])
}

@Test func persistentStoreRevokeKeepsOldValueWhenSaveFails() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = TrustedEndpoint(host: "router.lan", port: 443, fingerprint: fingerprint(1), approvedAt: Date())
    try await AtomicJSONStore(directory: directory).save([original], to: .trust, revision: 1)

    let failingStore = AtomicJSONStore(directory: directory, beforeCommit: { throw StoreError.writeFailed })
    let store = try await PersistentEndpointTrustStore(store: failingStore)

    await #expect(throws: StoreError.writeFailed) { try await store.revoke(host: "router.lan", port: 443) }
    #expect(await store.trusted(host: "router.lan", port: 443) == original)
}

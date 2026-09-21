import CryptoKit
import Foundation
import Testing
@testable import RoutewellKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("routewell-ssh-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - SSHTarget

@Test func sshTargetAcceptsHostnameIPv4AndIPv6() throws {
    _ = try SSHTarget(host: "router.lan", port: 22, user: "root")
    _ = try SSHTarget(host: "192.168.8.1", port: 22, user: "root")
    _ = try SSHTarget(host: "fd00::1", port: 22, user: "root")
}

@Test func sshTargetRejectsInvalidHost() {
    #expect(throws: SSHTargetError.invalidHost) { _ = try SSHTarget(host: "", port: 22, user: "root") }
    #expect(throws: SSHTargetError.invalidHost) { _ = try SSHTarget(host: "-bad.lan", port: 22, user: "root") }
    #expect(throws: SSHTargetError.invalidHost) { _ = try SSHTarget(host: "bad-.lan", port: 22, user: "root") }
    #expect(throws: SSHTargetError.invalidHost) { _ = try SSHTarget(host: "bad_host.lan", port: 22, user: "root") }
}

@Test func sshTargetRejectsInvalidPort() {
    #expect(throws: SSHTargetError.invalidPort) { _ = try SSHTarget(host: "router.lan", port: 0, user: "root") }
    #expect(throws: SSHTargetError.invalidPort) { _ = try SSHTarget(host: "router.lan", port: 65536, user: "root") }
}

@Test func sshTargetRejectsInvalidUser() {
    #expect(throws: SSHTargetError.invalidUser) { _ = try SSHTarget(host: "router.lan", port: 22, user: "root;rm") }
    #expect(throws: SSHTargetError.invalidUser) { _ = try SSHTarget(host: "router.lan", port: 22, user: "") }
    #expect(throws: SSHTargetError.invalidUser) { _ = try SSHTarget(host: "router.lan", port: 22, user: "Root") }
    #expect(throws: SSHTargetError.invalidUser) { _ = try SSHTarget(host: "router.lan", port: 22, user: "9root") }
}

// MARK: - SSHLauncher

@Test func launchPlanArgvForKeyFile() throws {
    let target = try SSHTarget(host: "router.lan", port: 22, user: "root")
    let plan = try SSHLauncher.plan(
        target: target,
        identity: .keyFile(URL(fileURLWithPath: "/keys/id_ed25519")),
        knownHostsFile: URL(fileURLWithPath: "/support/known_hosts"),
        command: .uptime
    )
    #expect(plan.executable == URL(fileURLWithPath: "/usr/bin/ssh"))
    #expect(plan.arguments == [
        "-F", "/dev/null",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=/support/known_hosts",
        "-o", "ConnectTimeout=10",
        "-o", "ClearAllForwardings=yes",
        "-o", "IdentitiesOnly=yes",
        "-i", "/keys/id_ed25519",
        "-o", "IdentityAgent=none",
        "-T", "-a", "-x",
        "-p", "22",
        "--", "root@router.lan",
        "uptime",
    ])
}

@Test func launchPlanArgvForAgentWithIPv6Host() throws {
    let target = try SSHTarget(host: "fd00::1", port: 2222, user: "admin")
    let plan = try SSHLauncher.plan(
        target: target,
        identity: .agent,
        knownHostsFile: URL(fileURLWithPath: "/support/known_hosts"),
        command: .dhcpLeases,
        agentSocket: URL(fileURLWithPath: "/tmp/ssh-agent.sock")
    )
    #expect(plan.arguments == [
        "-F", "/dev/null",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=/support/known_hosts",
        "-o", "ConnectTimeout=10",
        "-o", "ClearAllForwardings=yes",
        "-o", "IdentityAgent=/tmp/ssh-agent.sock",
        "-T", "-a", "-x",
        "-p", "2222",
        "--", "admin@fd00::1",
        "cat /tmp/dhcp.leases",
    ])
}

@Test func agentIdentityWithoutSocketThrows() throws {
    let target = try SSHTarget(host: "router.lan", port: 22, user: "root")
    #expect(throws: SSHLaunchError.agentSocketRequired) {
        _ = try SSHLauncher.plan(target: target, identity: .agent, knownHostsFile: URL(fileURLWithPath: "/x"), command: .uptime)
    }
}

// MARK: - SSHHostKeyStore

@Test func hostKeyStoreApproveReplaceAndRevokeRoundTrip() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SSHHostKeyStore(directory: directory)

    #expect(try await store.storedKeyLine(host: "router.lan", port: 22) == nil)

    try await store.approve(host: "router.lan", port: 22, keyLine: "router.lan ssh-ed25519 AAAA")
    #expect(try await store.storedKeyLine(host: "router.lan", port: 22) == "router.lan ssh-ed25519 AAAA")

    try await store.approve(host: "router.lan", port: 22, keyLine: "router.lan ssh-ed25519 BBBB")
    #expect(try await store.storedKeyLine(host: "router.lan", port: 22) == "router.lan ssh-ed25519 BBBB")

    let attributes = try FileManager.default.attributesOfItem(atPath: store.knownHostsFile.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

    try await store.revoke(host: "router.lan", port: 22)
    #expect(try await store.storedKeyLine(host: "router.lan", port: 22) == nil)
}

@Test func hostKeyStoreDistinguishesNonDefaultPort() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SSHHostKeyStore(directory: directory)

    try await store.approve(host: "router.lan", port: 2222, keyLine: "[router.lan]:2222 ssh-ed25519 AAAA")
    #expect(try await store.storedKeyLine(host: "router.lan", port: 2222) == "[router.lan]:2222 ssh-ed25519 AAAA")
    #expect(try await store.storedKeyLine(host: "router.lan", port: 22) == nil)

    try await store.approve(host: "router.lan", port: 22, keyLine: "router.lan ssh-ed25519 BBBB")
    #expect(try await store.storedKeyLine(host: "router.lan", port: 2222) == "[router.lan]:2222 ssh-ed25519 AAAA")
    #expect(try await store.storedKeyLine(host: "router.lan", port: 22) == "router.lan ssh-ed25519 BBBB")
}

// MARK: - SSHHostKeyScanner

@Test func scannerPlanBuildsExpectedArgv() {
    let plan = SSHHostKeyScanner.plan(host: "router.lan", port: 2222)
    #expect(plan.executable == URL(fileURLWithPath: "/usr/bin/ssh-keyscan"))
    #expect(plan.arguments == ["-p", "2222", "-T", "10", "-t", "ed25519,ecdsa,rsa", "--", "router.lan"])
}

@Test func scannerParsesLineAndComputesMatchingFingerprint() throws {
    // No `ssh-keygen`/`ssh-keyscan` invocation: the key blob is fabricated bytes, and
    // the expected fingerprint is computed independently, the same way the scanner
    // does (SHA-256 over the decoded blob, unpadded base64, "SHA256:" prefix).
    let keyMaterial = Data("test-ed25519-key-material".utf8)
    let keyBase64 = keyMaterial.base64EncodedString()
    let expectedDigest = SHA256.hash(data: keyMaterial)
    let expectedFingerprint = "SHA256:" + Data(expectedDigest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    let line = "[192.168.8.1]:22 ssh-ed25519 \(keyBase64)"

    let candidates = SSHHostKeyScanner.parse(Data(line.utf8), host: "192.168.8.1", port: 22)

    #expect(candidates.count == 1)
    #expect(candidates.first?.keyLine == line)
    #expect(candidates.first?.fingerprintSHA256 == expectedFingerprint)
}

@Test func scannerSkipsCommentsAndMalformedLines() {
    let output = "# comment\nnot-enough-fields\n"
    #expect(SSHHostKeyScanner.parse(Data(output.utf8), host: "router.lan", port: 22).isEmpty)
}

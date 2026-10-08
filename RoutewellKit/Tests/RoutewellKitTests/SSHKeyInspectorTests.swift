import Foundation
import Testing
@testable import RoutewellKit

// MARK: - Synthetic key builders (no real key material)

private func uint32(_ value: Int) -> Data {
    Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
}

private func sshString(_ bytes: Data) -> Data { uint32(bytes.count) + bytes }
private func sshString(_ text: String) -> Data { sshString(Data(text.utf8)) }

private func armour(_ label: String, body: String, eol: String = "\n") -> String {
    ["-----BEGIN \(label)-----", body, "-----END \(label)-----"].joined(separator: eol) + eol
}

/// Wrapped base64, 70 characters per line.
private func wrapped(_ data: Data) -> String {
    let encoded = data.base64EncodedString()
    return stride(from: 0, to: encoded.count, by: 70).map { start in
        let from = encoded.index(encoded.startIndex, offsetBy: start)
        let to = encoded.index(from, offsetBy: 70, limitedBy: encoded.endIndex) ?? encoded.endIndex
        return String(encoded[from..<to])
    }.joined(separator: "\n")
}

private func openSSHBinary(cipher: String = "none", kdf: String = "none", keyType: String) -> Data {
    let kdfOptions = kdf == "none" ? Data() : sshString(Data(repeating: 7, count: 24) + uint32(16))
    let publicBlob = sshString(keyType) + sshString(Data(repeating: 1, count: 32))
    let privateSection = Data(repeating: 2, count: 64)
    return Data("openssh-key-v1\0".utf8)
        + sshString(cipher) + sshString(kdf) + sshString(kdfOptions)
        + uint32(1) + sshString(publicBlob) + sshString(privateSection)
}

private func openSSHKey(cipher: String = "none", kdf: String = "none", keyType: String) -> String {
    armour("OPENSSH PRIVATE KEY", body: wrapped(openSSHBinary(cipher: cipher, kdf: kdf, keyType: keyType)))
}

private let dummyBody = Data(repeating: 3, count: 120).base64EncodedString()

// MARK: - OpenSSH new format

@Test(arguments: [
    ("ssh-ed25519", "ED25519"),
    ("ssh-rsa", "RSA"),
    ("ecdsa-sha2-nistp256", "ECDSA"),
    ("ecdsa-sha2-nistp384", "ECDSA"),
    ("ecdsa-sha2-nistp521", "ECDSA"),
    ("ssh-dss", "DSA"),
    ("sk-ssh-ed25519@openssh.com", "ED25519-SK"),
    ("sk-ecdsa-sha2-nistp256@openssh.com", "ECDSA-SK"),
])
func plainOpenSSHKeyIsUsable(keyType: String, kind: String) {
    let key = openSSHKey(keyType: keyType)
    #expect(SSHKeyInspector.inspect(Data(key.utf8)) == .usable(kind: kind))
}

@Test func plainOpenSSHKeyNamesEachType() {
    #expect(SSHKeyInspector.inspect(Data(openSSHKey(keyType: "ssh-ed25519").utf8)).displayType == "ED25519 private key")
    #expect(SSHKeyInspector.inspect(Data(openSSHKey(keyType: "ssh-rsa").utf8)).displayType == "RSA private key")
    #expect(SSHKeyInspector.inspect(Data(openSSHKey(keyType: "ecdsa-sha2-nistp256").utf8)).displayType == "ECDSA private key")
}

@Test func unknownOpenSSHKeyTypeIsUsableWithoutKind() {
    let key = openSSHKey(keyType: "ssh-future")
    #expect(SSHKeyInspector.inspect(Data(key.utf8)) == .usable(kind: nil))
}

@Test func encryptedOpenSSHKeyIsPassphraseProtected() {
    let key = openSSHKey(cipher: "aes256-ctr", kdf: "bcrypt", keyType: "ssh-ed25519")
    #expect(SSHKeyInspector.inspect(Data(key.utf8)) == .passphraseProtected)
}

@Test func truncatedOpenSSHKeyIsNotAKey() {
    let binary = openSSHBinary(keyType: "ssh-ed25519")
    // Cut at every length before the end of the public key: never a crash, never usable.
    for length in 0..<(binary.count - 68) {
        let key = armour("OPENSSH PRIVATE KEY", body: wrapped(binary.prefix(length)))
        #expect(SSHKeyInspector.inspect(Data(key.utf8)) == .notAKey, "length \(length)")
    }
}

@Test func malformedOpenSSHKeysAreNotAKey() {
    // Wrong magic.
    var wrongMagic = openSSHBinary(keyType: "ssh-ed25519")
    wrongMagic[0] = UInt8(ascii: "X")
    // String length far larger than the data.
    let hugeLength = Data("openssh-key-v1\0".utf8) + uint32(Int(UInt32.max)) + Data("none".utf8)
    // Zero keys.
    var zeroKeys = Data("openssh-key-v1\0".utf8)
    zeroKeys += sshString("none") + sshString("none") + sshString("") + uint32(0)
    // Public blob without a key type.
    var noType = Data("openssh-key-v1\0".utf8)
    noType += sshString("none") + sshString("none") + sshString("") + uint32(1) + sshString(Data())

    for binary in [wrongMagic, hugeLength, zeroKeys, noType] {
        let key = armour("OPENSSH PRIVATE KEY", body: wrapped(binary))
        #expect(SSHKeyInspector.inspect(Data(key.utf8)) == .notAKey)
    }
    #expect(SSHKeyInspector.inspect(Data(armour("OPENSSH PRIVATE KEY", body: "not base64 !!!").utf8)) == .notAKey)
}

@Test func openSSHKeyWithoutEndLineIsNotAKey() {
    let key = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + wrapped(openSSHBinary(keyType: "ssh-ed25519")) + "\n"
    #expect(SSHKeyInspector.inspect(Data(key.utf8)) == .notAKey)
}

@Test func crlfLineEndingsAndSurroundingWhitespaceAreFine() {
    let key = armour(
        "OPENSSH PRIVATE KEY",
        body: wrapped(openSSHBinary(keyType: "ssh-ed25519")).replacingOccurrences(of: "\n", with: "\r\n"),
        eol: "\r\n"
    )
    #expect(SSHKeyInspector.inspect(Data(key.utf8)) == .usable(kind: "ED25519"))
    #expect(SSHKeyInspector.inspect(Data(("\n  \r\n" + key + "\r\n \n").utf8)) == .usable(kind: "ED25519"))
}

// MARK: - PEM and PKCS#8

@Test func plainPEMKeysAreUsable() {
    #expect(SSHKeyInspector.inspect(Data(armour("RSA PRIVATE KEY", body: dummyBody).utf8)) == .usable(kind: "RSA"))
    #expect(SSHKeyInspector.inspect(Data(armour("EC PRIVATE KEY", body: dummyBody).utf8)) == .usable(kind: "ECDSA"))
    #expect(SSHKeyInspector.inspect(Data(armour("DSA PRIVATE KEY", body: dummyBody).utf8)) == .usable(kind: "DSA"))
}

@Test func encryptedPEMRSAKeyIsPassphraseProtected() {
    let body = "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00112233445566778899AABBCCDDEEFF\n\n" + dummyBody
    #expect(SSHKeyInspector.inspect(Data(armour("RSA PRIVATE KEY", body: body).utf8)) == .passphraseProtected)
}

@Test func pemKeyWithOnlyDEKInfoIsPassphraseProtected() {
    let body = "DEK-Info: AES-128-CBC,00112233445566778899AABBCCDDEEFF\n\n" + dummyBody
    #expect(SSHKeyInspector.inspect(Data(armour("EC PRIVATE KEY", body: body).utf8)) == .passphraseProtected)
}

@Test func encryptedPKCS8IsPassphraseProtected() {
    #expect(SSHKeyInspector.inspect(Data(armour("ENCRYPTED PRIVATE KEY", body: dummyBody).utf8)) == .passphraseProtected)
}

@Test func plainPKCS8IsUsableWithoutKind() {
    #expect(SSHKeyInspector.inspect(Data(armour("PRIVATE KEY", body: dummyBody).utf8)) == .usable(kind: nil))
}

@Test func pemWithEmptyBodyIsNotAKey() {
    #expect(SSHKeyInspector.inspect(Data("-----BEGIN RSA PRIVATE KEY-----\n-----END RSA PRIVATE KEY-----\n".utf8)) == .notAKey)
}

// MARK: - Public keys

@Test(arguments: [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyDummyDummyDummyDummyDummyDummyDummy",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummy simon@laptop",
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDummy my key comment\n",
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDummy router\r\n",
    "-----BEGIN SSH2 PUBLIC KEY-----\nComment: \"2048-bit RSA\"\nAAAAB3NzaC1yc2E=\n-----END SSH2 PUBLIC KEY-----\n",
    "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDummy\n-----END PUBLIC KEY-----\n",
])
func publicKeysAreDetected(text: String) {
    #expect(SSHKeyInspector.inspect(Data(text.utf8)) == .publicKey)
}

@Test func publicKeyBuiltFromWireFormatIsDetected() {
    let blob = sshString("ssh-ed25519") + sshString(Data(repeating: 1, count: 32))
    let line = "ssh-ed25519 \(blob.base64EncodedString()) simon@laptop\n"
    #expect(SSHKeyInspector.inspect(Data(line.utf8)) == .publicKey)
}

// MARK: - Not a key

@Test func randomTextIsNotAKey() {
    #expect(SSHKeyInspector.inspect(Data("hello world\nthis is not a key\n".utf8)) == .notAKey)
    #expect(SSHKeyInspector.inspect(Data("ssh-ed25519".utf8)) == .notAKey)
    #expect(SSHKeyInspector.inspect(Data("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n".utf8)) == .notAKey)
}

@Test func emptyAndBlankDataIsNotAKey() {
    #expect(SSHKeyInspector.inspect(Data()) == .notAKey)
    #expect(SSHKeyInspector.inspect(Data(" \r\n\t\n".utf8)) == .notAKey)
}

@Test func nonUTF8DataIsNotAKey() {
    #expect(SSHKeyInspector.inspect(Data([0xFF, 0xFE, 0x00, 0xC3, 0x28])) == .notAKey)
}

// MARK: - Files

private func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SSHKeyInspectorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

@Test func readsAKeyFromAFile() throws {
    try withTempDirectory { directory in
        let url = directory.appendingPathComponent("id_ed25519")
        try Data(openSSHKey(keyType: "ssh-ed25519").utf8).write(to: url)
        #expect(SSHKeyInspector.inspect(fileAt: url) == .usable(kind: "ED25519"))
    }
}

@Test func fileAtTheLimitIsReadAndOverItIsUnreadable() throws {
    try withTempDirectory { directory in
        let atLimit = directory.appendingPathComponent("at-limit")
        try Data(repeating: UInt8(ascii: "a"), count: SSHKeyInspector.maxBytes).write(to: atLimit)
        #expect(SSHKeyInspector.inspect(fileAt: atLimit) == .notAKey)

        let over = directory.appendingPathComponent("over-limit")
        try Data(repeating: UInt8(ascii: "a"), count: SSHKeyInspector.maxBytes + 1).write(to: over)
        #expect(SSHKeyInspector.inspect(fileAt: over) == .unreadable)
    }
}

@Test func missingFileIsUnreadable() throws {
    try withTempDirectory { directory in
        #expect(SSHKeyInspector.inspect(fileAt: directory.appendingPathComponent("nope")) == .unreadable)
    }
}

@Test func directoryIsUnreadable() throws {
    try withTempDirectory { directory in
        #expect(SSHKeyInspector.inspect(fileAt: directory) == .unreadable)
    }
}

@Test func emptyFileIsNotAKey() throws {
    try withTempDirectory { directory in
        let url = directory.appendingPathComponent("empty")
        try Data().write(to: url)
        #expect(SSHKeyInspector.inspect(fileAt: url) == .notAKey)
    }
}

// MARK: - Display type

@Test func displayTypeStrings() {
    #expect(SSHKeyInspection.usable(kind: "ED25519").displayType == "ED25519 private key")
    #expect(SSHKeyInspection.usable(kind: "RSA").displayType == "RSA private key")
    #expect(SSHKeyInspection.usable(kind: "ECDSA-SK").displayType == "ECDSA-SK private key")
    #expect(SSHKeyInspection.usable(kind: nil).displayType == "Private key")
}

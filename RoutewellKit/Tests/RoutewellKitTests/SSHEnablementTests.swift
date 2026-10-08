import Foundation
import Testing
@testable import RoutewellKit
import RoutewellMock

// Chunk 15. The SSH fixtures under `Fixtures/ssh/router/` follow the formats
// recorded on firmware 4.9.1 (`recorded-chunk-15`, kept local) with neutral
// values: documentation addresses, `02:00:…` MACs, example names, PIDs, and
// sizes. Log tags the recording did not contain (hostapd, netifd, odhcpd,
// firewall, AdGuardHome, openvpn, block, procd) and the telemetry values
// stay `[assumed]`. No test starts `ssh` or `ssh-keyscan`.

private func sshFixture(_ name: String, subdirectory: String = "Fixtures/ssh/router") throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: subdirectory))
    return try String(contentsOf: url, encoding: .utf8)
}

private func temporaryDirectory(_ name: String = "routewell ssh \(UUID())") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func result(_ status: Int32 = 0, _ stdout: String = "", stderr: String = "") -> ProcessResult {
    ProcessResult(exitStatus: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), stdoutTruncated: false, stderrTruncated: false)
}

/// Serves canned replies per command and records each command. Never runs ssh.
private actor ScriptedSSHRunner: SSHCommandRunning {
    enum Reply: Sendable { case output(Int32, String), failure(SSHFailure) }
    private var replies: [String: Reply]
    private(set) var commands: [SSHCommand] = []
    var fallback: Reply = .failure(.commandFailed(exitStatus: 127))

    init(_ replies: [SSHCommand: Reply] = [:]) {
        self.replies = Dictionary(uniqueKeysWithValues: replies.map { ($0.key.rendered, $0.value) })
    }

    func set(_ command: SSHCommand, _ reply: Reply) { replies[command.rendered] = reply }

    func run(_ command: SSHCommand, limits: ProcessLimits) async throws -> ProcessResult {
        commands.append(command)
        switch replies[command.rendered] ?? fallback {
        case .output(let status, let text): return result(status, text)
        case .failure(let failure): throw failure
        }
    }
}

/// Records argv and concurrency; returns one canned result. Never starts a process.
private actor FakeProcesses: ProcessRunning {
    private let reply: Result<ProcessResult, ProcessRunnerError>
    private let delay: Duration
    private(set) var launches: [[String]] = []
    private(set) var executables: [URL] = []
    private var running = 0
    private(set) var maxRunning = 0

    init(_ reply: Result<ProcessResult, ProcessRunnerError>, delay: Duration = .zero) {
        self.reply = reply
        self.delay = delay
    }

    func run(executable: URL, arguments: [String], environment: [String: String], limits: ProcessLimits) async throws -> ProcessResult {
        launches.append(arguments)
        executables.append(executable)
        running += 1
        maxRunning = max(maxRunning, running)
        defer { running -= 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try reply.get()
    }
}

private let keyA = Data((0..<51).map { UInt8($0) }).base64EncodedString()
private let keyB = Data((0..<51).map { UInt8(255 - $0) }).base64EncodedString()
private let keyRSA = Data((0..<279).map { UInt8($0 % 256) }).base64EncodedString()

private func keyscanOutput(ed25519: String = keyA) -> Data {
    Data("""
    # 192.0.2.1:22 SSH-2.0-dropbear
    192.0.2.1 ssh-rsa \(keyRSA)
    192.0.2.1 ssh-ed25519 \(ed25519)
    """.utf8)
}

// MARK: - SSH setup persistence

@Test func sshSettingsRoundTripAndOlderProfilesStillLoad() throws {
    let endpoint = try RouterEndpoint(scheme: .https, host: "192.0.2.1", port: 443)
    let profile = RouterProfile(name: "Home", liveEndpoint: endpoint,
                                ssh: SSHSettings(enabled: true, port: 2222, user: "root", keyFilePath: "/Users/me/.ssh/id_ed25519",
                                                 keyFileBookmark: Data([1, 2, 3])))
    let decoded = try JSONDecoder().decode(RouterProfile.self, from: JSONEncoder().encode(profile))
    #expect(decoded.ssh == profile.ssh)
    #expect(decoded.ssh?.keyFileBookmark == Data([1, 2, 3]))
    #expect(decoded.ssh?.identity == .keyFile(URL(fileURLWithPath: "/Users/me/.ssh/id_ed25519")))

    // Saved before chunk 15 added `useAgent`.
    let old = try JSONDecoder().decode(SSHSettings.self, from: Data(#"{"enabled":false,"port":22,"user":"root"}"#.utf8))
    #expect(old == SSHSettings())
    #expect(old.identity == nil)
    #expect(SSHSettings(useAgent: true).identity == .agent)
    #expect(SSHSettings(keyFilePath: "relative/key").identity == nil)
    // The type has no password field to fill.
    let keys = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(SSHSettings(useAgent: true))) as? [String: Any]).keys
    #expect(Set(keys) == ["enabled", "port", "user", "useAgent"])
}

// MARK: - Host-key trust

@Test func hostKeyNewKeyIsStoredOnlyWhenAccepted() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SSHHostKeyStore(directory: directory)
    let candidates = SSHHostKeyScanner.parse(keyscanOutput(), host: "192.0.2.1", port: 22)
    #expect(candidates.count == 2)

    let evaluation = try #require(SSHHostKeyTrust.evaluate(candidates, trustedKeyLine: nil))
    guard case .new(let candidate) = evaluation else { Issue.record("expected a new key"); return }
    #expect(candidate.algorithm == "ssh-ed25519")
    #expect(candidate.fingerprintSHA256.hasPrefix("SHA256:"))

    // Reject: nothing is stored.
    #expect(SSHHostKeyTrust.decide(evaluation, approved: false) == .rejected)
    #expect(try await store.storedKeyLine(host: "192.0.2.1", port: 22) == nil)

    // Accept: the exact key is stored with the host field ssh looks up.
    #expect(SSHHostKeyTrust.decide(evaluation, approved: true) == .trusted)
    try await SSHHostKeyTrust.store(candidate, host: "192.0.2.1", port: 22, in: store)
    #expect(try await store.storedKeyLine(host: "192.0.2.1", port: 22) == "192.0.2.1 ssh-ed25519 \(keyA)")
    #expect(candidate.normalized(host: "router.lan", port: 2222) == "[router.lan]:2222 ssh-ed25519 \(keyA)")

    let again = SSHHostKeyTrust.evaluate(candidates, trustedKeyLine: "192.0.2.1 ssh-ed25519 \(keyA)")
    #expect(again == .matches(candidate))
    #expect(SSHHostKeyTrust.decide(again!, approved: false) == .trusted)
}

@Test func hostKeyMismatchAlwaysRejectsWhateverTheAnswer() throws {
    let trusted = "192.0.2.1 ssh-ed25519 \(keyA)"
    let changed = SSHHostKeyScanner.parse(keyscanOutput(ed25519: keyB), host: "192.0.2.1", port: 22)
    let evaluation = try #require(SSHHostKeyTrust.evaluate(changed, trustedKeyLine: trusted))
    guard case .changed(let old, let presented) = evaluation else { Issue.record("expected a changed key"); return }
    #expect(old == SSHHostKeyCandidate(keyLine: trusted)?.fingerprintSHA256)
    #expect(presented.key == keyB)
    #expect(old != presented.fingerprintSHA256)
    #expect(SSHHostKeyTrust.decide(evaluation, approved: true) == .rejected)
    #expect(SSHHostKeyTrust.decide(evaluation, approved: false) == .rejected)
}

@Test func liveScannerRunsKeyscanWithoutCredentialsAndMapsFailures() async throws {
    let processes = FakeProcesses(.success(result(0, String(decoding: keyscanOutput(), as: UTF8.self))))
    let candidates = try await LiveSSHHostKeyScanner(processes: processes).scan(host: "192.0.2.1", port: 22)
    #expect(candidates.count == 2)
    #expect(await processes.executables == [URL(fileURLWithPath: "/usr/bin/ssh-keyscan")])
    #expect(await processes.launches == [["-p", "22", "-T", "10", "-t", "ed25519,ecdsa,rsa", "--", "192.0.2.1"]])

    let refused = FakeProcesses(.success(result(1, "", stderr: "connect to host 192.0.2.1 port 22: Connection refused")))
    await #expect(throws: SSHFailure.connectionFailed) { _ = try await LiveSSHHostKeyScanner(processes: refused).scan(host: "192.0.2.1", port: 22) }
    let silent = FakeProcesses(.success(result(0, "")))
    await #expect(throws: SSHFailure.connectionFailed) { _ = try await LiveSSHHostKeyScanner(processes: silent).scan(host: "192.0.2.1", port: 22) }
    let slow = FakeProcesses(.failure(.timedOut))
    await #expect(throws: SSHFailure.timedOut) { _ = try await LiveSSHHostKeyScanner(processes: slow).scan(host: "192.0.2.1", port: 22) }
    await #expect(throws: SSHFailure.configurationFailed) { _ = try await LiveSSHHostKeyScanner(processes: slow).scan(host: "-oProxyCommand=x", port: 22) }
}

// MARK: - Live runner

private func trustedRunner(processes: FakeProcesses, identity: SSHIdentity = .keyFile(URL(fileURLWithPath: "/Users/me/.ssh/id_ed25519")),
                           trust: Bool = true) async throws -> (LiveSSHCommandRunner, URL) {
    let directory = try temporaryDirectory()
    let store = SSHHostKeyStore(directory: directory)
    if trust { try await store.approve(host: "192.0.2.1", port: 22, keyLine: "192.0.2.1 ssh-ed25519 \(keyA)") }
    let connection = SSHConnection(target: try SSHTarget(host: "192.0.2.1", port: 22, user: "root"), identity: identity,
                                   agentSocket: identity == .agent ? URL(fileURLWithPath: "/tmp/agent.sock") : nil)
    return (LiveSSHCommandRunner(connection: connection, hostKeys: store, processes: processes), directory)
}

@Test func runnerSendsNothingUntilAHostKeyIsTrusted() async throws {
    let processes = FakeProcesses(.success(result(0, "{}")))
    let (runner, directory) = try await trustedRunner(processes: processes, trust: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: SSHFailure.hostKeyNotTrusted) { _ = try await runner.run(.systemBoard, limits: .init()) }
    #expect(await processes.launches.isEmpty)
}

@Test func runnerUsesStrictKeyOnlyArgvAndQuotesPathsWithSpaces() async throws {
    let processes = FakeProcesses(.success(result(0, "{}")))
    let (runner, directory) = try await trustedRunner(processes: processes)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await runner.run(.systemBoard, limits: .init())
    let argv = try #require(await processes.launches.first)
    #expect(await processes.executables == [URL(fileURLWithPath: "/usr/bin/ssh")])
    #expect(Array(argv.prefix(2)) == ["-F", "/dev/null"])
    #expect(argv.contains("BatchMode=yes") && argv.contains("StrictHostKeyChecking=yes") && argv.contains("IdentitiesOnly=yes"))
    #expect(!argv.contains { $0.localizedCaseInsensitiveContains("StrictHostKeyChecking=no") || $0.localizedCaseInsensitiveContains("password") })
    let knownHosts = try #require(argv.first { $0.hasPrefix("UserKnownHostsFile=") })
    #expect(knownHosts == "UserKnownHostsFile=\"\(directory.appendingPathComponent("known_hosts").path)\"")
    #expect(argv.last == "ubus call system board")

    let agentProcesses = FakeProcesses(.success(result(0, "{}")))
    let (agentRunner, agentDirectory) = try await trustedRunner(processes: agentProcesses, identity: .agent)
    defer { try? FileManager.default.removeItem(at: agentDirectory) }
    _ = try await agentRunner.run(.systemBoard, limits: .init())
    let agentArgv = try #require(await agentProcesses.launches.first)
    #expect(agentArgv.contains("IdentityAgent=/tmp/agent.sock") && !agentArgv.contains("-i"))

    #expect(throws: SSHLaunchError.invalidPath) {
        _ = try SSHLauncher.plan(target: try SSHTarget(host: "192.0.2.1", port: 22, user: "root"),
                                 identity: .keyFile(URL(fileURLWithPath: "/keys/%h")), knownHostsFile: URL(fileURLWithPath: "/k"), command: .uptime)
    }
}

@Test func runnerMapsSSHErrorsToTypedFailures() async throws {
    let cases: [(String, SSHFailure)] = [
        ("Host key verification failed.", .hostKeyChanged),
        ("root@192.0.2.1: Permission denied (publickey).", .authenticationFailed),
        ("ssh: connect to host 192.0.2.1 port 22: Connection refused", .connectionFailed),
        ("ssh: connect to host 192.0.2.1 port 22: Operation timed out", .timedOut),
        ("ssh: connect to host 192.0.2.1 port 22: No route to host", .networkFailed),
        ("Warning: Identity file /x not accessible: No such file or directory.\nLoad key \"/x\": invalid format", .configurationFailed),
        ("something new", .other("ssh")),
    ]
    for (stderr, expected) in cases {
        let processes = FakeProcesses(.success(result(255, "", stderr: stderr)))
        let (runner, directory) = try await trustedRunner(processes: processes)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: expected, "\(stderr)") { _ = try await runner.run(.systemBoard, limits: .init()) }
    }
    let slow = FakeProcesses(.failure(.timedOut))
    let (runner, directory) = try await trustedRunner(processes: slow)
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: SSHFailure.timedOut) { _ = try await runner.run(.systemBoard, limits: .init()) }
    // The remote command's own non-zero status is output, not an ssh failure.
    let ping = FakeProcesses(.success(result(1, "3 packets transmitted, 0 packets received")))
    let (pingRunner, pingDirectory) = try await trustedRunner(processes: ping)
    defer { try? FileManager.default.removeItem(at: pingDirectory) }
    #expect(try await pingRunner.run(.systemBoard, limits: .init()).exitStatus == 1)
}

/// The block OpenSSH 10 prints on every connection to the router's Dropbear `[verified live]`.
private let postQuantumWarning = """
** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
** The server may need to be upgraded. See https://openssh.com/pq.html
"""

@Test func sshClientWarningNeverReachesAParserOrAClassification() async throws {
    // `pgrep` found nothing: exit 1, and only the ssh client's warning on stderr.
    let processes = FakeProcesses(.success(result(1, "", stderr: postQuantumWarning)))
    let (runner, directory) = try await trustedRunner(processes: processes)
    defer { try? FileManager.default.removeItem(at: directory) }
    let checked = try await runner.run(.adGuardProcess, limits: .init())
    #expect(checked.stderr.isEmpty || String(decoding: checked.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(try await LiveSSHService(runner: runner).adGuardProcess() == .unavailable)
    #expect(SSHResultClassifier.classify(stderr: SSHResultClassifier.clientWarningsRemoved(postQuantumWarning + "\nConnection closed by 192.0.2.1 port 22"))
            == .connectionFailed)
    #expect(SSHResultClassifier.classify(stderr: SSHResultClassifier.clientWarningsRemoved(postQuantumWarning)) == .other("ssh"))
}

@Test func runnerRunsOneOperationAtATime() async throws {
    let processes = FakeProcesses(.success(result(0, "{}")), delay: .milliseconds(40))
    let (runner, directory) = try await trustedRunner(processes: processes)
    defer { try? FileManager.default.removeItem(at: directory) }
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 { group.addTask { _ = try? await runner.run(.systemBoard, limits: .init()) } }
    }
    #expect(await processes.launches.count == 4)
    #expect(await processes.maxRunning == 1)
}

// MARK: - Sentinels

@Test func sentinelsMapToTypedFailuresAndNeverPassAsOutput() {
    #expect(SSHSentinel.failure(in: "SSH_AUTH_FAILED") == .authenticationFailed)
    #expect(SSHSentinel.failure(in: "SSH_CONNECTION_FAILED\n") == .connectionFailed)
    #expect(SSHSentinel.failure(in: "  SSH_NETWORK_FAILED ") == .networkFailed)
    #expect(SSHSentinel.failure(in: "SSH_CONFIGURATION_FAILED") == .configurationFailed)
    #expect(SSHSentinel.failure(in: "SSH_ERROR:SocketException") == .other("SocketException"))
    #expect(SSHSentinel.failure(in: "SSH_ERROR:") == .other("unknown"))
    // A log line that only mentions a sentinel is output.
    #expect(SSHSentinel.failure(in: "Thu Jan 15 10:00:40 2026 user.err : saw SSH_AUTH_FAILED earlier") == nil)
    #expect(throws: SSHFailure.authenticationFailed) { _ = try SSHResultClassifier.check(result(0, "SSH_AUTH_FAILED\n")) }
    #expect(throws: SSHFailure.other("Timeout")) { _ = try SSHResultClassifier.check(result(0, "partial\nSSH_ERROR:Timeout")) }
    #expect(SSHResultClassifier.classify(stderr: "SSH_NETWORK_FAILED") == .networkFailed)
    #expect(SSHFailure.hostKeyChanged.category == .authentication)
    #expect(SSHFailure.timedOut.category == .timeout)
}

// MARK: - Probe

@Test func probeMapsSuccessFailureAndTimeoutToCapability() async throws {
    let board = try sshFixture("ubus-system-board")
    let supported = try await LiveSSHService(runner: ScriptedSSHRunner([.systemBoard: .output(0, board)])).check()
    #expect(supported.capability.state == .supported)
    #expect(supported.board?.model == "Example Router")
    #expect(supported.board?.kernel == "5.4.0" && supported.board?.boardName == "example,router")
    #expect(supported.board?.releaseVersion == "21.02-SNAPSHOT")
    #expect(supported.failure == nil)

    for failure in [SSHFailure.authenticationFailed, .connectionFailed, .hostKeyChanged, .hostKeyNotTrusted, .configurationFailed, .commandFailed(exitStatus: 127)] {
        let probe = try await LiveSSHService(runner: ScriptedSSHRunner([.systemBoard: .failure(failure)])).check()
        #expect(probe.capability.state == .unsupported, "\(failure)")
        #expect(probe.failure == failure)
    }
    for failure in [SSHFailure.timedOut, .networkFailed, .other("ssh")] {
        let probe = try await LiveSSHService(runner: ScriptedSSHRunner([.systemBoard: .failure(failure)])).check()
        #expect(probe.capability.state == .unknown, "\(failure)")
    }
    let malformed = try await LiveSSHService(runner: ScriptedSSHRunner([.systemBoard: .output(0, "not json")])).check()
    #expect(malformed.capability.state == .unknown)
    let nonZero = try await LiveSSHService(runner: ScriptedSSHRunner([.systemBoard: .output(4, "")])).check()
    #expect(nonZero.capability.state == .unsupported)
    // `probe()` is the same answer.
    #expect(await LiveSSHService(runner: ScriptedSSHRunner([.systemBoard: .output(0, board)])).probe().state == .supported)
}

// MARK: - Parsers

@Test func logreadParserReadsNewestFirstWithSeverityCategoryAndSource() throws {
    let tail = LogReadParser.parse(try sshFixture("logread-250"), timeZone: TimeZone(identifier: "Europe/London")!)
    #expect(tail.entries.count == 28)
    let newest = try #require(tail.entries.first)
    #expect(newest.line == "Jan 15 10:02:08 router odd line without a year")
    #expect(newest.time == nil && newest.severity == nil && newest.category == .system)

    let error = try #require(tail.entries.first { $0.severity == .error })
    #expect(error.facilityPriority == "user.err")
    #expect(error.source == "router")
    #expect(error.message == "[screen][ws_callback][error]ws closed")
    #expect(error.line == "user.err : [screen][ws_callback][error]ws closed")
    var components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Europe/London")!, from: try #require(error.time))
    components.nanosecond = nil
    #expect(components.hour == 10 && components.minute == 0 && components.second == 40 && components.year == 2026)

    func first(_ text: String) throws -> RouterLogEntry { try #require(tail.entries.first { $0.line.contains(text) }) }
    #expect(try first("DHCPACK(br-lan) 192.0.2.52").source == "dnsmasq")
    #expect(try first("DHCPACK(br-lan) 192.0.2.52").category == .dhcpDNS)
    #expect(try first("100001.000002").category == .kernel)
    #expect(try first("100001.000002").severity == .warning)
    #expect(try first("RawData").severity == .debug && first("RawData").category == .kernel)
    #expect(try first("netlink-ct").source == "netifyd" && first("netlink-ct").category == .system)
    #expect(try first("Exit (root)").source == "dropbear")
    #expect(try first("Pubkey auth").source == "dropbear" && first("Pubkey auth").category == .system)
    #expect(try first("Pubkey auth").severity == .notice)
    #expect(try first("hostapd").category == .wifi)
    #expect(try first("netifd").category == .networkWAN)
    #expect(try first("Reloading firewall").category == .firewall)
    #expect(try first("AdGuardHome").category == .adGuard && first("AdGuardHome").severity == .debug)
    #expect(try first("openvpn").category == .vpn)
    #expect(try first("block:").category == .storage)
    #expect(try first("crash loop").severity == .critical)
    #expect(try first("websocket").source == "router")

    // 300 lines keep only the newest 250.
    let many = (0..<300).map { "Mon Sep 21 23:00:00 2026 daemon.info test[1]: line \($0)" }.joined(separator: "\n")
    let bounded = LogReadParser.parse(many)
    #expect(bounded.entries.count == RouterLogTail.limit)
    #expect(bounded.entries.first?.message == "line 299" && bounded.entries.last?.message == "line 50")
}

@Test func logFiltersUseTheGroupedSeverityBandsAndCategories() throws {
    let tail = LogReadParser.parse(try sshFixture("logread-250"))
    let errors = tail.filtered(severity: .errorAndAbove, category: nil, search: "")
    #expect(Set(errors.compactMap(\.severity)) == [.error, .critical])
    #expect(tail.filtered(severity: .warningAndAbove, category: nil, search: "").allSatisfy { ($0.severity ?? .debug) <= .warning })
    #expect(Set(tail.filtered(severity: .info, category: nil, search: "").compactMap(\.severity)) == [.info, .notice])
    #expect(tail.filtered(severity: .debug, category: nil, search: "").map(\.source) == ["AdGuardHome", "kernel"])
    #expect(tail.filtered(severity: .all, category: .dhcpDNS, search: "").count == 8)
    #expect(tail.filtered(severity: .all, category: .kernel, search: "").count == 3)
    #expect(tail.filtered(severity: .all, category: nil, search: "PUBKEY").count == 1)
    #expect(tail.filtered(severity: .all, category: nil, search: "dropbear").count == 3)
    #expect(RouterLogSeverityFilter.allCases.map(\.rawValue) == ["All", "Error+", "Warning+", "Info", "Debug"])
    #expect(RouterLogCategory.allCases.map(\.rawValue) == ["System", "Network / WAN", "DHCP / DNS", "Wi-Fi", "Firewall", "VPN", "AdGuard", "Storage", "Kernel"])
}

@Test func storageParsersReadRootExternalVolumesAndSambaWithoutPaths() throws {
    let root = try #require(DiskFreeParser.parseRoot(try sshFixture("df-h-root")))
    #expect(root == RootFilesystem(filesystem: "overlayfs:/overlay", size: "7.2G", used: "1.1G", available: "6.1G", usePercent: 15, mountPoint: "/"))
    #expect(DiskFreeParser.parseRoot("Filesystem Size Used Available Use% Mounted on\n") == nil)

    let all = DiskFreeParser.parseKilobytes(try sshFixture("df-k"))
    #expect(all.first { $0.mountPoint == "/overlay" }?.device == "/dev/loop0")
    #expect(all.first { $0.mountPoint == "/tmp/mountd/disk2 part1" }?.device == "/dev/mmcblk1p1")
    let external = MountTableParser.externalVolumes(diskFree: try sshFixture("df-k"), mounts: try sshFixture("proc-mounts"))
    #expect(external.map(\.mountPoint) == ["/mnt/sda1", "/tmp/mountd/disk2 part1"])
    #expect(external[0].fileSystemType == "ext4")
    #expect(external[0].totalBytes == 488_281_250 * 1024 && external[0].availableBytes == 371_093_750 * 1024)
    #expect(external[1].fileSystemType == "exfat")

    let samba = SambaSharesParser.parse(try sshFixture("samba-shares"))
    #expect(samba == .configured([
        SambaShare(name: "Backups", readOnly: .value(false), guestAccess: .value(false)),
        SambaShare(name: "Media", readOnly: .value(true), guestAccess: .unknown),
    ]))
    #expect(SambaSharesParser.parse(SSHCommand.sambaNotConfiguredMarker + "\n") == .notConfigured)
    #expect(SambaSharesParser.parse("") == .configured([]))
    // The command filters on the router: only names and two flags leave it.
    #expect(SSHCommand.sambaShares.rendered.contains("(name|read_only|guest_ok)="))
    #expect(!SSHCommand.sambaShares.rendered.contains("path"))
}

@Test func interfaceEnumerationKeepsEthernetPortsAndDropsUnsafeNames() throws {
    let entries = InterfaceParser.parseEnumeration(try sshFixture("interfaces", subdirectory: "Fixtures/ssh/router/sys-class-net-sample"))
    #expect(!entries.contains { $0.name.description.contains(";") })
    let ports = entries.filter(\.isEthernetPort).map(\.name.description)
    // 4.9.1 enumerates these seven Ethernet ports `[verified live]`; the
    // VLAN `eth1.1`, radios, the bridge, `lo`, and `pppoe-wan` are left out.
    #expect(ports == ["eth0", "eth1", "eth2", "lan5", "lan6", "lan7", "lan8"])

    let names = ports.compactMap(NetworkInterfaceName.init)
    let parsed = InterfaceParser.parseTelemetry(try sshFixture("telemetry", subdirectory: "Fixtures/ssh/router/sys-class-net-sample"),
                                                names: names + [NetworkInterfaceName("lan9")!])
    #expect(parsed.missing == [NetworkInterfaceName("lan9")!])
    let byName = Dictionary(uniqueKeysWithValues: parsed.status.ports.map { ($0.name, $0) })
    #expect(byName["eth1"] == EthernetPortStatus(name: "eth1", link: .up, speedMbps: 10_000, duplex: "full", rxBytes: 300_000_000,
                                                 txBytes: 9_000_000_000, rxErrors: 0, txErrors: 0, rxDropped: 0, txDropped: 0))
    #expect(byName["eth2"]?.rxErrors == 3 && byName["eth2"]?.txDropped == 4)
    #expect(byName["lan6"]?.link == .down && byName["lan6"]?.speedMbps == nil && byName["lan6"]?.duplex == nil)
    #expect(byName["lan5"]?.speedMbps == nil)
    #expect(parsed.status.ports.map(\.name) == ports)
}

@Test func processIDParserKeepsOnlyThePID() throws {
    #expect(ProcessIDParser.adGuardProcessID(try sshFixture("pgrep-adguardhome"), exitStatus: 0) == .value(4321))
    #expect(ProcessIDParser.adGuardProcessID("4321 /usr/bin/AdGuardHome -c /etc/AdGuardHome/config.yaml\n", exitStatus: 0) == .value(4321))
    #expect(ProcessIDParser.adGuardProcessID("", exitStatus: 1) == .unavailable)
    #expect(ProcessIDParser.adGuardProcessID("", stderr: "pgrep: invalid option -- 'a'\nUsage: pgrep", exitStatus: 1) == .unknown)
    #expect(ProcessIDParser.adGuardProcessID("garbage", exitStatus: 0) == .unknown)
}

// MARK: - Allow-list

@Test func allowListIsFixedAndRejectsAnythingElse() {
    #expect(SSHCommand.systemBoard.rendered == "ubus call system board")
    #expect(SSHCommand.logTail.rendered == "logread -l 250")
    #expect(SSHCommand.rootFilesystem.rendered == "df -h /")
    #expect(SSHCommand.adGuardProcess.rendered == "pgrep -a AdGuardHome")
    #expect(SSHCommand.mountTable.rendered == "cat /proc/mounts")
    for bad in ["", "eth0;reboot", "eth0 ", "../etc", "..", ".", "-x", "eth$(id)", "a/b", "sixteen-chars-xx", "eth0\n", "é"] {
        #expect(NetworkInterfaceName(bad) == nil, "\(bad)")
    }
    let telemetry = SSHCommand.interfaceTelemetry([NetworkInterfaceName("eth0")!, NetworkInterfaceName("lan5")!]).rendered
    #expect(telemetry.hasPrefix("for i in eth0 lan5; do for f in operstate carrier speed duplex statistics/rx_bytes"))
    #expect(telemetry.contains("\"/sys/class/net/$i/$f\""))
    // Dropbear refuses exec commands over 9000 bytes: the recorder's one
    // `printf` per file for 28 interfaces was 30 610 bytes and failed live.
    let many = (0..<64).compactMap { NetworkInterfaceName("iface\($0)") }
    #expect(SSHCommand.interfaceTelemetry(many).rendered.utf8.count < 1_000)

    #expect(FixtureRecordingPlan.isReadOnly(FixtureCall(.ssh, method: "log-tail", fileName: "x")))
    #expect(!FixtureRecordingPlan.isReadOnly(FixtureCall(.ssh, method: "reboot", fileName: "x")))
    #expect(!FixtureRecordingPlan.isReadOnly(FixtureCall(.ssh, method: "logread -l 250", fileName: "x")))
    #expect(!FixtureRecordingPlan.isReadOnly(FixtureCall(.ssh, object: "system", method: "log-tail", fileName: "x")))
    #expect(Set(FixtureRecordingPlan.sshReads.values.map(\.rendered)).count == FixtureRecordingPlan.sshReads.count)
}

// MARK: - Session-only link-change log

@Test func linkChangeLogIsCappedAndSessionOnly() {
    var log = LinkChangeLog()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    log.observe(RouterPortsStatus(ports: [EthernetPortStatus(name: "lan5", link: .down)]), at: t0)
    #expect(log.changes.isEmpty)
    log.observe(RouterPortsStatus(ports: [EthernetPortStatus(name: "lan5", link: .unknown)]), at: t0)
    #expect(log.changes.isEmpty)
    log.observe(RouterPortsStatus(ports: [EthernetPortStatus(name: "lan5", link: .up)]), at: t0.addingTimeInterval(30))
    #expect(log.changes == [LinkChange(interface: "lan5", from: .down, to: .up, at: t0.addingTimeInterval(30))])
    for index in 0..<150 {
        log.observe(RouterPortsStatus(ports: [EthernetPortStatus(name: "lan5", link: index.isMultiple(of: 2) ? .down : .up)]),
                    at: t0.addingTimeInterval(Double(60 + index)))
    }
    #expect(log.changes.count == LinkChangeLog.capacity)
    #expect(log.changes.last?.at == t0.addingTimeInterval(209))
    // Not `Codable`: nothing can write it to disk.
    #expect(!((log as Any) is any Encodable))
}

// MARK: - Live service

@Test func portsEnumerateOnceAndAgainWhenAnInterfaceGoesAway() async throws {
    let interfaces = try sshFixture("interfaces", subdirectory: "Fixtures/ssh/router/sys-class-net-sample")
    let telemetry = try sshFixture("telemetry", subdirectory: "Fixtures/ssh/router/sys-class-net-sample")
    let runner = ScriptedSSHRunner([.networkInterfaces: .output(0, interfaces)])
    let names = ["eth0", "eth1", "eth2", "lan5", "lan6", "lan7", "lan8"].compactMap(NetworkInterfaceName.init)
    await runner.set(.interfaceTelemetry(names), .output(0, telemetry))
    let service = LiveSSHService(runner: runner)
    guard case .success(let first, _, let source) = try await service.ports() else { Issue.record("expected ports"); return }
    #expect(first.ports.count == 7 && source == .routerSSH)
    _ = try await service.ports()
    #expect(await runner.commands.filter { $0 == .networkInterfaces }.count == 1)

    await runner.set(.interfaceTelemetry(names), .output(0, telemetry.split(separator: "\n").filter { !$0.hasPrefix("lan8 ") }.joined(separator: "\n")))
    _ = try await service.ports()
    _ = try await service.ports()
    #expect(await runner.commands.filter { $0 == .networkInterfaces }.count == 2)

    let failing = LiveSSHService(runner: ScriptedSSHRunner([.networkInterfaces: .failure(.authenticationFailed)]))
    guard case .failure(let category, _) = try await failing.ports() else { Issue.record("expected failure"); return }
    #expect(category == .authentication)
}

@Test func storageKeepsEachPartOnItsOwn() async throws {
    let runner = ScriptedSSHRunner([
        .rootFilesystem: .output(0, try sshFixture("df-h-root")),
        .diskUsage: .output(0, try sshFixture("df-k")),
        .mountTable: .output(0, try sshFixture("proc-mounts")),
        .sambaShares: .failure(.timedOut),
    ])
    guard case .success(let storage, _, _) = try await LiveSSHService(runner: runner).storage() else { Issue.record("expected storage"); return }
    #expect(storage.root.observedValue?.usePercent == 15)
    #expect(storage.external.observedValue?.count == 2)
    #expect(storage.samba == .unknown)

    let down = ScriptedSSHRunner()
    await down.set(.rootFilesystem, .failure(.networkFailed))
    guard case .failure(let category, _) = try await LiveSSHService(runner: down).storage() else { Issue.record("expected failure"); return }
    #expect(category == .network)
}

@Test func logsAndProcessIDReadThroughTheService() async throws {
    let runner = ScriptedSSHRunner([
        .logTail: .output(0, try sshFixture("logread-250")),
        .adGuardProcess: .output(1, ""),
    ])
    let service = LiveSSHService(runner: runner)
    guard case .success(let tail, _, _) = try await service.logTail() else { Issue.record("expected logs"); return }
    #expect(tail.entries.count == 28)
    #expect(try await service.adGuardProcess() == .unavailable)
    await runner.set(.adGuardProcess, .output(0, "4321 /usr/bin/AdGuardHome\n"))
    #expect(try await service.adGuardProcess() == .value(4321))
    await runner.set(.adGuardProcess, .failure(.timedOut))
    #expect(try await service.adGuardProcess() == .unknown)
}

@Test func liveBackendGetsSSHOnlyWithARunnerAndWakeReportsNothingSentBeforeTrust() async throws {
    let endpoint = try RouterEndpoint(scheme: .https, host: "192.0.2.20", port: 443)
    let rpc = GLiNetRPCClient(endpoint: endpoint, username: "root", password: { "x" }, transport: StubHTTPTransport { _ in throw TransportError.timedOut })
    let without = LiveRouterBackend(configuration: .init(routerEndpoint: endpoint), rpc: rpc, adGuard: nil,
                                    trustStore: InMemoryEndpointTrustStore(), trustPrompt: DenyAllTrustPromptHandler())
    #expect(without.ssh == nil)
    let runner = ScriptedSSHRunner()
    await runner.set(.wakeClient(MACAddress("66:29:ea:33:fb:78")!), .failure(.hostKeyNotTrusted))
    let with = LiveRouterBackend(configuration: .init(routerEndpoint: endpoint), rpc: rpc, adGuard: nil,
                                 trustStore: InMemoryEndpointTrustStore(), trustPrompt: DenyAllTrustPromptHandler(), sshRunner: runner)
    #expect(with.ssh != nil)
    #expect(with.clientActions?.mechanism == .ssh)
    let wake = await with.clientActions!.wake(MACAddress("66:29:ea:33:fb:78")!)
    #expect(!wake.dispatched)
    #expect(wake.failure == .authentication)
}

@Test func sessionFencesSSHReads() async throws {
    let session = RouterSession()
    let backend = MockRouterBackend()
    let token = SessionToken(profileID: "a", revision: 1)
    try await session.beginRevision(token)
    let lease = SessionLease(token: token, backend: backend)
    try await session.installLease(lease)
    #expect(try await session.sshProbe(using: lease)?.capability.state == .supported)
    #expect(try await session.adGuardProcess(using: lease) == .value(4321))
    backend.mockSSH.setScenario(.off)
    #expect(try await session.routerPorts(using: lease) == nil)
    backend.mockSSH.setScenario(.populated)
    try await session.beginRevision(SessionToken(profileID: "a", revision: 2))
    await #expect(throws: SessionError.self) { _ = try await session.routerLogs(using: lease) }
}

// MARK: - Recording

@Test func textRedactorHidesAddressesNamesAndFingerprints() {
    var aliases = FixtureAliases()
    let text = """
    Thu Jan 15 10:00:30 2026 daemon.info dnsmasq-dhcp[1]: DHCPACK(br-lan) 10.1.2.3 0a:1b:2c:3d:4e:5f Alex-Laptop
    Thu Jan 15 10:01:20 2026 authpriv.notice dropbear[2]: Pubkey auth succeeded for 'root' with ED25519 key SHA256:abcDEF123+/x from 10.1.2.3:50000
    Thu Jan 15 10:01:21 2026 daemon.info dnsmasq[3]: query[A] private.example.com from fd00::1234
    samba4.@sambashare[0].name='Family Photos'
    samba4.@sambashare[0].read_only='no'
    kern.warn kernel: [100001.000001] contact me@example.org
    """
    let redacted = RecordedTextRedactor.redact(text, aliases: &aliases)
    for secret in ["10.1.2.3", "0a:1b:2c:3d:4e:5f", "Alex-Laptop", "abcDEF123", "private.example.com", "fd00::1234", "Family Photos", "me@example.org"] {
        #expect(!redacted.contains(secret), "\(secret)")
    }
    #expect(redacted.contains("read_only='no'"))
    #expect(redacted.contains("[100001.000001]"))
    #expect(redacted.contains("10:00:30"))
    #expect(redacted.contains("198.51.100.1:50000"))
    #expect(aliases.ipAddresses["10.1.2.3"] == "198.51.100.1")
}

@Test func recorderWritesRedactedSSHTextWhenSSHIsSetUp() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = RouterSession()
    let token = SessionToken(profileID: "synthetic", revision: 1)
    let lease = SessionLease(token: token, backend: SSHFixtureBackend())
    try await session.beginRevision(token)
    try await session.installLease(lease)
    let sshCalls = FixtureRecordingPlan.calls.filter { $0.transport == .ssh }
    let count = try await FixtureRecorder().record(session: session, lease: lease, to: directory, calls: sshCalls)
    #expect(count == sshCalls.count)
    let log = try String(contentsOf: directory.appendingPathComponent("ssh-logread-250.txt"), encoding: .utf8)
    #expect(log.hasPrefix("# exit status: 0"))
    #expect(!log.contains("10.1.2.3") && !log.contains("desktop"))
    let board = try String(contentsOf: directory.appendingPathComponent("ssh-ubus-system-board.json"), encoding: .utf8)
    #expect(board.contains("kernel") && !board.contains("example-router\""))
}

private struct SSHFixtureBackend: RouterBackend, FixtureRecordableBackend {
    func overview() async throws -> OverviewRefreshResult { throw CancellationError() }
    func recordFixture(_ call: FixtureCall) async -> JSONValue { .object([:]) }
    func recordSSHFixture(_ call: FixtureCall) async -> String? {
        let body = call.method == "system-board"
            ? #"{"hostname":"example-router","kernel":"5.4.0","model":"Example Router"}"#
            : "Thu Jan 15 10:00:30 2026 daemon.info dnsmasq-dhcp[1200]: DHCPACK(br-lan) 10.1.2.3 02:00:00:00:00:03 desktop"
        return "# exit status: 0\n" + body
    }
}

private extension Observed {
    var observedValue: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

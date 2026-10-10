import Foundation
import Testing
@testable import RoutewellKit

private func fixture(_ name: String, _ ext: String, _ folder: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/\(folder)"))
    return try Data(contentsOf: url)
}

private func json(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }

/// A short `config.yaml` with neutral values, in the newer list style.
private func configYAML(upstreams: [String] = ["https://dns.example.net/dns-query", "192.0.2.53"], cacheSize: Int = 4_194_304) -> Data {
    Data("""
    http:
      address: 0.0.0.0:3000
    users:
      - name: admin
        password: placeholder
    dns:
      bind_hosts:
        - 0.0.0.0
      port: 3053
      upstream_dns:
    \(upstreams.map { "    - '\($0)'" }.joined(separator: "\n"))
      blocking_mode: "default"
      ratelimit: 20
      cache_size: \(cacheSize)
    schema_version: 28

    """.utf8)
}

// MARK: Parsing

struct AdGuardInstanceParsingTests {
    @Test func versionCheckStates() throws {
        let available = AdGuardVersionCheck.parse(try json(fixture("version-available", "json", "adguard/instance")))
        #expect(available.update(current: "v0.107.65") == .available("v0.107.70"))
        #expect(available.update(current: "0.107.70") == .upToDate)
        #expect(AdGuardVersionCheck.parse(.object(["disabled": .bool(false)])).update(current: "v0.107.65") == .upToDate)
        #expect(AdGuardVersionCheck.parse(try json(fixture("version-disabled", "json", "adguard/instance"))).update(current: nil) == .unknown)
        #expect(AdGuardVersionCheck.parse(.object([:])).update(current: "v0.107.65") == .unknown)
    }

    @Test func retentionConfigs() throws {
        let log = AdGuardQueryLogConfig.parse(try json(fixture("querylog-config", "json", "adguard/instance")))
        #expect(log == AdGuardQueryLogConfig(enabled: true, intervalMilliseconds: 90 * 86_400_000, anonymizeClientIP: false))
        let stats = AdGuardStatsConfig.parse(try json(fixture("stats-config", "json", "adguard/overview")))
        #expect(stats.intervalMilliseconds == 86_400_000)
        #expect(AdGuardQueryLogConfig.parse(.object(["interval": .string("long")])).intervalMilliseconds == nil)
        #expect(AdGuardRetention.isValid(6 * AdGuardRetention.hour))
        #expect(!AdGuardRetention.isValid(1_000))
    }

    @Test func memoryAndSize() throws {
        let vmrss = String(decoding: try fixture("vmrss", "txt", "ssh/adguard"), as: UTF8.self)
        #expect(AdGuardResourceParser.memoryBytes(vmrss, exitStatus: 0) == .value(51_200 * 1024))
        #expect(AdGuardResourceParser.memoryBytes(vmrss + vmrss, exitStatus: 0) == .value(2 * 51_200 * 1024))
        #expect(AdGuardResourceParser.memoryBytes("", exitStatus: 0) == .unavailable)
        #expect(AdGuardResourceParser.memoryBytes("VmRSS: lots", exitStatus: 0) == .unknown)
        let du = String(decoding: try fixture("du-querylog", "txt", "ssh/adguard"), as: UTF8.self)
        #expect(AdGuardResourceParser.diskBytes(du) == .value(12_288 * 1024))
        #expect(AdGuardResourceParser.diskBytes("") == .unknown)
        #expect(AdGuardResourceParser.diskBytes("du: no such file") == .unknown)
    }

    @Test func configFileValuesInBothListStyles() throws {
        let file = try #require(AdGuardConfigFile(configYAML()))
        #expect(file.dns.upstreams == ["https://dns.example.net/dns-query", "192.0.2.53"])
        #expect(file.dns.blockingMode == "default")
        #expect(file.dns.rateLimit == 20)
        #expect(file.dns.cacheSize == 4_194_304)

        let older = try #require(AdGuardConfigFile(Data("dns:\n  upstream_dns:\n  - 192.0.2.53\n  - '[/home.arpa/]192.0.2.1'\n  cache_size: 1024\nfiltering:\n  enabled: true\n".utf8)))
        #expect(older.dns.upstreams == ["192.0.2.53", "[/home.arpa/]192.0.2.1"])
        #expect(older.dns.cacheSize == 1024)
        #expect(older.dns.rateLimit == nil)
    }

    @Test func notAConfigFile() {
        #expect(AdGuardConfigFile(Data()) == nil)
        #expect(AdGuardConfigFile(Data("http:\n  address: 0.0.0.0:3000\n".utf8)) == nil)
        #expect(AdGuardConfigFile(Data([0xFF, 0xFE, 0x00])) == nil)
        #expect(AdGuardConfigFile(Data(repeating: 0x20, count: AdGuardConfigFile.maximumBytes + 1)) == nil)
    }

    @Test func dnsValuesCompareOnlyWhatBothHave() throws {
        let file = try #require(AdGuardConfigFile(configYAML()))
        var settings = AdGuardDNSSettings(fields: ["upstream_dns": .array([.string("https://dns.example.net/dns-query"), .string("192.0.2.53")]),
                                                  "cache_size": .number(4_194_304)])
        #expect(file.dns.matches(settings))
        settings.cacheSize = 1
        #expect(!file.dns.matches(settings))
        #expect(file.dns.matches(AdGuardDNSSettings()))
    }
}

// MARK: SSH and the recorder

private actor InputRecordingRunner: SSHCommandRunning {
    var commands: [SSHCommand] = []
    var inputs: [Data] = []
    let stdout: Data
    let exitStatus: Int32

    init(stdout: Data = Data(), exitStatus: Int32 = 0) {
        self.stdout = stdout
        self.exitStatus = exitStatus
    }

    func run(_ command: SSHCommand, limits: ProcessLimits) async throws -> ProcessResult {
        commands.append(command)
        return ProcessResult(exitStatus: exitStatus, stdout: stdout, stderr: Data())
    }

    func run(_ command: SSHCommand, input: Data, limits: ProcessLimits) async throws -> ProcessResult {
        commands.append(command)
        inputs.append(input)
        return ProcessResult(exitStatus: exitStatus, stdout: Data(), stderr: Data())
    }
}

struct AdGuardInstanceSSHTests {
    @Test func commandsAreFixed() {
        #expect(SSHCommand.readAdGuardConfig.rendered == "cat /etc/AdGuardHome/config.yaml")
        #expect(SSHCommand.writeAdGuardConfig.rendered
            == "umask 077 && cat > /etc/AdGuardHome/config.yaml.routewell && mv /etc/AdGuardHome/config.yaml.routewell /etc/AdGuardHome/config.yaml")
        #expect(SSHCommand.adGuardQueryLogSize.rendered == "du -k /etc/AdGuardHome/data/querylog.json*")
        #expect(SSHCommand.writeAdGuardConfig.takesInput)
        #expect(!SSHCommand.readAdGuardConfig.takesInput)
        #expect(!SSHCommand.adGuardMemory.takesInput)
    }

    /// The config holds password hashes: the recorder never reads or writes it.
    @Test func recorderNeverTouchesTheConfigFile() {
        let commands = Set(FixtureRecordingPlan.sshReads.values)
        #expect(!commands.contains(.readAdGuardConfig))
        #expect(!commands.contains(.writeAdGuardConfig))
        #expect(commands.isSuperset(of: [.adGuardMemory, .adGuardQueryLogSize, .adGuardFiles]))
        let names = FixtureRecordingPlan.calls.map(\.method)
        #expect(names.contains("control/version.json"))
        #expect(names.contains("control/querylog/config"))
        for method in ["control/querylog_clear", "control/stats_reset", "control/stats/config/update", "control/querylog/config/update"] {
            #expect(!FixtureRecordingPlan.isReadOnly(FixtureCall(.adGuard, method: method, fileName: "x.json")))
        }
    }

    @Test func fileTransportSendsTheBytesOnStdin() async throws {
        let runner = InputRecordingRunner(stdout: configYAML())
        let transport = SSHAdGuardConfigFileTransport(runner: runner)
        #expect(try await transport.readConfigFile() == configYAML())
        try await transport.writeConfigFile(configYAML(cacheSize: 1))
        #expect(await runner.commands == [.readAdGuardConfig, .writeAdGuardConfig])
        #expect(await runner.inputs == [configYAML(cacheSize: 1)])

        let failing = SSHAdGuardConfigFileTransport(runner: InputRecordingRunner(exitStatus: 1))
        await #expect(throws: SSHFailure.commandFailed(exitStatus: 1)) { try await failing.readConfigFile() }
    }

    @Test func resourcesReadMemoryThenSize() async throws {
        let service = LiveSSHService(runner: InputRecordingRunner(stdout: Data("VmRSS:\t 1000 kB\n".utf8)))
        let resources = try await service.adGuardResources()
        #expect(resources.memoryBytes == .value(1_024_000))
        #expect(resources.queryLogBytes == .unknown)
    }
}

// MARK: Retention, clears, and the version check over HTTP

private final class InstanceServer: Sendable {
    private nonisolated(unsafe) var configs: [String: [String: JSONValue]] = [
        "/control/querylog/config": ["enabled": .bool(true), "interval": .number(7_776_000_000), "anonymize_client_ip": .bool(true),
                                     "ignored": .array([.string("example.com")]), "ignored_enabled": .bool(true)],
        "/control/stats/config": ["enabled": .bool(true), "interval": .number(86_400_000), "ignored": .array([]), "ignored_enabled": .bool(false)],
    ]
    private nonisolated(unsafe) var ignoresWrites = false
    private nonisolated(unsafe) var clearFails = false
    private(set) nonisolated(unsafe) var sent: [(method: String, path: String, body: JSONValue?)] = []
    private let lock = NSLock()
    let transport: StubHTTPTransport

    init(ignoresWrites: Bool = false, clearFails: Bool = false) {
        self.ignoresWrites = ignoresWrites
        self.clearFails = clearFails
        let box = Box()
        transport = StubHTTPTransport { request in try box.server!.answer(request) }
        box.server = self
    }

    private final class Box: @unchecked Sendable {
        weak var server: InstanceServer?
    }

    var requests: [(method: String, path: String, body: JSONValue?)] { lock.withLock { sent } }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let reply: (Int, JSONValue?) = try lock.withLock {
            sent.append((request.httpMethod ?? "", url.path, body))
            switch (request.httpMethod, url.path) {
            case ("GET", let path) where configs[path] != nil:
                return (200, .object(configs[path]!))
            case ("PUT", "/control/querylog/config/update"), ("PUT", "/control/stats/config/update"):
                let key = url.path.replacingOccurrences(of: "/update", with: "")
                if !ignoresWrites { configs[key] = body?.object }
                return (200, nil)
            case ("POST", "/control/querylog_clear"), ("POST", "/control/stats_reset"):
                if clearFails { throw TransportError.timedOut }
                return (200, nil)
            case ("POST", "/control/version.json"):
                return (200, .object(["disabled": .bool(false), "new_version": .string("v0.107.70")]))
            default:
                return (404, nil)
            }
        }
        let data = try reply.1.map { try JSONEncoder().encode($0) } ?? Data()
        return (data, StubHTTPTransport.response(reply.0, url: url))
    }
}

private final class StepClock: Sendable {
    private nonisolated(unsafe) var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let lock = NSLock()

    func now() -> Date { lock.withLock { current } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { current = current.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) }
    }
}

private func client(_ server: InstanceServer) -> AdGuardClient {
    AdGuardClient(baseURL: URL(string: "http://192.0.2.1:3000/")!,
                  credentials: BasicAdGuardCredentials(username: "admin", password: { "secret" }), transport: server.transport)
}

private func settingExecutor(_ server: InstanceServer) -> AdGuardSettingExecutor {
    let clock = StepClock()
    return AdGuardSettingExecutor(transport: LiveAdGuardSettingTransport(adGuard: client(server)), gate: MutationGate(),
                                  clock: { clock.now() }, sleep: { try await clock.sleep($0) })
}

struct AdGuardRetentionTests {
    @Test func queryLogRetentionSendsTheWholeConfigBack() async throws {
        let server = InstanceServer()
        let report = await settingExecutor(server).run(.retention(.queryLog, milliseconds: 7 * 86_400_000), availability: .running)
        #expect(report.outcome == .verifiedSuccess(.retention(.queryLog, 7 * 86_400_000)))
        let put = try #require(server.requests.first { $0.method == "PUT" })
        #expect(put.path == "/control/querylog/config/update")
        #expect(put.body == .object(["enabled": .bool(true), "interval": .number(604_800_000), "anonymize_client_ip": .bool(true),
                                     "ignored": .array([.string("example.com")]), "ignored_enabled": .bool(true)]))
    }

    @Test func statsRetentionAndNothingSentWhenAlreadySet() async {
        let server = InstanceServer()
        let executor = settingExecutor(server)
        #expect(await executor.run(.retention(.stats, milliseconds: 86_400_000), availability: .running).outcome
            == .verifiedSuccess(.retention(.stats, 86_400_000)))
        #expect(!server.requests.contains { $0.method == "PUT" })
        #expect(await executor.run(.retention(.stats, milliseconds: 30 * 86_400_000), availability: .running).outcome
            == .verifiedSuccess(.retention(.stats, 30 * 86_400_000)))
        #expect(server.requests.contains { $0.path == "/control/stats/config/update" })
    }

    @Test func ignoredRetentionIsAMismatch() async {
        let server = InstanceServer(ignoresWrites: true)
        let report = await settingExecutor(server).run(.retention(.stats, milliseconds: 7 * 86_400_000), availability: .running)
        #expect(report.outcome == .verifiedMismatch(expected: .retention(.stats, 7 * 86_400_000), actual: .retention(.stats, 86_400_000)))
    }

    @Test func invalidOrReadOnlyIsRejectedBeforeAnyRead() async {
        let server = InstanceServer()
        #expect(await settingExecutor(server).run(.retention(.stats, milliseconds: 1_000), availability: .running).dispatched == false)
        let cached = await settingExecutor(server).run(.clearData(.stats), availability: .cached)
        #expect(cached.outcome == .rejected(.preconditionFailed("AdGuard Home is not running.")))
        #expect(server.requests.isEmpty)
    }

    @Test func clearOutcomes() async {
        let server = InstanceServer()
        #expect(await settingExecutor(server).run(.clearData(.queryLog), availability: .running).outcome == .verifiedSuccess(.dataCleared(.queryLog)))
        #expect(await settingExecutor(server).run(.clearData(.stats), availability: .running).outcome == .verifiedSuccess(.dataCleared(.stats)))
        #expect(server.requests.map(\.path) == ["/control/querylog_clear", "/control/stats_reset"])
        let failing = InstanceServer(clearFails: true)
        let lost = await settingExecutor(failing).run(.clearData(.stats), availability: .running)
        #expect(lost.outcome == .unknownAfterDispatch)
        #expect(lost.dispatched)
    }

    @Test func versionCheckIsAPostThatOnlyReads() async throws {
        let server = InstanceServer()
        let reply = try await client(server).versionCheck()
        #expect(AdGuardVersionCheck.parse(reply).newVersion == "v0.107.70")
        #expect(server.requests.map(\.method) == ["POST"])
        #expect(server.requests.first?.body == .object(["recheck_now": .bool(false)]))
    }
}

// MARK: Backups on the Mac

struct AdGuardBackupStoreTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func saveAndListNewestFirst() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AdGuardBackupStore(root: root)
        let profile = UUID()
        let file = try #require(AdGuardConfigFile(configYAML()))
        let older = try await store.save(file, kind: .manual, version: "v0.107.65", for: profile, at: Date(timeIntervalSince1970: 100))
        let newer = try await store.save(file, kind: .beforeRestore, version: nil, for: profile, at: Date(timeIntervalSince1970: 200))
        #expect(await store.backups(for: profile).map(\.id) == [newer.id, older.id])
        #expect(older.size == file.data.count)
        #expect(try await store.file(older, for: profile) == file)
        #expect(await store.backups(for: UUID()).isEmpty)

        let path = AdGuardBackupStore.folder(root: root, profile: profile).appendingPathComponent("\(older.id.uuidString).yaml").path
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)

        // A record whose file is gone is not listed.
        try FileManager.default.removeItem(atPath: path)
        #expect(await store.backups(for: profile).map(\.id) == [newer.id])
    }

    @Test func exportWritesTheSameBytes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AdGuardBackupStore(root: root)
        let profile = UUID()
        let backup = try await store.save(try #require(AdGuardConfigFile(configYAML())), kind: .manual, version: nil, for: profile)
        let destination = root.appendingPathComponent("export.yaml")
        try await store.export(backup, for: profile, to: destination)
        #expect(try Data(contentsOf: destination) == configYAML())
    }

    @Test func memoryStoreAndRemoval() async throws {
        let store = AdGuardBackupStore(root: nil)
        let profile = UUID()
        _ = try await store.save(try #require(AdGuardConfigFile(configYAML())), kind: .manual, version: nil, for: profile)
        #expect(await store.backups(for: profile).count == 1)
        await store.remove(profile: profile)
        #expect(await store.backups(for: profile).isEmpty)
    }

    @Test func archiveKeepsTheInstanceSection() async throws {
        let store = AdGuardArchiveStore(root: nil)
        let profile = UUID()
        var reading = AdGuardOverviewReading(range: .day, stats: .failure(.timeout), statsConfig: .failure(.timeout),
                                             protection: .failure(.timeout), filtering: .failure(.timeout), observedAt: Date(timeIntervalSince1970: 0))
        reading.version = .success(AdGuardVersionCheck(disabled: false))
        reading.queryLog = .success(AdGuardQueryLogConfig(enabled: true, intervalMilliseconds: 86_400_000))
        await store.save(reading, for: profile)
        reading.observedAt = Date(timeIntervalSince1970: 120)
        reading.queryLog = .failure(.timeout)
        reading.version = .success(AdGuardVersionCheck(disabled: true))
        await store.save(reading, for: profile)
        let saved = try #require(await store.archive(for: profile)?.instance)
        #expect(saved.value == AdGuardInstanceInfo(version: AdGuardVersionCheck(disabled: true),
                                                   queryLog: AdGuardQueryLogConfig(enabled: true, intervalMilliseconds: 86_400_000)))
    }
}

// MARK: Restore

/// The router, AdGuard Home, and its config file in memory. A started
/// AdGuard Home takes its DNS values from the file; with `badFile`, it does
/// not answer while that file is in place.
private actor RouterFake: AdGuardConfigFileTransport, AdGuardServiceTransport, AdGuardSettingTransport {
    var enabled = true
    var file: Data
    var dns: AdGuardDNSSettings
    var events: [String] = []
    var badFile: Data?
    var staysOn = false
    var readFails = false

    init(file: Data) {
        self.file = file
        dns = Self.settings(from: file)
    }

    func set(badFile: Data? = nil, staysOn: Bool = false, readFails: Bool = false) {
        self.badFile = badFile
        self.staysOn = staysOn
        self.readFails = readFails
    }

    static func settings(from data: Data) -> AdGuardDNSSettings {
        let values = AdGuardConfigFile(data)?.dns
        return AdGuardDNSSettings(fields: ["upstream_dns": .array((values?.upstreams ?? []).map(JSONValue.string)),
                                           "cache_size": .number(Double(values?.cacheSize ?? 0))])
    }

    func readConfigFile() async throws -> Data {
        events.append("read file")
        if readFails { throw SSHFailure.timedOut }
        return file
    }

    func writeConfigFile(_ data: Data) async throws {
        events.append("write file")
        file = data
    }

    func readConfig() async throws -> AdGuardRouterConfig { AdGuardRouterConfig(enabled: enabled, handlesDNS: true) }

    func writeConfig(enabled: Bool, handlesDNS: Bool?) async throws -> Int? {
        events.append(enabled ? "start" : "stop")
        if enabled {
            self.enabled = true
            dns = Self.settings(from: file)
        } else if !staysOn {
            self.enabled = false
        }
        return nil
    }

    func readStatus() async throws -> AdGuardStatusResponse {
        guard enabled, file != badFile else { throw AdGuardClientError.transport(.timedOut) }
        return AdGuardStatusResponse(version: "v0.107.65", running: true)
    }

    func readDNS() async throws -> AdGuardDNSSettings {
        guard enabled, file != badFile else { throw AdGuardClientError.transport(.timedOut) }
        return dns
    }

    func readFeature(_ feature: AdGuardFeature) async throws -> JSONValue { .object([:]) }
    func readFiltering() async throws -> AdGuardFilteringStatus { AdGuardFilteringStatus() }
    func readUserRules() async throws -> [String] { [] }
    func write(_ write: AdGuardWrite) async throws {}
}

private actor SavedFiles {
    var files: [AdGuardConfigFile] = []
    func add(_ file: AdGuardConfigFile) { files.append(file) }
}

private func restoreExecutor(_ router: RouterFake) -> AdGuardBackupExecutor {
    let clock = StepClock()
    return AdGuardBackupExecutor(files: router, service: router, settings: router, gate: MutationGate(),
                                 clock: { clock.now() }, sleep: { try await clock.sleep($0) })
}

struct AdGuardRestoreTests {
    private let current = configYAML(cacheSize: 4_194_304)
    private let chosen = configYAML(upstreams: ["tls://dns.example.org"], cacheSize: 1_048_576)

    @Test func restoreBacksUpStopsWritesStartsAndVerifies() async throws {
        let router = RouterFake(file: current)
        let saved = SavedFiles()
        let report = await restoreExecutor(router).restore(try #require(AdGuardConfigFile(chosen)), availability: .running) {
            await saved.add($0)
            return true
        }
        #expect(report.outcome == .verifiedSuccess(AdGuardRestoreState(written: true, answering: true, dnsMatches: true)))
        #expect(await router.events == ["read file", "stop", "write file", "start"])
        #expect(await router.file == chosen)
        #expect(await saved.files.map(\.data) == [current])
    }

    @Test func badFileRollsBackToTheSavedOne() async throws {
        let router = RouterFake(file: current)
        await router.set(badFile: chosen)
        let report = await restoreExecutor(router).restore(try #require(AdGuardConfigFile(chosen)), availability: .running) { _ in true }
        #expect(report.outcome == .verifiedRecovery(restored: AdGuardRestoreState(written: true, answering: true, dnsMatches: true)))
        #expect(await router.events == ["read file", "stop", "write file", "start", "stop", "write file", "start"])
        #expect(await router.file == current)
    }

    /// Every file write fails, so the rollback cannot put the saved file
    /// back either.
    @Test func failedRollbackIsRecoveryFailed() async throws {
        let router = RouterFake(file: current)
        let clock = StepClock()
        let executor = AdGuardBackupExecutor(files: BrokenWrites(router), service: router, settings: router, gate: MutationGate(),
                                             clock: { clock.now() }, sleep: { try await clock.sleep($0) })
        let report = await executor.restore(try #require(AdGuardConfigFile(chosen)), availability: .running) { _ in true }
        #expect(report.outcome == .recoveryFailed(expected: AdGuardRestoreState(written: true, answering: true, dnsMatches: true),
                                                  actual: AdGuardRestoreState(written: false, answering: true, dnsMatches: false)))
        #expect(report.dispatched)
    }

    @Test func nothingIsSentWhenTheBackupFails() async throws {
        let router = RouterFake(file: current)
        let notSaved = await restoreExecutor(router).restore(try #require(AdGuardConfigFile(chosen)), availability: .running) { _ in false }
        #expect(notSaved.outcome == .rejected(.preconditionFailed(AdGuardBackupExecutor.notSaved)))
        await router.set(readFails: true)
        let unreadable = await restoreExecutor(router).restore(try #require(AdGuardConfigFile(chosen)), availability: .running) { _ in true }
        #expect(unreadable.outcome == .rejected(.preconditionFailed(AdGuardBackupExecutor.notBackedUp)))
        #expect(!unreadable.dispatched)
        #expect(await router.events == ["read file", "read file"])
    }

    @Test func notStoppedWritesNothing() async throws {
        let router = RouterFake(file: current)
        await router.set(staysOn: true)
        let report = await restoreExecutor(router).restore(try #require(AdGuardConfigFile(chosen)), availability: .running) { _ in true }
        #expect(report.outcome == .verifiedMismatch(expected: AdGuardRestoreState(written: true, answering: true, dnsMatches: true),
                                                     actual: AdGuardRestoreState(written: false, answering: true, dnsMatches: nil)))
        #expect(await router.file == current)
        #expect(await !router.events.contains("write file"))
    }

    @Test func readOnlyIsRejected() async throws {
        let router = RouterFake(file: current)
        let executor = restoreExecutor(router)
        let report = await executor.restore(try #require(AdGuardConfigFile(chosen)), availability: .cached) { _ in true }
        #expect(!report.dispatched)
        #expect(await executor.readConfig(availability: .cached) == .failure(.notRunning))
        #expect(await executor.readConfig(availability: .running) == .success(try #require(AdGuardConfigFile(current))))
        #expect(await router.events == ["read file"])
    }
}

/// The router's file never changes: every write fails, so the rollback
/// cannot put the saved file back either.
private struct BrokenWrites: AdGuardConfigFileTransport {
    let router: RouterFake
    init(_ router: RouterFake) { self.router = router }
    func readConfigFile() async throws -> Data { try await router.readConfigFile() }
    func writeConfigFile(_ data: Data) async throws { throw SSHFailure.timedOut }
}

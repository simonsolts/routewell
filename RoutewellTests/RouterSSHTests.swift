import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

// No test starts `ssh` or `ssh-keyscan`: the mock backend and
// fakes for the scanner and the process runner stand in for both.

private let british = Locale(identifier: "en_GB")

@MainActor private func sshEnvironment(segment: RouterSegment, scenario: MockSSHService.Scenario = .populated) async -> (AppEnvironment, MockRouterBackend) {
    let backend = MockRouterBackend()
    backend.mockSSH.setScenario(scenario)
    let model = AppModel(mode: .mock)
    let environment = AppEnvironment(model: model, backend: backend)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    environment.refresh.setWindowVisible(true)
    model.subpages[.router] = segment.rawValue
    model.selection = .router
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    return (environment, backend)
}

private struct FakeScanner: SSHHostKeyScanning {
    let candidates: [SSHHostKeyCandidate]
    func scan(host: String, port: Int) async throws(SSHFailure) -> [SSHHostKeyCandidate] { candidates }
}

private struct RefusingScanner: SSHHostKeyScanning {
    func scan(host: String, port: Int) async throws(SSHFailure) -> [SSHHostKeyCandidate] { throw .connectionFailed }
}

/// Serves the board JSON for every launch and records argv. Never starts a process.
private actor FakeProcesses: ProcessRunning {
    private(set) var launches: [[String]] = []
    func run(executable: URL, arguments: [String], environment: [String: String], limits: ProcessLimits) async throws -> ProcessResult {
        launches.append(arguments)
        let board = #"{"model":"Example Router","hostname":"router","release":{"version":"21.02-SNAPSHOT"}}"#
        return ProcessResult(exitStatus: 0, stdout: Data(board.utf8), stderr: Data(), stdoutTruncated: false, stderrTruncated: false)
    }
}

private struct NoTransport: HTTPTransport {
    func send(_ request: URLRequest, limits: HTTPRequestLimits) async throws -> (Data, HTTPURLResponse) {
        throw TransportError.invalidResponse
    }
}

private func candidate(_ seed: UInt8) -> SSHHostKeyCandidate {
    SSHHostKeyCandidate(keyLine: "192.0.2.1 ssh-ed25519 \(Data((0..<51).map { UInt8($0) &+ seed }).base64EncodedString())")!
}

private func temporaryKeyFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("routewell-test-key-\(UUID())")
    try Data("not a real key".utf8).write(to: url)
    return url
}

@MainActor private func waitForPrompt(_ setup: SSHSetupController) async {
    for _ in 0..<10_000 where setup.prompt == nil { await Task.yield() }
}

// MARK: SSHRequiredView and probe states

@MainActor @Test func sshRequiredViewClearsOnceSSHIsConfigured() async {
    let (environment, backend) = await sshEnvironment(segment: .ports, scenario: .off)
    let model = environment.model
    #expect(!model.sshConfigured)
    #expect(RouterSSHState(configured: model.sshConfigured, probe: model.sshProbe) == .notSetUp)
    #expect(model.sshProbe == nil && model.ports == nil)

    environment.setMockSSHScenario(.populated)
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    #expect(model.sshConfigured)
    #expect(RouterSSHState(configured: model.sshConfigured, probe: model.sshProbe) == .ready)
    #expect(model.ports?.ports.count == 7)
    #expect(backend.ssh != nil)

    // Switching SSH off again brings SSHRequiredView back.
    environment.setMockSSHScenario(.off)
    #expect(RouterSSHState(configured: model.sshConfigured, probe: model.sshProbe) == .notSetUp)
}

@MainActor @Test func probeScenariosShowTheirState() async {
    let (environment, _) = await sshEnvironment(segment: .storage, scenario: .probeFails)
    let model = environment.model
    #expect(RouterSSHState(configured: true, probe: model.sshProbe)
            == .unavailable(title: "SSH is not working", message: SSHFailure.authenticationFailed.message))
    #expect(model.storage == nil)
    #expect(model.capabilities[.ssh]?.state == .unsupported)

    environment.setMockSSHScenario(.hostKeyChanged)
    await environment.refresh.waitForSSH()
    guard case .unavailable(let title, let message) = RouterSSHState(configured: true, probe: model.sshProbe) else {
        Issue.record("expected unavailable"); return
    }
    #expect(title == "SSH host key changed" && message == SSHFailure.hostKeyChanged.message)

    environment.setMockSSHScenario(.probeTimesOut)
    await environment.refresh.waitForSSH()
    guard case .unavailable(let unknownTitle, _) = RouterSSHState(configured: true, probe: model.sshProbe) else {
        Issue.record("expected unknown"); return
    }
    #expect(unknownTitle == "SSH status unknown")
    #expect(model.capabilities[.ssh]?.state == .unknown)

    environment.setMockSSHScenario(.probePending)
    #expect(RouterSSHState(configured: model.sshConfigured, probe: model.sshProbe) == .checking)
    // A session switch cancels the pending probe.
    environment.switchMockProfile(AppEnvironment.mockProfiles[1])
    await environment.waitUntilReady()
}

@MainActor @Test func eachSSHSegmentLaysOutInEveryState() async {
    let (environment, _) = await sshEnvironment(segment: .ports)
    for scenario in [MockSSHService.Scenario.populated, .off, .probeFails] {
        environment.setMockSSHScenario(scenario)
        await environment.refresh.waitForSSH()
        for segment in [RouterSegment.ports, .storage, .logs] {
            environment.model.subpages[.router] = segment.rawValue
            await environment.refresh.waitForRefresh()
            await environment.refresh.waitForSSH()
            let view = NSHostingView(rootView: RouterScreen().environment(environment.model).environment(environment).frame(width: 1100, height: 800))
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0, "\(scenario) \(segment)")
        }
    }
}

// MARK: Ports, Storage, Logs

@MainActor @Test func portsSegmentMatchesTheMockupTable() async {
    let (environment, _) = await sshEnvironment(segment: .ports)
    let ports = RouterPortsModel(ports: try! #require(environment.model.ports), changes: environment.model.linkChanges, locale: british)
    #expect(ports.strip.map(\.value) == ["7", "4", "3", "0"])
    #expect(ports.strip[1].detail == "eth0 · eth1 · eth2 · lan7")
    #expect(ports.strip[2].detail == "lan5 · lan6 · lan8")
    #expect(RouterPortsModel.columns == ["Interface", "Link", "Speed", "Duplex", "RX", "TX", "Errors / drops"])
    #expect(ports.rows[0].map(\.text) == ["eth0", "Connected", "10 Gbps", "Full", "1 KB", "2 KB", "0 / 0"])
    #expect(ports.rows[1].map(\.text) == ["eth1", "Connected", "10 Gbps", "Full", "300 MB", "9 GB", "0 / 0"])
    #expect(ports.rows[3].map(\.text) == ["lan5", "Disconnected", "—", "—", "0 B", "0 B", "0 / 0"])
    #expect(ports.rows[0][1].tone == .healthy && ports.rows[3][1].tone == .unknown)
    #expect(RouterFormat.decimalBytes(318_100_000) == "318.1 MB" && RouterFormat.decimalBytes(2_100) == "2.1 KB")
    #expect(ports.history == RouterRowModel(label: "Link changes observed",
                                            detail: "Recorded while Routewell is running; unmonitored time is excluded.", value: "None"))
    #expect(RouterPortsModel.footnote == "Counters are cumulative since the router last booted. Errors and drops are shown as RX / TX.")
    #expect(ports.summary(hostname: "flint-demo").contains("eth2"))
}

@MainActor @Test func linkChangesListNewestFirstAndEndWithTheSession() async throws {
    let (environment, _) = await sshEnvironment(segment: .ports)
    let model = environment.model
    let token = try #require(model.session.expectedToken)
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    model.acceptPorts(.success(RouterPortsStatus(ports: [EthernetPortStatus(name: "lan5", link: .up)]), observedAt: t0, source: .mock), token: token)
    model.acceptPorts(.success(RouterPortsStatus(ports: [EthernetPortStatus(name: "lan5", link: .down)]), observedAt: t0.addingTimeInterval(30), source: .mock), token: token)
    let ports = RouterPortsModel(ports: try #require(model.ports), changes: model.linkChanges, locale: british)
    #expect(ports.history.value == "2")
    #expect(ports.changes.count == 2)
    #expect(ports.changes.first?.hasSuffix("lan5 · Connected → Disconnected") == true)
    environment.switchMockProfile(AppEnvironment.mockProfiles[1])
    #expect(model.linkChanges.changes.isEmpty)
}

@MainActor @Test func storageSegmentUsesTheMockupRowsAndFootnote() async {
    let (environment, _) = await sshEnvironment(segment: .storage)
    let storage = RouterStorageModel(storage: try! #require(environment.model.storage), locale: british)
    #expect(storage.rootStatus.value == "Available" && storage.rootStatus.tone == .healthy)
    #expect(storage.rootUsage == "15 % used" && storage.rootFraction == 0.15)
    #expect(storage.rootRows.map(\.value) == ["1.1 G", "6.1 G", "7.2 G"])
    #expect(storage.rootRows.map(\.label) == ["Used", "Available", "Capacity"])
    #expect(storage.sharing.map(\.value) == ["Configured", "1"])
    #expect(storage.shares == [[RouterCell(text: "Backups"), RouterCell(text: "Unknown"), RouterCell(text: "No"), RouterCell(text: "No")]])
    #expect(storage.mounted.value == "1")
    let volume = try! #require(storage.volumes.first)
    #expect(volume.mountPoint == "/mnt/sda1" && volume.type == "ext4" && volume.usage == "120 GB of 500 GB")
    #expect(abs((volume.fraction ?? 0) - 0.24) < 0.000_001)
    #expect(storage.externalAvailable?.value == "380 GB")
    #expect(RouterStorageModel.footnote == "Read-only observations. No credentials, share paths or files are read; file browsing and storage changes are not available here.")
    #expect(RouterStorageModel(storage: StorageStatus(samba: .value(.notConfigured))).sharing.map(\.value) == ["Not configured"])
    #expect(RouterStorageModel(storage: StorageStatus()).rootStatus.value == "Unknown")
}

@MainActor @Test func logsFilterBySeverityCategoryAndSearch() async {
    let (environment, _) = await sshEnvironment(segment: .logs)
    let tail = try! #require(environment.model.routerLogs)
    let all = RouterLogsModel(tail: tail, severity: .all, category: nil, search: "")
    #expect(all.entries.count == 17)
    #expect(all.status == "Showing 17 most recent entries · newest first")
    #expect(all.entries.first?.source == "AdGuardHome")

    let errors = RouterLogsModel(tail: tail, severity: .errorAndAbove, category: nil, search: "")
    #expect(errors.entries.map(\.message) == ["[screen][ws_callback][error]ws closed"])
    #expect(errors.status == "Showing 1 of 17 most recent entries · newest first")
    #expect(RouterLogsModel(tail: tail, severity: .warningAndAbove, category: nil, search: "").entries.count == 4)
    #expect(RouterLogsModel(tail: tail, severity: .debug, category: nil, search: "").entries.count == 1)
    #expect(RouterLogsModel(tail: tail, severity: .all, category: .dhcpDNS, search: "").entries.count == 5)
    #expect(RouterLogsModel(tail: tail, severity: .all, category: .kernel, search: "").entries.count == 2)
    #expect(RouterLogsModel(tail: tail, severity: .info, category: .dhcpDNS, search: "192.0.2.52").entries.count == 2)
    #expect(RouterLogsModel(tail: tail, severity: .all, category: nil, search: "no such text").entries.isEmpty)

    let selected = try! #require(errors.entries.first)
    let detail = RouterLogsModel.detail(selected, locale: british)
    #expect(detail.map(\.label) == ["Time", "Facility · priority", "Source", "Message"])
    #expect(detail[0].value.hasPrefix("Thu 15 Jan"))
    #expect(detail[0].value.contains("2026, 10:00:40"))
    #expect(detail[1].value == "user.err" && detail[2].value == "router" && detail[3].value == "[screen][ws_callback][error]ws closed")
    #expect(RouterLogsModel.tone(.error) == .error && RouterLogsModel.tone(.warning) == .attention)
    #expect(RouterLogsModel.tone(.notice) == .inProgress && RouterLogsModel.tone(.info) == .unknown)
    #expect(RouterLogsModel.copyText([selected]).hasSuffix("user.err : [screen][ws_callback][error]ws closed"))
}

@MainActor @Test func logsReadOnlyOnDemandNotOnTimedTicks() async {
    let (environment, _) = await sshEnvironment(segment: .logs)
    #expect(environment.model.routerLogs != nil)
    let first = environment.model.routerLogsFreshness.lastSuccess
    environment.refresh.refreshNow(automaticTick: .seconds(60))
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()
    #expect(environment.model.routerLogsFreshness.lastSuccess == first)
}

// MARK: Overview PID row

@MainActor @Test func overviewAdGuardRowShowsTheProcessID() async {
    var snapshot = MockRouterBackend.snapshot(at: .now)
    snapshot.adGuard.version = "0.107.73"
    #expect(RouterOverviewModel(snapshot: snapshot, wireless: nil, sshConfigured: true, adGuardProcessID: .value(4321)).services[0].detail
            == "0.107.73 · process 4321")
    #expect(RouterOverviewModel(snapshot: snapshot, wireless: nil).services[0].detail == "0.107.73 · process ID needs SSH")
    #expect(RouterOverviewModel(snapshot: snapshot, wireless: nil, sshConfigured: true, adGuardProcessID: .unavailable).services[0].detail
            == "0.107.73 · no process found")
    #expect(RouterOverviewModel(snapshot: snapshot, wireless: nil, sshConfigured: true).services[0].detail == "0.107.73 · process ID unknown")

    let (environment, _) = await sshEnvironment(segment: .overview)
    #expect(environment.model.adGuardProcessID == .value(4321))
}

// MARK: Host-key trust prompt

@MainActor @Test func trustPromptAcceptStoresTheKeyAndTurnsSSHOn() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routewell-ssh-app-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try temporaryKeyFile()
    defer { try? FileManager.default.removeItem(at: key) }
    let store = SSHHostKeyStore(directory: directory)
    let setup = SSHSetupController(hostKeys: store, scanner: FakeScanner(candidates: [candidate(0)]))
    var saved: [SSHSettings] = []
    setup.save = { saved.append($0) }
    let draft = SSHSettings(keyFilePath: key.path)

    let task = Task { await setup.enable(draft, host: "192.0.2.1") }
    await waitForPrompt(setup)
    #expect(setup.prompt == .newKey(host: "192.0.2.1", port: 22, candidate: candidate(0)))
    setup.resolve(true)
    await task.value
    #expect(saved.last?.enabled == true)
    #expect(try await store.storedKeyLine(host: "192.0.2.1", port: 22) == candidate(0).keyLine)
    #expect(setup.trustedFingerprint == candidate(0).fingerprintSHA256)

    // Same key next time: no prompt.
    await setup.enable(draft, host: "192.0.2.1")
    #expect(setup.prompt == nil && saved.last?.enabled == true)
}

@MainActor @Test func trustPromptRejectLeavesSSHOff() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routewell-ssh-app-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try temporaryKeyFile()
    defer { try? FileManager.default.removeItem(at: key) }
    let store = SSHHostKeyStore(directory: directory)
    let setup = SSHSetupController(hostKeys: store, scanner: FakeScanner(candidates: [candidate(0)]))
    var saved: [SSHSettings] = []
    setup.save = { saved.append($0) }

    let task = Task { await setup.enable(SSHSettings(keyFilePath: key.path), host: "192.0.2.1") }
    await waitForPrompt(setup)
    setup.resolve(false)
    await task.value
    #expect(saved.last?.enabled == false)
    #expect(try await store.storedKeyLine(host: "192.0.2.1", port: 22) == nil)
    #expect(setup.message == "SSH stays off. The host key was not trusted.")

    // No key file and no agent: nothing is scanned, SSH stays off.
    let noKey = SSHSetupController(hostKeys: store, scanner: RefusingScanner(), agentSocket: { nil }, agentAllowed: true)
    noKey.save = { saved.append($0) }
    await noKey.enable(SSHSettings(), host: "192.0.2.1")
    #expect(noKey.message == "Choose a private key file.")
    await noKey.enable(SSHSettings(useAgent: true), host: "192.0.2.1")
    #expect(noKey.message == "No SSH agent was found. Start one, or choose a key file.")
    // In the App Sandbox the agent is refused even when its socket exists.
    let sandboxed = SSHSetupController(hostKeys: store, scanner: RefusingScanner(),
                                       agentSocket: { URL(fileURLWithPath: "/tmp/agent.sock") }, agentAllowed: false)
    sandboxed.save = { saved.append($0) }
    await sandboxed.enable(SSHSettings(useAgent: true), host: "192.0.2.1")
    #expect(sandboxed.message == "The SSH agent is not available in this version of Routewell. Choose a key file.")
    let refused = SSHSetupController(hostKeys: store, scanner: RefusingScanner())
    refused.save = { saved.append($0) }
    await refused.enable(SSHSettings(keyFilePath: key.path), host: "192.0.2.1")
    #expect(refused.message == "SSH stays off. \(SSHFailure.connectionFailed.message)")
    #expect(saved.allSatisfy { !$0.enabled })
}

@MainActor @Test func changedHostKeyIsRefusedEvenWhenReplaced() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routewell-ssh-app-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try temporaryKeyFile()
    defer { try? FileManager.default.removeItem(at: key) }
    let store = SSHHostKeyStore(directory: directory)
    try await store.approve(host: "192.0.2.1", port: 22, keyLine: candidate(0).keyLine)
    let setup = SSHSetupController(hostKeys: store, scanner: FakeScanner(candidates: [candidate(9)]))
    var saved: [SSHSettings] = []
    setup.save = { saved.append($0) }

    let task = Task { await setup.enable(SSHSettings(keyFilePath: key.path), host: "192.0.2.1") }
    await waitForPrompt(setup)
    #expect(setup.prompt == .changedKey(host: "192.0.2.1", port: 22, trustedFingerprint: candidate(0).fingerprintSHA256, candidate: candidate(9)))
    setup.resolve(true)
    await task.value
    // Refused for this attempt, whatever the answer; the new key is stored for next time.
    #expect(saved.last?.enabled == false)
    #expect(try await store.storedKeyLine(host: "192.0.2.1", port: 22) == candidate(9).keyLine)
    #expect(setup.message == "The new host key is trusted. Switch SSH on to connect with it.")

    // Keep SSH Off leaves the old key.
    try await store.approve(host: "192.0.2.1", port: 22, keyLine: candidate(0).keyLine)
    let again = Task { await setup.enable(SSHSettings(keyFilePath: key.path), host: "192.0.2.1") }
    await waitForPrompt(setup)
    setup.resolve(false)
    await again.value
    #expect(try await store.storedKeyLine(host: "192.0.2.1", port: 22) == candidate(0).keyLine)
    #expect(saved.last?.enabled == false)
}

@MainActor @Test func promptViewLaysOutForNewChangedAndPreview() {
    let prompts: [SSHSetupController.Prompt] = [
        .newKey(host: "192.0.2.1", port: 22, candidate: candidate(0)),
        .changedKey(host: "192.0.2.1", port: 22, trustedFingerprint: candidate(0).fingerprintSHA256, candidate: candidate(9)),
        .preview(.new), .preview(.changed),
    ]
    for prompt in prompts {
        let view = NSHostingView(rootView: SSHHostKeyPromptView(prompt: prompt, onCancel: {}, onApprove: {}))
        #expect(view.fittingSize.height > 0)
    }
}

// MARK: Live wiring

@MainActor @Test func enablingSSHBuildsTheLiveRunnerAndProbesOnceThroughTheProcessRunner() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routewell ssh live \(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try temporaryKeyFile()
    defer { try? FileManager.default.removeItem(at: key) }
    let processes = FakeProcesses()
    let environment = AppEnvironment(model: AppModel(mode: .live), backend: nil, sshDirectory: directory,
                                     hostKeyScanner: FakeScanner(candidates: [candidate(0)]), processRunner: processes,
                                     transportFactory: { _ in NoTransport() })
    await environment.waitUntilReady()
    let saved = await environment.saveFinishedRouter(try RouterEndpoint.parse("192.0.2.1"))
    #expect(saved)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    #expect(!environment.model.sshConfigured)
    #expect(environment.model.session.lease?.backend.clientActions?.mechanism == .sshRequired)
    #expect(await processes.launches.isEmpty)

    let enabling = Task { await environment.sshSetup.enable(SSHSettings(keyFilePath: key.path), host: "192.0.2.1") }
    await waitForPrompt(environment.sshSetup)
    environment.sshSetup.resolve(true)
    await enabling.value
    #expect(environment.persistence.selectedProfile?.ssh?.enabled == true)
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    await environment.refresh.waitForSSH()

    #expect(environment.model.sshConfigured)
    #expect(environment.model.session.lease?.backend.clientActions?.mechanism == .ssh)
    #expect(environment.model.sshProbe?.capability.state == .supported)
    let launches = await processes.launches
    #expect(launches.count == 1)
    #expect(launches.first?.last == "ubus call system board")
    #expect(launches.first?.contains("StrictHostKeyChecking=yes") == true)
    #expect(launches.first?.contains("UserKnownHostsFile=\"\(directory.appendingPathComponent("known_hosts").path)\"") == true)

    // Switching SSH off rebuilds the session without SSH.
    environment.sshSetup.disable(environment.persistence.selectedProfile!.ssh!)
    await environment.waitUntilReady()
    #expect(!environment.model.sshConfigured)
    #expect(environment.model.session.lease?.backend.clientActions?.mechanism == .sshRequired)
}

// MARK: Key file bookmark (App Sandbox)

@MainActor @Test func keyFileBookmarkFollowsAMovedKeyAndIsIgnoredForTheAgent() throws {
    let key = try temporaryKeyFile()
    let moved = key.appendingPathExtension("moved")
    defer { try? FileManager.default.removeItem(at: key); try? FileManager.default.removeItem(at: moved) }
    let bookmark = try #require(SSHKeyFileAccess.bookmark(for: key))
    let access = SSHKeyFileAccess()

    // Unchanged file: nothing to save.
    #expect(access.activate(SSHSettings(keyFilePath: key.path, keyFileBookmark: bookmark)) == nil)

    // Moved file: the bookmark finds it, and the new path is returned to save.
    try FileManager.default.moveItem(at: key, to: moved)
    let refreshed = try #require(access.activate(SSHSettings(keyFilePath: key.path, keyFileBookmark: bookmark)))
    #expect(refreshed.keyFilePath == moved.resolvingSymlinksInPath().path)
    #expect(refreshed.identity == .keyFile(URL(fileURLWithPath: refreshed.keyFilePath ?? "")))

    // The agent and older settings without a bookmark use no bookmark.
    #expect(access.activate(SSHSettings(keyFilePath: moved.path, keyFileBookmark: bookmark, useAgent: true)) == nil)
    #expect(access.activate(SSHSettings(keyFilePath: moved.path)) == nil)
    #expect(access.activate(nil) == nil)
}

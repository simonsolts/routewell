import Foundation
import Testing
@testable import RoutewellKit
import RoutewellMock

/// Serves canned process results and records each command. Never runs ssh.
private actor FakeSSHRunner: SSHCommandRunning {
    enum Reply: Sendable { case output(Int32, String), error(ProcessRunnerError), wait(Duration, String) }
    private let reply: Reply
    private(set) var commands: [SSHCommand] = []

    init(_ reply: Reply) { self.reply = reply }

    func run(_ command: SSHCommand, limits: ProcessLimits) async throws -> ProcessResult {
        commands.append(command)
        switch reply {
        case .output(let status, let text):
            return ProcessResult(exitStatus: status, stdout: Data(text.utf8), stderr: Data(), stdoutTruncated: false, stderrTruncated: false)
        case .error(let error):
            throw error
        case .wait(let duration, let text):
            try await Task.sleep(for: duration)
            return ProcessResult(exitStatus: 0, stdout: Data(text.utf8), stderr: Data(), stdoutTruncated: false, stderrTruncated: false)
        }
    }
}

private let busyBoxReply = """
PING 192.168.8.10 (192.168.8.10): 56 data bytes
64 bytes from 192.168.8.10: seq=0 ttl=64 time=2.912 ms
--- 192.168.8.10 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 2.101/3.150/4.220 ms
"""

private let busyBoxNoReply = """
PING 192.168.8.11 (192.168.8.11): 56 data bytes
--- 192.168.8.11 ping statistics ---
3 packets transmitted, 0 packets received, 100% packet loss
"""

@Suite struct ClientActionsTests {
    private let target = IPv4Literal("192.168.8.10")!
    private let device = MACAddress("66:29:ea:33:fb:78")!

    @Test func ipv4LiteralAcceptsOnlyDottedDecimal() {
        #expect(IPv4Literal("192.168.8.10")?.description == "192.168.8.10")
        #expect(IPv4Literal("010.1.1.1")?.description == "10.1.1.1")
        for bad in ["192.168.8", "192.168.8.256", "1.2.3.4; reboot", "1.2.3.4 ", "::1", "1.2.3.4$(id)", "١.2.3.4", ""] {
            #expect(IPv4Literal(bad) == nil, "\(bad)")
        }
    }

    @Test func commandsRenderOnlyValidatedValues() {
        #expect(SSHCommand.pingClient(target).rendered == "ping -c 3 -W 2 192.168.8.10")
        let wake = SSHCommand.wakeClient(device).rendered
        #expect(wake.contains("etherwake -i br-lan 66:29:EA:33:FB:78"))
        #expect(wake.contains("wol 66:29:EA:33:FB:78"))
        #expect(wake.contains(SSHCommand.wakeToolMissingMarker))
    }

    @Test func pingSummaryParsing() {
        #expect(PingOutputParser.parse(busyBoxReply) == PingResult(transmitted: 3, received: 3, averageMilliseconds: 3.15))
        // RouterPilot matched "0% packet loss", which "100% packet loss" also contains.
        #expect(PingOutputParser.parse(busyBoxNoReply) == PingResult(transmitted: 3, received: 0))
        #expect(PingOutputParser.parse("3 packets transmitted, 2 received, 33% packet loss, time 2003ms\nrtt min/avg/max/mdev = 1.0/2.5/3.0/0.4 ms")
                == PingResult(transmitted: 3, received: 2, averageMilliseconds: 2.5))
        #expect(PingOutputParser.parse("ping: bad address") == nil)
    }

    @Test func sshPingReportsReplyNoReplyAndFailure() async throws {
        let gate = MutationGate()
        let ok = FakeSSHRunner(.output(0, busyBoxReply))
        #expect(try await SSHClientActions(runner: ok, gate: gate).ping(target) == .success(PingResult(transmitted: 3, received: 3, averageMilliseconds: 3.15)))
        #expect(await ok.commands == [.pingClient(target)])
        let silent = FakeSSHRunner(.output(1, busyBoxNoReply))
        #expect(try await SSHClientActions(runner: silent, gate: gate).ping(target) == .success(PingResult(transmitted: 3, received: 0)))
        let timeout = FakeSSHRunner(.error(.timedOut))
        #expect(try await SSHClientActions(runner: timeout, gate: gate).ping(target) == .failure(.timeout))
        let garbage = FakeSSHRunner(.output(0, "hello"))
        #expect(try await SSHClientActions(runner: garbage, gate: gate).ping(target) == .failure(.malformedResponse))
        let cancelled = FakeSSHRunner(.error(.cancelled))
        await #expect(throws: CancellationError.self) { _ = try await SSHClientActions(runner: cancelled, gate: gate).ping(target) }
    }

    @Test func wakeOutcomesFollowTheToolOutput() async {
        let gate = MutationGate()
        let sent = await SSHClientActions(runner: FakeSSHRunner(.output(0, "")), gate: gate).wake(device)
        #expect(sent.outcome == .verifiedSuccess(.sent) && sent.dispatched)
        let missing = await SSHClientActions(runner: FakeSSHRunner(.output(0, SSHCommand.wakeToolMissingMarker + "\n")), gate: gate).wake(device)
        #expect(missing.outcome == .rejected(.preconditionFailed("No Wake-on-LAN tool on the router")) && missing.dispatched)
        let failed = await SSHClientActions(runner: FakeSSHRunner(.output(1, "etherwake: ioctl error")), gate: gate).wake(device)
        #expect(failed.outcome == .unknownAfterDispatch && failed.dispatched)
        // Connection lost after dispatch: unknown, not a failure.
        let lost = await SSHClientActions(runner: FakeSSHRunner(.error(.timedOut)), gate: gate).wake(device)
        #expect(lost.outcome == .unknownAfterDispatch && lost.dispatched && lost.failure == .timeout)
        let notStarted = await SSHClientActions(runner: FakeSSHRunner(.error(.launchFailed("no ssh"))), gate: gate).wake(device)
        #expect(!notStarted.dispatched)
    }

    @Test func wakeHoldsTheRouterGate() async throws {
        let gate = MutationGate()
        let actions = SSHClientActions(runner: FakeSSHRunner(.wait(.milliseconds(200), "")), gate: gate)
        let task = Task { await actions.wake(device) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gate.isHeld)
        _ = await task.value
        try await Task.sleep(for: .milliseconds(20))
        #expect(await !gate.isHeld)
    }

    @Test func sshRequiredSendsNothing() async throws {
        let actions = SSHRequiredClientActions()
        #expect(actions.mechanism == .sshRequired)
        #expect(try await actions.ping(target) == .failure(.unavailable))
        let report = await actions.wake(device)
        #expect(report.outcome == .rejected(.capabilityUnavailable) && !report.dispatched)
    }

    @Test func liveBackendWithoutSSHShowsSSHRequired() throws {
        let endpoint = try RouterEndpoint(scheme: .https, host: "192.0.2.20", port: 443)
        let transport = StubHTTPTransport { _ in throw TransportError.timedOut }
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: "root", password: { "x" }, transport: transport)
        let backend = LiveRouterBackend(configuration: .init(routerEndpoint: endpoint), rpc: rpc, adGuard: nil,
                                        trustStore: InMemoryEndpointTrustStore(), trustPrompt: DenyAllTrustPromptHandler())
        #expect(backend.clientActions?.mechanism == .sshRequired)
        let withSSH = LiveRouterBackend(configuration: .init(routerEndpoint: endpoint), rpc: rpc, adGuard: nil,
                                        trustStore: InMemoryEndpointTrustStore(), trustPrompt: DenyAllTrustPromptHandler(),
                                        sshRunner: FakeSSHRunner(.output(0, "")))
        #expect(withSSH.clientActions?.mechanism == .ssh)
        #expect(backend.queryLog == nil)
    }

    @Test func mockMechanismsIncludeHidden() async throws {
        let backend = MockRouterBackend()
        #expect(backend.clientActions?.mechanism == .ssh)
        backend.mockClientActions.setMechanism(.rpc)
        #expect(backend.clientActions?.mechanism == .rpc)
        backend.mockClientActions.setMechanism(.sshRequired)
        #expect(try await backend.clientActions?.ping(target) == .failure(.unavailable))
        backend.mockClientActions.setMechanism(nil)
        #expect(backend.clientActions == nil)
    }

    @Test func sessionFencesPingAndWake() async throws {
        let session = RouterSession()
        let token = SessionToken(profileID: "a", revision: 1)
        let backend = MockRouterBackend()
        try await session.beginRevision(token)
        let lease = SessionLease(token: token, backend: backend)
        try await session.installLease(lease)
        let ping = try await session.ping(using: lease, address: IPv4Literal("192.168.8.192")!)
        #expect(ping == .success(PingResult(transmitted: 3, received: 3, averageMilliseconds: 3.2)))
        let wake = try await session.wake(using: lease, mac: device)
        #expect(wake?.outcome == .verifiedSuccess(.sent))
        backend.mockClientActions.setMechanism(nil)
        #expect(try await session.ping(using: lease, address: target) == nil)
        try await session.beginRevision(SessionToken(profileID: "a", revision: 2))
        await #expect(throws: SessionError.self) { _ = try await session.wake(using: lease, mac: device) }
    }
}

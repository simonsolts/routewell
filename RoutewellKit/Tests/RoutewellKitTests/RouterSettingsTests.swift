import Foundation
import Testing
@testable import RoutewellKit

// MARK: Test Connection (chunk 15B)

/// Counts which checks ran, so a test can prove that nothing else was sent.
private actor CallLog {
    private(set) var calls: [String] = []
    func add(_ call: String) { calls.append(call) }
}

private func connectionTest(router: RouterCheck, sshEnabled: Bool = true, ssh: SSHProbeResult = .working,
                            adGuardConfigured: Bool = true, adGuardEnabled: Observed<Bool> = .value(true),
                            adGuardStatus: ConnectionCheckFailure? = nil, log: CallLog) -> ConnectionTest {
    ConnectionTest(
        router: { await log.add("router"); return router },
        sshEnabled: sshEnabled,
        ssh: { await log.add("ssh"); return ssh },
        adGuardConfigured: adGuardConfigured,
        adGuardEnabled: { await log.add("get_config"); return adGuardEnabled },
        adGuardStatus: { await log.add("control/status"); return adGuardStatus }
    )
}

private extension SSHProbeResult {
    static let working = SSHProbeResult(capability: Capability(.supported, evidence: .successfulResponse, observedAt: .now))
    static let refused = SSHProbeResult(capability: Capability(.unsupported, evidence: .sshProbeFailed("refused"), observedAt: .now),
                                        failure: .authenticationFailed)
}

@Test func allThreeChecksWork() async {
    let log = CallLog()
    let report = await connectionTest(router: .responded(milliseconds: 12), log: log).run()
    #expect(report == ConnectionTestReport(router: .responded(milliseconds: 12), ssh: .working, adGuard: .working))
    #expect(await log.calls.first == "router")
    #expect(Set(await log.calls) == ["router", "ssh", "get_config", "control/status"])
}

@Test func routerFailureLeavesSSHAndAdGuardNotTestedAndSendsNothingElse() async {
    let log = CallLog()
    let report = await connectionTest(router: .failed(.noResponse), log: log).run()
    #expect(report == ConnectionTestReport(router: .failed(.noResponse), ssh: .notTested, adGuard: .notTested))
    #expect(await log.calls == ["router"])

    // SSH switched off still reads Off, not Not tested.
    let offLog = CallLog()
    let off = await connectionTest(router: .failed(.signInRefused), sshEnabled: false, log: offLog).run()
    #expect(off.ssh == .off)
    #expect(off.adGuard == .notTested)
}

@Test func sshOffIsNeverProbed() async {
    let log = CallLog()
    let report = await connectionTest(router: .responded(milliseconds: 5), sshEnabled: false, log: log).run()
    #expect(report.ssh == .off)
    #expect(report.adGuard == .working)
    #expect(!(await log.calls.contains("ssh")))
}

@Test func sshProbeFailureKeepsItsReason() async {
    let log = CallLog()
    let report = await connectionTest(router: .responded(milliseconds: 5), ssh: .refused, log: log).run()
    #expect(report.ssh == .failed(.authenticationFailed))
}

@Test func adGuardOffOnTheRouterSkipsItsStatusCall() async {
    let log = CallLog()
    let report = await connectionTest(router: .responded(milliseconds: 5), adGuardEnabled: .value(false), log: log).run()
    #expect(report.adGuard == .offOnRouter)
    #expect(!(await log.calls.contains("control/status")))

    // An unknown get_config still asks AdGuard Home itself.
    let unknownLog = CallLog()
    let unknown = await connectionTest(router: .responded(milliseconds: 5), adGuardEnabled: .unknown,
                                       adGuardStatus: .signInRefused, log: unknownLog).run()
    #expect(unknown.adGuard == .failed(.signInRefused))
    #expect(await unknownLog.calls.contains("control/status"))

    let notSetUpLog = CallLog()
    let notSetUp = await connectionTest(router: .responded(milliseconds: 5), adGuardConfigured: false, log: notSetUpLog).run()
    #expect(notSetUp.adGuard == .notSetUp)
    #expect(!(await notSetUpLog.calls.contains("get_config")))
}

@Test func progressStartsWithEveryRowTestingAndEndsComplete() async {
    let log = CallLog()
    let seen = Reports()
    let report = await connectionTest(router: .responded(milliseconds: 5), log: log).run { await seen.add($0) }
    let reports = await seen.all
    #expect(reports.first == ConnectionTestReport())
    #expect(reports.last == report)
    #expect(report.isComplete)
    #expect(!ConnectionTestReport(router: .responded(milliseconds: 5)).isComplete)
}

private actor Reports {
    private(set) var all: [ConnectionTestReport] = []
    func add(_ report: ConnectionTestReport) { all.append(report) }
}

@Test func routerLatencyRoundsToWholeMillisecondsOfAtLeastOne() {
    #expect(RouterCheck.responded(after: .milliseconds(38)) == .responded(milliseconds: 38))
    #expect(RouterCheck.responded(after: .microseconds(38_700)) == .responded(milliseconds: 38))
    #expect(RouterCheck.responded(after: .seconds(1)) == .responded(milliseconds: 1000))
    #expect(RouterCheck.responded(after: .zero) == .responded(milliseconds: 1))
}

@Test func failuresMapToPlainCategories() {
    #expect(ConnectionCheckFailure(GLiNetRPCError.transport(.timedOut)) == .noResponse)
    #expect(ConnectionCheckFailure(GLiNetRPCError.transport(.unreachable(code: -1004))) == .noResponse)
    #expect(ConnectionCheckFailure(GLiNetRPCError.transport(.untrustedServer(.untrustedNew(ConnectionCheckFailure.fingerprint)))) == .certificateNotTrusted)
    #expect(ConnectionCheckFailure(GLiNetRPCError.accessDenied) == .signInRefused)
    #expect(ConnectionCheckFailure(GLiNetRPCError.loginPaused) == .signInPaused)
    #expect(ConnectionCheckFailure(GLiNetRPCError.malformedResponse) == .unexpectedReply)
    #expect(ConnectionCheckFailure(AdGuardClientError.unauthorized(401)) == .signInRefused)
    #expect(ConnectionCheckFailure(AdGuardClientError.transport(.timedOut)) == .noResponse)
    #expect(ConnectionCheckFailure(AdGuardClientError.httpStatus(500)) == .unexpectedReply)
}

private extension ConnectionCheckFailure {
    static let fingerprint = try! CertificateFingerprint(sha256: Data(repeating: 0x22, count: 32))
}

// MARK: Input checks

@Test func routerNamesAreTrimmedAndAnEmptyNameKeepsTheOldOne() {
    #expect(RouterSettingsInput.name("  Home router \n") == "Home router")
    #expect(RouterSettingsInput.name("   ") == nil)
    #expect(RouterSettingsInput.name("") == nil)
    #expect(RouterSettingsInput.name(String(repeating: "a", count: 100))?.count == RouterSettingsInput.nameLimit)
}

@Test func addressesMustParseAndUseHTTPS() throws {
    #expect(try RouterSettingsInput.address(" 192.0.2.1 ").get() == RouterEndpoint.parse("192.0.2.1"))
    #expect(try RouterSettingsInput.address("router.example:8443").get().port == 8443)
    #expect(RouterSettingsInput.address("http://192.0.2.1") == .failure(.plainHTTP))
    #expect(RouterSettingsInput.address("") == .failure(.invalid(.empty)))
    #expect(RouterSettingsInput.address("192.0.2.1/admin") == .failure(.invalid(.pathNotAllowed)))
    #expect(RouterSettingsInput.address("not a host") == .failure(.invalid(.invalidHost)))
}

@Test func portsAreOneTo65535() {
    #expect(RouterSettingsInput.port("22") == 22)
    #expect(RouterSettingsInput.port(" 2222 ") == 2222)
    #expect(RouterSettingsInput.port("0") == nil)
    #expect(RouterSettingsInput.port("65536") == nil)
    #expect(RouterSettingsInput.port("-1") == nil)
    #expect(RouterSettingsInput.port("") == nil)
    #expect(RouterSettingsInput.port("２２") == nil)
}

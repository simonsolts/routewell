import Foundation
import AppKit
import SwiftUI
import Testing
import RoutewellKit
import RoutewellMock
@testable import Routewell

// MARK: Helpers

/// Counts requests and answers none, so nothing reaches a network.
private actor CountingTransport: HTTPTransport {
    private(set) var sent = 0
    func send(_ request: URLRequest, limits: HTTPRequestLimits) async throws -> (Data, HTTPURLResponse) {
        sent += 1
        throw TransportError.invalidResponse
    }
}

private struct FakeScanner: SSHHostKeyScanning {
    func scan(host: String, port: Int) async throws(SSHFailure) -> [SSHHostKeyCandidate] { [hostKey] }
}

/// Never starts a process; every SSH probe is refused.
private actor NoProcesses: ProcessRunning {
    private(set) var launches = 0
    func run(executable: URL, arguments: [String], environment: [String: String], limits: ProcessLimits) async throws -> ProcessResult {
        launches += 1
        return ProcessResult(exitStatus: 255, stdout: Data(), stderr: Data("Permission denied (publickey).".utf8),
                             stdoutTruncated: false, stderrTruncated: false)
    }
}

private let hostKey = SSHHostKeyCandidate(keyLine: "192.0.2.1 ssh-ed25519 \(Data(repeating: 0x33, count: 32).base64EncodedString())")!
private let otherHostKey = SSHHostKeyCandidate(keyLine: "198.51.100.1 ssh-ed25519 \(Data(repeating: 0x44, count: 32).base64EncodedString())")!
private let fingerprint = try! CertificateFingerprint(sha256: Data(repeating: 0x55, count: 32))

private struct LiveFixture {
    let environment: AppEnvironment
    let credentials: InMemoryCredentialStore
    let transport: CountingTransport
    let processes: NoProcesses
    let directory: URL
    let model: RouterSettingsModel
}

/// A finished live router at 192.0.2.1 with a pinned certificate. No
/// transport, process, or scanner reaches the network.
@MainActor private func liveFixture() async -> LiveFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routewell-settings-\(UUID())")
    let credentials = InMemoryCredentialStore()
    let transport = CountingTransport()
    let processes = NoProcesses()
    let environment = AppEnvironment(model: AppModel(mode: .live), backend: nil, credentials: credentials, sshDirectory: directory,
                                     hostKeyScanner: FakeScanner(), processRunner: processes, transportFactory: { _ in transport })
    await environment.waitUntilReady()
    let endpoint = try! RouterEndpoint.parse("192.0.2.1")
    _ = await environment.saveFinishedRouter(endpoint)
    await environment.trust.approve(TrustedEndpoint(host: endpoint.host, port: endpoint.port, fingerprint: fingerprint, approvedAt: .now))
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    let model = RouterSettingsModel(services: environment.liveRouterSettings, app: environment.model)
    await model.reloadLocal()
    return LiveFixture(environment: environment, credentials: credentials, transport: transport, processes: processes,
                       directory: directory, model: model)
}

@MainActor private func mockFixture() async -> (AppEnvironment, MockRouterSettingsServices, RouterSettingsModel) {
    let environment = AppEnvironment(model: AppModel(mode: .mock), backend: MockRouterBackend())
    await environment.waitUntilReady()
    await environment.refresh.waitForRefresh()
    let services = environment.mockRouterSettings
    services.delay = .zero
    let model = RouterSettingsModel(services: services, app: environment.model)
    await model.load()
    return (environment, services, model)
}

// MARK: Tabs

@MainActor @Test func everyTabLaysOutInLiveAndMockMode() async {
    let live = await liveFixture()
    let (mock, _, _) = await mockFixture()
    for environment in [live.environment, mock] {
        for tab in SettingsTab.allCases {
            environment.model.settingsTab = tab
            let view = NSHostingView(rootView: SettingsView(environment: environment).environment(environment.model))
            view.frame = NSRect(x: 0, y: 0, width: 680, height: 640)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width > 0)
        }
    }
    #expect(SettingsView.services(live.environment) is LiveRouterSettingsServices)
    #expect(SettingsView.services(mock) is MockRouterSettingsServices)
    // No finished router: the tab has nothing to edit.
    let empty = AppEnvironment(model: AppModel(mode: .live), backend: nil, transportFactory: { _ in CountingTransport() })
    await empty.waitUntilReady()
    #expect(SettingsView.services(empty) == nil)
}

@Test func generalTabShowsTheVersionFromInfoPlist() {
    #expect(GeneralSettingsTab.versionText(["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "4"]) == "1.2.3 (4)")
    #expect(GeneralSettingsTab.versionText(["CFBundleShortVersionString": "1.2.3"]) == "1.2.3")
    #expect(GeneralSettingsTab.versionText(nil) == "Unknown")
    #expect(GeneralSettingsTab.versionText(Bundle.main.infoDictionary) != "0.1 (1)")
}

// MARK: Alerts

@Test func alertsUseTheDesignCopy() {
    #expect(RouterSettingsAlert.startSetupAgain.title == "Start setup again?")
    #expect(RouterSettingsAlert.startSetupAgain.message(name: "Home") ==
            "This removes “Home” and all of its settings from this Mac: password, trusted certificate, SSH key and host key, and AdGuard config. Nothing on the router changes.")
    #expect(RouterSettingsAlert.startSetupAgain.action == "Remove and Start Setup")
    #expect(RouterSettingsAlert.forgetCertificate.title == "Forget the trusted certificate?")
    #expect(RouterSettingsAlert.forgetCertificate.message(name: "") ==
            "Routewell will stop connecting until you confirm the router’s certificate again. You’ll be asked the next time it connects.")
    #expect(RouterSettingsAlert.forgetCertificate.action == "Forget Certificate")
    #expect(RouterSettingsAlert.forgetHostKey.title == "Forget the SSH host key?")
    #expect(RouterSettingsAlert.forgetHostKey.message(name: "") ==
            "SSH features stop until you confirm the router’s SSH fingerprint again. You’ll be asked the next time Routewell connects over SSH.")
    #expect(RouterSettingsAlert.forgetHostKey.action == "Forget Host Key")
}

@MainActor @Test func forgetCertificateRemovesOnlyThisPinAndReconnects() async {
    let fixture = await liveFixture()
    let environment = fixture.environment
    await environment.trust.approve(TrustedEndpoint(host: "198.51.100.1", port: 443, fingerprint: fingerprint, approvedAt: .now))
    #expect(fixture.model.certificate == fingerprint)
    #expect(fixture.model.status != .waitingForCertificate)
    let before = environment.model.session.expectedToken

    fixture.model.alert = .forgetCertificate
    await fixture.model.confirm(.forgetCertificate)
    #expect(fixture.model.alert == nil)
    #expect(fixture.model.certificate == nil)
    #expect(fixture.model.status == .waitingForCertificate)
    #expect(environment.trust.trusted.map(\.host) == ["198.51.100.1"])
    #expect(environment.model.session.expectedToken != before)
}

@MainActor @Test func forgetHostKeyRemovesTheKeyAndTurnsSSHOff() async throws {
    let fixture = await liveFixture()
    let environment = fixture.environment
    try await environment.sshSetup.hostKeys.approve(host: "192.0.2.1", port: 22, keyLine: hostKey.keyLine)
    environment.updateSSHSettings(SSHSettings(enabled: true, keyFilePath: "/nonexistent/id_example"))
    await environment.waitUntilReady()
    await fixture.model.reloadLocal()
    #expect(fixture.model.hostKey == hostKey.fingerprintSHA256)

    await fixture.model.confirm(.forgetHostKey)
    #expect(fixture.model.hostKey == nil)
    #expect(try await environment.sshSetup.hostKeys.storedKeyLine(host: "192.0.2.1", port: 22) == nil)
    #expect(environment.persistence.selectedProfile?.ssh?.enabled == false)
}

@MainActor @Test func mockAlertsChangeOnlyTheMockState() async {
    let (environment, services, model) = await mockFixture()
    await model.confirm(.forgetCertificate)
    #expect(model.certificate == nil)
    #expect(model.status == .waitingForCertificate)
    await model.confirm(.forgetHostKey)
    #expect(model.hostKey == nil)
    #expect(!model.sshOn)
    await model.confirm(.startSetupAgain)
    #expect(environment.onboarding.run != nil)
    #expect(environment.persistence.profiles.profiles.count == AppEnvironment.mockProfiles.count)
    #expect(services.calls == ["forgetCertificate", "forgetHostKey", "startSetupAgain"])
}

// MARK: Start Setup Again

@MainActor @Test func startSetupAgainRemovesEveryItemForThisRouterAndNothingElse() async throws {
    let fixture = await liveFixture()
    let environment = fixture.environment
    let credentials = fixture.credentials
    let keep = try RouterEndpoint.parse("198.51.100.1")
    // Another router's items, which must stay.
    let other = RouterProfile(name: "Other", liveEndpoint: keep, adGuard: AdGuardSettings())
    try await credentials.save(Data("other".utf8), for: other.credential)
    environment.persistence.updateSSHSettings(SSHSettings(enabled: false, keyFilePath: "/nonexistent/id_example", keyFileBookmark: Data([1, 2, 3])))
    let profile = try #require(environment.persistence.selectedProfile)
    let adGuardReference = CredentialReference(profileID: profile.id, endpoint: profile.endpoint, kind: .adGuardPassword)
    _ = await environment.saveAdGuardPassword(Data("adguard".utf8))
    try await environment.sshSetup.hostKeys.approve(host: "192.0.2.1", port: 22, keyLine: hostKey.keyLine)
    try await environment.sshSetup.hostKeys.approve(host: "198.51.100.1", port: 22, keyLine: otherHostKey.keyLine)
    await environment.trust.approve(TrustedEndpoint(host: "198.51.100.1", port: 443, fingerprint: fingerprint, approvedAt: .now))
    #expect(await environment.persistence.addLiveProfile(other, password: Data("other".utf8)))
    environment.persistence.select(profile.id)
    let otherIDs = environment.persistence.profiles.profiles.map(\.id).filter { $0 != profile.id }

    await fixture.model.confirm(.startSetupAgain)

    // This router: profile (with its key bookmark), both Keychain items, pin, host key.
    #expect(!environment.persistence.profiles.profiles.contains { $0.id == profile.id })
    await #expect(throws: (any Error).self) { try await credentials.read(profile.credential) }
    await #expect(throws: (any Error).self) { try await credentials.read(adGuardReference) }
    #expect(!environment.trust.trusted.contains { $0.host == "192.0.2.1" })
    #expect(try await environment.sshSetup.hostKeys.storedKeyLine(host: "192.0.2.1", port: 22) == nil)
    // The other router keeps everything.
    #expect(environment.persistence.profiles.profiles.map(\.id) == otherIDs)
    #expect(otherIDs.contains(other.id))
    #expect(try await credentials.read(other.credential) == Data("other".utf8))
    #expect(environment.trust.trusted.map(\.host) == ["198.51.100.1"])
    #expect(try await environment.sshSetup.hostKeys.storedKeyLine(host: "198.51.100.1", port: 22) == otherHostKey.keyLine)
    // Onboarding starts, and nothing went to the router.
    #expect(environment.onboarding.run?.state == .welcome)
    #expect(await fixture.processes.launches == 0)
}

// MARK: Router group

@MainActor @Test func renameDoesNotReconnectAndTheSidebarUsesIt() async {
    let fixture = await liveFixture()
    let environment = fixture.environment
    let token = environment.model.session.expectedToken
    fixture.model.nameDraft = "  Home router  "
    fixture.model.commitName()
    #expect(environment.persistence.selectedProfile?.name == "Home router")
    #expect(fixture.model.nameDraft == "Home router")
    #expect(environment.model.session.expectedToken == token)
    // An empty name puts the old one back.
    fixture.model.nameDraft = "   "
    fixture.model.commitName()
    #expect(fixture.model.nameDraft == "Home router")
    #expect(environment.persistence.selectedProfile?.name == "Home router")
}

@MainActor @Test func addressIsCheckedAndMovesBothKeychainItems() async throws {
    let fixture = await liveFixture()
    let environment = fixture.environment
    let model = fixture.model
    _ = await environment.saveAdGuardPassword(Data("adguard".utf8))
    let old = try #require(environment.persistence.selectedProfile)

    model.addressDraft = "http://192.0.2.1"
    await model.commitAddress()
    #expect(model.addressMessage == "Routewell connects over HTTPS. Remove http:// from the address.")
    model.addressDraft = "192.0.2.1/admin"
    await model.commitAddress()
    #expect(model.addressMessage == "Remove the path from the address.")
    #expect(environment.persistence.selectedProfile?.liveEndpoint == old.liveEndpoint)

    // The same address changes nothing and keeps the password.
    model.addressDraft = "https://192.0.2.1"
    await model.commitAddress()
    #expect(model.addressMessage == nil)
    #expect(model.addressDraft == "192.0.2.1")
    #expect(try await fixture.credentials.read(old.credential) == Data("secret".utf8))

    let token = environment.model.session.expectedToken
    model.addressDraft = "192.0.2.2:8443"
    await model.commitAddress()
    #expect(model.addressMessage == nil)
    let moved = try #require(environment.persistence.selectedProfile)
    #expect(moved.liveEndpoint == (try RouterEndpoint.parse("192.0.2.2:8443")))
    #expect(model.addressDraft == "192.0.2.2:8443")
    #expect(try await fixture.credentials.read(moved.credential) == Data("secret".utf8))
    let movedAdGuard = CredentialReference(profileID: moved.id, endpoint: moved.endpoint, kind: .adGuardPassword)
    #expect(try await fixture.credentials.read(movedAdGuard) == Data("adguard".utf8))
    await #expect(throws: (any Error).self) { try await fixture.credentials.read(old.credential) }
    #expect(environment.model.session.expectedToken != token)
}

@MainActor @Test func passwordChangeCancelAndSave() async throws {
    let fixture = await liveFixture()
    let model = fixture.model
    #expect(!model.editingPassword)
    model.beginPasswordChange()
    #expect(model.editingPassword)
    model.newPassword = "typed"
    model.cancelPasswordChange()
    #expect(!model.editingPassword)
    #expect(model.newPassword.isEmpty)
    let profile = try #require(fixture.environment.persistence.selectedProfile)
    #expect(try await fixture.credentials.read(profile.credential) == Data("secret".utf8))

    model.beginPasswordChange()
    model.newPassword = "changed"
    await model.savePassword()
    #expect(!model.editingPassword)
    #expect(model.newPassword.isEmpty)
    #expect(model.passwordMessage == nil)
    #expect(try await fixture.credentials.read(profile.credential) == Data("changed".utf8))
}

// MARK: SSH group

@MainActor @Test func turningSSHOnOpensTheStepsAndSkipLeavesItOff() async throws {
    let fixture = await liveFixture()
    let environment = fixture.environment
    let model = fixture.model
    #expect(!model.sshOn)

    model.setSSH(true)
    let sheet = try #require(model.sshSheet)
    #expect(sheet.state == .sshKey)
    #expect(!model.sshOn)
    sheet.tertiary()
    await sheet.settle()
    #expect(model.sshSheet == nil)
    #expect(!model.sshOn)
    #expect(environment.persistence.selectedProfile?.ssh?.enabled != true)

    // Closing the sheet part way also leaves SSH off.
    model.setSSH(true)
    let closed = try #require(model.sshSheet)
    model.sshSheetClosed()
    await closed.settle()
    #expect(model.sshSheet == nil)
    #expect(!model.sshOn)
    #expect(await fixture.processes.launches == 0)
}

@MainActor @Test func aNewSSHPortTurnsSSHOffAndAsksForTheHostKeyAgain() async throws {
    let (environment, services, model) = await mockFixture()
    #expect(model.sshOn)
    model.portDraft = "70000"
    model.commitPort()
    #expect(model.sshMessage == "Port must be a number between 1 and 65535.")
    #expect(model.sshSheet == nil)

    model.portDraft = "2222"
    model.commitPort()
    #expect(services.ssh.port == 2222)
    #expect(!model.sshOn)
    let sheet = try #require(model.sshSheet)
    #expect(sheet.state == .sshChosen)
    sheet.primary()
    await sheet.settle()
    sheet.primary()
    await sheet.settle()
    #expect(model.sshSheet == nil)
    #expect(model.sshOn)
    #expect(environment.mockSSHScenario == .populated)
}

@MainActor @Test func aKeyFileIsCheckedBeforeItIsSaved() async {
    let (_, services, model) = await mockFixture()
    model.chooseKeyFile()
    #expect(model.sshMessage == nil)
    #expect(services.calls.last == "useKey")
    #expect(SSHKeyInspection.passphraseProtected.problem?.contains("passphrase") == true)
}

// MARK: AdGuard config

@MainActor @Test func adGuardConfigIsCollapsedAndShowsTheOffState() async {
    let (_, services, model) = await mockFixture()
    #expect(!model.adGuardExpanded)
    #expect(model.adGuardStatus == .active)
    #expect(!model.adGuardOff)

    services.adGuardOffOnRouter = true
    await model.load()
    #expect(model.adGuardOff)
    #expect(model.adGuardStatus == .offOnRouter)
    #expect(model.adGuardStatus.text == "AdGuard Home off on router")

    model.setAdGuardSeparateAccount(true)
    #expect(!model.adGuard.useRouterCredentials)
    model.adGuardPortDraft = "3001"
    model.commitAdGuardPort()
    model.setAdGuardHTTPS(true)
    #expect(model.adGuard == AdGuardSettings(port: 3001, useRouterCredentials: false, useHTTPS: true))
}

// MARK: Test Connection

@MainActor @Test func testConnectionRowsForEachMockScenario() async {
    let (environment, services, model) = await mockFixture()
    model.runTest()
    await model.settleTest()
    #expect(model.testRows.map(\.value) == ["12 ms", "Working", "Working"])
    #expect(model.subtitle == "GL-EXAMPLE · Firmware 4.0.0 · 192.0.2.1")

    services.adGuardOffOnRouter = true
    environment.setMockSSHScenario(.off)
    model.runTest()
    await model.settleTest()
    #expect(model.testRows.map(\.value) == ["12 ms", "Off", "Off on router"])
    #expect(model.adGuardOff)

    services.testFails = true
    model.runTest()
    await model.settleTest()
    #expect(model.testRows.map(\.value) == ["No response", "Off", "Not tested"])
    #expect(model.testRows.first?.failed == true)
    #expect(model.status == .notReachable)

    environment.setMockSSHScenario(.populated)
    model.runTest()
    await model.settleTest()
    #expect(model.testRows.map(\.value) == ["No response", "Not tested", "Not tested"])
}

@MainActor @Test func liveTestConnectionStopsAfterTheRouterFails() async {
    let fixture = await liveFixture()
    let sentBefore = await fixture.transport.sent
    fixture.model.runTest()
    await fixture.model.settleTest()
    #expect(fixture.model.testRows.map(\.value) == ["Unexpected reply", "Off", "Not tested"])
    // Only the router check's own sign-in attempt went out.
    #expect(await fixture.transport.sent - sentBefore == 1)
}

@MainActor @Test func headerStatusFollowsTrustAndReachability() async {
    let (_, services, model) = await mockFixture()
    #expect(model.status == .connected(uptime: RouterSettingsModel.uptime(1_198_800)))
    #expect(RouterSettingsModel.uptime(79_200) == "0d 22h")
    #expect(RouterSettingsModel.Status.connected(uptime: "0d 22h").text == "Connected · 0d 22h up")
    services.certificateTrusted = false
    await model.reloadLocal()
    #expect(model.status == .waitingForCertificate)
    services.hostKeyTrusted = false
    await model.reloadLocal()
    #expect(model.hostKey == nil)
}

#if DEBUG
import Foundation
import Observation
import RoutewellKit
import RoutewellMock

/// The Router tab in mock mode: the same layout with neutral values kept in
/// memory. The switches in the tab's Mock section set the scenarios.
/// Nothing touches the network, the Keychain, or the host key file.
@MainActor @Observable
final class MockRouterSettingsServices: RouterSettingsServices {
    static let model = "GL-EXAMPLE"
    static let firmware = "4.0.0"
    static let keyPath = MockOnboardingServices.keyURL.path
    static let hostKeyFingerprint = SSHHostKeyCandidate(
        keyLine: "\(MockOnboardingServices.gateway) ssh-ed25519 \(Data(repeating: 0x11, count: 32).base64EncodedString())"
    )?.fingerprintSHA256

    // Scenarios.
    var adGuardOffOnRouter = false
    var testFails = false
    var certificateTrusted = true
    var hostKeyTrusted = true
    /// The tab's Mock disclosure; kept here because a profile switch
    /// rebuilds the tab.
    var mockSectionExpanded = false
    /// Shortens every pause; tests use zero.
    var delay: Duration = .milliseconds(700)

    private let environment: AppEnvironment
    private var endpoint = try! RouterEndpoint.parse(MockOnboardingServices.gateway)
    private var sshPort = SSHSettings().port
    private var adGuardSettings = AdGuardSettings()
    private(set) var calls: [String] = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var name: String { environment.persistence.selectedProfile?.name ?? "router" }
    var address: String { OnboardingModel.shortAddress(endpoint) }
    var host: String { endpoint.host }
    var username: String { SSHSettings().user }

    var facts: RouterFacts {
        let router = environment.model.snapshot?.router
        return RouterFacts(model: Self.model, firmware: Self.firmware, reachability: router?.reachability ?? .unknown,
                           uptimeSeconds: router?.uptimeSeconds)
    }

    var ssh: SSHSettings {
        SSHSettings(enabled: environment.mockSSHScenario != .off, port: sshPort, keyFilePath: Self.keyPath)
    }

    var adGuard: AdGuardSettings? { adGuardSettings }

    func certificate() async -> CertificateFingerprint? { certificateTrusted ? MockOnboardingServices.fingerprint : nil }
    func hostKey() async -> String? { hostKeyTrusted ? Self.hostKeyFingerprint : nil }
    func adGuardHomeEnabled() async -> Observed<Bool> { .value(!adGuardOffOnRouter) }

    func rename(_ name: String) {
        calls.append("rename")
        environment.renameRouter(name)
    }

    func setAddress(_ endpoint: RouterEndpoint) async -> Bool {
        calls.append("setAddress")
        self.endpoint = endpoint
        return true
    }

    func changePassword(_ password: Data) async -> Bool {
        calls.append("changePassword")
        return true
    }

    func forgetCertificate() async {
        calls.append("forgetCertificate")
        certificateTrusted = false
    }

    func forgetHostKey() async {
        calls.append("forgetHostKey")
        hostKeyTrusted = false
        environment.setMockSSHScenario(.off)
    }

    func sshSteps() -> any OnboardingServices { MockOnboardingServices(scenario: .found, delay: delay) }

    func sshStepsEnded(connected: Bool) {
        calls.append("sshStepsEnded(\(connected))")
        guard connected else { return }
        hostKeyTrusted = true
        environment.setMockSSHScenario(.populated)
    }

    func turnSSHOff() {
        calls.append("turnSSHOff")
        environment.setMockSSHScenario(.off)
    }

    func chooseKeyFile() -> ChosenSSHKey? { MockOnboardingServices(scenario: .found).chooseKeyFile() }

    func savedKey() -> ChosenSSHKey? {
        ChosenSSHKey(url: MockOnboardingServices.keyURL, bookmark: nil, inspection: .usable(kind: "ED25519"))
    }

    func useKey(_ key: ChosenSSHKey) { calls.append("useKey") }

    func setSSHPortOff(_ port: Int) {
        calls.append("setSSHPortOff(\(port))")
        sshPort = port
        environment.setMockSSHScenario(.off)
    }

    func updateAdGuard(_ settings: AdGuardSettings) {
        calls.append("updateAdGuard")
        adGuardSettings = settings
    }

    func saveAdGuardPassword(_ password: Data) async -> Bool {
        calls.append("saveAdGuardPassword")
        return true
    }

    func connectionTest(trustPrompt: TrustPromptController, onProbe: @escaping @MainActor (RouterProbe) -> Void) -> ConnectionTest? {
        let fails = testFails, adGuardOn = !adGuardOffOnRouter, delay = delay
        let probe = RouterProbe(model: Self.model, firmware: Self.firmware, hostname: nil)
        return ConnectionTest(
            router: {
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !fails else { return .failed(.noResponse) }
                await onProbe(probe)
                return .responded(milliseconds: 12)
            },
            sshEnabled: ssh.enabled,
            ssh: {
                if delay > .zero { try? await Task.sleep(for: delay / 2) }
                return SSHProbeResult(capability: Capability(.supported, evidence: .successfulResponse, observedAt: .now))
            },
            adGuardConfigured: true,
            adGuardEnabled: { .value(adGuardOn) },
            adGuardStatus: {
                if delay > .zero { try? await Task.sleep(for: delay) }
                return nil
            }
        )
    }

    func startSetupAgain() async {
        calls.append("startSetupAgain")
        await environment.startSetupAgain()
    }
}
#endif

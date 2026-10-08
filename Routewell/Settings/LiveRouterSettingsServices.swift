import AppKit
import Foundation
import RoutewellKit

/// The Router tab for the saved live router. Every change goes through
/// `AppEnvironment`, which rebuilds the session where a change needs it.
@MainActor
final class LiveRouterSettingsServices: RouterSettingsServices {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var profile: RouterProfile? { environment.persistence.selectedProfile }
    private var endpoint: RouterEndpoint? { profile?.liveEndpoint }

    var name: String { profile?.name ?? "" }
    var address: String { endpoint.map(OnboardingModel.shortAddress) ?? "" }
    var host: String { endpoint?.host ?? "" }
    var username: String { profile?.username ?? SSHSettings().user }
    var ssh: SSHSettings { profile?.ssh ?? SSHSettings() }
    var adGuard: AdGuardSettings? { profile?.adGuard }

    var facts: RouterFacts {
        let model = environment.model
        let router = model.snapshot?.router
        var reachability = router?.reachability ?? .unknown
        if router == nil, model.session.setupFailed || model.refreshFailed { reachability = .unreachable }
        return RouterFacts(model: router?.model, firmware: router?.firmware, reachability: reachability, uptimeSeconds: router?.uptimeSeconds)
    }

    func certificate() async -> CertificateFingerprint? {
        guard let endpoint else { return nil }
        // A prompt answered in the main window approves through the store.
        await environment.trust.reload()
        return environment.trust.trusted.first { $0.host == endpoint.host && $0.port == endpoint.port }?.fingerprint
    }

    func hostKey() async -> String? {
        guard let endpoint else { return nil }
        await environment.sshSetup.loadTrustedFingerprint(host: endpoint.host, port: ssh.port)
        return environment.sshSetup.trustedFingerprint
    }

    func adGuardHomeEnabled() async -> Observed<Bool> {
        await environment.waitUntilReady()
        return await environment.adGuardHomeEnabled()
    }

    func rename(_ name: String) { environment.renameRouter(name) }

    func setAddress(_ endpoint: RouterEndpoint) async -> Bool { await environment.updateLiveAddress(endpoint) }

    func changePassword(_ password: Data) async -> Bool { await environment.changeLivePassword(password) }

    func forgetCertificate() async { await environment.forgetCertificate() }

    func forgetHostKey() async {
        guard let endpoint else { return }
        await environment.sshSetup.forgetHostKey(ssh, host: endpoint.host)
    }

    func sshSteps() -> any OnboardingServices { LiveOnboardingServices(environment: environment) }

    /// The steps saved SSH on, or put it back as it was.
    func sshStepsEnded(connected: Bool) {}

    func turnSSHOff() { environment.sshSetup.disable(ssh) }

    func chooseKeyFile() -> ChosenSSHKey? { LiveOnboardingServices(environment: environment).chooseKeyFile() }

    func savedKey() -> ChosenSSHKey? {
        guard let path = ssh.keyFilePath else { return nil }
        let url = URL(fileURLWithPath: path)
        return ChosenSSHKey(url: url, bookmark: ssh.keyFileBookmark, inspection: SSHKeyInspector.inspect(fileAt: url))
    }

    /// Keeps SSH on or off as it is; the session is rebuilt, so the probe
    /// runs again with the new key.
    func useKey(_ key: ChosenSSHKey) {
        var settings = ssh
        settings.keyFilePath = key.url.path
        settings.keyFileBookmark = key.bookmark
        settings.useAgent = false
        environment.updateSSHSettings(settings)
    }

    func setSSHPortOff(_ port: Int) {
        var settings = ssh
        settings.port = port
        settings.enabled = false
        environment.updateSSHSettings(settings)
    }

    func updateAdGuard(_ settings: AdGuardSettings) { environment.updateAdGuardSettings(settings) }

    func saveAdGuardPassword(_ password: Data) async -> Bool { await environment.saveAdGuardPassword(password) }

    func connectionTest(trustPrompt: TrustPromptController, onProbe: @escaping @MainActor (RouterProbe) -> Void) -> ConnectionTest? {
        environment.connectionTest(trustPromptController: trustPrompt, onProbe: onProbe)
    }

    func startSetupAgain() async { await environment.startSetupAgain() }
}

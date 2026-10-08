import AppKit
import Foundation
import RoutewellKit

/// Onboarding against the real router. Discovery sends only an
/// unauthenticated `challenge`; the password is sent only after the person
/// trusted the certificate, and only to that pinned certificate.
@MainActor
final class LiveOnboardingServices: OnboardingServices {
    private let environment: AppEnvironment
    private let discovery: RouterDiscovery
    private let scanner: any SSHHostKeyScanning
    /// What this run saved, so closing the window can remove it.
    private var trusted: (host: String, port: Int)?
    private var profileID: UUID?
    private var storedHostKey: String?
    /// Longest wait for the session's first SSH probe.
    var probeTimeout: Duration = .seconds(45)

    init(environment: AppEnvironment,
         discovery: RouterDiscovery = RouterDiscovery(prober: LiveRouterChallengeProbe(), gateway: SystemGatewayLocator(),
                                                      resolver: SystemHostResolver(), localNetwork: SystemLocalNetworkCheck()),
         scanner: any SSHHostKeyScanning = LiveSSHHostKeyScanner()) {
        self.environment = environment
        self.discovery = discovery
        self.scanner = scanner
    }

    func discover(onFallback: @escaping @MainActor @Sendable () -> Void) async -> DiscoveryResult {
        await discovery.run { await onFallback() }
    }

    func probe(manual endpoint: RouterEndpoint) async -> ManualProbeResult {
        await discovery.probe(manual: endpoint)
    }

    func trust(_ router: DiscoveredRouter) async -> Bool {
        guard let fingerprint = router.fingerprint else { return false }
        let host = router.endpoint.host, port = router.endpoint.port
        await environment.trust.approve(TrustedEndpoint(host: host, port: port, fingerprint: fingerprint, approvedAt: .now))
        guard await environment.trust.store.trusted(host: host, port: port)?.fingerprint == fingerprint else { return false }
        trusted = (host, port)
        return true
    }

    func signIn(to router: DiscoveredRouter, name: String, password: String) async -> OnboardingSignIn {
        let probe: RouterProbe
        do {
            probe = try await environment.onboardingSignIn(endpoint: router.endpoint, password: password)
        } catch GLiNetRPCError.accessDenied {
            return .wrongPassword
        } catch GLiNetRPCError.loginPaused {
            return .paused
        } catch GLiNetRPCError.transport(.untrustedServer(let decision)) {
            switch decision {
            case .untrustedNew(let fingerprint), .untrustedChanged(_, let fingerprint): return .certificateChanged(fingerprint)
            case .trusted: return .unreachable
            }
        } catch GLiNetRPCError.transport(let error) {
            if case .tlsFailure = error { return .failed("The secure connection to the router failed. Try again.") }
            return .unreachable
        } catch {
            return .failed("The router’s reply wasn’t understood. Try again.")
        }
        if let profileID { await environment.forgetRouter(profileID) }
        guard let id = await environment.saveOnboardedProfile(name: name, endpoint: router.endpoint, password: Data(password.utf8)) else {
            return .failed(environment.persistence.credentialMessage ?? "The router could not be saved. Try again.")
        }
        profileID = id
        return .signedIn(probe)
    }

    /// Routewell keeps the path and a bookmark to it, never the key.
    func chooseKeyFile() -> ChosenSSHKey? {
        let panel = NSOpenPanel()
        panel.message = "Choose the private key for SSH to the router. Routewell stores only its location."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return ChosenSSHKey(url: url, bookmark: SSHKeyFileAccess.bookmark(for: url), inspection: SSHKeyInspector.inspect(fileAt: url))
    }

    func scanHostKey(host: String) async -> Result<SSHHostKeyCandidate, SSHFailure> {
        do {
            let candidates = try await scanner.scan(host: host, port: SSHSettings().port)
            guard let preferred = SSHHostKeyTrust.preferred(candidates) else { return .failure(.connectionFailed) }
            return .success(preferred)
        } catch {
            return .failure(error)
        }
    }

    /// Onboarding starts empty, so the key the person checked replaces any
    /// key left from an earlier setup of the same address.
    func enableSSH(key: ChosenSSHKey, hostKey: SSHHostKeyCandidate, host: String) async -> SSHProbeResult {
        let port = SSHSettings().port
        do {
            try await SSHHostKeyTrust.store(hostKey, host: host, port: port, in: environment.sshSetup.hostKeys)
        } catch {
            return SSHProbeResult(capability: Capability(), failure: .configurationFailed)
        }
        storedHostKey = host
        let settings = SSHSettings(enabled: true, port: port, keyFilePath: key.url.path, keyFileBookmark: key.bookmark)
        if environment.persistence.selectedProfile?.ssh == settings {
            environment.refresh.reprobeSSH()
        } else {
            environment.updateSSHSettings(settings)
            await environment.waitUntilReady()
        }
        return await waitForProbe()
    }

    func recheckSSH() async -> SSHProbeResult {
        environment.refresh.reprobeSSH()
        return await waitForProbe()
    }

    func disableSSH() async {
        if let host = storedHostKey {
            try? await environment.sshSetup.hostKeys.revoke(host: host, port: SSHSettings().port)
            storedHostKey = nil
        }
        if let ssh = environment.persistence.selectedProfile?.ssh, ssh != SSHSettings() {
            environment.updateSSHSettings(SSHSettings())
            await environment.waitUntilReady()
        }
    }

    func adGuardHomeEnabled() async -> Observed<Bool> {
        guard let lease = environment.model.session.lease, let reader = lease.backend as? AdGuardHomeStateReading else { return .unknown }
        let value = await reader.adGuardHomeEnabled()
        return environment.model.session.expectedToken == lease.token ? value : .unknown
    }

    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    func finish(name: String) async -> Bool {
        guard let profileID else { return false }
        return await environment.completeSetup(profileID, name: name)
    }

    func abandon() async {
        if let profileID {
            await environment.forgetRouter(profileID)
            self.profileID = nil
        } else if let trusted {
            await environment.trust.revoke(host: trusted.host, port: trusted.port)
        }
        trusted = nil
        storedHostKey = nil
    }

    /// The refresh controller probes SSH once per new session lease. This
    /// waits for that result instead of starting a second connection.
    private func waitForProbe() async -> SSHProbeResult {
        let model = environment.model
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: probeTimeout)
        while clock.now < deadline, !Task.isCancelled {
            if model.session.isReady, let probe = model.sshProbe { return probe }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return SSHProbeResult(capability: Capability(), failure: .timedOut)
    }
}

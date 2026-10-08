import Foundation
import RoutewellKit

/// A key file the person chose, with what `SSHKeyInspector` found in it.
struct ChosenSSHKey: Equatable {
    var url: URL
    /// Security-scoped bookmark, so `ssh` can read the key after a relaunch.
    var bookmark: Data?
    var inspection: SSHKeyInspection

    var name: String { url.lastPathComponent }
    /// "~/.ssh", for the key box.
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
}

enum OnboardingSignIn: Equatable {
    case signedIn(RouterProbe)
    case wrongPassword
    case paused
    case unreachable
    /// The router now presents a different certificate from the one trusted a
    /// moment ago. Nothing was sent; the person checks the new one.
    case certificateChanged(CertificateFingerprint)
    case failed(String)
}

/// Everything onboarding does outside its own state: the network, the
/// Keychain, the profile, and SSH. Live and mock implementations.
@MainActor
protocol OnboardingServices: AnyObject {
    func discover(onFallback: @escaping @MainActor @Sendable () -> Void) async -> DiscoveryResult
    func probe(manual endpoint: RouterEndpoint) async -> ManualProbeResult
    /// Pins the router's certificate. Nothing secret is sent before this.
    func trust(_ router: DiscoveredRouter) async -> Bool
    /// Signs in as `root`. On success the profile (name, address, Keychain
    /// password) is saved, still marked unfinished, and its session starts.
    func signIn(to router: DiscoveredRouter, name: String, password: String) async -> OnboardingSignIn
    func chooseKeyFile() -> ChosenSSHKey?
    func scanHostKey(host: String) async -> Result<SSHHostKeyCandidate, SSHFailure>
    /// Trusts the host key, switches SSH on for the profile, and returns the
    /// session's first SSH probe.
    func enableSSH(key: ChosenSSHKey, hostKey: SSHHostKeyCandidate, host: String) async -> SSHProbeResult
    func recheckSSH() async -> SSHProbeResult
    /// Leaves SSH off and removes anything this run set up for it.
    func disableSSH() async
    func adGuardHomeEnabled() async -> Observed<Bool>
    func openLocalNetworkSettings()
    /// Marks the profile finished. False when it could not be saved.
    func finish(name: String) async -> Bool
    /// Closed before Finish: removes what this run saved.
    func abandon() async
}

extension SSHProbeResult {
    /// How the SSH check step reads a probe result.
    enum Verdict: Equatable { case connected, rejected, unreachable }

    var verdict: Verdict {
        if capability.state == .supported { return .connected }
        switch failure {
        case .authenticationFailed?, .configurationFailed?, .hostKeyChanged?, .hostKeyNotTrusted?: return .rejected
        default: return .unreachable
        }
    }
}

#if DEBUG
import CryptoKit
import Foundation
import RoutewellKit

/// First-run mock mode (Debug › Show Onboarding, or `ROUTEWELL_ONBOARDING=<scenario>`
/// with the mock backend). Each scenario fails once at its step, then the
/// retry succeeds, so every state can be reached with the buttons.
enum MockOnboardingScenario: String, CaseIterable, Identifiable {
    case found, fallback, manual, denied, wrongPassword, paused, unreachable
    case passphraseKey, keyRejected, sshNotReachable, adGuardOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .found: "Router found"
        case .fallback: "Found at 192.168.8.1"
        case .manual: "Not found, enter address"
        case .denied: "Local Network denied"
        case .wrongPassword: "Wrong password"
        case .paused: "Sign-in paused"
        case .unreachable: "Router not reachable"
        case .passphraseKey: "Key with a passphrase"
        case .keyRejected: "Key rejected"
        case .sshNotReachable: "SSH not reachable"
        case .adGuardOff: "AdGuard Home off"
        }
    }
}

/// Synthetic values only: documentation addresses, generated fingerprints,
/// and example names. Nothing is saved and nothing touches the network.
@MainActor
final class MockOnboardingServices: OnboardingServices {
    nonisolated static let gateway = "192.0.2.1"
    nonisolated static let keyURL = URL(fileURLWithPath: "/Users/example/.ssh/id_example")
    nonisolated static let fingerprint = try! CertificateFingerprint(sha256: Data(SHA256.hash(data: Data("routewell-mock-certificate".utf8))))
    nonisolated static let probe = RouterProbe(model: "GL-EXAMPLE", firmware: "4.0.0", hostname: "example-router")

    let scenario: MockOnboardingScenario
    /// Shortens every pause; tests use zero.
    let delay: Duration
    private var signIns = 0
    private var keyChoices = 0
    private var probes = 0
    private var denials = 0
    private(set) var calls: [String] = []

    init(scenario: MockOnboardingScenario, delay: Duration = .milliseconds(900)) {
        self.scenario = scenario
        self.delay = delay
    }

    func discover(onFallback: @escaping @MainActor @Sendable () -> Void) async -> DiscoveryResult {
        calls.append("discover")
        let prober = MockProber(scenario: scenario, delay: delay)
        let denied = scenario == .denied && denials == 0
        if denied { denials += 1 }
        let slack = Duration.milliseconds(300)
        let timing = RouterDiscovery.Timing(attempt: delay + slack, firstRow: delay * 2 + slack, total: delay * 4 + slack * 2,
                                            retryPause: delay / 4, gatewayGrace: delay)
        let discovery = RouterDiscovery(prober: prober, gateway: MockGateway(), resolver: MockResolver(),
                                        localNetwork: MockLocalNetwork(denied: denied), timing: timing)
        return await discovery.run { await onFallback() }
    }

    func probe(manual endpoint: RouterEndpoint) async -> ManualProbeResult {
        calls.append("probe")
        await pause()
        return .found(DiscoveredRouter(endpoint: endpoint, source: .manual, fingerprint: Self.fingerprint))
    }

    func trust(_ router: DiscoveredRouter) async -> Bool {
        calls.append("trust")
        return true
    }

    func signIn(to router: DiscoveredRouter, name: String, password: String) async -> OnboardingSignIn {
        calls.append("signIn")
        await pause()
        signIns += 1
        guard signIns == 1 else { return .signedIn(Self.probe) }
        switch scenario {
        case .wrongPassword: return .wrongPassword
        case .paused: return .paused
        case .unreachable: return .unreachable
        default: return .signedIn(Self.probe)
        }
    }

    func chooseKeyFile() -> ChosenSSHKey? {
        calls.append("chooseKey")
        keyChoices += 1
        if scenario == .passphraseKey, keyChoices == 1 {
            return ChosenSSHKey(url: Self.keyURL.appendingPathExtension("protected"), bookmark: nil, inspection: .passphraseProtected)
        }
        return ChosenSSHKey(url: Self.keyURL, bookmark: nil, inspection: .usable(kind: "ED25519"))
    }

    var sshPort: Int { 22 }

    func scanHostKey(host: String) async -> Result<SSHHostKeyCandidate, SSHFailure> {
        calls.append("scanHostKey")
        await pause()
        let blob = Data(repeating: 0x11, count: 32).base64EncodedString()
        return SSHHostKeyCandidate(keyLine: "\(host) ssh-ed25519 \(blob)").map { .success($0) } ?? .failure(.other("mock"))
    }

    func enableSSH(key: ChosenSSHKey, hostKey: SSHHostKeyCandidate, host: String) async -> SSHProbeResult {
        calls.append("enableSSH")
        return await probeResult()
    }

    func recheckSSH() async -> SSHProbeResult {
        calls.append("recheckSSH")
        return await probeResult()
    }

    func disableSSH() async { calls.append("disableSSH") }

    func adGuardHomeEnabled() async -> Observed<Bool> {
        .value(scenario != .adGuardOff)
    }

    func openLocalNetworkSettings() {
        calls.append("openSettings")
        denials = 1
    }

    /// False makes Finish fail, as when the profile file cannot be written.
    var finishSaves = true

    func finish(name: String) async -> Bool {
        calls.append("finish")
        return finishSaves
    }

    func abandon() async { calls.append("abandon") }

    private func probeResult() async -> SSHProbeResult {
        await pause()
        probes += 1
        if probes == 1 {
            switch scenario {
            case .keyRejected: return SSHProbeResult(capability: Capability(.unsupported, evidence: .sshProbeFailed("mock"), observedAt: .now),
                                                     failure: .authenticationFailed)
            case .sshNotReachable: return SSHProbeResult(capability: Capability(.unsupported, evidence: .sshProbeFailed("mock"), observedAt: .now),
                                                         failure: .connectionFailed)
            default: break
            }
        }
        return SSHProbeResult(capability: Capability(.supported, evidence: .successfulResponse, observedAt: .now),
                              board: SystemBoard(model: Self.probe.model, hostname: Self.probe.hostname))
    }

    private func pause() async {
        if delay > .zero { try? await Task.sleep(for: delay) }
    }
}

private struct MockProber: RouterChallengeProbing {
    let scenario: MockOnboardingScenario
    let delay: Duration

    func probe(_ endpoint: RouterEndpoint) async -> ChallengeProbeOutcome {
        if delay > .zero { try? await Task.sleep(for: delay) }
        switch scenario {
        case .manual, .denied: return .noAnswer
        case .fallback:
            return endpoint.host == RouterDiscovery.fallbackHost ? .glinet(fingerprint: MockOnboardingServices.fingerprint) : .notGLiNet
        default:
            return endpoint.host == MockOnboardingServices.gateway ? .glinet(fingerprint: MockOnboardingServices.fingerprint) : .notGLiNet
        }
    }
}

private struct MockGateway: GatewayLocating {
    func gatewayAddress() async -> String? { MockOnboardingServices.gateway }
}

private struct MockResolver: HostResolving {
    func ipv4Addresses(for host: String) async -> [String] { [] }
}

private struct MockLocalNetwork: LocalNetworkAccessChecking {
    let denied: Bool
    func isDenied(host: String) async -> Bool { denied }
}
#endif

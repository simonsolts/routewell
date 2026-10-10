import Foundation
import RoutewellKit

extension AppEnvironment {
    /// Sign-in for onboarding: a throwaway client checks the password with the
    /// certificate the person just trusted. A changed certificate is never
    /// prompted for here; it comes back as `untrustedServer`.
    func onboardingSignIn(endpoint: RouterEndpoint, password: String) async throws -> RouterProbe {
        let transport = transportFactory(trust.store)
        let rpc = GLiNetRPCClient(endpoint: endpoint, username: SSHSettings().user, password: { password },
                                  transport: transport, log: logging.eventLog)
        let backend = LiveRouterBackend(configuration: LiveBackendConfiguration(routerEndpoint: endpoint), rpc: rpc, adGuard: nil,
                                        trustStore: trust.store, trustPrompt: RefusingTrustPrompt(), log: logging.eventLog)
        return try await backend.probe()
    }

    /// Saves the signed-in router, still unfinished, and starts its session,
    /// so the SSH steps can probe through it. `needsSetup` stays true.
    func saveOnboardedProfile(name: String, endpoint: RouterEndpoint, password: Data) async -> UUID? {
        let profile = RouterProfile(name: name, liveEndpoint: endpoint, username: SSHSettings().user,
                                    adGuard: AdGuardSettings(), setupComplete: false)
        guard await persistence.addLiveProfile(profile, password: password) else { return nil }
        reconnectLiveSession()
        await waitUntilReady()
        return profile.id
    }

    /// Onboarding's Finish: the profile is complete, so the main window opens.
    func completeSetup(_ id: UUID, name: String) async -> Bool {
        guard await persistence.completeSetup(id, name: name) else { return false }
        updateNeedsSetup()
        return true
    }

    /// The launch guess: onboarding unless the saved, selected profile is a
    /// finished live router. Reads the file without loading the store.
    static func peekNeedsSetup(in directory: URL) -> Bool {
        guard let saved = AtomicJSONStore.peek(ProfileSettings.self, from: .profiles, in: directory) else { return true }
        let selected = saved.profiles.first { $0.id == saved.selectedID } ?? saved.profiles.first
        return !(selected?.liveEndpoint != nil && selected?.setupComplete == true)
    }
}

/// Never prompts. Onboarding shows the fingerprint on its own step first.
private struct RefusingTrustPrompt: TrustPromptHandler {
    func requestTrust(host: String, port: Int, decision: TrustDecision) async -> Bool { false }
}

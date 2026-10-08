import Foundation
import Observation
import RoutewellKit

/// Settings › Router › SSH: switching SSH on scans the router's host key,
/// asks the person to trust a new one, and saves the settings. A changed
/// key is always refused for this attempt; "Replace Trusted Key" stores the
/// new key and leaves SSH off, so the next switch-on connects with it.
/// Nothing here ever asks for or stores a password.
@MainActor @Observable
final class SSHSetupController {
    enum Prompt: Equatable {
        case newKey(host: String, port: Int, candidate: SSHHostKeyCandidate)
        case changedKey(host: String, port: Int, trustedFingerprint: String, candidate: SSHHostKeyCandidate)
        /// DEBUG preview in mock mode: nothing is scanned or stored.
        case preview(Prompt.Kind)

        enum Kind: Equatable { case new, changed }
    }

    private(set) var prompt: Prompt?
    private(set) var busy = false
    private(set) var message: String?
    /// The trusted key's fingerprint for the profile's host and port.
    private(set) var trustedFingerprint: String?
    let hostKeys: SSHHostKeyStore
    /// False in the App Sandbox, which blocks the agent's socket.
    let agentAllowed: Bool
    /// Also used by onboarding's SSH steps in the Settings sheet.
    let scanner: any SSHHostKeyScanning
    private let agentSocket: @MainActor () -> URL?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// Persists the settings and rebuilds the live session.
    var save: @MainActor (SSHSettings) -> Void = { _ in }

    init(hostKeys: SSHHostKeyStore, scanner: any SSHHostKeyScanning,
         agentSocket: @escaping @MainActor () -> URL? = { SSHAgentLocator.socket() },
         agentAllowed: Bool = !AppSandbox.isActive) {
        self.hostKeys = hostKeys
        self.agentAllowed = agentAllowed
        self.scanner = scanner
        self.agentSocket = agentSocket
    }

    var agentAvailable: Bool { agentSocket() != nil }

    /// Why these settings cannot be switched on, or `nil`.
    func problem(with settings: SSHSettings, host: String) -> String? {
        if (try? SSHTarget(host: host, port: settings.port, user: settings.user)) == nil {
            return "Enter a user name in lower case (for example root) and a port from 1 to 65535."
        }
        if settings.useAgent {
            guard agentAllowed else { return "The SSH agent is not available in this version of Routewell. Choose a key file." }
            return agentAvailable ? nil : "No SSH agent was found. Start one, or choose a key file."
        }
        guard let path = settings.keyFilePath, path.hasPrefix("/") else { return "Choose a private key file." }
        return FileManager.default.isReadableFile(atPath: path) ? nil : "The key file cannot be read. Choose it again."
    }

    func loadTrustedFingerprint(host: String, port: Int) async {
        let line = try? await hostKeys.storedKeyLine(host: host, port: port)
        trustedFingerprint = line.flatMap(SSHHostKeyCandidate.init(keyLine:))?.fingerprintSHA256
    }

    /// Switch on: check the settings, scan the host key, ask when it is new,
    /// then save. SSH stays off after any refusal or failure.
    func enable(_ draft: SSHSettings, host: String) async {
        guard !busy else { return }
        var settings = draft
        settings.enabled = false
        if let problem = problem(with: settings, host: host) {
            message = problem
            save(settings)
            return
        }
        busy = true
        defer { busy = false }
        message = "Checking the router's SSH host key…"
        let candidates: [SSHHostKeyCandidate]
        do {
            candidates = try await scanner.scan(host: host, port: settings.port)
        } catch {
            message = "SSH stays off. \(error.message)"
            save(settings)
            return
        }
        let stored = try? await hostKeys.storedKeyLine(host: host, port: settings.port)
        guard let evaluation = SSHHostKeyTrust.evaluate(candidates, trustedKeyLine: stored) else {
            message = "SSH stays off. The router sent no host key Routewell can read."
            save(settings)
            return
        }
        switch evaluation {
        case .matches:
            settings.enabled = true
            message = "SSH is on. Routewell checks the connection once now."
        case .new(let candidate):
            let approved = await ask(.newKey(host: host, port: settings.port, candidate: candidate))
            if SSHHostKeyTrust.decide(evaluation, approved: approved) == .trusted, await store(candidate, host: host, port: settings.port) {
                settings.enabled = true
                message = "SSH is on. Routewell checks the connection once now."
            } else if approved {
                message = "SSH stays off. The host key could not be saved."
            } else {
                message = "SSH stays off. The host key was not trusted."
            }
        case .changed(let trusted, let candidate):
            let replace = await ask(.changedKey(host: host, port: settings.port, trustedFingerprint: trusted, candidate: candidate))
            // Always refused for this attempt, whatever the answer.
            _ = SSHHostKeyTrust.decide(evaluation, approved: replace)
            if replace, await store(candidate, host: host, port: settings.port) {
                message = "The new host key is trusted. Switch SSH on to connect with it."
            } else {
                message = "SSH stays off. The router's SSH host key changed."
            }
        }
        await loadTrustedFingerprint(host: host, port: settings.port)
        save(settings)
    }

    func disable(_ draft: SSHSettings) {
        var settings = draft
        settings.enabled = false
        message = nil
        save(settings)
    }

    /// Removes the trusted key and switches SSH off.
    func forgetHostKey(_ draft: SSHSettings, host: String) async {
        try? await hostKeys.revoke(host: host, port: draft.port)
        await loadTrustedFingerprint(host: host, port: draft.port)
        disable(draft)
        message = "The host key was removed. Switching SSH on asks again."
    }

    func resolve(_ approved: Bool) {
        let preview = { if case .preview? = self.prompt { true } else { false } }()
        prompt = nil
        continuation?.resume(returning: approved)
        continuation = nil
        if preview { message = "Mock preview only: nothing was scanned or stored." }
    }

    #if DEBUG
    func preview(_ kind: Prompt.Kind) { prompt = .preview(kind) }
    #endif

    private func ask(_ request: Prompt) async -> Bool {
        resolve(false)
        prompt = request
        return await withCheckedContinuation { continuation = $0 }
    }

    private func store(_ candidate: SSHHostKeyCandidate, host: String, port: Int) async -> Bool {
        do {
            try await SSHHostKeyTrust.store(candidate, host: host, port: port, in: hostKeys)
            return true
        } catch {
            return false
        }
    }
}

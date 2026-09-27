import AppKit
import SwiftUI
import RoutewellKit

/// Settings › Router › SSH for a live profile: switch, user, port, and a key
/// file or the SSH agent. There is no password field. Switching SSH on
/// checks the router's host key first (`SSHSetupController`).
struct SSHSettingsSection: View {
    let environment: AppEnvironment
    let profile: RouterProfile
    @Environment(AppModel.self) private var model
    @State private var user = "root"
    @State private var port = 22
    @State private var useAgent = false
    @State private var keyFilePath: String?
    @State private var keyFileBookmark: Data?
    @State private var confirmingForget = false

    private var setup: SSHSetupController { environment.sshSetup }
    private var host: String { profile.liveEndpoint?.host ?? "" }
    private var saved: SSHSettings { profile.ssh ?? SSHSettings() }
    private var draft: SSHSettings {
        SSHSettings(enabled: saved.enabled, port: port, user: user.trimmingCharacters(in: .whitespaces), keyFilePath: keyFilePath,
                    keyFileBookmark: keyFileBookmark, useAgent: useAgent)
    }

    var body: some View {
        Section {
            Toggle("Use SSH", isOn: Binding(
                get: { saved.enabled },
                set: { on in
                    if on { Task { await setup.enable(draft, host: host) } } else { setup.disable(draft) }
                }
            ))
            .disabled(setup.busy)
            TextField("User", text: $user).onSubmit { saveEdit() }
            TextField("Port", value: $port, format: .number.grouping(.never)).onSubmit { savePort() }
            if setup.agentAllowed {
                Picker("Sign in with", selection: $useAgent) {
                    Text("Key file").tag(false)
                    Text("SSH agent").tag(true)
                }
                .onChange(of: useAgent) { saveEdit() }
            }
            if useAgent {
                LabeledContent("SSH agent", value: setup.agentAvailable ? "Found" : "Not found")
            } else {
                LabeledContent("Key file") {
                    HStack {
                        Text(keyFilePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None chosen")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseKeyFile() }
                    }
                }
            }
            LabeledContent("Host key") {
                Text(setup.trustedFingerprint ?? "Not trusted").font(.caption.monospaced()).textSelection(.enabled)
            }
            if saved.enabled {
                LabeledContent("Connection") {
                    HStack {
                        Text(connectionText).foregroundStyle(.secondary)
                        Button("Check Again") { environment.refresh.reprobeSSH() }
                            .disabled(model.sshConfigured && model.sshProbe == nil)
                    }
                }
            }
            Button("Forget Host Key…") { confirmingForget = true }
                .disabled(setup.trustedFingerprint == nil || setup.busy)
            if let message = setup.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("SSH")
        } footer: {
            Text("SSH reads what the router API does not offer: Ports, Storage, Logs, the AdGuard Home process, Ping, and Wake. Keys only, never a password. "
                 + (setup.agentAllowed ? "A key with a passphrase needs the SSH agent."
                                       : "A key with a passphrase needs the SSH agent, which is not available in this version of Routewell."))
        }
        .onAppear {
            user = saved.user
            port = saved.port
            useAgent = saved.useAgent && setup.agentAllowed
            keyFilePath = saved.keyFilePath
            keyFileBookmark = saved.keyFileBookmark
            Task { await setup.loadTrustedFingerprint(host: host, port: saved.port) }
        }
        .alert("Forget the SSH host key?", isPresented: $confirmingForget) {
            Button("Forget Host Key") { Task { await setup.forgetHostKey(draft, host: host) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SSH switches off. Switching it on again shows the router's fingerprint to check.")
        }
    }

    private var connectionText: String {
        guard model.sshConfigured else { return "Not connected" }
        guard let probe = model.sshProbe else { return "Checking…" }
        return probe.capability.state == .supported ? "Working" : (probe.failure?.message ?? "Not working")
    }

    /// User and key changes keep SSH on and rebuild the session, so the
    /// probe runs once more.
    private func saveEdit() {
        guard draft != saved else { return }
        environment.updateSSHSettings(draft)
    }

    /// The trusted key belongs to one host and port, so a new port switches
    /// SSH off until the person checks its key.
    private func savePort() {
        guard draft != saved else { return }
        if saved.enabled, port != saved.port {
            setup.disable(draft)
            Task { await setup.loadTrustedFingerprint(host: host, port: port) }
        } else {
            environment.updateSSHSettings(draft)
        }
    }

    /// Routewell keeps the path and a bookmark to it, never the key; `ssh`
    /// reads the key.
    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose the private key for SSH to the router. Routewell stores only its location."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyFilePath = url.path
        keyFileBookmark = SSHKeyFileAccess.bookmark(for: url)
        saveEdit()
    }
}

/// Asks whether to trust a new SSH host key, or explains that the key
/// changed. A changed key never connects from this sheet; "Replace Trusted
/// Key" only stores the new key, and SSH stays off.
struct SSHHostKeyPromptView: View {
    let prompt: SSHSetupController.Prompt
    let onCancel: () -> Void
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch prompt {
            case .newKey(let host, let port, let candidate):
                newKey(host: host, port: port, algorithm: candidate.algorithm, fingerprint: candidate.fingerprintSHA256)
            case .changedKey(let host, let port, let trusted, let candidate):
                changedKey(host: host, port: port, trusted: trusted, algorithm: candidate.algorithm, fingerprint: candidate.fingerprintSHA256)
            case .preview(.new):
                newKey(host: "192.168.8.1", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:mockmockmockmockmockmockmockmockmockmockmoc")
            case .preview(.changed):
                changedKey(host: "192.168.8.1", port: 22, trusted: "SHA256:mockmockmockmockmockmockmockmockmockmockmoc",
                           algorithm: "ssh-ed25519", fingerprint: "SHA256:newkeynewkeynewkeynewkeynewkeynewkeynewkeyn")
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func newKey(host: String, port: Int, algorithm: String, fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trust this router's SSH host key?").font(.headline)
            Text("Routewell has not used SSH with \(host):\(port) before. Compare this fingerprint with the one the router shows before you trust it.")
                .fixedSize(horizontal: false, vertical: true)
            fingerprintRow(fingerprint, label: algorithm)
            HStack {
                Spacer()
                Button("Don't Trust", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Trust and Turn On SSH", action: onApprove).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func changedKey(host: String, port: Int, trusted: String, algorithm: String, fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The router's SSH host key changed").font(.headline)
            Text("\(host):\(port) presented a different key. This can mean the router was reset or updated, or that another device answers for it. Routewell refused the connection, and SSH stays off.")
                .fixedSize(horizontal: false, vertical: true)
            fingerprintRow(trusted, label: "Previously trusted")
            fingerprintRow(fingerprint, label: "Now presented · \(algorithm)")
            Text("Replace the trusted key only if you know why it changed. SSH stays off until you switch it on again.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Replace Trusted Key", action: onApprove)
                Button("Keep SSH Off", action: onCancel).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func fingerprintRow(_ fingerprint: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

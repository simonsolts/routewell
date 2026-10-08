import SwiftUI
import RoutewellKit

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

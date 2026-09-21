import SwiftUI
import RoutewellKit

/// A sheet asking whether to trust a certificate `URLSessionTransport`
/// could not verify automatically. Chunk 09 wires this to the live transport;
/// this chunk only builds the view and its controller.
struct TrustPromptView: View {
    let request: TrustPromptRequest
    let onCancel: () -> Void
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(request.host):\(request.port)").font(.headline)
            switch request.decision {
            case .untrustedNew(let fingerprint):
                Text("Routewell cannot verify this router's certificate. Compare this fingerprint with the one on the router before you trust it.")
                fingerprintRow(fingerprint)
                buttons(approveTitle: "Trust this certificate")
            case .untrustedChanged(let expected, let actual):
                Text("The router's certificate changed. This can mean a firmware update or an attack.")
                fingerprintRow(expected, label: "Previously trusted")
                fingerprintRow(actual, label: "Now presented")
                buttons(approveTitle: "Replace trusted certificate")
            case .trusted:
                EmptyView()
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func fingerprintRow(_ fingerprint: CertificateFingerprint, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
            Text(fingerprint.display).font(.system(.body, design: .monospaced))
        }
    }

    private func buttons(approveTitle: String) -> some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
            Button(approveTitle, action: onApprove)
        }
    }
}

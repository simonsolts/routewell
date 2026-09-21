import SwiftUI

/// Static guidance shown from the Overview screen in live mode when the
/// last refresh failure looks like it could be a denied Local Network
/// permission. A timeout is not conclusive, so the text says so.
struct LocalNetworkGuidanceView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If macOS asked for Local Network permission and it was refused, allow Routewell in System Settings > Privacy & Security > Local Network. A timeout does not always mean permission was refused.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Local Network Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
    }
}

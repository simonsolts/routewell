import SwiftUI

/// App settings only. The router login and the trusted certificate moved to
/// the Router tab (chunk 15B).
struct AdvancedSettingsTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Logs", value: "Session only")
                Button("Choose Export Folder…") {}.disabled(true)
                Button("Reset Settings…") {}.disabled(true)
            }
            Text("Diagnostic export is not available yet.").foregroundStyle(.secondary)
        }
    }
}

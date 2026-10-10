import SwiftUI
import RoutewellKit

/// App settings only.
struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $model.showInMenuBar)
                Toggle("Show Dock icon", isOn: .constant(true)).disabled(true)
                Toggle("Open at login", isOn: .constant(false)).disabled(true)
            } footer: {
                Text("Menu bar visibility is saved on this Mac. Login items and Dock visibility are not available yet.")
            }
            Section {
                Picker("Refresh every", selection: $model.refreshIntervalSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
                Toggle("Pause refreshing when hidden", isOn: $model.pauseWhenHidden)
                Picker("Appearance", selection: .constant("System")) { Text("System").tag("System") }.disabled(true)
            } footer: {
                Text("Refresh settings are saved on this Mac. When paused with the window hidden, the menu bar refreshes every 60 seconds. Appearance follows macOS.")
            }
            Section {
                LabeledContent("Version", value: Self.versionText(Bundle.main.infoDictionary))
                LabeledContent("Router", value: model.session.expectedToken?.profileID ?? "Not connected")
            }
        }
    }

    /// "0.15.2 (3)": the version and build number from the app's Info.plist.
    static func versionText(_ info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }
}

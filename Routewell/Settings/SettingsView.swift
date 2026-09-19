import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Section {
                    Toggle("Show in menu bar", isOn: $model.showInMenuBar)
                    Toggle("Show Dock icon", isOn: .constant(true)).disabled(true)
                    Toggle("Open at login", isOn: .constant(false)).disabled(true)
                } footer: {
                    Text("Menu bar visibility applies for this session. Login items and Dock visibility are not available yet.")
                }
                Section {
                    Picker("Refresh every", selection: .constant(30)) { Text("30 seconds").tag(30) }.disabled(true)
                    Toggle("Pause refreshing when hidden", isOn: .constant(true)).disabled(true)
                    Picker("Appearance", selection: .constant("System")) { Text("System").tag("System") }.disabled(true)
                } footer: {
                    Text("Refresh is manual in this build (⌘R). Appearance follows macOS.")
                }
                Section {
                    LabeledContent("Version", value: "0.1 (1)")
                    LabeledContent("Router", value: model.session.expectedToken?.profileID ?? "Not connected")
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                if model.mode == .mock {
                    Section("Mock routers") {
                        Picker("Profile", selection: Binding(
                            get: { model.session.expectedToken?.profileID ?? AppEnvironment.mockProfiles[0] },
                            set: { environment.switchMockProfile($0) }
                        )) {
                            ForEach(AppEnvironment.mockProfiles, id: \.self) { Text($0).tag($0) }
                        }
                        Toggle("Delay refresh by 5 seconds", isOn: $model.slowMockRefresh)
                        Text("In-memory samples only. Use ⌘R, then switch profiles to try a refresh in progress.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Address", text: .constant(""), prompt: Text("Router hostname or IP address"))
                    TextField("Username", text: .constant(""))
                    Picker("SSH authentication", selection: .constant("Key")) { Text("SSH key").tag("Key") }
                    Button("Test Connection") {}
                }.disabled(true)
                Section {
                    Text("Connection setup will be available in a later build. No credentials are collected here.")
                        .foregroundStyle(.secondary)
                }
            }.tabItem { Label("Router", systemImage: "wifi.router") }

            Form {
                Section {
                    TextField("URL", text: .constant(""), prompt: Text("https://router.local"))
                    Picker("Authentication", selection: .constant("Router")) { Text("Router credentials").tag("Router") }
                    Toggle("Verify server identity", isOn: .constant(true))
                }.disabled(true)
                Text("AdGuard Home connection settings are not available yet.").foregroundStyle(.secondary)
            }.tabItem { Label("AdGuard Home", systemImage: "shield") }

            Form {
                Section {
                    Toggle("New devices", isOn: .constant(false))
                    Toggle("Internet outages", isOn: .constant(false))
                    Toggle("Operation finished", isOn: .constant(false))
                    Toggle("Protection changed", isOn: .constant(false))
                    Toggle("Show in Notification Center", isOn: .constant(false))
                }.disabled(true)
                Text("Notifications are not available yet. This build does not request notification permission.")
                    .foregroundStyle(.secondary)
            }.tabItem { Label("Notifications", systemImage: "bell") }

            Form {
                Section {
                    LabeledContent("Logs", value: "Session only")
                    Button("Choose Export Folder…") {}.disabled(true)
                    Button("Reset Settings…") {}.disabled(true)
                }
                Text("Diagnostics and persistent settings are not available yet.").foregroundStyle(.secondary)
            }.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 420)
    }
}

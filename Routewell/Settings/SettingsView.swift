import SwiftUI
import RoutewellKit

struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(AppModel.self) private var model
    @State private var mockSecret = ""
    @State private var confirmingDelete = false
    var body: some View {
        @Bindable var model = model
        TabView {
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
                    LabeledContent("Version", value: "0.1 (1)")
                    LabeledContent("Router", value: model.session.expectedToken?.profileID ?? "Not connected")
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                if model.mode == .mock {
                    Section("Mock routers") {
                        Picker("Profile", selection: Binding(
                            get: { environment.persistence.profiles.selectedID },
                            set: { if let id = $0 { environment.selectMockProfile(id) } }
                        )) {
                            ForEach(environment.persistence.profiles.profiles) { Text($0.name).tag(Optional($0.id)) }
                        }
                        HStack {
                            Button("Add Mock Profile") { environment.addMockProfile() }
                            Button("Delete Mock Profile…", role: .destructive) { confirmingDelete = true }
                                .disabled(environment.persistence.selectedProfile == nil)
                        }
                        Picker("Scenario", selection: Binding(
                            get: { model.mockScenarioID },
                            set: { environment.switchMockScenario($0) }
                        )) {
                            ForEach(AppEnvironment.mockScenarios, id: \.self) { scenario in
                                Text(scenario.capitalized).tag(scenario)
                            }
                        }
                        Text("Healthy, partial, offline, stale, and slow samples stay in memory. The slow scenario takes five seconds.")
                            .foregroundStyle(.secondary)
                    }
                }
                if model.mode == .mock, let profile = environment.persistence.selectedProfile {
                    Section("Mock credential · Keychain") {
                        LabeledContent("Endpoint", value: profile.endpoint)
                        SecureField("Mock password", text: $mockSecret)
                        HStack {
                            Button("Save Mock Credential") {
                                let secret = Data(mockSecret.utf8)
                                mockSecret = ""
                                Task { await environment.persistence.credential(.save(secret)) }
                            }.disabled(mockSecret.isEmpty)
                            Button("Check") { Task { await environment.persistence.credential(.check) } }
                            Button("Delete Credential", role: .destructive) {
                                Task { await environment.persistence.credential(.delete) }
                            }
                        }
                        Text(environment.persistence.credentialMessage ?? "Use a made-up password. Only this mock profile’s Routewell Keychain item is accessed. No network connection is made.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Address", text: .constant(""), prompt: Text("Router hostname or IP address"))
                    TextField("Username", text: .constant(""))
                    Picker("SSH authentication", selection: .constant("Key")) { Text("SSH key").tag("Key") }
                    Button("Test Connection") {}
                }.disabled(true)
                Section {
                    Text("Live connection setup will be available in a later build.")
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
                Text("Diagnostic export is not available yet.").foregroundStyle(.secondary)
            }.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .disabled(environment.persistence.isLoading || environment.persistence.credentialBusy)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(environment.persistence.status)
                        .foregroundStyle(environment.persistence.errors.isEmpty ? Color.secondary : Color.red)
                    Spacer()
                    if !environment.persistence.errors.isEmpty {
                        Button("Retry Save") { Task { await environment.persistence.flush() } }
                    }
                }
                if let notice = environment.persistence.recoveryNotice { Text(notice).foregroundStyle(.orange) }
            }.font(.caption).padding(12)
        }
        .onChange(of: environment.persistence.profiles.selectedID) { mockSecret = "" }
        .confirmationDialog("Delete \(environment.persistence.selectedProfile?.name ?? "mock profile")?", isPresented: $confirmingDelete) {
            Button("Delete Mock Profile", role: .destructive) {
                Task { await environment.deleteMockProfile() }
            }
        } message: {
            Text("Removes this saved mock profile and its exact Routewell mock credential from Keychain. Other Keychain items are not touched.")
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 560)
    }
}

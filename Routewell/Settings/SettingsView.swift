import SwiftUI
import RoutewellKit

struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(AppModel.self) private var model
    @State private var mockSecret = ""
    @State private var confirmingDelete = false
    @State private var addressText = ""
    @State private var addressError: String?
    @State private var usernameText = ""
    @State private var newPassword = ""
    @State private var adGuardPort = 3000
    @State private var adGuardUseRouterCredentials = true
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
                if model.mode == .live, let profile = environment.persistence.selectedProfile, profile.liveEndpoint != nil {
                    Section("Router") {
                        TextField("Address", text: $addressText, prompt: Text("Router hostname or IP address"))
                            .onSubmit { Task { await saveAddress() } }
                        if let addressError { Text(addressError).font(.caption).foregroundStyle(.red) }
                        TextField("Username", text: $usernameText)
                            .onSubmit { environment.persistence.updateLiveUsername(usernameText) }
                        Picker("SSH authentication", selection: .constant("Key")) { Text("SSH key").tag("Key") }.disabled(true)
                        Button("Test Connection") {}.disabled(true)
                            .help("Available after live status is added")
                    }
                    Section("Change password") {
                        SecureField("New password", text: $newPassword)
                        Button("Save Password") {
                            let secret = Data(newPassword.utf8)
                            newPassword = ""
                            Task { await environment.persistence.changeLivePassword(secret) }
                        }.disabled(newPassword.isEmpty)
                    }
                    .onAppear {
                        addressText = profile.liveEndpoint?.displayString ?? profile.endpoint
                        usernameText = profile.username
                    }
                } else {
                    Section {
                        Text("Set up a router in the Setup screen to edit its address and username here.")
                            .foregroundStyle(.secondary)
                    }
                }
            }.tabItem { Label("Router", systemImage: "wifi.router") }

            Form {
                if model.mode == .live, let profile = environment.persistence.selectedProfile, profile.liveEndpoint != nil {
                    Section("AdGuard Home") {
                        Stepper("Port: \(adGuardPort)", value: $adGuardPort, in: 1...65535)
                            .onChange(of: adGuardPort) { _, newValue in saveAdGuardSettings(port: newValue) }
                        Toggle("Use router login for AdGuard Home", isOn: $adGuardUseRouterCredentials)
                            .onChange(of: adGuardUseRouterCredentials) { _, newValue in saveAdGuardSettings(useRouterCredentials: newValue) }
                        Button("Test Connection") {}.disabled(true)
                            .help("Available after live status is added")
                    }
                    .onAppear {
                        adGuardPort = profile.adGuard?.port ?? 3000
                        adGuardUseRouterCredentials = profile.adGuard?.useRouterCredentials ?? true
                    }
                } else {
                    Text("AdGuard Home connection settings are not available yet.").foregroundStyle(.secondary)
                }
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
                Section("Trusted certificates") {
                    if environment.trust.trusted.isEmpty {
                        Text("No certificates are trusted yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(environment.trust.trusted, id: \.self) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.host):\(entry.port)")
                                    Text(entry.fingerprint.display).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    Task { await environment.trust.revoke(host: entry.host, port: entry.port) }
                                }
                            }
                        }
                    }
                    Text("Trust is approved per router address, not for a whole certificate authority.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

    private func saveAddress() async {
        do {
            let endpoint = try RouterEndpoint.parse(addressText)
            addressError = nil
            let saved = await environment.persistence.updateLiveAddress(endpoint)
            if !saved { addressError = "Could not save the new address. Try again." }
        } catch {
            addressError = error.message
        }
    }

    private func saveAdGuardSettings(port: Int? = nil, useRouterCredentials: Bool? = nil) {
        guard let profile = environment.persistence.selectedProfile else { return }
        var settings = profile.adGuard ?? AdGuardSettings()
        if let port { settings.port = port }
        if let useRouterCredentials { settings.useRouterCredentials = useRouterCredentials }
        environment.persistence.updateAdGuardSettings(settings)
    }
}

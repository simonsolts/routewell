import SwiftUI
import RoutewellKit
#if DEBUG
import RoutewellMock
#endif

struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(AppModel.self) private var model
    @State private var mockSecret = ""
    #if DEBUG
    @State private var mockFeatureBehaviors: [DataArea: MockRouterBackend.FeatureBehavior] = [:]
    #endif
    @State private var confirmingDelete = false
    @State private var addressText = ""
    @State private var addressError: String?
    @State private var usernameText = ""
    @State private var newPassword = ""
    @State private var adGuardPort = 3000
    @State private var adGuardUseRouterCredentials = true
    @State private var adGuardUseHTTPS = false
    @State private var adGuardUsername = ""
    @State private var adGuardPassword = ""
    @State private var isTestingRouterConnection = false
    @State private var routerConnectionTestResult: String?
    @State private var routerConnectionTestTask: Task<Void, Never>?
    @State private var isTestingAdGuardConnection = false
    @State private var adGuardConnectionTestResult: String?
    @State private var adGuardConnectionTestTask: Task<Void, Never>?
    /// Owned by this window, not `MainWindow`'s shared `trustPrompt`: a
    /// certificate prompt from a probe started in this window's Router or
    /// AdGuard Home tab must show here, never on the main window.
    @State private var testConnectionTrustPrompt = TrustPromptController()
    private var mutationInFlight: Bool { environment.mutation.inFlight != nil }
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
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
            .tag("General")

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
                    .disabled(mutationInFlight)
                    #if DEBUG
                    Section {
                        ForEach([DataArea.clients, .queryLog, .network, .maintenance, .vpn, .plugins, .telemetry], id: \.self) { area in
                            Picker(area.rawValue, selection: Binding(
                                get: { mockFeatureBehaviors[area] ?? MockRouterBackend.defaultFeatureBehavior(for: area) },
                                set: { behavior in
                                    mockFeatureBehaviors[area] = behavior
                                    environment.setMockFeatureBehavior(behavior, for: area)
                                }
                            )) {
                                ForEach(MockRouterBackend.FeatureBehavior.allCases, id: \.self) { behavior in
                                    Text(behavior.rawValue.capitalized).tag(behavior)
                                }
                            }
                        }
                    } header: {
                        Text("Mock feature capabilities")
                    } footer: {
                        Text("Each area probes independently. Slow waits five seconds; failing leaves capability unknown.")
                    }
                    Section {
                        Picker("Clients data", selection: Binding(
                            get: { environment.mockClientsScenario },
                            set: { environment.setMockClientsScenario($0) }
                        )) {
                            Text("New devices present").tag(MockClientsService.Scenario.newDevices)
                            Text("All devices known").tag(MockClientsService.Scenario.standard)
                            Text("Empty router list").tag(MockClientsService.Scenario.empty)
                            Text("AdGuard join mismatch").tag(MockClientsService.Scenario.adGuardMismatch)
                            Text("Router list fails").tag(MockClientsService.Scenario.primaryFailure)
                        }
                        Picker("Ping and Wake", selection: Binding(
                            get: { environment.mockClientActionsMechanism },
                            set: { environment.setMockClientActions($0) }
                        )) {
                            Text("Router RPC").tag(ClientActionMechanism?.some(.rpc))
                            Text("SSH").tag(ClientActionMechanism?.some(.ssh))
                            Text("SSH not set up").tag(ClientActionMechanism?.some(.sshRequired))
                            Text("Hidden (no mechanism)").tag(ClientActionMechanism?.none)
                        }
                    } header: {
                        Text("Mock clients")
                    } footer: {
                        Text("Device and presence history in mock mode stay in memory. Each device the seed history has not seen is reported once per app session. DNS activity uses the query-log capability above.")
                    }
                    Section {
                        Picker("SQM", selection: Binding(
                            get: { environment.mockSQMBehavior },
                            set: { environment.setMockSQMBehavior($0) }
                        )) {
                            Text("Unavailable (method not found)").tag(MockRouterService.SQMBehavior.unavailable)
                            Text("Available, off").tag(MockRouterService.SQMBehavior.available)
                            Text("Available, on with limits").tag(MockRouterService.SQMBehavior.enabled)
                            Text("Read fails").tag(MockRouterService.SQMBehavior.failing)
                        }
                        Picker("Firmware check", selection: Binding(
                            get: { environment.mockFirmwareBehavior },
                            set: { environment.setMockFirmwareBehavior($0) }
                        )) {
                            Text("Unable to check").tag(MockRouterService.FirmwareBehavior.unableToCheck)
                            Text("Update available").tag(MockRouterService.FirmwareBehavior.updateAvailable)
                            Text("Up to date").tag(MockRouterService.FirmwareBehavior.upToDate)
                        }
                        Picker("SSH", selection: Binding(
                            get: { environment.mockSSHScenario },
                            set: { environment.setMockSSHScenario($0) }
                        )) {
                            Text("Populated").tag(MockSSHService.Scenario.populated)
                            Text("SSH off (not set up)").tag(MockSSHService.Scenario.off)
                            Text("Probe pending").tag(MockSSHService.Scenario.probePending)
                            Text("Probe fails (key refused)").tag(MockSSHService.Scenario.probeFails)
                            Text("Probe times out").tag(MockSSHService.Scenario.probeTimesOut)
                            Text("Host key changed").tag(MockSSHService.Scenario.hostKeyChanged)
                        }
                        HStack {
                            Button("Preview New Host Key…") { environment.sshSetup.preview(.new) }
                            Button("Preview Changed Host Key…") { environment.sshSetup.preview(.changed) }
                        }
                    } header: {
                        Text("Mock router")
                    } footer: {
                        Text("Wi-Fi always shows three populated bands. Multi-WAN reports no interface state. The SSH picker drives Ports, Storage, Logs, and the AdGuard Home process ID; each change runs the SSH probe once. The host-key previews scan and store nothing. The firmware check runs when you press Check for Updates.")
                    }
                    #endif
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
                    if mutationInFlight {
                        Section { Text("A change is running. Wait for it to finish.").foregroundStyle(.secondary) }
                    }
                    Section("Router") {
                        TextField("Address", text: $addressText, prompt: Text("Router hostname or IP address"))
                            .onSubmit { Task { await saveAddress() } }
                        if let addressError { Text(addressError).font(.caption).foregroundStyle(.red) }
                        Button("Test Connection") {
                            routerConnectionTestTask?.cancel()
                            routerConnectionTestTask = Task { await testRouterConnection(profile: profile) }
                        }
                        .disabled(isTestingRouterConnection)
                        if let routerConnectionTestResult {
                            Text(routerConnectionTestResult).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(mutationInFlight)
                    Section("Change password") {
                        SecureField("New password", text: $newPassword)
                        Button("Save Password") {
                            let secret = Data(newPassword.utf8)
                            newPassword = ""
                            Task { await environment.changeLivePassword(secret) }
                        }.disabled(newPassword.isEmpty)
                    }
                    .disabled(mutationInFlight)
                    .onAppear {
                        addressText = profile.liveEndpoint?.displayString ?? profile.endpoint
                        usernameText = profile.username
                    }
                    SSHSettingsSection(environment: environment, profile: profile)
                        .disabled(mutationInFlight)
                } else {
                    Section {
                        Text("Set up a router in the Setup screen to edit its address and username here.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { environment.sshSetup.prompt != nil },
                set: { if !$0 { environment.sshSetup.resolve(false) } }
            )) {
                if let prompt = environment.sshSetup.prompt {
                    SSHHostKeyPromptView(prompt: prompt,
                                         onCancel: { environment.sshSetup.resolve(false) },
                                         onApprove: { environment.sshSetup.resolve(true) })
                }
            }
            .tabItem { Label("Router", systemImage: "wifi.router") }.tag("Router")

            Form {
                if model.mode == .live, let profile = environment.persistence.selectedProfile, profile.liveEndpoint != nil {
                    if mutationInFlight {
                        Section { Text("A change is running. Wait for it to finish.").foregroundStyle(.secondary) }
                    }
                    Section {
                        Picker("Login", selection: $adGuardUseRouterCredentials) {
                            Text("Use router login").tag(true)
                            Text("AdGuard Home account").tag(false)
                        }
                        .onChange(of: adGuardUseRouterCredentials) { _, newValue in saveAdGuardSettings(useRouterCredentials: newValue) }
                        if !adGuardUseRouterCredentials {
                            TextField("Username", text: $adGuardUsername)
                                .onSubmit { saveAdGuardSettings(username: adGuardUsername) }
                            SecureField("Password", text: $adGuardPassword)
                            Button("Save AdGuard Home Password") {
                                let secret = Data(adGuardPassword.utf8)
                                adGuardPassword = ""
                                Task { await environment.saveAdGuardPassword(secret) }
                            }.disabled(adGuardPassword.isEmpty)
                        }
                        Stepper("Port: \(adGuardPort)", value: $adGuardPort, in: 1...65535)
                            .onChange(of: adGuardPort) { _, newValue in saveAdGuardSettings(port: newValue) }
                        Toggle("Use HTTPS", isOn: $adGuardUseHTTPS)
                            .onChange(of: adGuardUseHTTPS) { _, newValue in saveAdGuardSettings(useHTTPS: newValue) }
                        Button("Test Connection") {
                            adGuardConnectionTestTask?.cancel()
                            adGuardConnectionTestTask = Task { await testAdGuardConnection(profile: profile) }
                        }
                        .disabled(isTestingAdGuardConnection)
                        if let adGuardConnectionTestResult {
                            Text(adGuardConnectionTestResult).font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("AdGuard Home")
                    } footer: {
                        Text("On firmware 4.9 and later the router login may not work for AdGuard Home. Create an AdGuard Home account and use it here.")
                    }
                    .disabled(mutationInFlight)
                    .onAppear {
                        adGuardPort = profile.adGuard?.port ?? 3000
                        adGuardUseRouterCredentials = profile.adGuard?.useRouterCredentials ?? true
                        adGuardUseHTTPS = profile.adGuard?.useHTTPS ?? false
                        adGuardUsername = profile.adGuard?.username ?? ""
                    }
                } else {
                    Text("AdGuard Home connection settings are not available yet.").foregroundStyle(.secondary)
                }
            }.tabItem { Label("AdGuard Home", systemImage: "shield") }.tag("AdGuard Home")

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
            }.tabItem { Label("Notifications", systemImage: "bell") }.tag("Notifications")

            Form {
                if model.mode == .live, let profile = environment.persistence.selectedProfile, profile.liveEndpoint != nil {
                    if mutationInFlight {
                        Section { Text("A change is running. Wait for it to finish.").foregroundStyle(.secondary) }
                    }
                    Section {
                        TextField("Router login username", text: $usernameText)
                            .onSubmit { environment.updateLiveUsername(usernameText) }
                    } footer: {
                        Text("The GL.iNet web login user. Firmware 4.x uses admin. Only change this if your router is different.")
                    }
                    .disabled(mutationInFlight)
                    .onAppear { usernameText = profile.username }
                }
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
            }.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag("Advanced")
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
        .onDisappear {
            routerConnectionTestTask?.cancel()
            adGuardConnectionTestTask?.cancel()
        }
        .sheet(isPresented: Binding(
            get: { testConnectionTrustPrompt.pending != nil },
            set: { if !$0 { testConnectionTrustPrompt.resolve(false) } }
        )) {
            if let request = testConnectionTrustPrompt.pending {
                TrustPromptView(
                    request: request,
                    onCancel: { testConnectionTrustPrompt.resolve(false) },
                    onApprove: { testConnectionTrustPrompt.resolve(true) }
                )
            }
        }
    }

    private func saveAddress() async {
        do {
            let endpoint = try RouterEndpoint.parse(addressText)
            addressError = nil
            let saved = await environment.updateLiveAddress(endpoint)
            if !saved { addressError = "Could not save the new address. Try again." }
        } catch {
            addressError = error.message
        }
    }

    private func saveAdGuardSettings(port: Int? = nil, useRouterCredentials: Bool? = nil, useHTTPS: Bool? = nil, username: String? = nil) {
        guard let profile = environment.persistence.selectedProfile else { return }
        var settings = profile.adGuard ?? AdGuardSettings()
        if let port { settings.port = port }
        if let useRouterCredentials { settings.useRouterCredentials = useRouterCredentials }
        if let useHTTPS { settings.useHTTPS = useHTTPS }
        if let username { settings.username = username }
        environment.updateAdGuardSettings(settings)
    }

    private func testRouterConnection(profile: RouterProfile) async {
        guard let endpoint = try? RouterEndpoint.parse(addressText) else {
            routerConnectionTestResult = "Enter a valid router address before testing."
            return
        }
        isTestingRouterConnection = true
        defer { isTestingRouterConnection = false }
        routerConnectionTestResult = await environment.testRouterConnection(
            endpoint: endpoint,
            username: usernameText.trimmingCharacters(in: .whitespaces),
            password: .keychain(profile.credential),
            trustPromptController: testConnectionTrustPrompt
        )
    }

    private func testAdGuardConnection(profile: RouterProfile) async {
        guard let endpoint = profile.liveEndpoint else { return }
        let settings = profile.adGuard ?? AdGuardSettings(port: adGuardPort, useRouterCredentials: adGuardUseRouterCredentials, useHTTPS: adGuardUseHTTPS, username: adGuardUsername)
        isTestingAdGuardConnection = true
        defer { isTestingAdGuardConnection = false }
        let adGuardCredential = CredentialReference(profileID: profile.id, endpoint: profile.endpoint, kind: .adGuardPassword)
        adGuardConnectionTestResult = await environment.testAdGuardConnection(
            routerEndpoint: endpoint,
            username: usernameText.trimmingCharacters(in: .whitespaces),
            routerPassword: .keychain(profile.credential),
            adGuardSettings: settings,
            adGuardPassword: .keychain(adGuardCredential),
            trustPromptController: testConnectionTrustPrompt
        )
    }
}

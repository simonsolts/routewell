#if DEBUG
import SwiftUI
import RoutewellKit
import RoutewellMock

/// The "Mock" disclosure at the bottom of the Router tab: every mock control
/// that Settings had before chunk 15B, and the Router tab's own scenarios.
struct MockSettingsSections: View {
    let environment: AppEnvironment
    @Bindable var services: MockRouterSettingsServices
    let router: RouterSettingsModel
    @Environment(AppModel.self) private var model
    @State private var mockSecret = ""
    @State private var mockFeatureBehaviors: [DataArea: MockRouterBackend.FeatureBehavior] = [:]
    @State private var confirmingDelete = false

    private var mutationInFlight: Bool { environment.mutation.inFlight != nil }

    var body: some View {
        Section {
            EmptyView()
        } header: {
            Button {
                withAnimation { services.mockSectionExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(services.mockSectionExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Mock").bold()
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(services.mockSectionExpanded ? "Expanded" : "Collapsed")
        } footer: {
            if !services.mockSectionExpanded {
                Text("Mock routers, scenarios, and capabilities. Mock mode only.")
            }
        }
        if services.mockSectionExpanded {
            routerSettingsScenarios
            mockRouters
            featureCapabilities
            mockClients
            mockRouter
            mockCredential
        }
    }

    private var routerSettingsScenarios: some View {
        Section {
            Toggle("AdGuard Home off on router", isOn: Binding(
                get: { services.adGuardOffOnRouter },
                set: { services.adGuardOffOnRouter = $0; Task { await router.load() } }
            ))
            Toggle("Test Connection fails", isOn: $services.testFails)
            Toggle("Certificate trusted", isOn: Binding(
                get: { services.certificateTrusted },
                set: { services.certificateTrusted = $0; Task { await router.reloadLocal() } }
            ))
            Toggle("Host key trusted", isOn: Binding(
                get: { services.hostKeyTrusted },
                set: { services.hostKeyTrusted = $0; Task { await router.reloadLocal() } }
            ))
            Toggle("SSH on", isOn: Binding(
                get: { environment.mockSSHScenario != .off },
                set: { environment.setMockSSHScenario($0 ? .populated : .off) }
            ))
        } header: {
            Text("Mock router settings")
        } footer: {
            Text("Values above are neutral examples kept in memory. Nothing is saved, and nothing contacts a router. Start Setup Again opens the mock assistant and removes nothing.")
        }
    }

    private var mockRouters: some View {
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
        .confirmationDialog("Delete \(environment.persistence.selectedProfile?.name ?? "mock profile")?", isPresented: $confirmingDelete) {
            Button("Delete Mock Profile", role: .destructive) {
                Task { await environment.deleteMockProfile() }
            }
        } message: {
            Text("Removes this saved mock profile and its exact Routewell mock credential from Keychain. Other Keychain items are not touched.")
        }
    }

    private var featureCapabilities: some View {
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
    }

    private var mockClients: some View {
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
    }

    private var mockRouter: some View {
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
    }

    @ViewBuilder private var mockCredential: some View {
        if let profile = environment.persistence.selectedProfile {
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
            .onChange(of: environment.persistence.profiles.selectedID) { mockSecret = "" }
        }
    }
}
#endif

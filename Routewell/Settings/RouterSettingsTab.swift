import SwiftUI
import RoutewellKit

/// Settings › Router (chunk 15B, `design/router-settings.md`): everything
/// about the router in one scrolling tab.
struct RouterSettingsTab: View {
    let environment: AppEnvironment
    @State private var model: RouterSettingsModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focus: Field?

    enum Field: Hashable { case name, address, newPassword, port, adGuardUsername, adGuardPassword, adGuardPort }

    init(environment: AppEnvironment, services: any RouterSettingsServices, app: AppModel) {
        self.environment = environment
        _model = State(initialValue: RouterSettingsModel(services: services, app: app))
    }

    /// A given model, for previews and snapshots.
    init(environment: AppEnvironment, model: RouterSettingsModel) {
        self.environment = environment
        _model = State(initialValue: model)
    }

    private var services: any RouterSettingsServices { model.services }
    private var mutationInFlight: Bool { environment.adGuard.isWriting }

    var body: some View {
        Form {
            Section { RouterHeaderCard(model: model) }
            if !model.testRows.isEmpty {
                Section { ForEach(model.testRows, id: \.label) { TestResultRow(row: $0) } }
            }
            routerGroup
            sshGroup
            adGuardGroup
            Section { startSetupAgainRow }
            #if DEBUG
            if environment.model.mode == .mock, let mock = services as? MockRouterSettingsServices {
                MockSettingsSections(environment: environment, services: mock, router: model)
            }
            #endif
        }
        .disabled(mutationInFlight)
        .task { await model.load() }
        .onChange(of: environment.model.snapshot?.observedAt) { Task { await model.reloadLocal() } }
        .onChange(of: focus) { old, _ in commit(old) }
        .onDisappear { model.cancelTest() }
        .alert(model.alert?.title ?? "", isPresented: alertShown, presenting: model.alert) { alert in
            Button(alert.action, role: .destructive) { confirm(alert) }
            Button("Cancel", role: .cancel) {}
        } message: { alert in
            Text(alert.message(name: services.name))
        }
        .sheet(item: sshSheet) { sheet in
            OnboardingView(model: sheet)
                .frame(width: OnboardingView.size.width, height: OnboardingView.size.height)
                .onExitCommand { model.sshSheetClosed() }
        }
        .sheet(isPresented: trustPromptShown) {
            if let request = model.trustPrompt.pending {
                TrustPromptView(request: request,
                                onCancel: { model.trustPrompt.resolve(false) },
                                onApprove: { model.trustPrompt.resolve(true) })
            }
        }
        .sheet(isPresented: hostKeyPromptShown) {
            if let prompt = environment.sshSetup.prompt {
                SSHHostKeyPromptView(prompt: prompt,
                                     onCancel: { environment.sshSetup.resolve(false) },
                                     onApprove: { environment.sshSetup.resolve(true) })
            }
        }
    }

    // MARK: Router

    private var routerGroup: some View {
        Section("Router") {
            LabeledContent("Name") {
                TextField("Name", text: $model.nameDraft)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 240)
                    .focused($focus, equals: .name)
                    .onSubmit { model.commitName() }
            }
            LabeledContent {
                TextField("Address", text: $model.addressDraft)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 240)
                    .focused($focus, equals: .address)
                    .onSubmit { Task { await model.commitAddress() } }
            } label: {
                Text("Address")
                Text(model.addressMessage ?? "IP address or host name")
                    .foregroundStyle(model.addressMessage == nil ? Color.secondary : Color.red)
            }
            LabeledContent {
                if model.editingPassword {
                    HStack {
                        SecureField("New password", text: $model.newPassword)
                            .labelsHidden()
                            .frame(width: 160)
                            .focused($focus, equals: .newPassword)
                            .onSubmit { Task { await model.savePassword() } }
                        Button("Cancel") { model.cancelPasswordChange() }
                        Button("Save") { Task { await model.savePassword() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.newPassword.isEmpty)
                    }
                } else {
                    HStack {
                        Text("••••••••").foregroundStyle(.secondary).accessibilityLabel("Saved password")
                        Button("Change…") {
                            model.beginPasswordChange()
                            focus = .newPassword
                        }
                    }
                }
            } label: {
                Text("Password")
                Text(model.passwordMessage ?? "Signs in as \(services.username) · saved in your Keychain")
                    .foregroundStyle(model.passwordMessage == nil ? Color.secondary : Color.red)
            }
            LabeledContent {
                if model.certificate != nil {
                    Button("Forget…") { model.alert = .forgetCertificate }
                }
            } label: {
                Text("HTTPS certificate")
                if let certificate = model.certificate {
                    Text("Trusted · SHA-256 \(certificate.display)")
                        .font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(certificate.display)
                } else if model.loaded {
                    Text("Not trusted. You’ll confirm it the next time Routewell connects.").foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: SSH

    private var sshGroup: some View {
        Section {
            HStack(spacing: 12) {
                OnboardingArt(motif: .terminal, tint: .purple, size: 32).frame(width: 32, height: 32)
                Toggle(isOn: Binding(get: { model.sshOn }, set: { model.setSSH($0) })) {
                    Text("Use SSH")
                    Text("Adds ping and wake, port status, storage, the system log, DHCP reservations and network tests.")
                }
            }
            if model.sshOn {
                LabeledContent {
                    HStack {
                        Text(services.ssh.keyFilePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None chosen")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { model.chooseKeyFile() }
                    }
                } label: {
                    Text("Key file")
                    Text("Must not have a passphrase")
                }
                LabeledContent("Port") {
                    TextField("Port", text: $model.portDraft)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .focused($focus, equals: .port)
                        .onSubmit { model.commitPort() }
                }
                LabeledContent {
                    if model.hostKey != nil {
                        Button("Forget…") { model.alert = .forgetHostKey }
                    }
                } label: {
                    Text("Host key")
                    if let hostKey = model.hostKey {
                        Text("Trusted · \(hostKey)")
                            .font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.tail)
                            .textSelection(.enabled)
                            .help(hostKey)
                    } else if model.loaded {
                        Text("Not trusted. You’ll confirm it the next time SSH connects.").foregroundStyle(.orange)
                    }
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if model.sshStatus == .checking {
                            ProgressView().controlSize(.mini)
                        } else {
                            StatusDot(tone: model.sshStatus.tone)
                        }
                        Text(model.sshStatus.text).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = model.sshMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("SSH")
        } footer: {
            if !model.sshOn {
                Text("Turning SSH on walks you through choosing a key and trusting the router’s host key.")
            }
        }
    }

    // MARK: AdGuard config

    private var adGuardGroup: some View {
        Section {
            if model.adGuardExpanded {
                if model.adGuardOff {
                    Label {
                        Text("**AdGuard Home is off on this router.** These settings have no effect until it’s turned on in the router’s admin panel.")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                    .listRowBackground(Color.orange.opacity(0.12))
                }
                Group {
                    Picker("Sign in with", selection: Binding(
                        get: { !model.adGuard.useRouterCredentials },
                        set: { model.setAdGuardSeparateAccount($0) }
                    )) {
                        Text("Router password").tag(false)
                        Text("Separate account").tag(true)
                    }
                    if !model.adGuard.useRouterCredentials {
                        TextField("Username", text: $model.adGuardUsernameDraft, prompt: Text("AdGuard Home username"))
                            .multilineTextAlignment(.trailing)
                            .focused($focus, equals: .adGuardUsername)
                            .onSubmit { model.commitAdGuardUsername() }
                        SecureField("Password", text: $model.adGuardPasswordDraft, prompt: Text("AdGuard Home password"))
                            .multilineTextAlignment(.trailing)
                            .focused($focus, equals: .adGuardPassword)
                            .onSubmit { Task { await model.saveAdGuardPassword() } }
                    }
                    LabeledContent("Port") {
                        TextField("Port", text: $model.adGuardPortDraft)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .focused($focus, equals: .adGuardPort)
                            .onSubmit { model.commitAdGuardPort() }
                    }
                    Toggle("Use HTTPS", isOn: Binding(get: { model.adGuard.useHTTPS }, set: { model.setAdGuardHTTPS($0) }))
                    if let message = model.adGuardMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .opacity(model.adGuardOff ? 0.5 : 1)
            }
        } header: {
            Button {
                withAnimation { model.adGuardExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(model.adGuardExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("AdGuard config").bold()
                    Spacer()
                    StatusDot(tone: model.adGuardStatus.tone)
                    Text(model.adGuardStatus.text).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AdGuard config, \(model.adGuardStatus.text)")
            .accessibilityValue(model.adGuardExpanded ? "Expanded" : "Collapsed")
        } footer: {
            if model.adGuardExpanded {
                Text("On firmware 4.9 and later, the router password may not work for AdGuard Home. If so, create an AdGuard Home account and choose Separate account.")
            } else {
                Text(model.adGuardOff
                     ? "AdGuard Home is off on this router, so these settings currently have no effect."
                     : "Connection details for AdGuard Home on the router. Most people never change these.")
            }
        }
    }

    // MARK: Start setup again

    private var startSetupAgainRow: some View {
        LabeledContent {
            Button("Start Setup Again…") { model.alert = .startSetupAgain }
                .foregroundStyle(.red)
        } label: {
            Text("Start setup again")
            Text("Removes this router and all of its settings from Routewell, then opens setup.")
        }
    }

    // MARK: Plumbing

    private func confirm(_ alert: RouterSettingsAlert) {
        if alert == .startSetupAgain {
            environment.onboarding.showWindow = { [openWindow] in
                openWindow(id: "onboarding")
                NSApp.activate()
            }
        }
        Task { await model.confirm(alert) }
    }

    /// Fields commit on Return and when focus leaves them.
    private func commit(_ field: Field?) {
        switch field {
        case .name: model.commitName()
        case .address: Task { await model.commitAddress() }
        case .port: model.commitPort()
        case .adGuardUsername: model.commitAdGuardUsername()
        case .adGuardPort: model.commitAdGuardPort()
        case .newPassword, .adGuardPassword, nil: break
        }
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    private var sshSheet: Binding<OnboardingModel?> {
        Binding(get: { model.sshSheet }, set: { if $0 == nil { model.sshSheetClosed() } })
    }

    private var trustPromptShown: Binding<Bool> {
        Binding(get: { model.trustPrompt.pending != nil }, set: { if !$0 { model.trustPrompt.resolve(false) } })
    }

    private var hostKeyPromptShown: Binding<Bool> {
        Binding(get: { environment.sshSetup.prompt != nil }, set: { if !$0 { environment.sshSetup.resolve(false) } })
    }
}

/// Tile, name, "model · Firmware · address", status, and Test Connection.
struct RouterHeaderCard: View {
    let model: RouterSettingsModel

    var body: some View {
        HStack(spacing: 14) {
            OnboardingArt(motif: .router, tint: .teal, size: 52).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.services.name).font(.system(size: 15, weight: .bold))
                Text(model.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    StatusDot(tone: model.status.tone)
                    Text(model.status.text).font(.caption).foregroundStyle(model.status.color)
                }
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            Button("Test Connection") { model.runTest() }
                .disabled(model.testing)
        }
        .padding(.vertical, 4)
    }
}

/// One Test Connection result: a spinner while testing, then a dot and value.
struct TestResultRow: View {
    let row: RouterSettingsModel.TestRow

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if row.value == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    StatusDot(tone: row.tone)
                }
            }
            .frame(width: 14, height: 14)
            Text(row.label)
            Spacer()
            Text(row.value ?? "Testing…").foregroundStyle(row.failed ? Color.red : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension RouterSettingsModel.Status {
    var tone: StatusTone {
        switch self {
        case .connected: .healthy
        case .notReachable: .error
        case .waitingForCertificate: .degraded
        case .checking: .unknown
        }
    }

    var color: Color {
        switch self {
        case .notReachable: .red
        case .waitingForCertificate: .orange
        case .connected, .checking: .secondary
        }
    }
}

extension RouterSettingsModel.SSHStatus {
    var tone: StatusTone {
        switch self {
        case .working: .healthy
        case .checking: .inProgress
        case .notConnected: .unknown
        case .failed: .error
        }
    }
}

extension RouterSettingsModel.AdGuardState {
    var tone: StatusTone {
        switch self {
        case .active: .healthy
        case .offOnRouter, .unknown: .unknown
        }
    }
}

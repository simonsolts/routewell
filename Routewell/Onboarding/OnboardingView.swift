import AppKit
import SwiftUI
import RoutewellKit

/// The onboarding window's root: shows the current run, starts the first-run
/// one after bootstrap, and hands over to the main window at Finish.
struct OnboardingWindow: View {
    let environment: AppEnvironment
    var delegate: AppDelegate?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var controller: OnboardingController { environment.onboarding }

    var body: some View {
        Group {
            if let run = controller.run {
                OnboardingView(model: run)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .frame(width: OnboardingView.size.width, height: OnboardingView.size.height)
        .toolbar(removing: .title)
        .onAppear {
            controller.showMainWindow = { [openWindow] in
                openWindow(id: "main")
                NSApp.activate()
            }
            controller.closeWindow = { [dismissWindow] in dismissWindow(id: "onboarding") }
            delegate?.reopen = { [environment, openWindow] in
                openWindow(id: environment.model.needsSetup ? "onboarding" : "main")
            }
        }
        .task {
            await environment.waitUntilReady()
            guard controller.run == nil else { return }
            if controller.runForLaunch() == nil {
                // Opened at launch, but bootstrap found a finished router.
                openWindow(id: "main")
                dismissWindow(id: "onboarding")
            }
        }
        .onDisappear { controller.windowClosed() }
    }
}

/// One state of the Quiet assistant: tile, title, body, the step's
/// controls, and the footer with the dots or Skip SSH and the buttons.
struct OnboardingView: View {
    static let size = CGSize(width: 720, height: 572)

    @Bindable var model: OnboardingModel
    @FocusState private var fieldFocused: Bool

    private var spec: OnboardingSpec { model.spec }
    private var tint: Color { model.state.step.tint }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                OnboardingArt(motif: spec.motif, tint: tint, badge: spec.badge, size: 84)
                    .padding(.bottom, 12)
                Text(spec.title)
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(spec.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
                controls
                    .frame(maxWidth: 440)
                    .padding(.top, 18)
            }
            .padding(.top, 36)
            .padding(.horizontal, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: model.state, initial: true) {
            fieldFocused = [.manual, .name, .password, .wrong].contains(model.state)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if spec.skipSSH {
                Button("Skip SSH") { model.tertiary() }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            } else {
                StepDots(current: model.state.step)
            }
            Spacer()
            if let secondary = spec.secondary {
                Button(secondary) { model.secondary() }
                    .controlSize(.large)
            }
            Button { model.primary() } label: {
                Text(spec.primary).frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.primaryDisabled)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        switch model.state.kind {
        case .intro: IntroCard()
        case .search:
            VStack(spacing: 12) {
                RowsBox(rows: zip(["Searching this network", "Trying \(RouterDiscovery.fallbackHost)"], model.state.rows).map { $0 })
                LinkButton("Enter Address Manually…") { model.enterAddress() }
            }
        case .check:
            RowsBox(rows: zip(["Reaching SSH on \(model.host):22", "Signing in as root with \(model.key?.name ?? "your key")"],
                              model.state.rows).map { $0 })
        case .found:
            VStack(spacing: 12) {
                FoundCard(address: model.displayAddress)
                LinkButton("Use a Different Address…") { model.enterAddress() }
            }
        case .manual: manualField
        case .denied: DeniedSteps(tint: tint)
        case .name:
            FieldGroup(label: "Name", note: "You can change this later in Settings.") {
                TextField("Name", text: $model.name, prompt: Text("router"))
                    .textFieldStyle(.roundedBorder).controlSize(.large).labelsHidden()
                    .focused($fieldFocused)
            }
        case .cert: certificate
        case .password: passwordField
        case .offer: SSHFeatureGrid()
        case .key: keyChooser
        case .hostkey: hostKeyBox
        case .done:
            if let summary = model.summary { SummaryRows(summary: summary) }
        }
    }

    private var manualField: some View {
        FieldGroup(label: "Router address", note: "An IP address or a host name. Routewell connects over HTTPS.",
                   error: model.manualMessage) {
            HStack(spacing: 8) {
                TextField("Router address", text: $model.address, prompt: Text("192.168.8.1 or router.lan"))
                    .textFieldStyle(.roundedBorder).controlSize(.large).labelsHidden()
                    .focused($fieldFocused)
                if model.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private var certificate: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fingerprint = model.router?.fingerprint {
                let bytes = fingerprint.display.split(separator: ":")
                FingerprintBox(label: "Certificate fingerprint (SHA-256)", place: model.displayAddress,
                               lines: [bytes.prefix(16).joined(separator: ":"), bytes.dropFirst(16).joined(separator: ":")])
            }
            if let notice = model.certificateNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hostKeyBox: some View {
        Group {
            if let hostKey = model.hostKey {
                let text = hostKey.fingerprintSHA256
                let split = text.index(text.startIndex, offsetBy: min(28, text.count))
                FingerprintBox(label: "Host key fingerprint (\(Self.algorithmName(hostKey.algorithm)))", place: "\(model.host):22",
                               lines: [String(text[..<split]), String(text[split...])])
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the router’s SSH host key…").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .onboardingBox()
            }
        }
    }

    static func algorithmName(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        default: algorithm.hasPrefix("ecdsa-") ? "ECDSA" : algorithm
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password").font(.system(size: 13, weight: .medium))
            SecureField("Password", text: $model.password, prompt: Text("Router password"))
                .textFieldStyle(.roundedBorder).controlSize(.large).labelsHidden()
                .focused($fieldFocused)
                .disabled(model.state == .signing)
                .overlay {
                    if model.state == .wrong {
                        RoundedRectangle(cornerRadius: 6).stroke(.red, lineWidth: 1)
                            .shadow(color: .red.opacity(0.25), radius: 2)
                    }
                }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.state == .signing { ProgressView().controlSize(.mini) }
                Text(passwordStatus.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(passwordStatus.color)
        }
    }

    private var passwordStatus: (text: String, color: Color) {
        switch model.state {
        case .signing: ("Signing in…", .secondary)
        case .wrong: ("That password didn’t work. Check it and try again.", .red)
        case .locked: ("You can try again in a few minutes", .orange)
        case .unreach: ("No response from \(model.displayAddress).", .red)
        default: model.passwordMessage.map { ($0, Color.red) } ?? ("Saved in your Keychain.", .secondary)
        }
    }

    private var keyChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let key = model.key {
                HStack(spacing: 12) {
                    OnboardingArt(motif: .key, tint: .purple, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text("\(key.folder) · \(key.inspection.isUsable ? key.inspection.displayType : "Not usable")")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") { model.chooseKey() }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .onboardingBox(border: key.inspection.isUsable ? Color(nsColor: .separatorColor) : .red)
                if let problem = key.inspection.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 12) {
                    OnboardingArt(motif: .key, tint: .purple, size: 36)
                    Text("No key chosen").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose Key File…") { model.chooseKey() }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            KeyNotes()
        }
    }
}

// MARK: - Pieces

private extension View {
    /// The design's grouped box: tertiary fill, separator border, radius 10.
    func onboardingBox(border: Color = Color(nsColor: .separatorColor)) -> some View {
        background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 1))
    }
}

/// Five dots; the current step a 22 pt pill in its tint.
struct StepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(color(step))
                    .frame(width: step == current ? 22 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count), \(current.label)")
    }

    private func color(_ step: OnboardingStep) -> Color {
        if step == current { return step.tint }
        return step.rawValue < current.rawValue ? Color.primary.opacity(0.45) : Color(nsColor: .tertiaryLabelColor)
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity)
    }
}

/// Explains the Local Network prompt with a small picture of it.
private struct IntroCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS will ask whether Routewell can find devices on your local network. Choose **Allow** so Routewell can reach your router.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text("“Routewell” would like to find and connect to devices on your local network.")
                    .font(.system(size: 10.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text("Don’t Allow")
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
                        .foregroundStyle(.secondary)
                    Text("Allow")
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.3)))
                }
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Picture of the macOS prompt. Choose Allow.")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .onboardingBox()
    }
}

/// The search and SSH check lists.
private struct RowsBox: View {
    let rows: [(String, OnboardingRowState)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    RowIcon(state: row.1).frame(width: 16, height: 16)
                    Text(row.0).font(.system(size: 13))
                        .foregroundStyle(row.1 == .wait ? .secondary : .primary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Self.value(row.1))
            }
        }
        .onboardingBox()
    }

    static func value(_ state: OnboardingRowState) -> String {
        switch state {
        case .spin: "In progress"
        case .ok: "Done"
        case .fail: "Failed"
        case .wait: "Waiting"
        }
    }
}

private struct RowIcon: View {
    let state: OnboardingRowState

    var body: some View {
        switch state {
        case .spin: ProgressView().controlSize(.small).scaleEffect(0.8)
        case .ok: StatusGlyph(symbol: "checkmark.circle.fill", color: .green, size: 16)
        case .fail: StatusGlyph(symbol: "xmark.circle.fill", color: .red, size: 16)
        case .wait: Circle().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5).frame(width: 12, height: 12)
        }
    }
}

private struct StatusGlyph: View {
    let symbol: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .font(.system(size: size))
    }
}

/// "GL.iNet router" and the address. Model and firmware need sign-in, so
/// they appear on Finish instead.
private struct FoundCard: View {
    let address: String

    var body: some View {
        HStack(spacing: 12) {
            OnboardingArt(motif: .router, tint: .teal, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("GL.iNet router").font(.system(size: 13, weight: .semibold))
                Text(address).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            StatusGlyph(symbol: "checkmark.circle.fill", color: .green, size: 18)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .onboardingBox()
        .accessibilityElement(children: .combine)
    }
}

private struct FieldGroup<Field: View>: View {
    let label: String
    let note: String
    var error: String?
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium))
            field
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DeniedSteps: View {
    let tint: Color
    private let steps = [
        "Open System Settings › Privacy & Security › Local Network.",
        "Turn on Routewell.",
        "Come back here and click Try Again.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                if index > 0 { Divider() }
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(tint.opacity(0.18)))
                    Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .onboardingBox()
    }
}

private struct FingerprintBox: View {
    let label: String
    let place: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                Spacer()
                Text(place)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingBox()
    }
}

private struct SSHFeatureGrid: View {
    private struct Feature: Identifiable {
        let motif: ArtMotif
        let tint: Color
        let title: String
        let detail: String
        var id: String { title }
    }

    private let features = [
        Feature(motif: .ping, tint: .teal, title: "Ping and wake", detail: "Check devices respond, and wake them remotely."),
        Feature(motif: .ports, tint: .blue, title: "Port status", detail: "See which Ethernet ports are in use."),
        Feature(motif: .storage, tint: .indigo, title: "Storage", detail: "Check the router’s storage and drives."),
        Feature(motif: .log, tint: .orange, title: "System log", detail: "Read the router’s own log."),
        Feature(motif: .dhcp, tint: .pink, title: "DHCP reservations", detail: "Give devices a fixed address."),
        Feature(motif: .speed, tint: .green, title: "Network tests", detail: "Run tests from the router itself."),
    ]

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: 3), spacing: 18) {
                ForEach(features) { feature in
                    VStack(spacing: 5) {
                        OnboardingArt(motif: feature.motif, tint: feature.tint, size: 44)
                        Text(feature.title).font(.system(size: 12, weight: .semibold))
                        Text(feature.detail)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("You can set up SSH later, or turn it off any time, in Settings › Router.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// The three notes under the key chooser, verbatim from the design.
private struct KeyNotes: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bullet(Text("Your router must already accept this key. Add its public key in the router’s admin panel first."))
            bullet(Text("Keys protected by a passphrase aren’t supported."))
            bullet(Text(hiddenFiles))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var hiddenFiles: AttributedString {
        var text = AttributedString("Keys are usually in the hidden .ssh folder in your home folder. In the Open panel, press ")
        var keyCap = AttributedString(" ⇧⌘. ")
        keyCap.foregroundColor = .primary
        keyCap.backgroundColor = Color.primary.opacity(0.08)
        text += keyCap
        text += AttributedString(" to show hidden files.")
        return text
    }

    private func bullet(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.primary)
            text.fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SummaryRows: View {
    let summary: OnboardingSummary

    var body: some View {
        VStack(spacing: 0) {
            row(summary.router, motif: .router, tint: .teal)
            Divider()
            row(summary.ssh, motif: .terminal, tint: .purple)
            Divider()
            row(summary.adGuard, motif: .cert, tint: .green)
        }
        .onboardingBox()
    }

    private func row(_ row: OnboardingSummary.Row, motif: ArtMotif, tint: Color) -> some View {
        HStack(spacing: 12) {
            OnboardingArt(motif: motif, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 13, weight: .semibold))
                Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(row.state)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(row.tone == .connected ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

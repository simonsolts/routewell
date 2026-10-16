import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import RoutewellKit

/// The sheet the Wi-Fi screen shows.
struct WiFiSheetHost: View {
    let sheet: WiFiSheet
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            switch sheet {
            case .network: WiFiNetworkSheet()
            case .useOneName: WiFiUseOneNameSheet()
            case .guestIoT: WiFiGuestSheet()
            case .review: WiFiApplySheet()
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(environment.wifi.isApplying)
    }
}

// MARK: - Network sheet

struct WiFiNetworkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @State private var showsPassword = false
    @State private var advanced = false

    var body: some View {
        let controller = environment.wifi
        if let draft = controller.draft, let wireless = controller.base {
            let devices = controller.overview?.devices ?? []
            let plan = controller.plan(for: draft.change)
            let problems = draft.edit.problems
            VStack(alignment: .leading, spacing: 14) {
                WiFiShareCard(name: draft.original.name, security: draft.original.security, bands: draft.original.bands,
                              password: draft.original.password?.revealed ?? "", hidden: draft.original.hidden)
                form(draft)
                bandTiles(draft, wireless: wireless, devices: devices)
                if let moved = WiFiEditFormat.movedBands(draft, wireless: wireless).first,
                   let other = wireless.radio(moved)?.mainNetwork?.ssid {
                    Text("The router keeps one main network per band. \(WiFiFormat.band(moved)) moves from \(other) to this network.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                advancedSection(draft)
                if let problem = problems.first {
                    Label(WiFiEditFormat.problem(problem), systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red)
                }
                HStack(spacing: 10) {
                    if let plan, let line = WiFiEditFormat.mustJoinLine(plan, devices: devices) {
                        Label(line, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Cancel", role: .cancel) { controller.closeSheet() }
                        .keyboardShortcut(.cancelAction)
                    Button("Apply…") { controller.review(draft.change) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.hasChanges || !problems.isEmpty || plan?.isEmpty != false || !controller.canEdit)
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WiFiNetworkDraft, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { environment.wifi.draft?[keyPath: keyPath] ?? fallback },
                set: { environment.wifi.draft?[keyPath: keyPath] = $0 })
    }

    private func form(_ draft: WiFiNetworkDraft) -> some View {
        WiFiBox {
            row("Name") {
                TextField("Name", text: binding(\.name, fallback: "")).textFieldStyle(.roundedBorder).frame(width: 220)
                    .labelsHidden()
            }
            Divider().padding(.leading, 14)
            row("Password") {
                HStack(spacing: 4) {
                    Group {
                        if showsPassword {
                            TextField("Password", text: binding(\.password, fallback: ""))
                        } else {
                            SecureField("Password", text: binding(\.password, fallback: ""))
                        }
                    }
                    .textFieldStyle(.roundedBorder).frame(width: 196).labelsHidden()
                    Button { showsPassword.toggle() } label: { Image(systemName: showsPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                }
            }
            Divider().padding(.leading, 14)
            row("Security", help: draft.bands.contains(.ghz6) ? "6 GHz allows only WPA3. Turn off 6 GHz to choose another mode." : nil) {
                Picker("Security", selection: Binding(get: { environment.wifi.draft?.effectiveSecurity ?? .wpa3 },
                                                      set: { environment.wifi.draft?.security = $0 })) {
                    ForEach(WiFiEditFormat.securityChoices(current: draft.original.security), id: \.self) { security in
                        Text(WiFiFormat.security(security)).tag(security)
                    }
                }
                .labelsHidden().frame(width: 150)
                .disabled(draft.bands.contains(.ghz6))
            }
            Divider().padding(.leading, 14)
            row("Visible") {
                Toggle("Visible", isOn: binding(\.visible, fallback: true)).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    static let sshOnly = "Routewell changes this over SSH; GL's web page has no switch for it, and a save there can undo it."

    /// A switch, or the value as text when it cannot change.
    @ViewBuilder private func optionalSwitch(_ title: String, value: Bool?, writable: Bool, keyPath: WritableKeyPath<WiFiNetworkDraft, Bool?>) -> some View {
        if writable, let value {
            Toggle(title, isOn: Binding(get: { environment.wifi.draft?[keyPath: keyPath] ?? value },
                                        set: { environment.wifi.draft?[keyPath: keyPath] = $0 }))
                .toggleStyle(.switch).labelsHidden()
        } else {
            Text(WiFiEditFormat.onOff(value)).foregroundStyle(.secondary)
        }
    }

    private func row<Content: View>(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            HelpLabel(title: title, help: help)
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func bandTiles(_ draft: WiFiNetworkDraft, wireless: WirelessStatus, devices: [WiFiDevice]) -> some View {
        HStack(spacing: 8) {
            ForEach(WirelessBand.allCases, id: \.self) { band in
                let on = draft.bands.contains(band)
                let available = wireless.radio(band)?.mainNetwork != nil
                Button {
                    if on { environment.wifi.draft?.bands.remove(band) } else { environment.wifi.draft?.bands.insert(band) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            BandDot(band: band)
                            Text(WiFiFormat.band(band)).fontWeight(.medium)
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? band.color : .secondary).accessibilityHidden(true)
                        }
                        Text(WiFiEditFormat.bandTile(band, draft: draft, wireless: wireless, devices: devices))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(on ? band.color.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? band.color.opacity(0.6) : Color(nsColor: .separatorColor)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!available || (on && draft.bands.count == 1))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func advancedSection(_ draft: WiFiNetworkDraft) -> some View {
        DisclosureGroup("Advanced", isExpanded: $advanced) {
            WiFiBox {
                row("Random hardware address", help: "The network uses a made-up BSSID. Leave on unless a device needs a fixed one.") {
                    Toggle("Random hardware address", isOn: binding(\.randomBSSID, fallback: true)).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 14)
                row("Isolate devices", help: "Devices on the main networks cannot reach each other. The router sets this for all main network names at once.") {
                    if draft.isolate != nil {
                        Toggle("Isolate devices", isOn: Binding(get: { environment.wifi.draft?.isolate ?? false },
                                                                set: { environment.wifi.draft?.isolate = $0 }))
                            .toggleStyle(.switch).labelsHidden()
                    } else {
                        Text(WiFiFormat.dash).foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.leading, 14)
                row("Roaming help (802.11k/v)", help: "Tells devices about the other bands so they can move to a better one. \(Self.sshOnly)") {
                    optionalSwitch("Roaming help", value: draft.roamingHelp, writable: draft.canWriteRoaming, keyPath: \.roamingHelp)
                }
                Divider().padding(.leading, 14)
                row("Fast roaming (802.11r)", help: "Helps only with more than one access point. \(Self.sshOnly)") {
                    optionalSwitch("Fast roaming", value: draft.fastRoaming, writable: draft.canWriteRoaming, keyPath: \.fastRoaming)
                }
            }
            .padding(.top, 6)
        }
    }
}

/// The network's header card: name, security, bands, and the code to join.
struct WiFiShareCard: View {
    let name: String
    let security: WiFiSecurity?
    let bands: [WirelessBand]
    let password: String
    let hidden: Bool

    var body: some View {
        let colors = bands.sorted().map(\.color)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "wifi").font(.title2.weight(.semibold)).accessibilityHidden(true)
                Text(name).font(.title3.weight(.semibold)).lineLimit(1)
                Label(WiFiFormat.security(security), systemImage: security?.isSecured == false ? "lock.open" : "lock").font(.callout)
                HStack(spacing: 4) {
                    ForEach(bands.sorted(), id: \.self) { band in
                        Text(WiFiFormat.band(band)).font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 8)
            if let image = WiFiJoinCode.image(WiFiEditFormat.joinCode(name: name, password: password, security: security, hidden: hidden)) {
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: 92, height: 92)
                    .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("QR code to join \(name)")
            }
        }
        .padding(16)
        .background(LinearGradient(colors: colors.isEmpty ? [.blue] : colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

enum WiFiJoinCode {
    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

// MARK: - Use One Name

struct WiFiUseOneNameSheet: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.wifi
        let groups = controller.overview?.groups.filter { $0.kind == .main } ?? []
        let keep = controller.keepName ?? groups.first?.name ?? ""
        let change = controller.useOneNameChange(keeping: keep)
        let plan = change.flatMap(controller.plan(for:))
        let devices = controller.overview?.devices.filter { $0.kind == .main && !$0.viaLink } ?? []
        VStack(alignment: .leading, spacing: 16) {
            Text("Use one name on all bands").font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { group in WiFiMiniCard(network: WiFiMiniNetwork(name: group.name, bands: group.bands)) }
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    WiFiMiniCard(network: WiFiMiniNetwork(name: keep, bands: change?.networks.first?.bands ?? []), after: true)
                    if let plan {
                        let joinAgain = plan.mustJoin.count
                        Text("\(max(0, devices.count - joinAgain)) keep working · \(joinAgain) join again")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Text("Keep the name").font(.callout).foregroundStyle(.secondary)
                Picker("Keep the name", selection: Binding(get: { keep }, set: { controller.keepName = $0 })) {
                    ForEach(groups) { group in Text(group.name).tag(group.name) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { controller.closeSheet() }.keyboardShortcut(.cancelAction)
                Button("Review…") { if let change { controller.review(change) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(change == nil || plan?.isEmpty != false || !controller.canEdit)
            }
        }
    }
}

struct WiFiMiniCard: View {
    let network: WiFiMiniNetwork
    var after = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(network.name).fontWeight(.semibold).lineLimit(1)
            HStack(spacing: 4) {
                ForEach(network.bands, id: \.self) { band in BandPill(band: band) }
            }
        }
        .padding(10)
        .frame(minWidth: 170, alignment: .leading)
        .background(after ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(after ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Review and apply

struct WiFiApplySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.wifi
        if let run = controller.run {
            if let outcome = run.outcome {
                WiFiApplyResult(page: WiFiOutcomePresentation(outcome, run: run))
            } else {
                WiFiApplyProgress(run: run)
            }
        } else if let change = controller.pending, let wireless = controller.base, let plan = controller.plan(for: change) {
            review(WiFiReviewPresentation(change: change, plan: plan, wireless: wireless, sections: controller.baseSections))
        }
    }

    private func review(_ page: WiFiReviewPresentation) -> some View {
        let controller = environment.wifi
        return VStack(alignment: .leading, spacing: 14) {
            Text(page.title).font(.title3.weight(.semibold))
            if page.before != page.after {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) { ForEach(page.before) { WiFiMiniCard(network: $0) } }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) { ForEach(page.after) { WiFiMiniCard(network: $0, after: true) } }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(page.changes, id: \.self) { line in
                    Label(line, systemImage: "pencil").font(.callout)
                }
            }
            WiFiBox {
                ForEach(Array(page.impacts.enumerated()), id: \.element.id) { index, impact in
                    if index > 0 { Divider().padding(.leading, 44) }
                    HStack(spacing: 10) {
                        Image(systemName: Self.symbol(impact.kind)).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("\(Text(impact.bold).fontWeight(.semibold)) \(Text(impact.rest).foregroundStyle(.secondary))")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
            if let hint = page.ethernetHint {
                Label(hint, systemImage: "cable.connector").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { controller.closeSheet() }.keyboardShortcut(.cancelAction)
                Button("Apply") { controller.apply() }.keyboardShortcut(.defaultAction).disabled(!controller.canEdit)
            }
        }
    }

    static func symbol(_ kind: WiFiReviewPresentation.Impact.Kind) -> String {
        switch kind {
        case .restart: "wifi"
        case .devices: "person.2"
        case .thisMac: "laptopcomputer"
        }
    }
}

/// The progress trail of an apply.
struct WiFiApplyProgress: View {
    let run: WiFiApplyRun

    var body: some View {
        let names = WiFiReviewPresentation.trail(macDrops: run.plan.thisMac.drops)
        let current = WiFiReviewPresentation.trailIndex(run.step)
        return VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(WiFiReviewPresentation.progressTitle(run.step, plan: run.plan)).font(.headline)
            HStack(spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    if index > 0 {
                        Rectangle().fill(index <= current ? Color.accentColor : Color(nsColor: .separatorColor)).frame(width: 28, height: 2)
                    }
                    Image(systemName: index < current ? "checkmark.circle.fill" : index == current ? "circle.inset.filled" : "circle")
                        .foregroundStyle(index <= current ? Color.accentColor : .secondary)
                        .help(name)
                        .accessibilityLabel("\(name), \(index < current ? "done" : index == current ? "now" : "next")")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

/// The last screen of an apply that did not end in the guest share card.
struct WiFiApplyResult: View {
    let page: WiFiOutcomePresentation
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    var body: some View {
        let controller = environment.wifi
        return VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: page.tone == .success ? "checkmark.circle.fill" : page.tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(page.tone == .success ? .green : page.tone == .warning ? .orange : .secondary)
                    .accessibilityHidden(true)
                Text(page.title).font(.headline)
                Text(page.text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                if page.showsWiFiSettings {
                    Button("Open Wi-Fi Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") { openURL(url) }
                    }
                }
                Button(page.tone == .success ? "Done" : "Close") { controller.closeSheet() }.keyboardShortcut(.defaultAction)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

import AppKit
import SwiftUI
import RoutewellKit

/// Guest and IoT: set up and Turn On, or change and turn off an on network;
/// after Turn On, the share card and, for IoT, the devices that joined.
struct WiFiGuestSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var advanced = false
    @State private var copied = false

    var body: some View {
        let controller = environment.wifi
        if let draft = controller.guestDraft {
            if let run = controller.run {
                if case .verifiedSuccess? = run.outcome, !draft.isOn {
                    ready(draft)
                } else if let outcome = run.outcome {
                    WiFiApplyResult(page: WiFiOutcomePresentation(outcome, run: run))
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Turning on \(draft.name)…").font(.headline)
                        Text("New networks start, \(WiFiReviewPresentation.newNetworks).").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
            } else {
                setup(draft)
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WiFiGuestDraft, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { environment.wifi.guestDraft?[keyPath: keyPath] ?? fallback },
                set: { environment.wifi.guestDraft?[keyPath: keyPath] = $0 })
    }

    private func header(_ kind: WiFiNetworkKind, ready: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind == .iot ? "house.fill" : "person.fill")
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background((kind == .iot ? Color.orange : .green).gradient, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(ready ? "\(WiFiGuestFormat.title(kind)) is on" : WiFiGuestFormat.title(kind)).font(.title3.weight(.semibold))
                Text(WiFiGuestFormat.subtitle(kind, ready: ready)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Set up, change, turn off

    private func setup(_ draft: WiFiGuestDraft) -> some View {
        let controller = environment.wifi
        let change = draft.change
        let plan = controller.plan(for: change)
        let problems = draft.edit.problems
        return VStack(alignment: .leading, spacing: 14) {
            header(draft.kind, ready: false)
            if draft.kind == .guest {
                WiFiShareCard(name: draft.name, security: draft.effectiveSecurity, bands: draft.bands.sorted(), password: draft.password,
                              hidden: !draft.visible)
            }
            form(draft)
            bandTiles(draft)
            if draft.kind == .iot, !draft.isOn { devicesToMove(draft) }
            reachBox(draft.kind == .iot ? "IoT devices can reach" : "Guests can reach", rows: WiFiGuestFormat.reach(draft))
            if draft.kind == .iot { reachBox("Can reach IoT devices", rows: WiFiGuestFormat.into) }
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                WiFiBox {
                    row("Address range") { Text(draft.range ?? WiFiFormat.dash).monospaced().foregroundStyle(.secondary) }
                    Divider().padding(.leading, 14)
                    row("Visible") { Toggle("Visible", isOn: binding(\.visible, fallback: true)).toggleStyle(.switch).labelsHidden() }
                }
                .padding(.top, 6)
            }
            HStack(spacing: 10) {
                if let problem = problems.first {
                    Label(WiFiEditFormat.problem(problem), systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                } else if !draft.isOn {
                    Label("New networks start, \(WiFiReviewPresentation.newNetworks)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if draft.isOn {
                    Button("Turn Off…") { controller.review(draft.turnOffChange) }.disabled(!controller.canEdit)
                }
                Button("Cancel", role: .cancel) { controller.closeSheet() }.keyboardShortcut(.cancelAction)
                if draft.isOn {
                    Button("Apply…") { controller.review(change) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!problems.isEmpty || plan?.isEmpty != false || !controller.canEdit)
                } else {
                    Button("Turn On") { controller.turnOn() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!problems.isEmpty || plan?.isEmpty != false || !controller.canEdit)
                }
            }
        }
    }

    private func form(_ draft: WiFiGuestDraft) -> some View {
        WiFiBox {
            row("Name") {
                TextField("Name", text: binding(\.name, fallback: "")).textFieldStyle(.roundedBorder).frame(width: 220).labelsHidden()
            }
            Divider().padding(.leading, 14)
            row("Password") {
                HStack(spacing: 4) {
                    TextField("Password", text: binding(\.password, fallback: "")).textFieldStyle(.roundedBorder).frame(width: 196).labelsHidden()
                    Button { environment.wifi.guestDraft?.password = WiFiGuestDraft.newPassword() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Make a new password")
                        .accessibilityLabel("Make a new password")
                }
            }
            Divider().padding(.leading, 14)
            if draft.kind == .iot {
                row("Security", help: "Many smart home devices cannot join with WPA3. WPA2 works with almost all of them.") {
                    Picker("Security", selection: binding(\.security, fallback: .wpa2)) {
                        ForEach([WiFiSecurity.wpa2, .wpa2WPA3], id: \.self) { Text(WiFiFormat.security($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
            } else {
                row("Security", help: "WPA3 when 6 GHz is on, else WPA2/WPA3.") {
                    Text(WiFiFormat.security(draft.effectiveSecurity)).foregroundStyle(.secondary)
                }
            }
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

    private func bandTiles(_ draft: WiFiGuestDraft) -> some View {
        let wireless = environment.wifi.base
        return HStack(spacing: 8) {
            ForEach(WirelessBand.allCases, id: \.self) { band in
                let on = draft.bands.contains(band)
                let available = wireless?.radio(band)?.network(draft.kind) != nil
                Button {
                    if on { environment.wifi.guestDraft?.bands.remove(band) } else { environment.wifi.guestDraft?.bands.insert(band) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            BandDot(band: band)
                            Text(WiFiFormat.band(band)).fontWeight(.medium)
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? band.color : .secondary).accessibilityHidden(true)
                        }
                        Text(available ? WiFiGuestFormat.bandTile(band, kind: draft.kind) : "Not available")
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
                .help(available ? "" : "The router has no \(draft.kind == .iot ? "IoT" : "guest") network on \(WiFiFormat.band(band)).")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func devicesToMove(_ draft: WiFiGuestDraft) -> some View {
        let controller = environment.wifi
        let candidates = controller.moveCandidates
        let printerChosen = draft.moving.contains(where: controller.isPrinter)
        return VStack(alignment: .leading, spacing: 6) {
            HelpLabel(title: "Devices to move",
                      help: "Routewell cannot move a device. After you turn on the network, join it from each device's own app. Routewell shows when each one arrives.")
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No devices on 2.4 GHz now.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(candidates) { device in
                        let chosen = draft.moving.contains(device.mac)
                        Button {
                            if chosen { controller.guestDraft?.moving.remove(device.mac) } else { controller.guestDraft?.moving.insert(device.mac) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: chosen ? "checkmark" : "plus").font(.caption2.weight(.bold)).accessibilityHidden(true)
                                Text(WiFiFormat.deviceName(device)).lineLimit(1)
                                if controller.isPrinter(device.mac) {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(WiFiGuestFormat.printerWarning)
                                }
                            }
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(chosen ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(chosen ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
            if printerChosen {
                Text(WiFiGuestFormat.printerWarning).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private func reachBox(_ title: String, rows: [WiFiGuestFormat.Reach]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            WiFiBox {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, reach in
                    if index > 0 { Divider().padding(.leading, 14) }
                    row(reach.title, help: reach.help) {
                        HStack(spacing: 6) {
                            if reach.locked {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary).accessibilityLabel("Locked")
                            }
                            if let on = reach.on {
                                Toggle(reach.title, isOn: reachBinding(reach.row, value: on)).toggleStyle(.switch).labelsHidden()
                                    .disabled(reach.locked)
                            } else {
                                Text(WiFiFormat.dash).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reachBinding(_ row: WiFiGuestFormat.Reach.Row, value: Bool) -> Binding<Bool> {
        switch row {
        case .eachOther: Binding(get: { environment.wifi.guestDraft?.eachOther ?? value }, set: { environment.wifi.guestDraft?.eachOther = $0 })
        case .modem: Binding(get: { environment.wifi.guestDraft?.reachesModem ?? value }, set: { environment.wifi.guestDraft?.reachesModem = $0 })
        default: .constant(value)
        }
    }

    // MARK: Ready

    private func ready(_ draft: WiFiGuestDraft) -> some View {
        let controller = environment.wifi
        let moving = draft.movingDevices
        let joined = controller.joinedIoT(Set(moving.map(\.mac)))
        return VStack(alignment: .leading, spacing: 14) {
            header(draft.kind, ready: true)
            WiFiShareCard(name: draft.name, security: draft.effectiveSecurity, bands: draft.bands.sorted(), password: draft.password,
                          hidden: !draft.visible)
            HStack {
                Text("Password").foregroundStyle(.secondary)
                Text(draft.password).monospaced().textSelection(.enabled)
            }
            .font(.callout)
            if draft.kind == .guest {
                Text("Guests point their phone camera at the code to join.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else if !moving.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Join from each device's app").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    WiFiBox {
                        ForEach(Array(moving.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { Divider().padding(.leading, 14) }
                            let done = joined.contains(device.mac)
                            HStack(spacing: 8) {
                                Text(WiFiFormat.deviceName(device))
                                Spacer()
                                Text(done ? "Joined" : "Waiting").foregroundStyle(.secondary)
                                if done {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                StatusDot(tone: .healthy)
                Text(draft.kind == .iot ? WiFiGuestFormat.joinedLine(joined: joined.count, of: moving.count) : WiFiGuestFormat.onLine(draft.bands))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if draft.kind == .guest {
                    Button(copied ? "Copied" : "Copy Password") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.password, forType: .string)
                        copied = true
                    }
                }
                Button("Done") { controller.closeSheet() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

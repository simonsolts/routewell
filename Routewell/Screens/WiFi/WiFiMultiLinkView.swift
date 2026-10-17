import SwiftUI
import RoutewellKit

/// Multi-link is its own network on this router. Off: the Wi-Fi 7 devices
/// with today's rate, and Set Up Multi-Link…. On: the network, its devices,
/// and its settings; changes stay staged until Apply… in the apply bar.
struct WiFiMultiLinkView: View {
    let overview: WiFiOverview
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let air = environment.wifi.airState == .available ? model.wifiAir : nil
        switch model.wifi?.mlo {
        case .success(let mlo)?:
            let page = WiFiMultiLinkPresentation(mlo: mlo, devices: overview.devices, air: air)
            if page.isOn { on(page, mlo: mlo) } else { off(page, hasStations: overview.hasStations) }
        case .failure(let failure)?:
            ContentUnavailableView {
                Label("Multi-link unknown", systemImage: "link")
            } description: {
                Text(failure.failureCategory.message)
            }
        case nil:
            ProgressView("Loading multi-link…").frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func off(_ page: WiFiMultiLinkPresentation, hasStations: Bool) -> some View {
        let controller = environment.wifi
        return WiFiBox {
            VStack(spacing: 14) {
                Image(systemName: "link").font(.title.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(WiFiMLOStyle.violet, in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                Text("Multi-link is off").font(.title2.weight(.bold))
                Text(hasStations ? page.subtitle : "Which devices use Wi-Fi 7 is shown with SSH.")
                    .foregroundStyle(.secondary)
                if !page.cards.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(page.cards) { card in WiFiLinkCard(card: card) }
                    }
                    .frame(maxWidth: 760)
                }
                Button("Set Up Multi-Link…") { controller.openMultiLinkSetup() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!controller.canEdit || model.wifi.flatMap { try? $0.mlo.get().main } == nil)
                if hasStations, page.others > 0 {
                    Text("Your other \(WiFiFormat.devices(page.others)) stay as they are.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
    }

    private func on(_ page: WiFiMultiLinkPresentation, mlo: MLOConfiguration) -> some View {
        let controller = environment.wifi
        let draft = controller.mloEdits
        let shown = controller.mloShown
        let enabled = shown?.enabled ?? true
        let bands = shown?.bands ?? Set(page.bands)
        let fastName = shown?.fastName
        return VStack(alignment: .leading, spacing: 16) {
            WiFiBox {
                HStack(spacing: 12) {
                    Image(systemName: "link").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(WiFiMLOStyle.violet, in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.name ?? WiFiFormat.dash).font(.title3.weight(.bold))
                        Text(!enabled ? "Off after you apply" : overview.hasStations ? page.subtitle : "Multi-link on \(page.bands.map(WiFiFormat.band).joined(separator: " + "))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Multi-link", isOn: Binding(get: { enabled }, set: { on in controller.editMLO { $0.enabled = on } }))
                        .toggleStyle(.switch).controlSize(.large).labelsHidden()
                        .disabled(!controller.canEdit)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            if !page.cards.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(page.cards) { card in WiFiLinkCard(card: card) }
                }
            }
            WiFiMLOBandTiles(bands: bands, supported: mlo.supportedBands, editable: controller.canEdit) { band in
                controller.editMLO { draft in
                    if draft.bands.contains(band) { draft.bands.remove(band) } else { draft.bands.insert(band) }
                }
            }
            WiFiBox {
                row("Name") {
                    TextField("Name", text: Binding(get: { shown?.name ?? "" }, set: { name in controller.editMLO { $0.name = name } }))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 210).labelsHidden()
                        .disabled(!controller.canEdit)
                }
                Divider().padding(.leading, 12)
                WiFiMLOPasswordRows(fastName: fastName, samePassword: shown?.samePassword ?? false,
                                    password: shown?.password ?? "", editable: controller.canEdit && fastName != nil) { same in
                    controller.editMLO { $0.samePassword = same }
                } setPassword: { password in
                    controller.editMLO { $0.password = password }
                }
                Divider().padding(.leading, 12)
                row("Security", help: "6 GHz allows only WPA3.") {
                    Text(WiFiFormat.security(mlo.main?.encryption)).foregroundStyle(.secondary)
                }
                Divider().padding(.leading, 12)
                row("Link mode", help: "EMLSR: the device listens on both bands and sends on the better one. It uses less battery than sending on both at once.") {
                    Text(page.linkMode).foregroundStyle(.secondary)
                }
            }
            if let problem = draft?.network.problems.first {
                Label(WiFiEditFormat.problem(problem), systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
            if overview.hasStations, page.others > 0 {
                Text("\(WiFiFormat.devices(page.others)) cannot use multi-link").font(.subheadline).foregroundStyle(.secondary)
            }
            if let draft, draft.hasChanges {
                HStack(spacing: 10) {
                    Text(WiFiMLOFormat.applyBar(draft)).fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Button("Revert") { controller.revertMLO() }
                    Button("Apply…") { controller.reviewMLO() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!controller.canEdit || !draft.network.problems.isEmpty)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5))
            }
        }
    }

    private func row<Content: View>(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            HelpLabel(title: title, help: help)
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}

enum WiFiMLOStyle {
    static let violet = LinearGradient(colors: [Color(red: 0.82, green: 0.54, blue: 1), Color(red: 0.61, green: 0.25, blue: 0.88)],
                                       startPoint: .top, endPoint: .bottom)
}

/// "Same password as <network>" and, when off, the password field.
struct WiFiMLOPasswordRows: View {
    let fastName: String?
    let samePassword: Bool
    let password: String
    let editable: Bool
    let setSame: @MainActor @Sendable (Bool) -> Void
    let setPassword: @MainActor @Sendable (String) -> Void

    var body: some View {
        HStack {
            Text("Same password as \(fastName ?? WiFiFormat.dash)")
            Spacer(minLength: 12)
            Toggle("Same password", isOn: Binding(get: { samePassword }, set: setSame)).toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(!editable)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 40)
        if !samePassword {
            Divider().padding(.leading, 12)
            HStack {
                Text("Password")
                Spacer(minLength: 12)
                TextField("Password", text: Binding(get: { password }, set: setPassword))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 186).labelsHidden()
                Button { setPassword(WiFiGuestDraft.newPassword()) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Make a new password")
                    .accessibilityLabel("Make a new password")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 40)
        }
    }
}

/// Three band tiles. With two bands on, those two cannot turn off.
struct WiFiMLOBandTiles: View {
    let bands: Set<WirelessBand>
    let supported: [WirelessBand]
    let editable: Bool
    let toggle: (WirelessBand) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WirelessBand.allCases, id: \.self) { band in
                let on = bands.contains(band)
                let available = supported.contains(band)
                let locked = on && bands.count <= 2
                Button { toggle(band) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            BandDot(band: band)
                            Text(WiFiFormat.band(band)).fontWeight(.semibold)
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Color.accentColor : .secondary).accessibilityHidden(true)
                        }
                        Text(available ? WiFiMLOFormat.bandTile(band) : "Not available").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(on ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!editable || !available || locked)
                .help(locked ? "Multi-link needs at least 2 bands" : available ? "" : "The router has no multi-link on \(WiFiFormat.band(band)).")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// One device: its link rate as a bar. Off: the band it uses now. On: the
/// total rate, because the router does not report one per band.
struct WiFiLinkCard: View {
    let card: WiFiMultiLinkPresentation.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer").font(.system(size: 17)).foregroundStyle(.white).frame(width: 34, height: 34)
                    .background(WiFiMLOStyle.violet, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name).fontWeight(.semibold)
                    Text(card.sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(card.rate).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("Gbps").font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quinary)
                    Rectangle().fill(card.band.map { AnyShapeStyle($0.color.gradient) } ?? AnyShapeStyle(WiFiMLOStyle.violet))
                        .frame(width: max(6, proxy.size.width * card.fraction))
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Group {
                if let band = card.band {
                    Label { Text(card.legend) } icon: { BandDot(band: band) }
                } else {
                    Text(card.legend)
                }
            }
            .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

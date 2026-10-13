import SwiftUI
import RoutewellKit

/// Multi-link is its own network on this router. Off: the Wi-Fi 7 devices
/// with today's rate and a dashed segment for a second band (no number:
/// nothing reports one). On: the network, its devices, and its settings.
/// Read-only; setup and changes come in a later version.
struct WiFiMultiLinkView: View {
    let overview: WiFiOverview
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let air = environment.wifi.airState == .available ? model.wifiAir : nil
        switch model.wifi?.mlo {
        case .success(let mlo)?:
            let page = WiFiMultiLinkPresentation(mlo: mlo, devices: overview.devices, air: air)
            if page.isOn { on(page) } else { off(page, hasStations: overview.hasStations) }
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
        WiFiBox {
            VStack(spacing: 12) {
                Image(systemName: "link").font(.title.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityHidden(true)
                Text("Multi-link is off").font(.title2.weight(.bold))
                Text(hasStations ? page.subtitle : "Which devices use Wi-Fi 7 is shown with SSH.")
                    .foregroundStyle(.secondary)
                if !page.cards.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(page.cards) { card in WiFiLinkCard(card: card, isOn: false) }
                    }
                    .frame(maxWidth: 640)
                }
                if hasStations, page.others > 0 {
                    Text("Your other \(WiFiFormat.devices(page.others)) stay as they are.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func on(_ page: WiFiMultiLinkPresentation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            WiFiBox {
                HStack(spacing: 12) {
                    Image(systemName: "link").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.name ?? WiFiFormat.dash).font(.title3.weight(.bold))
                        Text(overview.hasStations ? page.subtitle : "Multi-link on \(page.bands.map(WiFiFormat.band).joined(separator: " + "))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Multi-link", isOn: .constant(true)).toggleStyle(.switch).labelsHidden().disabled(true)
                }
                .padding(14)
            }
            if !page.cards.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(page.cards) { card in WiFiLinkCard(card: card, isOn: true) }
                }
            }
            HStack(spacing: 8) {
                ForEach(WirelessBand.allCases, id: \.self) { band in
                    BandPill(band: band, on: page.bands.contains(band))
                }
            }
            WiFiBox {
                LabelValueRow(label: "Name", value: page.name ?? WiFiFormat.dash)
                Divider().padding(.leading, 12)
                HStack {
                    HelpLabel(title: "Security", help: "6 GHz allows only WPA3.")
                    Spacer()
                    Text(WiFiFormat.security(model.wifi.flatMap { try? $0.mlo.get().main?.encryption } ?? nil)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Divider().padding(.leading, 12)
                HStack {
                    HelpLabel(title: "Link mode",
                              help: "EMLSR: the device listens on both bands and sends on the better one. It uses less battery than sending on both at once.")
                    Spacer()
                    Text(page.linkMode).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            if overview.hasStations, page.others > 0 {
                Text("\(WiFiFormat.devices(page.others)) cannot use multi-link").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// One device: its link rate as a bar, and for "off" a dashed segment
/// for the band multi-link could add.
struct WiFiLinkCard: View {
    let card: WiFiMultiLinkPresentation.Card
    let isOn: Bool

    var body: some View {
        WiFiBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.secondary).frame(width: 26, height: 26)
                        .background(.quaternary, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.name).fontWeight(.semibold)
                        Text(card.sub).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(card.rate).font(.title3.weight(.semibold)).monospacedDigit()
                        Text("Gbps").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        Rectangle().fill((card.band?.color ?? .secondary).gradient)
                            .frame(width: max(6, proxy.size.width * card.fraction * (isOn ? 1 : 0.7)))
                        if !isOn {
                            Rectangle().fill(.clear)
                                .overlay(Rectangle().stroke(WirelessBand.ghz5.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                .frame(width: proxy.size.width * 0.25)
                                .help("5 GHz with multi-link")
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 3) {
                    Label { Text(card.legend) } icon: { BandDot(band: card.band ?? .ghz6) }
                    if !isOn {
                        Label { Text("+ 5 GHz with multi-link") } icon: { BandDot(band: .ghz5) }
                    }
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

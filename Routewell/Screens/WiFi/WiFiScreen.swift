import SwiftUI
import RoutewellKit

/// Wi-Fi: Overview, Radios, and Multi-link, with the network sheet, Use One
/// Name, and Review and apply. The toolbar's tab bar lives in `MainWindow`.
struct WiFiScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    private var tab: WiFiTab { WiFiTab(rawValue: model.subpages[.wifi] ?? "") ?? .overview }

    var body: some View {
        Group {
            if model.wifiCapability.state == .unsupported {
                FeatureUnavailableView(title: "Wi-Fi", capability: model.wifiCapability)
            } else if let wireless = model.wireless, let overview = environment.wifi.overview {
                VStack(spacing: 0) {
                    WiFiNotes()
                    ScrollView {
                        Group {
                            switch tab {
                            case .overview: WiFiOverviewView(overview: overview, wireless: wireless)
                            case .radios: WiFiRadiosView(overview: overview, wireless: wireless)
                            case .multiLink: WiFiMultiLinkView(overview: overview)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else if model.session.lease == nil && !model.session.switching {
                ContentUnavailableView("No router connected", systemImage: "wifi", description: Text("Connect a router to see its Wi-Fi."))
            } else if let failure = model.wifiFreshness.failure {
                ContentUnavailableView {
                    Label("Wi-Fi unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure.failureCategory.message)
                } actions: {
                    Button("Refresh") { environment.refresh.refreshNow() }
                        .disabled(!environment.refresh.isAvailable || model.isRefreshing)
                }
            } else {
                ProgressView("Loading Wi-Fi…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: Binding(get: { environment.wifi.sheet }, set: { if $0 == nil { environment.wifi.closeSheet() } })) { sheet in
            WiFiSheetHost(sheet: sheet)
        }
    }
}

/// The freshness note after a failed read, and the one SSH note.
struct WiFiNotes: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let state = environment.wifi.airState
        let freshness = Self.freshness(model, airState: state)
        if freshness.failure != nil || state != .available {
            VStack(alignment: .leading, spacing: 6) {
                RouterFreshnessNote(freshness: freshness)
                if let note = Self.sshNote(state) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(note).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if state != .checking {
                            Button("Open Router Settings") { SSHRequiredView.openRouterSettings(model, open: { openSettings() }) }
                                .controlSize(.small)
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// The RPC reads' freshness, else the SSH reads' while their last values
    /// are on screen.
    static func freshness(_ model: AppModel, airState: WiFiAirState) -> Freshness {
        guard model.wifiFreshness.failure == nil, airState == .available, model.wifiAir != nil else { return model.wifiFreshness }
        return model.wifiAirFreshness
    }

    static func sshNote(_ state: WiFiAirState) -> String? {
        switch state {
        case .notSetUp: "Signal, Wi-Fi versions, and the channels Auto skips need SSH."
        case .checking: "Checking the SSH connection…"
        case .notWorking: "SSH is not working, so signal, Wi-Fi versions, and the channels Auto skips are not shown."
        case .available: nil
        }
    }
}

extension WirelessBand {
    var color: Color {
        switch self { case .ghz2_4: .teal; case .ghz5: .indigo; case .ghz6: .purple }
    }
}

/// A small coloured band dot.
struct BandDot: View {
    let band: WirelessBand
    var body: some View {
        Circle().fill(band.color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// "2.4 GHz" with its dot, filled when the network uses the band.
struct BandPill: View {
    let band: WirelessBand
    var on = true

    var body: some View {
        HStack(spacing: 4) {
            BandDot(band: band).opacity(on ? 1 : 0.35)
            Text(WiFiFormat.band(band))
        }
        .font(.caption)
        .foregroundStyle(on ? .primary : .tertiary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(on ? band.color.opacity(0.12) : .clear, in: Capsule())
        .overlay(Capsule().stroke(on ? .clear : Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// A rounded box like the other screens' insets.
struct WiFiBox<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }
}

/// A label with an ⓘ that shows its help on hover.
struct HelpLabel: View {
    let title: String
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let help {
                Image(systemName: "info.circle").foregroundStyle(.secondary).help(help).accessibilityLabel("About \(title)")
                    .accessibilityHint(help)
            }
        }
    }
}

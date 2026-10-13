import SwiftUI
import RoutewellKit

/// "How does each band use the air?": one lane per band and an inspector
/// for the selected one. Values only; nothing here changes the router.
struct WiFiRadiosView: View {
    let overview: WiFiOverview
    let wireless: WirelessStatus
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.wifi
        let air = controller.airState == .available ? model.wifiAir : nil
        let radios = wireless.radios.filter { $0.band != nil }.sorted { $0.band! < $1.band! }
        let selected = radios.first { $0.band == controller.selectedBand } ?? radios.first
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(radios, id: \.band) { radio in
                    WiFiLaneView(radio: radio, lane: WiFiLane(radio: radio, autoSkips: air?.autoSkips(device: radio.device)),
                                 selected: radio.band == selected?.band) {
                        if let band = radio.band { controller.selectedBand = band }
                    }
                }
                HStack(spacing: 16) {
                    Label { Text("Your channel") } icon: {
                        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3).fill(Color.accentColor).frame(width: 14, height: 9)
                    }
                    Label { Text("DFS (shared with radar)") } icon: { WiFiHatch().frame(width: 14, height: 9) }
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            .frame(maxWidth: .infinity)
            if let selected, let band = selected.band {
                WiFiInspectorView(inspector: WiFiRadioInspector(radio: selected, band: band, devices: overview.devices, air: air))
                    .frame(width: 304)
            }
        }
    }
}

struct WiFiLaneView: View {
    let radio: WirelessRadio
    let lane: WiFiLane
    let selected: Bool
    let select: () -> Void

    var body: some View {
        let band = radio.band ?? .ghz5
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BandDot(band: band)
                    Text(WiFiFormat.band(band)).fontWeight(.semibold)
                    Text(Self.now(radio)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                }
                spectrum(band).frame(height: 96)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(WiFiFormat.band(band)), \(Self.now(radio))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func now(_ radio: WirelessRadio) -> String {
        let channel = WiFiFormat.channel(radio).map { "Channel \($0)" } ?? "Channel \(WiFiFormat.dash)"
        return "\(channel) · \(WiFiFormat.width(radio))\(radio.isAutoChannel == false ? " · Manual" : "")"
    }

    private func spectrum(_ band: WirelessBand) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let count = max(1, lane.channels.count)
            let step = width / Double(count)
            ZStack(alignment: .topLeading) {
                if let dfs = lane.dfsFraction {
                    WiFiHatch().frame(width: width * (dfs.upperBound - dfs.lowerBound), height: 74)
                        .offset(x: width * dfs.lowerBound, y: 4)
                }
                if let block = lane.blockFraction, let channel = WiFiFormat.channel(radio) {
                    UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                        .fill(band.color.gradient)
                        .overlay(alignment: .top) { Text("\(channel)").font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.top, 6) }
                        .frame(width: max(step, width * (block.upperBound - block.lowerBound)), height: 54)
                        .offset(x: width * block.lowerBound, y: 24)
                }
                Rectangle().fill(.separator).frame(height: 1).offset(y: 78)
                ForEach(Array(lane.channels.enumerated()), id: \.offset) { index, channel in
                    VStack(spacing: 2) {
                        Circle().fill(channel.psc ? band.color : .clear).frame(width: 4, height: 4)
                        Text("\(channel.number)")
                            .font(.system(size: 9.5)).monospacedDigit()
                            .foregroundStyle(lane.skipped(channel.number) ? .quaternary : .secondary)
                    }
                    .fixedSize()
                    .position(x: step * (Double(index) + 0.5), y: 88)
                    .opacity(count > 30 && index % 2 == 1 ? 0 : 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct WiFiInspectorView: View {
    let inspector: WiFiRadioInspector
    @State private var advancedOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wifi").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(inspector.band.color.gradient, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(WiFiFormat.band(inspector.band)).font(.title3.weight(.bold))
                    Text(inspector.deviceLine).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            WiFiBox {
                ForEach(Array(inspector.rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
                    HStack {
                        HelpLabel(title: row.label, help: row.help)
                        Spacer(minLength: 8)
                        Text(row.value).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                    if row.label == "Power" { ruler }
                }
            }
            DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
                WiFiBox {
                    ForEach(Array(inspector.advanced.enumerated()), id: \.offset) { _, row in
                        LabelValueRow(label: row.label, value: row.value)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    /// Where the band's devices sit, strong to weak. Hidden without signal.
    @ViewBuilder private var ruler: some View {
        if let ruler = inspector.ruler {
            if ruler.isEmpty {
                Text("No devices on \(WiFiFormat.band(inspector.band)) now").font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .topLeading) {
                        Capsule()
                            .fill(LinearGradient(colors: [.green.opacity(0.45), .green.opacity(0.15), .orange.opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                            .frame(height: 6).offset(y: 14)
                        Rectangle().fill(.orange).frame(width: 1, height: 18).offset(x: width * (30.0 / 45), y: 8)
                        ForEach(Array(ruler.enumerated()), id: \.offset) { _, device in
                            Circle().fill(inspector.band.color).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(device.weak ? Color.orange : Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                                .help(device.name)
                                .offset(x: width * device.position - 6, y: 11)
                        }
                        HStack {
                            Text("Strong")
                            Spacer()
                            Text("Weak")
                        }
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .offset(y: 32)
                    }
                }
                .frame(height: 46)
                .padding(.horizontal, 12).padding(.bottom, 8)
                .accessibilityElement()
                .accessibilityLabel("Signal of each device on this band")
            }
        }
    }
}

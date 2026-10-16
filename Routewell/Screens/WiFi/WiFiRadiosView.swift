import SwiftUI
import RoutewellKit

/// "How does each band use the air?": one lane per band and an inspector
/// for the selected one. Changes stay staged until Apply… in the apply bar.
struct WiFiRadiosView: View {
    let overview: WiFiOverview
    let wireless: WirelessStatus
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.wifi
        let air = controller.airState == .available ? model.wifiAir : nil
        let edits = controller.radioEdits
        let radios = wireless.radios.filter { $0.band != nil }.sorted { $0.band! < $1.band! }
        let selected = radios.first { $0.band == controller.selectedBand } ?? radios.first
        VStack(spacing: 14) {
            if let edits, edits.changeCount > 0 {
                WiFiApplyBar(edits: edits)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(radios, id: \.band) { radio in
                        let shown = radio.applying(radio.band.flatMap { edits?.current($0) })
                        let isSelected = radio.band == selected?.band
                        WiFiLaneView(radio: shown, lane: WiFiLane(radio: shown, autoSkips: Self.skips(radio, air: air, edits: edits)),
                                     selected: isSelected,
                                     pick: isSelected && shown.isAutoChannel == false && controller.canEdit ? { channel in
                                         if let band = radio.band { controller.pickChannel(band, channel) }
                                     } : nil) {
                            if let band = radio.band { controller.selectedBand = band }
                        }
                    }
                    HStack(spacing: 16) {
                        Label { Text("Your channel") } icon: {
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3).fill(Color.accentColor).frame(width: 14, height: 9)
                        }
                        Label { Text("DFS (shared with radar)") } icon: { WiFiHatch().frame(width: 14, height: 9) }
                        Spacer(minLength: 8)
                        Text(WiFiRadioFormat.country(air)).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
                .frame(maxWidth: .infinity)
                if let selected, let band = selected.band {
                    WiFiInspectorView(inspector: WiFiRadioInspector(wireless: wireless, band: band, devices: overview.devices, air: air,
                                                                    edits: edits, editable: controller.canEdit))
                        .frame(width: 304)
                }
            }
        }
    }

    /// The channels Auto skips: the staged DFS choice on 5 GHz, else the read.
    static func skips(_ radio: WirelessRadio, air: WiFiAir?, edits: WiFiRadioEdits?) -> [Int]? {
        if radio.band == .ghz5, let edits, let option = edits.change.options.first, case .autoSkips(let list) = option.setting { return list }
        return air?.autoSkips(device: radio.device)
    }
}

/// "N changes · <bands> restart", Revert, Apply….
struct WiFiApplyBar: View {
    let edits: WiFiRadioEdits
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.wifi
        HStack(spacing: 10) {
            Text(WiFiRadioFormat.applyBar(edits)).monospacedDigit()
            Spacer(minLength: 8)
            Button("Revert") { controller.revertRadios() }
            Button("Apply…") { controller.reviewRadios() }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canEdit)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5))
    }
}

struct WiFiLaneView: View {
    let radio: WirelessRadio
    let lane: WiFiLane
    let selected: Bool
    /// Set on the selected lane in Manual: a click on a channel picks it.
    var pick: ((Int) -> Void)?
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
                if let pick {
                    ForEach(Array(lane.channels.enumerated()), id: \.offset) { index, channel in
                        Button { pick(channel.number) } label: { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .frame(width: step, height: 96)
                            .offset(x: step * Double(index))
                            .help("Channel \(channel.number)")
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct WiFiInspectorView: View {
    let inspector: WiFiRadioInspector
    @Environment(AppEnvironment.self) private var environment
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
            if inspector.editable, let settings = inspector.settings {
                controls(settings)
            } else {
                values
            }
            if let warning = inspector.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controller: WiFiController { environment.wifi }

    private func edit(_ change: @escaping (inout WiFiRadioSettings) -> Void) {
        controller.editRadio(inspector.band, change)
    }

    private func row<Content: View>(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            HelpLabel(title: title, help: help)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ViewBuilder private func controls(_ settings: WiFiRadioSettings) -> some View {
        let band = inspector.band
        WiFiBox {
            row("Channel", help: WiFiRadioInspector.channelHelp) {
                Picker("Channel", selection: Binding(get: { settings.isAutoChannel }, set: { auto in controller.setAutoChannel(band, auto) })) {
                    Text("Auto").tag(true)
                    Text("Manual").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if !settings.isAutoChannel {
                Divider().padding(.leading, 12)
                row("Use channel") {
                    Picker("Use channel", selection: Binding(get: { settings.channel }, set: { controller.pickChannel(band, $0) })) {
                        ForEach(inspector.channels) { Text($0.label).tag($0.number) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Divider().padding(.leading, 12)
            row("Width") {
                HStack(spacing: 2) {
                    ForEach(inspector.widths) { choice in
                        Button(choice.label) { edit { $0.width = choice.width } }
                            .buttonStyle(WiFiSegmentStyle(on: settings.width == choice.width))
                            .disabled(choice.disabledReason != nil)
                            .help(choice.disabledReason ?? (choice.width.map { "\($0) MHz" } ?? "Auto width"))
                            .accessibilityLabel(choice.width.map { "\($0) MHz" } ?? "Auto width")
                            .accessibilityAddTraits(settings.width == choice.width ? .isSelected : [])
                    }
                }
            }
            if band == .ghz5 {
                Divider().padding(.leading, 12)
                row("DFS channels", help: WiFiRadioInspector.dfsHelp) {
                    if inspector.autoDFSWritable, let on = inspector.autoDFS {
                        Toggle("DFS channels", isOn: Binding(get: { on }, set: { controller.setAutoDFS($0) })).toggleStyle(.switch).labelsHidden()
                    } else {
                        Text(WiFiEditFormat.onOff(inspector.autoDFS)).foregroundStyle(.secondary)
                    }
                }
            }
            if band == .ghz6, let psc = settings.pscOnly {
                Divider().padding(.leading, 12)
                row("Preferred channels only", help: WiFiRadioInspector.pscHelp) {
                    Toggle("Preferred channels only", isOn: Binding(get: { psc }, set: { on in edit { $0.pscOnly = on } }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
        WiFiBox {
            VStack(alignment: .leading, spacing: 8) {
                HelpLabel(title: "Power", help: WiFiRadioInspector.powerHelp)
                Picker("Power", selection: Binding(get: { settings.txPower }, set: { level in edit { $0.txPower = level } })) {
                    ForEach(TxPowerLevel.levels, id: \.self) { Text(WiFiFormat.power($0)).tag($0) }
                    if !TxPowerLevel.levels.contains(settings.txPower) { Text(WiFiFormat.power(settings.txPower)).tag(settings.txPower) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            ruler
        }
        DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
            WiFiBox {
                row("Wi-Fi versions") {
                    Picker("Wi-Fi versions", selection: Binding(get: { settings.hwmode }, set: { mode in edit { $0.hwmode = mode } })) {
                        ForEach(inspector.versions, id: \.hwmode) { Text($0.label).tag($0.hwmode) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(inspector.versions.count <= 1)
                }
            }
            .padding(.top, 6)
        }
    }

    private var values: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                                .help(device.help)
                                .offset(x: width * device.position - 6, y: 11)
                                .animation(.default, value: device.position)
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

/// A small segment with a disabled state, for the width choices.
struct WiFiSegmentStyle: ButtonStyle {
    let on: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(on ? Color.white : isEnabled ? Color.primary : Color.secondary.opacity(0.5))
            .background(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(configuration.isPressed ? 0.6 : 0.3),
                        in: RoundedRectangle(cornerRadius: 5))
    }
}

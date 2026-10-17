import SwiftUI
import RoutewellKit

/// Set up multi-link in three steps (Bands, Name, Review), then Turn On,
/// progress, and the done screen with the share card for a new name.
struct WiFiMultiLinkSheet: View {
    enum Step: Int, CaseIterable { case bands, name, review }

    @Environment(AppEnvironment.self) private var environment
    @State private var step: Step

    init(step: Step = .bands) { _step = State(initialValue: step) }

    var body: some View {
        let controller = environment.wifi
        if let draft = controller.mloDraft {
            VStack(alignment: .leading, spacing: 12) {
                header(done: controller.run != nil)
                if let run = controller.run {
                    if case .verifiedSuccess? = run.outcome {
                        done(draft)
                    } else if let outcome = run.outcome {
                        WiFiApplyResult(page: WiFiOutcomePresentation(outcome, run: run))
                    } else {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.large)
                            Text("Turning on multi-link…").font(.headline)
                            Text(WiFiMLOFormat.Review(plan: run.plan).note).font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                } else {
                    switch step {
                    case .bands: bands(draft)
                    case .name: name(draft)
                    case .review: review(draft)
                    }
                }
            }
        }
    }

    private func header(done: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "link").font(.callout.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(WiFiMLOStyle.violet, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text("Set up multi-link").font(.title3.weight(.bold))
            Spacer(minLength: 8)
            if !done {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        if item != .bands { Rectangle().fill(.quaternary).frame(width: 18, height: 1.5) }
                        let current = item == step
                        let finished = item.rawValue < step.rawValue
                        HStack(spacing: 5) {
                            ZStack {
                                Circle().fill(current ? Color.accentColor : finished ? .green : Color(nsColor: .quaternaryLabelColor))
                                if finished {
                                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                } else {
                                    Text("\(item.rawValue + 1)").font(.system(size: 10, weight: .bold))
                                }
                            }
                            .foregroundStyle(current || finished ? .white : .secondary)
                            .frame(width: 18, height: 18)
                            Text(Self.title(item)).font(.system(size: 11.5)).fontWeight(current ? .semibold : .regular)
                                .foregroundStyle(current ? .primary : .tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    static func title(_ step: Step) -> String {
        switch step {
        case .bands: "Bands"
        case .name: "Name"
        case .review: "Review"
        }
    }

    private func footer<Buttons: View>(_ note: String?, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { environment.wifi.closeSheet() }.keyboardShortcut(.cancelAction)
            buttons()
        }
        .controlSize(.large)
        .padding(.top, 4)
    }

    // MARK: Steps

    private func bands(_ draft: WiFiMLODraft) -> some View {
        let controller = environment.wifi
        return VStack(alignment: .leading, spacing: 12) {
            WiFiLinkPreview(bands: draft.bands.sorted(), device: controller.wifi7Devices.first.map(WiFiFormat.deviceName) ?? "Wi-Fi 7 device")
                .frame(height: 132)
            WiFiMLOBandTiles(bands: draft.bands, supported: draft.mlo?.supportedBands ?? [], editable: true) { band in
                if draft.bands.contains(band) { controller.mloDraft?.bands.remove(band) } else { controller.mloDraft?.bands.insert(band) }
            }
            footer("Pick at least 2 bands.") {
                Button("Continue") { step = .name }.keyboardShortcut(.defaultAction).disabled(draft.bands.count < 2)
            }
        }
    }

    private func name(_ draft: WiFiMLODraft) -> some View {
        let controller = environment.wifi
        let problems = draft.network.problems
        let mains = WiFiReviewPresentation.mains(draft.wireless).map(\.name)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                choice(title: "New name", selected: !draft.sameName,
                       rows: mains.map { ($0, false, nil) } + [(draft.name.isEmpty ? WiFiFormat.dash : draft.name, true, "New")],
                       note: "Join it on each Wi-Fi 7 device. Easy to undo.") { controller.mloDraft?.sameName = false }
                choice(title: "Same as \(draft.fastName ?? WiFiFormat.dash)", selected: draft.sameName,
                       rows: mains.map { ($0, $0 == draft.fastName, $0 == draft.fastName ? "Multi-link" : nil) },
                       note: "Nothing to join.") { controller.mloDraft?.sameName = true }
                    .disabled(draft.fastName == nil)
            }
            WiFiBox {
                if !draft.sameName {
                    HStack {
                        Text("Name")
                        Spacer(minLength: 12)
                        TextField("Name", text: Binding(get: { controller.mloDraft?.name ?? "" }, set: { controller.mloDraft?.name = $0 }))
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 210).labelsHidden()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 40)
                    Divider().padding(.leading, 12)
                }
                WiFiMLOPasswordRows(fastName: draft.fastName, samePassword: draft.samePassword, password: draft.password,
                                    editable: draft.fastName != nil) { same in
                    controller.mloDraft?.samePassword = same
                    if !same, controller.mloDraft?.password.isEmpty == true { controller.mloDraft?.password = WiFiGuestDraft.newPassword() }
                } setPassword: { controller.mloDraft?.password = $0 }
                Divider().padding(.leading, 12)
                HStack {
                    HelpLabel(title: "Security", help: "6 GHz allows only WPA3.")
                    Spacer(minLength: 12)
                    Text(WiFiFormat.security(.wpa3)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 40)
            }
            footer(problems.first.map(WiFiEditFormat.problem)) {
                Button("Back") { step = .bands }
                Button("Continue") { step = .review }.keyboardShortcut(.defaultAction).disabled(!problems.isEmpty)
            }
        }
    }

    private func choice(title: String, selected: Bool, rows: [(name: String, linked: Bool, tag: String?)], note: String,
                        select: @escaping () -> Void) -> some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            Image(systemName: row.linked ? "link" : "wifi")
                                .foregroundStyle(row.linked ? WirelessBand.ghz6.color : .secondary).frame(width: 14).accessibilityHidden(true)
                            Text(row.name).fontWeight(row.tag == "New" ? .semibold : .regular).lineLimit(1)
                            Spacer(minLength: 4)
                            if let tag = row.tag {
                                Text(tag).font(.system(size: 10, weight: .semibold)).foregroundStyle(WirelessBand.ghz6.color)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func review(_ draft: WiFiMLODraft) -> some View {
        let controller = environment.wifi
        let plan = controller.plan(for: draft.change)
        let page = plan.map(WiFiMLOFormat.Review.init)
        let network = draft.network
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(WirelessBand.ghz6.color).accessibilityHidden(true)
                Text(network.ssid ?? WiFiFormat.dash).fontWeight(.semibold)
                Spacer(minLength: 8)
                ForEach(network.bands, id: \.self) { band in BandPill(band: band, on: true) }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1))
            if let page {
                HStack(spacing: 8) {
                    tile("wifi", tint: .gray, bold: page.restartBold, rest: page.restartRest)
                    tile("person.fill", tint: .gray, bold: page.devicesBold, rest: page.devicesRest)
                    tile("laptopcomputer", tint: .purple, bold: "This Mac", rest: page.mac)
                }
            }
            footer(page?.note) {
                Button("Back") { step = .name }
                Button("Turn On") { controller.turnOnMultiLink() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan?.isEmpty != false || !network.problems.isEmpty || !controller.canEdit)
            }
        }
    }

    private func tile(_ symbol: String, tint: Color, bold: String, rest: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(bold).font(.callout.weight(.semibold))
            Text(rest).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 91)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: Done

    private func done(_ draft: WiFiMLODraft) -> some View {
        let controller = environment.wifi
        let network = draft.network
        let name = network.ssid ?? WiFiFormat.dash
        return VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green).accessibilityHidden(true)
            Text("Multi-link is on").font(.title3.weight(.bold))
            Text(WiFiMLOFormat.doneLine(name: name, sameName: draft.sameName, devices: controller.wifi7Devices.map(WiFiFormat.deviceName)))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !draft.sameName {
                WiFiShareCard(name: name, security: network.encryption, bands: network.bands, password: network.password?.revealed ?? "", hidden: false)
            }
            HStack {
                Spacer()
                Button("Done") { controller.closeSheet() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A device linked to the router with one curve per band, and a dash that
/// flows along each curve unless Reduce Motion is on.
struct WiFiLinkPreview: View {
    let bands: [WirelessBand]
    let device: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let from = CGPoint(x: 90 + 30, y: size.height / 2)
            let to = CGPoint(x: size.width - 90 - 38, y: size.height / 2)
            ZStack {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    Canvas { canvas, _ in
                        for (index, band) in bands.enumerated() {
                            let path = Self.curve(from: from, to: to, offset: Self.offset(index, count: bands.count))
                            canvas.stroke(path, with: .color(band.color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            guard !reduceMotion else { continue }
                            let cycle = band == .ghz6 ? 1.0 : 1.6
                            let phase = -28 * time.truncatingRemainder(dividingBy: cycle) / cycle
                            canvas.stroke(path, with: .color(.white.opacity(0.85)),
                                          style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 24], dashPhase: phase))
                        }
                    }
                }
                ForEach(Array(bands.enumerated()), id: \.element) { index, band in
                    let offset = Self.offset(index, count: bands.count)
                    HStack(spacing: 4) {
                        BandDot(band: band)
                        Text(WiFiFormat.band(band)).font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    // The curve's middle is 1.9 × its offset from the centre line.
                    .position(x: (from.x + to.x) / 2, y: size.height / 2 + offset * 1.9 + (offset > 0 ? 12 : -12))
                }
                node("laptopcomputer", device, size: 38, radius: 11, fill: WiFiMLOStyle.violet).position(x: 90, y: size.height / 2 + 8)
                node("wifi.router", "Router", size: 44, radius: 12,
                     fill: LinearGradient(colors: [Color(red: 0.35, green: 0.69, blue: 1), Color(red: 0.04, green: 0.49, blue: 1)],
                                          startPoint: .top, endPoint: .bottom))
                    .position(x: size.width - 90, y: size.height / 2 + 8)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device) linked to the router on \(WiFiMLOFormat.bands(bands))")
    }

    /// Curves sit 13 points apart around the centre line.
    static func offset(_ index: Int, count: Int) -> CGFloat { (CGFloat(index) - CGFloat(count - 1) / 2) * 13 }

    /// The curves bow apart in the middle.
    static func curve(from: CGPoint, to: CGPoint, offset: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: from.x, y: from.y + offset))
            path.addCurve(to: CGPoint(x: to.x, y: to.y + offset),
                          control1: CGPoint(x: from.x + (to.x - from.x) / 3, y: from.y + offset * 2.2),
                          control2: CGPoint(x: from.x + (to.x - from.x) * 2 / 3, y: from.y + offset * 2.2))
        }
    }

    private func node(_ symbol: String, _ name: String, size: CGFloat, radius: CGFloat, fill: LinearGradient) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(fill, in: RoundedRectangle(cornerRadius: radius))
            Text(name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
        }
    }
}

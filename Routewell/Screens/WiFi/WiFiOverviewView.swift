import SwiftUI
import RoutewellKit

/// "Is my Wi-Fi OK, and what should I change?": the air map, the networks
/// by name, the suggestions, and one tile per radio.
struct WiFiOverviewView: View {
    let overview: WiFiOverview
    let wireless: WirelessStatus
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.wifi
        let page = WiFiOverviewPresentation(overview: overview, wireless: wireless, suggestions: controller.suggestions)
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    WiFiAirMap(page: page).frame(width: 528)
                    side(page)
                }
                VStack(alignment: .leading, spacing: 18) {
                    WiFiAirMap(page: page)
                    side(page)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(page.radios) { tile in
                    WiFiRadioTile(tile: tile) { controller.openRadios(tile.band) }
                }
            }
        }
    }

    private func side(_ page: WiFiOverviewPresentation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            WiFiNetworkCards(page: page)
            WiFiSuggestions(page: page)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Air map

struct WiFiAirMap: View {
    let page: WiFiOverviewPresentation
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WiFiBox {
            VStack(alignment: .leading, spacing: 0) { content }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(page.deviceCount)").font(.title.weight(.semibold)).monospacedDigit()
            Text(page.deviceCount == 1 ? "device on Wi-Fi" : "devices on Wi-Fi").foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                StatusDot(tone: page.signalLine == nil ? .unknown : page.hasWeak ? .degraded : .healthy)
                Text(page.signalLine ?? "Signal \(WiFiFormat.dash)")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.top, 12)
        fan
            .aspectRatio(500 / 268, contentMode: .fit)
            .padding(.horizontal, 14)
        if page.showsRings {
            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    Circle().fill(.quaternary).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.orange, lineWidth: 2).frame(width: 14, height: 14))
                    Text("Can use a faster band")
                }
                HStack(spacing: 5) {
                    Circle().strokeBorder(WirelessBand.ghz6.color, lineWidth: 1.5).frame(width: 7, height: 7)
                    Text("Wi-Fi 7")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 10).padding(.bottom, 12)
        } else {
            Spacer().frame(height: 12)
        }
    }

    private var fan: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 500
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let center = CGPoint(x: 250 * scale, y: 248 * scale)
                    for band in WirelessBand.allCases {
                        guard let sector = WiFiOverviewPresentation.sectors[band] else { continue }
                        var wedge = Path()
                        wedge.move(to: center)
                        wedge.addArc(center: center, radius: 240 * scale, startAngle: .degrees(-sector.from), endAngle: .degrees(-sector.to), clockwise: false)
                        wedge.closeSubpath()
                        context.fill(wedge, with: .color(band.color.opacity(0.07)))
                    }
                    if page.showsRings {
                        for dBm in [-50, -60, -70] {
                            let radius = WiFiOverviewPresentation.radius(dBm: dBm) * scale
                            var ring = Path()
                            ring.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                            context.stroke(ring, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        }
                    }
                }
                if page.showsRings {
                    ForEach(Array(zip(["Strong", "Good", "Fair", "Weak"], [-45, -55, -65, -76])), id: \.0) { word, dBm in
                        Text(word).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            .position(x: (250 + WiFiOverviewPresentation.radius(dBm: dBm)) * scale, y: 259 * scale)
                    }
                }
                if !page.showsRings, page.deviceCount > 0 {
                    Text("Signal unknown").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        .position(x: (250 + WiFiOverviewPresentation.unknownRadius) * scale, y: 259 * scale)
                }
                ForEach(page.sectorLabels, id: \.band) { sector in
                    let angle = (sector.band == .ghz2_4 ? 150.0 : sector.band == .ghz5 ? 90 : 30) * .pi / 180
                    HStack(spacing: 4) {
                        BandDot(band: sector.band)
                        Text(WiFiFormat.band(sector.band))
                        Text(sector.label).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    .position(x: (250 + 214 * cos(angle)) * scale, y: (248 - 214 * sin(angle)) * scale)
                    if sector.count == 0 {
                        Text("Not used").font(.system(size: 11)).foregroundStyle(.tertiary)
                            .position(x: (250 + 114 * cos(angle)) * scale, y: (248 - 114 * sin(angle)) * scale)
                    }
                }
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        let time = context.date.timeIntervalSinceReferenceDate
                        ZStack {
                            ForEach([0.0, 1.2, 2.4], id: \.self) { delay in
                                let wave = Self.wave(time: time, delay: delay)
                                Circle().stroke(Self.blue, lineWidth: 1.5 * scale).frame(width: 30 * scale, height: 30 * scale)
                                    .scaleEffect(wave.scale).opacity(wave.opacity)
                            }
                        }
                        .position(x: 250 * scale, y: 248 * scale)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                WiFiHub().position(x: 250 * scale, y: 248 * scale)
                ForEach(page.dots) { dot in
                    WiFiDeviceDot(device: dot.device, highlighted: environment.wifi.highlighted.contains(dot.device.mac),
                                  hovered: environment.wifi.hovered == dot.device.mac)
                        .onHover { inside in if inside { environment.wifi.hovered = dot.device.mac } }
                        .position(x: dot.x * scale, y: dot.y * scale)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: dot.x)
                }
                if let dot = page.dots.first(where: { $0.device.mac == environment.wifi.hovered }) {
                    let x = dot.x * scale, width = proxy.size.width
                    Color.clear.frame(width: 0, height: 0)
                        .overlay(alignment: .bottom) {
                            WiFiDotCard(lines: WiFiOverviewPresentation.tooltip(dot.device))
                                // Slides the card sideways so it stays inside the map near either edge.
                                .alignmentGuide(HorizontalAlignment.center) { card in
                                    min(max(card.width / 2, card.width - (width - x)), x)
                                }
                                .offset(y: -12)
                        }
                        .position(x: x, y: dot.y * scale)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onHover { inside in if !inside { environment.wifi.hovered = nil } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wi-Fi devices by band and signal")
    }

    private static let blue = Color(red: 0, green: 0x7A / 255, blue: 1)

    /// One ring: from the hub's size to 15 times it, fading from .45 to 0, eased out over 3.6 s.
    static func wave(time: TimeInterval, delay: TimeInterval) -> (scale: Double, opacity: Double) {
        let eased = OnboardingArtAnimation.easeOut(OnboardingArtAnimation.wrap(time - delay, 3.6) / 3.6)
        return (1 + 14 * eased, 0.45 * (1 - eased))
    }
}

/// The router at the centre of the fan.
struct WiFiHub: View {
    var body: some View {
        SVGPathParser.parse("M2.5 7a8 8 0 0 1 11 0M4.6 9.2a5 5 0 0 1 6.8 0M6.7 11.4a2 2 0 0 1 2.6 0")
            .stroke(.white, lineWidth: 1.6)
            .frame(width: 16, height: 16)
            .frame(width: 30, height: 30)
            .background(LinearGradient(colors: [Color(red: 0x5A / 255, green: 0xB0 / 255, blue: 1), Color(red: 0x0A / 255, green: 0x7C / 255, blue: 1)],
                                       startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 9))
            .padding(4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .shadow(color: Color(red: 0x0A / 255, green: 0x7C / 255, blue: 1).opacity(0.35), radius: 5, y: 4)
            .accessibilityHidden(true)
    }
}

/// The card over a hovered dot.
struct WiFiDotCard: View {
    let lines: [String]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let ink: Color = dark ? .white : .black
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: index == 0 ? 12 : 11, weight: index == 0 ? .semibold : .regular))
                    .foregroundStyle(ink.opacity(index == 0 ? 0.847 : dark ? 0.55 : 0.498))
                    .frame(minHeight: 16)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(dark ? Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255) : .white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8.5).strokeBorder(dark ? .white.opacity(0.16) : .black.opacity(0.18), lineWidth: 0.5).padding(-0.5))
        .shadow(color: .black.opacity(dark ? 0.55 : 0.18), radius: dark ? 20 : 17, y: dark ? 14 : 10)
    }
}

struct WiFiDeviceDot: View {
    let device: WiFiDevice
    let highlighted: Bool
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if device.canUseFasterBand {
                Circle().strokeBorder(.orange, lineWidth: 2).frame(width: 18, height: 18)
            }
            Circle().fill(device.band?.color ?? .secondary).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
            if device.generation == .wifi7 {
                Circle().fill(Color(nsColor: .controlBackgroundColor)).frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(WirelessBand.ghz6.color, lineWidth: 1.5))
                    .offset(x: 8, y: -8)
            }
            if highlighted {
                Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 22, height: 22)
            }
        }
        .scaleEffect(hovered ? 1.35 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovered)
        .frame(width: 24, height: 24)
        .contentShape(Circle())
        .accessibilityElement()
        .accessibilityLabel(WiFiOverviewPresentation.accessibilityLabel(device))
    }
}

// MARK: - Networks

struct WiFiNetworkCards: View {
    let page: WiFiOverviewPresentation
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        WiFiBox {
            ForEach(Array(page.cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 { Divider().padding(.leading, 56) }
                if card.multiLink {
                    Button { environment.wifi.openMultiLink() } label: { row(card, chevron: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens Multi-link")
                } else if let group = card.group {
                    Button {
                        if group.kind == .main { environment.wifi.openNetwork(group) } else { environment.wifi.openGuest(group.kind, group: group) }
                    } label: { row(card, chevron: true) }
                        .buttonStyle(.plain)
                        .disabled(!environment.wifi.canEdit)
                        .accessibilityHint("Opens the network's settings")
                } else {
                    row(card, chevron: false)
                }
            }
            if !page.addTiles.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    ForEach(page.addTiles, id: \.self) { missing in
                        addTile(missing)
                    }
                }
                .padding(12)
            }
        }
    }

    private func row(_ card: WiFiOverviewPresentation.NetworkCard, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            tile(card)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(card.name).fontWeight(.semibold)
                    if card.secured {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Secured")
                    }
                }
                HStack(spacing: 4) {
                    ForEach(WirelessBand.allCases, id: \.self) { band in BandPill(band: band, on: card.bands.contains(band)) }
                }
            }
            Spacer(minLength: 8)
            Label(card.count, systemImage: "person.fill").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityLabel("\(card.count) devices")
            if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func tile(_ card: WiFiOverviewPresentation.NetworkCard) -> some View {
        let (symbol, color): (String, Color) = card.multiLink ? ("link", .purple)
            : card.kind == .guest ? ("person.fill", .green) : card.kind == .iot ? ("house.fill", .orange) : ("wifi", .blue)
        return Image(systemName: symbol)
            .font(.body.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    /// Guest and IoT open their setup sheets; Multi-link opens its tab.
    @ViewBuilder private func addTile(_ missing: WiFiOverview.Missing) -> some View {
        let (title, symbol): (String, String) = switch missing {
        case .guest: ("Guest", "person")
        case .iot: ("IoT", "house")
        case .multiLink: ("Multi-link", "link")
        }
        let content = HStack(spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 0)
            Image(systemName: "plus").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .contentShape(Rectangle())
        switch missing {
        case .multiLink:
            Button { environment.wifi.openMultiLink() } label: { content }.buttonStyle(.plain).accessibilityLabel("Multi-link, not set up")
        case .guest, .iot:
            Button { environment.wifi.openGuest(missing == .guest ? .guest : .iot) } label: { content }
                .buttonStyle(.plain)
                .disabled(!environment.wifi.canEdit)
                .accessibilityLabel("\(title) network, not set up")
                .accessibilityHint("Opens the setup")
        }
    }
}

// MARK: - Suggestions

struct WiFiSuggestions: View {
    let page: WiFiOverviewPresentation
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let controller = environment.wifi
        WiFiBox {
            HStack {
                Text("Suggestions").font(.headline)
                Spacer()
                if !page.suggestions.isEmpty {
                    Text("\(page.suggestions.count)").font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 1).background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            if page.suggestions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                    Text("Nothing to improve").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
            ForEach(page.suggestions) { line in
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(line.suggestion)).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                    Text(line.title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let action = line.action {
                        Button(action.label) {
                            switch action.target {
                            case .radios: controller.openRadios(.ghz5)
                            case .multiLink: controller.openMultiLink()
                            case .useOneName: controller.openUseOneName()
                            case .iot: controller.openGuest(.iot)
                            }
                        }
                        .controlSize(.small)
                    }
                    Button { controller.dismiss(line.suggestion) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .contentShape(Rectangle())
                .onHover { inside in controller.highlighted = inside ? Set(line.suggestion.devices) : [] }
            }
            Spacer().frame(height: 6)
        }
    }

    static func symbol(_ suggestion: WiFiSuggestion) -> String {
        switch suggestion {
        case .fasterBand: "equal"
        case .multiLinkReady: "link"
        case .ownNetwork: "house"
        case .dfsChannels: "chart.bar"
        }
    }
}

// MARK: - Radio tiles

struct WiFiRadioTile: View {
    let tile: WiFiOverviewPresentation.RadioTile
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            WiFiBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        BandDot(band: tile.band)
                        Text(WiFiFormat.band(tile.band)).fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    WiFiSpectrumStrip(band: tile.band, block: tile.block, dfs: tile.dfs).frame(height: 18)
                    HStack {
                        Text(tile.now).monospacedDigit()
                        Spacer()
                        Text(tile.mode)
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Radios")
    }
}

/// A thin strip: the DFS area hatched, the channel block in the band's colour.
struct WiFiSpectrumStrip: View {
    let band: WirelessBand
    let block: ClosedRange<Double>?
    let dfs: ClosedRange<Double>?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.separator).frame(height: 1)
                if let dfs {
                    WiFiHatch().frame(width: width * (dfs.upperBound - dfs.lowerBound)).offset(x: width * dfs.lowerBound)
                }
                if let block {
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                        .fill(band.color.gradient)
                        .frame(width: max(4, width * (block.upperBound - block.lowerBound)))
                        .offset(x: width * block.lowerBound)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Diagonal lines for the DFS area.
struct WiFiHatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
    }
}

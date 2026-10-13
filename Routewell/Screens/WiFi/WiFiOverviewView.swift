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
                HStack(spacing: 14) {
                    Label { Text("Can use a faster band") } icon: { Circle().stroke(.orange, lineWidth: 1.5).frame(width: 9, height: 9) }
                    Label { Text("Wi-Fi 7") } icon: { Circle().fill(.purple).frame(width: 5, height: 5) }
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                .padding(.horizontal, 14).padding(.bottom, 12)
            } else {
                Spacer().frame(height: 12)
            }
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
                }
                Image(systemName: "wifi.router").font(.title3).foregroundStyle(.secondary)
                    .position(x: 250 * scale, y: 248 * scale)
                    .accessibilityHidden(true)
                ForEach(page.dots) { dot in
                    WiFiDeviceDot(device: dot.device, highlighted: environment.wifi.highlighted.contains(dot.device.mac))
                        .position(x: dot.x * scale, y: dot.y * scale)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: dot.x)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wi-Fi devices by band and signal")
    }
}

struct WiFiDeviceDot: View {
    let device: WiFiDevice
    let highlighted: Bool

    var body: some View {
        ZStack {
            if device.canUseFasterBand {
                Circle().stroke(.orange, lineWidth: 1.5).frame(width: 18, height: 18)
            }
            Circle().fill(device.band?.color ?? .secondary).frame(width: 11, height: 11)
                .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
            if device.generation == .wifi7 {
                Circle().fill(.white).frame(width: 4, height: 4)
            }
            if highlighted {
                Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 22, height: 22)
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
        .help(WiFiOverviewPresentation.tooltip(device))
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
                    Button { environment.wifi.openNetwork(group) } label: { row(card, chevron: true) }
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

    /// Guest and IoT open their setup sheets in a later version; Multi-link
    /// opens its tab.
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
            if missing == .multiLink { Image(systemName: "plus").foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .contentShape(Rectangle())
        if missing == .multiLink {
            Button { environment.wifi.openMultiLink() } label: { content }.buttonStyle(.plain).accessibilityLabel("Multi-link, not set up")
        } else {
            content.accessibilityLabel("\(title) network, not set up")
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

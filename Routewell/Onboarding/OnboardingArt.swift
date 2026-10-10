import SwiftUI

enum ArtMotif: String, CaseIterable {
    case router, laptop, search, network, tag, cert, lock, key, fingerprint
    case terminal, ping, ports, storage, log, dhcp, speed, done, warn
}

enum ArtBadge: String, CaseIterable { case check, warn, error }

/// Onboarding illustration: a tinted glass-style glyph, optionally on a tile, with an optional status badge.
/// Drawn in a 120 x 120 space and scaled to `size`. Only `search` and `terminal` animate.
struct OnboardingArt: View {
    let motif: ArtMotif
    let tint: Color
    let tile: Bool
    let badge: ArtBadge?
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(motif: ArtMotif, tint: Color, tile: Bool = true, badge: ArtBadge? = nil, size: CGFloat) {
        self.motif = motif
        self.tint = tint
        self.tile = tile
        self.badge = badge
        self.size = size
    }

    private var resolvedBadge: ArtBadge? {
        badge ?? (motif == .done ? .check : motif == .warn ? .warn : nil)
    }

    private var animates: Bool {
        (motif == .search || motif == .terminal) && !reduceMotion
    }

    var body: some View {
        Group {
            if animates {
                TimelineView(.animation) { art(time: $0.date.timeIntervalSinceReferenceDate) }
            } else {
                art(time: 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func art(time: TimeInterval) -> some View {
        let palette = Palette(tint)
        return ZStack {
            if tile {
                Element(rect(6, 6, 108, 108, rx: 25), fill: .tl)
                Element(rect(6.5, 6.5, 107, 107, rx: 24.5), stroke: .color(.white.opacity(0.35)), width: 1)
            }
            Glyph(motif: motif, time: time, reduceMotion: reduceMotion)
                .shadow(color: palette.shadow, radius: 8, x: 0, y: 3)
                .scaleEffect(tile ? 0.72 : 1)
            if let resolvedBadge {
                BadgeMark(kind: resolvedBadge)
            }
        }
        .frame(width: 120, height: 120)
        .environment(\.artPalette, palette)
        .scaleEffect(size / 120)
        .frame(width: size, height: size)
    }
}

/// The two animations, as pure functions of time.
enum OnboardingArtAnimation {
    static let pulseDuration: TimeInterval = 2.4
    static let blinkDuration: TimeInterval = 1.2

    /// rwPulse: scale .45 to 1.2 over the whole cycle; opacity 0 to .9 at 25 %, then to 0.
    /// `delay` shifts the phase. Time before the delay wraps, so staggered rings never sit still.
    static func pulse(time: TimeInterval, delay: TimeInterval, reduceMotion: Bool) -> (scale: Double, opacity: Double) {
        guard !reduceMotion else { return (1, 1) }
        let phase = wrap(time - delay, pulseDuration) / pulseDuration
        let scale = 0.45 + 0.75 * easeOut(phase)
        let opacity = phase < 0.25
            ? 0.9 * easeOut(phase / 0.25)
            : 0.9 * (1 - easeOut((phase - 0.25) / 0.75))
        return (scale, opacity)
    }

    /// rwBlink with steps(1): full opacity for the first half of each cycle, .35 for the second.
    static func blinkOpacity(time: TimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        return wrap(time, blinkDuration) < blinkDuration / 2 ? 1 : 0.35
    }

    private static func wrap(_ t: TimeInterval, _ period: TimeInterval) -> TimeInterval {
        let r = t.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    /// CSS `ease-out`, cubic-bezier(0, 0, .58, 1).
    private static func easeOut(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let t = (lo + hi) / 2
            let bx = 3 * (1 - t) * t * t * 0.58 + t * t * t
            if bx < x { lo = t } else { hi = t }
        }
        let t = (lo + hi) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }
}

// MARK: - Colours

private enum Paint {
    case t, wave, wave2, ink, rim, ports, notch
    case gl, tl, ac, led
    case color(Color)
}

private struct Palette {
    let t, wave, wave2, ink, ports, notch, shadow: Color

    /// `color-mix(in srgb, T pct%, base)`.
    init(_ tint: Color) {
        func mix(_ pct: Double, _ base: Color) -> Color { base.mix(with: tint, by: pct / 100, in: .device) }
        t = tint
        wave = mix(50, .white)
        wave2 = mix(22, .white)
        ink = mix(85, .black)
        ports = mix(35, Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255))
        notch = mix(25, .white)
        // drop-shadow colour: T 45 % mixed with black at .45 alpha, premultiplied.
        shadow = mix(64.5, .black).opacity(0.70)
        glBottom = mix(20, .white)
        tlTop = mix(72, .white)
        tlBottom = mix(82, .black)
        acTop = mix(70, .white)
    }

    private let glBottom, tlTop, tlBottom, acTop: Color

    func style(_ paint: Paint, box: CGRect) -> AnyShapeStyle {
        let space = SVGShape.space
        func linear(_ stops: [Gradient.Stop]) -> AnyShapeStyle {
            AnyShapeStyle(LinearGradient(stops: stops,
                                         startPoint: UnitPoint(x: 0.5, y: box.minY / space),
                                         endPoint: UnitPoint(x: 0.5, y: box.maxY / space)))
        }
        switch paint {
        case .t: return AnyShapeStyle(t)
        case .wave: return AnyShapeStyle(wave)
        case .wave2: return AnyShapeStyle(wave2)
        case .ink: return AnyShapeStyle(ink)
        case .rim: return AnyShapeStyle(Color.white.opacity(0.95))
        case .ports: return AnyShapeStyle(ports)
        case .notch: return AnyShapeStyle(notch)
        case .color(let c): return AnyShapeStyle(c)
        case .gl:
            return linear([.init(color: .white.opacity(0.98), location: 0),
                           .init(color: glBottom.opacity(0.96), location: 1)])
        case .tl:
            return linear([.init(color: tlTop, location: 0), .init(color: t, location: 0.55),
                           .init(color: tlBottom, location: 1)])
        case .ac:
            return linear([.init(color: acTop, location: 0), .init(color: t, location: 1)])
        case .led:
            return AnyShapeStyle(RadialGradient(
                colors: [Color(red: 0xc9 / 255, green: 1, blue: 0xe2 / 255),
                         Color(red: 0x22 / 255, green: 0xc9 / 255, blue: 0x6d / 255)],
                center: UnitPoint(x: (box.minX + 0.4 * box.width) / space, y: (box.minY + 0.35 * box.height) / space),
                startRadius: 0, endRadius: 0.7 * box.width))
        }
    }
}

extension EnvironmentValues {
    @Entry fileprivate var artPalette = Palette(.blue)
}

// MARK: - Building blocks

private func path(_ d: String) -> SVGShape { SVGShape(d: d) }
private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rx: CGFloat = 0) -> SVGShape {
    SVGShape(x: x, y: y, width: w, height: h, rx: rx)
}
private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> SVGShape { SVGShape(cx: cx, cy: cy, r: r) }

/// SVG `rotate(degrees cx cy)`.
private struct Rot {
    let degrees: Double, cx: CGFloat, cy: CGFloat
    init(_ degrees: Double, _ cx: CGFloat = 60, _ cy: CGFloat = 60) {
        self.degrees = degrees
        self.cx = cx
        self.cy = cy
    }
}

/// One SVG element: a fill and a centred stroke, with gradients sized to the shape's own box.
private struct Element: View {
    @Environment(\.artPalette) private var palette
    let shape: SVGShape
    var fill: Paint?
    var stroke: Paint?
    var width: CGFloat
    var cap: CGLineCap
    var join: CGLineJoin
    var dash: [CGFloat]
    var opacity: Double
    var rotate: Rot?

    init(_ shape: SVGShape, fill: Paint? = nil, stroke: Paint? = nil, width: CGFloat = 1,
         cap: CGLineCap = .butt, join: CGLineJoin = .miter, dash: [CGFloat] = [],
         opacity: Double = 1, rotate: Rot? = nil) {
        self.shape = shape
        self.fill = fill
        self.stroke = stroke
        self.width = width
        self.cap = cap
        self.join = join
        self.dash = dash
        self.opacity = opacity
        self.rotate = rotate
    }

    var body: some View {
        let box = shape.bounds
        ZStack {
            if let fill { shape.fill(palette.style(fill, box: box)) }
            if let stroke {
                shape.stroke(palette.style(stroke, box: box),
                             style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: join, miterLimit: 4, dash: dash))
            }
        }
        .opacity(opacity)
        .rotationEffect(.degrees(rotate?.degrees ?? 0),
                        anchor: UnitPoint(x: (rotate?.cx ?? 60) / 120, y: (rotate?.cy ?? 60) / 120))
    }
}

/// SVG `<use>` of a 120 x 120 symbol at (x, y) with the given width.
private struct Use<Content: View>: View {
    let x: CGFloat, y: CGFloat, width: CGFloat
    var opacity: Double = 1
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: 120, height: 120)
            .scaleEffect(width / 120, anchor: .topLeading)
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

private struct BadgeMark: View {
    let kind: ArtBadge

    var body: some View {
        let (color, d): (Color, String) = switch kind {
        case .check: (.green, "M83 92 L89 98 L99 86")
        case .warn: (.orange, "M91 83 V92 M91 99 V99.2")
        case .error: (.red, "M85 86 L97 98 M97 86 L85 98")
        }
        ZStack {
            Element(circle(91, 92, 15), fill: .color(color), stroke: .color(.white), width: 3)
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
            Element(path(d), stroke: .color(.white), width: 4.5, cap: .round, join: .round)
        }
    }
}

// MARK: - Motifs

private struct RouterSymbol: View {
    var body: some View {
        ZStack {
            Element(rect(29, 20, 7, 50, rx: 3.5), fill: .gl, stroke: .rim, width: 1, rotate: Rot(-6, 32.5, 70))
            Element(rect(84, 20, 7, 50, rx: 3.5), fill: .gl, stroke: .rim, width: 1, rotate: Rot(6, 87.5, 70))
            Element(path("M42 50 Q60 34 78 50"), stroke: .wave, width: 7, cap: .round)
            Element(path("M50 59.5 Q60 51.5 70 59.5"), stroke: .wave2, width: 7, cap: .round)
            Element(rect(16, 66, 88, 30, rx: 15), fill: .gl, stroke: .rim, width: 1.2)
            Element(circle(60, 81, 4.5), fill: .led)
        }
    }
}

private struct LaptopSymbol: View {
    var body: some View {
        ZStack {
            Element(rect(22, 26, 76, 52, rx: 6), fill: .gl, stroke: .rim, width: 1.2)
            Element(rect(27.5, 31.5, 65, 41, rx: 2.5), fill: .ac, opacity: 0.85)
            Element(path("M36 48 h22 M36 56 h34 M36 64 h16"), stroke: .color(.white.opacity(0.75)), width: 3.5, cap: .round)
            Element(path("M10 80 H110 L104 88 Q103 90 100 90 H20 Q17 90 16 88 Z"), fill: .gl, stroke: .rim, width: 1)
            Element(rect(50, 80, 20, 3, rx: 1.5), fill: .notch)
        }
    }
}

private struct Glyph: View {
    let motif: ArtMotif
    let time: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        ZStack { content }.frame(width: 120, height: 120)
    }

    @ViewBuilder private var content: some View {
        switch motif {
        case .router: Use(x: 0, y: 0, width: 120) { RouterSymbol() }
        case .laptop: Use(x: 0, y: 0, width: 120) { LaptopSymbol() }
        case .search:
            ForEach([0.0, 0.8, 1.6], id: \.self) { delay in
                let a = OnboardingArtAnimation.pulse(time: time, delay: delay, reduceMotion: reduceMotion)
                Element(circle(60, 62, 44), stroke: .wave, width: 2.5)
                    .scaleEffect(a.scale, anchor: UnitPoint(x: 0.5, y: 62 / 120))
                    .opacity(a.opacity)
            }
            Use(x: 20, y: 18, width: 80) { RouterSymbol() }
        case .network:
            Element(circle(60, 60, 38), fill: .gl, stroke: .rim, width: 1.2)
            Element(path("M22 60 H98 M60 22 C44 36 44 84 60 98 C76 84 76 36 60 22 M30 40 H90 M30 80 H90"),
                    stroke: .wave, width: 3.5, cap: .round)
        case .tag:
            Use(x: -4, y: -6, width: 96) { RouterSymbol() }
            Element(path("M66 70 H100 Q106 70 106 76 V96 Q106 102 100 102 H66 L56 86 Z"), fill: .gl, stroke: .rim, width: 1.2)
            Element(circle(66, 86, 3), fill: .wave)
            Element(path("M76 82 H96 M76 90 H90"), stroke: .t, width: 4, cap: .round)
        case .cert:
            Element(path("M60 16 L95 28 V57 C95 80 79 95 60 104 C41 95 25 80 25 57 V28 Z"), fill: .gl, stroke: .rim, width: 1.2)
            Element(path("M60 27 L85 36 V57 C85 74 74 85 60 92 C46 85 35 74 35 57 V36 Z"), stroke: .wave2, width: 2)
            Element(path("M45 60 L56 71 L76 49"), stroke: .t, width: 7.5, cap: .round, join: .round)
        case .lock:
            Element(path("M42 56 V44 A18 18 0 0 1 78 44 V56"), stroke: .color(.white), width: 9, cap: .round)
            Element(rect(28, 52, 64, 50, rx: 12), fill: .gl, stroke: .rim, width: 1.2)
            Element(circle(60, 72, 6.5), fill: .t)
            Element(rect(57, 73, 6, 14, rx: 3), fill: .t)
        case .key:
            ZStack {
                Element(rect(50, 53, 56, 14, rx: 7), fill: .gl, stroke: .rim, width: 1)
                Element(rect(84, 62, 8, 15, rx: 2.5), fill: .gl, stroke: .rim, width: 1)
                Element(rect(96, 62, 8, 11, rx: 2.5), fill: .gl, stroke: .rim, width: 1)
                Element(circle(36, 60, 21), fill: .gl, stroke: .rim, width: 1.2)
                Element(circle(32, 60, 7), fill: .t)
            }
            .frame(width: 120, height: 120)
            .rotationEffect(.degrees(-38))
        case .fingerprint:
            Element(rect(24, 18, 72, 84, rx: 16), fill: .gl, stroke: .rim, width: 1.2)
            ForEach([
                "M60 60 V70",
                "M52 76 C53 70 52 64 52 60 A8 8 0 0 1 68 60 C68 66 68 72 66 80",
                "M45 72 C46 68 45 64 45 60 A15 15 0 0 1 75 60 C75 68 74 76 72 84",
                "M39 50 A22 22 0 0 1 81 54 C82 62 81 72 79 80",
                "M38 62 V66",
            ], id: \.self) { d in
                Element(path(d), stroke: .t, width: 3.6, cap: .round)
            }
        case .terminal:
            Element(rect(14, 22, 92, 76, rx: 14), fill: .gl, stroke: .rim, width: 1.2)
            ForEach([28.0, 38.0, 48.0], id: \.self) { cx in
                Element(circle(cx, 35, 3.2), fill: .wave2)
            }
            Element(path("M32 56 L44 65 L32 74"), stroke: .t, width: 6, cap: .round, join: .round)
            Element(path("M52 76 H74"), stroke: .t, width: 6, cap: .round)
                .opacity(OnboardingArtAnimation.blinkOpacity(time: time, reduceMotion: reduceMotion))
        case .ping:
            Element(path("M78 36 A26 26 0 0 1 78 84 M86 26 A40 40 0 0 1 86 94"), stroke: .wave, width: 5, cap: .round)
            Element(rect(30, 22, 42, 76, rx: 10), fill: .gl, stroke: .rim, width: 1.2)
            Element(path("M45 52 A10 10 0 1 0 57 52 M51 44 V58"), stroke: .t, width: 4.5, cap: .round)
            Element(rect(45, 88, 12, 3, rx: 1.5), fill: .wave2)
        case .ports:
            Element(rect(12, 38, 96, 44, rx: 12), fill: .gl, stroke: .rim, width: 1.2)
            Element(path("M22 58 h16 v14 h-4 v3 h-8 v-3 h-4 z"), fill: .ports)
            Element(path("M44 58 h16 v14 h-4 v3 h-8 v-3 h-4 z"), fill: .ports)
            Element(path("M66 58 h16 v14 h-4 v3 h-8 v-3 h-4 z"), fill: .ports)
            Element(path("M88 58 h12 v14 h-3 v3 h-6 v-3 h-3 z"), fill: .ports, opacity: 0.6)
            Element(circle(30, 49, 3), fill: .led)
            Element(circle(52, 49, 3), fill: .led)
            Element(circle(74, 49, 3), fill: .color(Color(red: 0xf5 / 255, green: 0xb7 / 255, blue: 0x40 / 255)))
            Element(circle(94, 49, 3), fill: .color(.black.opacity(0.15)))
        case .storage:
            Element(rect(18, 28, 84, 64, rx: 14), fill: .gl, stroke: .rim, width: 1.2)
            Element(circle(46, 60, 15), stroke: .wave2, width: 7)
            Element(circle(46, 60, 15), stroke: .t, width: 7, cap: .round, dash: [62, 100], rotate: Rot(-90, 46, 60))
            Element(path("M72 52 H90 M72 62 H86 M72 72 H82"), stroke: .wave, width: 4, cap: .round)
        case .log:
            Element(path("M30 16 H74 L92 34 V100 Q92 104 88 104 H34 Q30 104 30 100 Z"), fill: .gl, stroke: .rim, width: 1.2)
            Element(path("M74 16 V30 Q74 34 78 34 H92"), fill: .wave2)
            Element(path("M42 50 H80 M42 62 H70 M42 74 H78 M42 86 H62"), stroke: .t, width: 4.5, cap: .round)
            Element(path("M42 62 H70 M42 86 H62"), stroke: .wave, width: 4.5, cap: .round)
        case .dhcp:
            Element(path("M60 14 C80 14 94 28 94 47 C94 72 60 104 60 104 C60 104 26 72 26 47 C26 28 40 14 60 14 Z"),
                    fill: .gl, stroke: .rim, width: 1.2)
            Element(circle(60, 47, 14), fill: .t)
            Element(circle(60, 47, 5), fill: .color(.white))
        case .speed:
            Element(path("M22 82 A38 38 0 0 1 98 82"), stroke: .color(.white), width: 16, cap: .round)
            Element(path("M22 82 A38 38 0 0 1 98 82"), stroke: .t, width: 8, cap: .round, dash: [84, 200])
            Element(path("M60 82 L80 56"), stroke: .ink, width: 5, cap: .round)
            Element(circle(60, 82, 8), fill: .gl, stroke: .rim, width: 1)
        case .done: Use(x: 0, y: -6, width: 120) { RouterSymbol() }
        case .warn: Use(x: 0, y: -6, width: 120, opacity: 0.8) { RouterSymbol() }
        }
    }
}

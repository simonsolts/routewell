import SwiftUI
import Synchronization

/// Parses SVG path data (the `d` attribute) into a SwiftUI `Path`.
/// Supports M L H V C Q A Z and their lowercase relative forms.
/// Stops at the first command or number it does not understand and keeps what it has.
enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var scan = Scanner(d)
        var path = Path()
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var cmd: UInt8 = 0
        while true {
            scan.skipSeparators()
            if scan.atEnd { break }
            if let letter = scan.letter() {
                cmd = letter
                if cmd | 0x20 == UInt8(ascii: "z") {
                    path.closeSubpath()
                    cur = start
                    continue
                }
            } else if cmd == 0 || cmd | 0x20 == UInt8(ascii: "z") {
                break
            }
            let rel = cmd >= UInt8(ascii: "a")
            let o = rel ? cur : .zero
            switch cmd | 0x20 {
            case UInt8(ascii: "m"):
                guard let v = scan.numbers(2) else { return path }
                cur = CGPoint(x: o.x + v[0], y: o.y + v[1])
                start = cur
                path.move(to: cur)
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")  // extra pairs are line-to
            case UInt8(ascii: "l"):
                guard let v = scan.numbers(2) else { return path }
                cur = CGPoint(x: o.x + v[0], y: o.y + v[1])
                path.addLine(to: cur)
            case UInt8(ascii: "h"):
                guard let v = scan.numbers(1) else { return path }
                cur.x = o.x + v[0]
                path.addLine(to: cur)
            case UInt8(ascii: "v"):
                guard let v = scan.numbers(1) else { return path }
                cur.y = o.y + v[0]
                path.addLine(to: cur)
            case UInt8(ascii: "c"):
                guard let v = scan.numbers(6) else { return path }
                let end = CGPoint(x: o.x + v[4], y: o.y + v[5])
                path.addCurve(to: end,
                              control1: CGPoint(x: o.x + v[0], y: o.y + v[1]),
                              control2: CGPoint(x: o.x + v[2], y: o.y + v[3]))
                cur = end
            case UInt8(ascii: "q"):
                guard let v = scan.numbers(4) else { return path }
                let end = CGPoint(x: o.x + v[2], y: o.y + v[3])
                path.addQuadCurve(to: end, control: CGPoint(x: o.x + v[0], y: o.y + v[1]))
                cur = end
            case UInt8(ascii: "a"):
                guard let r = scan.numbers(3), let large = scan.flag(), let sweep = scan.flag(),
                      let e = scan.numbers(2) else { return path }
                let end = CGPoint(x: o.x + e[0], y: o.y + e[1])
                addArc(to: &path, from: cur, rx: r[0], ry: r[1], rotation: r[2],
                       large: large, sweep: sweep, end: end)
                cur = end
            default:
                return path
            }
        }
        return path
    }

    /// Adds an SVG elliptical arc as cubic curves (endpoint to centre parameterization, SVG spec F.6.5).
    static func addArc(to path: inout Path, from p0: CGPoint, rx rxIn: Double, ry ryIn: Double,
                       rotation: Double, large: Bool, sweep: Bool, end p1: CGPoint) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if p0 == p1 { return }
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = (large == sweep ? -1.0 : 1.0) * (max(0, num / den)).squareRoot()
        let cxp = coef * rx * y1 / ry
        let cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry
        let vx = (-x1 - cxp) / rx, vy = (-y1 - cyp) / ry
        let theta1 = atan2(uy, ux)
        var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        func point(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: cx + cosP * rx * u - sinP * ry * v, y: cy + sinP * rx * u + cosP * ry * v)
        }
        let count = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(count)
        let k = 4.0 / 3.0 * tan(step / 4)
        var a = theta1
        for i in 0..<count {
            let b = a + step
            let end = i == count - 1 ? p1 : point(cos(b), sin(b))
            path.addCurve(to: end,
                          control1: point(cos(a) - k * sin(a), sin(a) + k * cos(a)),
                          control2: point(cos(b) + k * sin(b), sin(b) - k * cos(b)))
            a = b
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0
        init(_ d: String) { bytes = Array(d.utf8) }
        var atEnd: Bool { i >= bytes.count }

        mutating func skipSeparators() {
            while i < bytes.count, bytes[i] == 44 || bytes[i] == 32 || (9...13).contains(bytes[i]) { i += 1 }
        }

        mutating func letter() -> UInt8? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let c = bytes[i] | 0x20
            guard (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(c) else { return nil }
            i += 1
            return bytes[i - 1]
        }

        mutating func numbers(_ count: Int) -> [Double]? {
            var out: [Double] = []
            for _ in 0..<count {
                guard let n = number() else { return nil }
                out.append(n)
            }
            return out
        }

        /// Arc flags are single characters and may have no separator after them.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < bytes.count, bytes[i] == 48 || bytes[i] == 49 else { return nil }
            i += 1
            return bytes[i - 1] == 49
        }

        private func isDigit(_ j: Int) -> Bool { j < bytes.count && (48...57).contains(bytes[j]) }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = i
            var j = i
            if j < bytes.count, bytes[j] == 43 || bytes[j] == 45 { j += 1 }
            var digits = 0
            while isDigit(j) { j += 1; digits += 1 }
            if j < bytes.count, bytes[j] == 46 {
                j += 1
                while isDigit(j) { j += 1; digits += 1 }
            }
            guard digits > 0 else { return nil }
            if j < bytes.count, bytes[j] | 0x20 == UInt8(ascii: "e") {
                var k = j + 1
                if k < bytes.count, bytes[k] == 43 || bytes[k] == 45 { k += 1 }
                if isDigit(k) {
                    while isDigit(k) { k += 1 }
                    j = k
                }
            }
            i = j
            return Double(String(decoding: bytes[begin..<j], as: UTF8.self))
        }
    }
}

/// A shape drawn in a fixed 120 x 120 coordinate space, scaled to fit the frame it is given.
struct SVGShape: Shape {
    enum Kind: Hashable, Sendable {
        case path(String)
        case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
    }

    struct Geometry: Sendable {
        let path: Path
        /// Tight bounding box of the fill area, used for objectBoundingBox gradients.
        let bounds: CGRect
    }

    static let space: CGFloat = 120
    let kind: Kind

    init(d: String) { kind = .path(d) }
    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat = 0) {
        kind = .rect(x: x, y: y, width: width, height: height, rx: rx)
    }
    init(cx: CGFloat, cy: CGFloat, r: CGFloat) { kind = .circle(cx: cx, cy: cy, r: r) }

    /// The shape in 120 x 120 space.
    var geometry: Geometry { Self.geometry(for: kind) }
    var bounds: CGRect { geometry.bounds }

    func path(in rect: CGRect) -> Path {
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / Self.space, y: rect.height / Self.space)
        return geometry.path.applying(transform)
    }

    // Parsed path data is cached, so the parser does not run on every frame.
    private static let cache = Mutex<[String: Geometry]>([:])

    private static func geometry(for kind: Kind) -> Geometry {
        switch kind {
        case .path(let d):
            if let hit = cache.withLock({ $0[d] }) { return hit }
            let path = SVGPathParser.parse(d)
            let made = Geometry(path: path, bounds: path.cgPath.boundingBoxOfPath)
            cache.withLock { $0[d] = made }
            return made
        case .rect(let x, let y, let w, let h, let rx):
            // Built from plain segments. `Path(roundedRect:)` is a special
            // primitive that the on-screen renderer drew at the wrong size
            // inside the scaled, shadowed glyph group.
            let r = CGRect(x: x, y: y, width: w, height: h)
            let radius = min(rx, w / 2, h / 2)
            var path = Path()
            path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
            path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
            path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radius)
            path.closeSubpath()
            return Geometry(path: path, bounds: r)
        case .circle(let cx, let cy, let r):
            // Starts at 3 o'clock and runs clockwise, like an SVG circle, so dashes line up.
            var path = Path()
            let right = CGPoint(x: cx + r, y: cy), left = CGPoint(x: cx - r, y: cy)
            path.move(to: right)
            SVGPathParser.addArc(to: &path, from: right, rx: r, ry: r, rotation: 0, large: true, sweep: true, end: left)
            SVGPathParser.addArc(to: &path, from: left, rx: r, ry: r, rotation: 0, large: true, sweep: true, end: right)
            path.closeSubpath()
            return Geometry(path: path, bounds: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        }
    }
}

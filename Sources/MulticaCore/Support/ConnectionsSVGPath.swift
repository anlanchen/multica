import Foundation

/// SVG path data (`d`) reduced to absolute move/line/cubic/close commands, so
/// brand marks can be drawn natively at any size.
public enum ConnectionsSVGPath {
    public struct Point: Sendable, Hashable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    public enum Command: Sendable, Hashable {
        case move(Point)
        case line(Point)
        case cubic(Point, Point, Point)
        case close
    }

    private struct Scanner {
        let chars: [Character]
        var i = 0

        init(_ s: String) { chars = Array(s) }

        mutating func skipSeparators() {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
        }

        mutating func command() -> Character? {
            skipSeparators()
            guard i < chars.count, chars[i].isLetter, chars[i] != "e", chars[i] != "E" else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        var atNumber: Bool {
            var j = i
            while j < chars.count, chars[j].isWhitespace || chars[j] == "," { j += 1 }
            guard j < chars.count else { return false }
            let c = chars[j]
            return c.isNumber || c == "-" || c == "+" || c == "."
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var sawDot = false, sawDigit = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { sawDigit = true; i += 1 }
                else if c == ".", !sawDot { sawDot = true; i += 1 }
                else { break }
            }
            if sawDigit, i < chars.count, chars[i] == "e" || chars[i] == "E" {
                var j = i + 1
                if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
                if j < chars.count, chars[j].isNumber {
                    i = j
                    while i < chars.count, chars[i].isNumber { i += 1 }
                }
            }
            guard sawDigit else { i = start; return nil }
            return Double(String(chars[start..<i]))
        }

        /// Arc flags may be written without separators (`a1 1 0 01.5.5`).
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }
    }

    public static func parse(_ d: String) -> [Command] {
        var s = Scanner(d)
        var out: [Command] = []
        var current = Point(0, 0)
        var start = Point(0, 0)
        var lastControl: Point?
        var lastQuad: Point?
        var cmd: Character?

        while true {
            if let c = s.command() {
                cmd = c
            } else if cmd == nil || !s.atNumber {
                break
            }
            guard let c = cmd else { break }
            let rel = c.isLowercase
            func pt(_ x: Double, _ y: Double) -> Point { rel ? Point(current.x + x, current.y + y) : Point(x, y) }
            var nextControl: Point?
            var nextQuad: Point?

            switch c.uppercased() {
            case "M":
                guard let x = s.number(), let y = s.number() else { return out }
                current = pt(x, y)
                start = current
                out.append(.move(current))
                cmd = rel ? "l" : "L"
            case "L":
                guard let x = s.number(), let y = s.number() else { return out }
                current = pt(x, y)
                out.append(.line(current))
            case "H":
                guard let x = s.number() else { return out }
                current = Point(rel ? current.x + x : x, current.y)
                out.append(.line(current))
            case "V":
                guard let y = s.number() else { return out }
                current = Point(current.x, rel ? current.y + y : y)
                out.append(.line(current))
            case "C":
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(),
                      let x = s.number(), let y = s.number() else { return out }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), end = pt(x, y)
                out.append(.cubic(c1, c2, end))
                current = end
                nextControl = c2
            case "S":
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return out }
                let c1 = lastControl.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let c2 = pt(x2, y2), end = pt(x, y)
                out.append(.cubic(c1, c2, end))
                current = end
                nextControl = c2
            case "Q":
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return out }
                let q = pt(x1, y1), end = pt(x, y)
                out.append(quadratic(from: current, q, end))
                current = end
                nextQuad = q
            case "T":
                guard let x = s.number(), let y = s.number() else { return out }
                let q = lastQuad.map { Point(2 * current.x - $0.x, 2 * current.y - $0.y) } ?? current
                let end = pt(x, y)
                out.append(quadratic(from: current, q, end))
                current = end
                nextQuad = q
            case "A":
                guard let rx = s.number(), let ry = s.number(), let rotation = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let x = s.number(), let y = s.number() else { return out }
                let end = pt(x, y)
                out.append(contentsOf: arc(from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep))
                current = end
            case "Z":
                out.append(.close)
                current = start
                cmd = nil
            default:
                return out
            }
            lastControl = nextControl
            lastQuad = nextQuad
        }
        return out
    }

    private static func quadratic(from p0: Point, _ q: Point, _ p: Point) -> Command {
        .cubic(Point(p0.x + 2 / 3 * (q.x - p0.x), p0.y + 2 / 3 * (q.y - p0.y)),
               Point(p.x + 2 / 3 * (q.x - p.x), p.y + 2 / 3 * (q.y - p.y)), p)
    }

    /// Endpoint arc → cubic Béziers (SVG 1.1 appendix F.6).
    static func arc(from p0: Point, to p: Point, rx rxIn: Double, ry ryIn: Double, rotation: Double, large: Bool, sweep: Bool) -> [Command] {
        if p0 == p { return [] }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { return [.line(p)] }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var out: [Command] = []
        var t = theta1
        func point(_ a: Double) -> Point {
            Point(cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi, cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func derivative(_ a: Double) -> Point {
            Point(-rx * sin(a) * cosPhi - ry * cos(a) * sinPhi, -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        for i in 0..<segments {
            let t2 = t + step
            let a = point(t), b = i == segments - 1 ? p : point(t2)
            let da = derivative(t), db = derivative(t2)
            out.append(.cubic(Point(a.x + k * da.x, a.y + k * da.y), Point(b.x - k * db.x, b.y - k * db.y), b))
            t = t2
        }
        return out
    }
}

import CoreGraphics
import Foundation

// An icon's SVG body as one path on Lucide's 24-unit grid, y down, to be stroked. See spec/icons.md.
// Covers what Lucide uses: path, circle, ellipse, rect, line, polyline and polygon, and every path command.
// Lucide's few filled dots (r 0.5) sit inside their own 1.5 px stroke, so stroking alone draws them.

extension Icons {
    /// Each icon's outline, parsed the first time it's drawn. NSCache is thread-safe.
    nonisolated(unsafe) private static let outlines = NSCache<NSString, CGPath>()

    /// The icon's outline, or nil for a name this client doesn't know.
    public static func path(_ name: String) -> CGPath? {
        if let found = outlines.object(forKey: name as NSString) { return found }
        guard let body = body(name) else { return nil }
        let outline = svgPath(body)
        outlines.setObject(outline, forKey: name as NSString)
        return outline
    }
}

/// The elements of an SVG body as one path.
func svgPath(_ body: String) -> CGPath {
    let path = CGMutablePath()
    for element in body.matches(of: /<(\w+)([^>]*)>/) {
        var a: [String: String] = [:]
        for attribute in element.output.2.matches(of: /([\w-]+)="([^"]*)"/) {
            a[String(attribute.output.1)] = String(attribute.output.2)
        }
        func n(_ key: String) -> CGFloat { a[key].flatMap(Double.init).map { CGFloat($0) } ?? 0 }
        switch element.output.1 {
        case "path":
            addPathData(a["d"] ?? "", to: path)
        case "circle":
            path.addEllipse(in: CGRect(x: n("cx") - n("r"), y: n("cy") - n("r"), width: 2 * n("r"), height: 2 * n("r")))
        case "ellipse":
            path.addEllipse(in: CGRect(x: n("cx") - n("rx"), y: n("cy") - n("ry"), width: 2 * n("rx"), height: 2 * n("ry")))
        case "rect":
            let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
            let rx = a["rx"] != nil ? n("rx") : n("ry"), ry = a["ry"] != nil ? n("ry") : n("rx")
            path.addRoundedRect(in: rect, cornerWidth: min(rx, rect.width / 2), cornerHeight: min(ry, rect.height / 2))
        case "line":
            path.move(to: CGPoint(x: n("x1"), y: n("y1")))
            path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
        case "polyline", "polygon":
            var scanner = PathScanner(a["points"] ?? "")
            var points: [CGPoint] = []
            while let x = scanner.number(), let y = scanner.number() { points.append(CGPoint(x: x, y: y)) }
            path.addLines(between: points)
            if element.output.1 == "polygon" { path.closeSubpath() }
        default:
            break
        }
    }
    return path
}

/// Numbers, flags and commands in path data, with SVG's loose separators: "1.02.5" is 1.02 then .5.
struct PathScanner {
    private let bytes: [UInt8]
    private var i = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    private func at(_ k: Int, _ characters: String) -> Bool {
        k < bytes.count && characters.utf8.contains(bytes[k])
    }

    private mutating func skip() {
        while at(i, " ,\n\r\t") { i += 1 }
    }

    /// The next command letter, if one comes next. "e" is an exponent, never a command.
    mutating func command() -> UInt8? {
        skip()
        guard i < bytes.count, at(i, "MmLlHhVvCcSsQqTtAaZz") else { return nil }
        defer { i += 1 }
        return bytes[i]
    }

    mutating func number() -> CGFloat? {
        skip()
        let start = i
        if at(i, "+-") { i += 1 }
        while at(i, "0123456789") { i += 1 }
        if at(i, ".") { i += 1; while at(i, "0123456789") { i += 1 } }
        if i > start, at(i, "eE") {
            i += 1
            if at(i, "+-") { i += 1 }
            while at(i, "0123456789") { i += 1 }
        }
        guard let value = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else {
            i = start
            return nil
        }
        return CGFloat(value)
    }

    /// An arc's flag: one digit, which may run into what follows ("011 2" is 0, 1, 1 2).
    mutating func flag() -> Bool? {
        skip()
        guard at(i, "01") else { return nil }
        defer { i += 1 }
        return bytes[i] == UInt8(ascii: "1")
    }

    var atEnd: Bool {
        mutating get { skip(); return i >= bytes.count }
    }
}

/// Path data, appended to path.
func addPathData(_ d: String, to path: CGMutablePath) {
    var s = PathScanner(d)
    var command: Character = " "
    var point = CGPoint.zero, start = CGPoint.zero
    var lastCubic: CGPoint?, lastQuad: CGPoint?

    while !s.atEnd {
        if let next = s.command() {
            command = Character(UnicodeScalar(next))
        } else if command == " " || command.lowercased() == "z" {
            return  // numbers with no command to repeat
        }
        let relative = command.isLowercase
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            relative ? CGPoint(x: point.x + x, y: point.y + y) : CGPoint(x: x, y: y)
        }
        var cubic: CGPoint?, quad: CGPoint?
        switch command.lowercased() {
        case "m":  // then implicit lines
            guard let x = s.number(), let y = s.number() else { return }
            point = at(x, y)
            start = point
            path.move(to: point)
            command = relative ? "l" : "L"
        case "l":
            guard let x = s.number(), let y = s.number() else { return }
            point = at(x, y)
            path.addLine(to: point)
        case "h":
            guard let x = s.number() else { return }
            point = CGPoint(x: relative ? point.x + x : x, y: point.y)
            path.addLine(to: point)
        case "v":
            guard let y = s.number() else { return }
            point = CGPoint(x: point.x, y: relative ? point.y + y : y)
            path.addLine(to: point)
        case "c":
            guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(),
                  let x = s.number(), let y = s.number() else { return }
            let c1 = at(x1, y1), c2 = at(x2, y2)
            point = at(x, y)
            path.addCurve(to: point, control1: c1, control2: c2)
            cubic = c2
        case "s":  // the first control reflects the last curve's
            guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return }
            let c1 = lastCubic.map { CGPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point
            let c2 = at(x2, y2)
            point = at(x, y)
            path.addCurve(to: point, control1: c1, control2: c2)
            cubic = c2
        case "q":
            guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return }
            let c = at(x1, y1)
            point = at(x, y)
            path.addQuadCurve(to: point, control: c)
            quad = c
        case "t":
            guard let x = s.number(), let y = s.number() else { return }
            let c = lastQuad.map { CGPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point
            point = at(x, y)
            path.addQuadCurve(to: point, control: c)
            quad = c
        case "a":
            guard let rx = s.number(), let ry = s.number(), let rotation = s.number(), let large = s.flag(),
                  let sweep = s.flag(), let x = s.number(), let y = s.number() else { return }
            let end = at(x, y)
            addArc(to: path, from: point, to: end, rx: rx, ry: ry, degrees: rotation, large: large, sweep: sweep)
            point = end
        case "z":
            path.closeSubpath()
            point = start
        default:
            return
        }
        (lastCubic, lastQuad) = (cubic, quad)
    }
}

/// SVG's endpoint arc, converted to its centre and drawn as a transformed unit circle (SVG 1.1, appendix F.6).
func addArc(to path: CGMutablePath, from p1: CGPoint, to p2: CGPoint, rx: CGFloat, ry: CGFloat, degrees: CGFloat,
            large: Bool, sweep: Bool) {
    var rx = abs(rx), ry = abs(ry)
    guard rx > 0, ry > 0, p1 != p2 else {
        if p1 != p2 { path.addLine(to: p2) }
        return
    }
    let phi = degrees * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
    let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
    let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    let coef = (large != sweep ? 1 : -1) * max(0, num / den).squareRoot()
    let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
    let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (p1.x + p2.x) / 2,
                         y: sinPhi * cx1 + cosPhi * cy1 + (p1.y + p2.y) / 2)
    let start = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
    var delta = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - start
    if sweep, delta < 0 { delta += 2 * .pi }
    if !sweep, delta > 0 { delta -= 2 * .pi }
    let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: phi).scaledBy(x: rx, y: ry)
    path.addRelativeArc(center: .zero, radius: 1, startAngle: start, delta: delta, transform: transform)
}

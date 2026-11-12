import SwiftUI

/// A small broom, as the desktop draws it: a handle and a filled head, on a 16-unit grid.
nonisolated struct BroomIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var lines = Path()
        lines.move(to: p(8.7, 8.0))
        lines.addLine(to: p(13.2, 2.5))
        lines.move(to: p(6.7, 7.8))
        lines.addLine(to: p(9.7, 10.2))
        var path = lines.strokedPath(StrokeStyle(lineWidth: 1.5 * s, lineCap: .round, lineJoin: .round))
        var head = Path()
        head.move(to: p(6.2, 8.4))
        head.addLine(to: p(9.2, 10.8))
        head.addLine(to: p(6.8, 14.1))
        head.addLine(to: p(2.3, 11.0))
        head.closeSubpath()
        path.addPath(head)
        return path
    }
}

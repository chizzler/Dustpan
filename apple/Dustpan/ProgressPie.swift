import SwiftUI

/// A wedge from 12 o'clock, clockwise, filling fraction of a circle.
nonisolated struct ProgressPie: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        guard fraction < 1 else { return Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                               width: radius * 2, height: radius * 2)) }
        var path = Path()
        path.move(to: centre)
        path.addArc(center: centre, radius: radius, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

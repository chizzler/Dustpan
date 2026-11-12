import DustpanCore
import SwiftUI

/// A day's time column behind its blocks: hours outside the grid shaded, a line each hour, the past dimmed.
struct GridBackground: View {
    let grid: GridPrefs
    /// Minutes from midnight dimmed as past: the whole day before today, up to now today.
    let pastUntil: Int

    var body: some View {
        Canvas { context, size in
            let perMinute = CalendarMetrics.perMinute
            let shade = GraphicsContext.Shading.color(.primary.opacity(0.03))
            func band(_ from: Int, _ to: Int) {
                guard to > from else { return }
                context.fill(Path(CGRect(x: 0, y: Double(from) * perMinute, width: size.width,
                                         height: Double(to - from) * perMinute)), with: shade)
            }
            band(0, grid.startHour * 60)
            band(grid.endHour * 60, dayMinutes)
            band(0, pastUntil)
            for hour in 1..<24 {
                context.fill(Path(CGRect(x: 0, y: Double(hour) * CalendarMetrics.hourHeight, width: size.width, height: 1)),
                             with: .color(.primary.opacity(0.08)))
            }
            context.fill(Path(CGRect(x: 0, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.1)))
        }
        .accessibilityHidden(true)
    }
}

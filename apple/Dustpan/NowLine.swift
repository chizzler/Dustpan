import DustpanCore
import SwiftUI

/// The red line at the current minute on today's column, moved once a minute.
struct NowLine: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Rectangle()
                .fill(.red)
                .frame(height: 2)
                .offset(y: Double(minuteOfDay(context.date)) * CalendarMetrics.perMinute - 1)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Minutes from midnight on this device's clock.
func minuteOfDay(_ date: Date) -> Int {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
}

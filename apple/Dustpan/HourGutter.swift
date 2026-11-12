import DustpanCore
import SwiftUI

/// The hours down the left of Week and Day, each beside its line.
struct HourGutter: View {
    let timeFormat: String

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : clockText(hour * 60, timeFormat: timeFormat))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .offset(y: -7)
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .frame(height: CalendarMetrics.hourHeight)
            }
        }
        .frame(width: CalendarMetrics.gutterWidth)
        .accessibilityHidden(true)
    }
}

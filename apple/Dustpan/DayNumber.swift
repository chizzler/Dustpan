import DustpanCore
import SwiftUI

/// A calendar day's number, in the accent colour's capsule when it's today, dimmed when past or out of the month.
struct DayNumber: View {
    let day: Day
    let isToday: Bool
    let dimmed: Bool

    var body: some View {
        Text(day.parts.day, format: .number)
            .font(.callout)
            .monospacedDigit()
            .bold(isToday)
            .foregroundStyle(isToday ? Color.white : dimmed ? Color.secondary : Color.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.tint.opacity(isToday ? 1 : 0), in: .capsule)
    }
}

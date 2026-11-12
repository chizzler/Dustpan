import DustpanCore
import SwiftUI

/// A Month day's date, marked when it's today and dimmed when past or in another month, and its load:
/// "3h / 8h", red when over the day length.
struct MonthDayHeader: View {
    let cell: MonthPage.Cell
    let dayLength: Int

    var body: some View {
        HStack {
            Text(cell.day.parts.day, format: .number)
                .font(.callout)
                .monospacedDigit()
                .bold(cell.isToday)
                .foregroundStyle(cell.isToday ? Color.white : dimmed ? Color.secondary : Color.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.tint.opacity(cell.isToday ? 1 : 0), in: .capsule)
            Spacer(minLength: 0)
            if cell.load.planned > 0 {
                Text("\(formatMinutes(cell.load.planned)) / \(formatMinutes(dayLength))")
                    .font(.callout)
                    .foregroundStyle(cell.load.over ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .help("Planned against your day length")
            }
        }
    }

    private var dimmed: Bool { !cell.inMonth || cell.isPast }
}

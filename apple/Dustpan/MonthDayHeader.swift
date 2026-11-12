import DustpanCore
import SwiftUI

/// A Month day's date, marked when it's today and dimmed when past or in another month, and its load:
/// "3h / 8h", red when over the day length.
struct MonthDayHeader: View {
    let cell: MonthPage.Cell
    let dayLength: Int

    var body: some View {
        HStack {
            DayNumber(day: cell.day, isToday: cell.isToday, dimmed: !cell.inMonth || cell.isPast)
            Spacer(minLength: 0)
            DayLoadText(load: cell.load, dayLength: dayLength)
        }
    }
}

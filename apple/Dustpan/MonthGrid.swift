import DustpanCore
import SwiftUI

/// Six weeks under the weekday names, every day the same size.
struct MonthGrid: View {
    let page: MonthPage
    @Binding var selection: String?

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(page.weeks[0]) { cell in
                    Text(weekdayName(cell.day))
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(page.weeks, id: \.[0].id) { week in
                GridRow {
                    ForEach(week) { cell in
                        MonthCell(cell: cell, colors: page.colors, selection: $selection)
                    }
                }
            }
        }
    }

    /// "Mon"
    private func weekdayName(_ day: Day) -> String { Calendar.current.shortWeekdaySymbols[day.weekday % 7] }
}

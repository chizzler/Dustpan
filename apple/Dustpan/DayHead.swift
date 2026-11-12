import DustpanCore
import SwiftUI

/// A day above Week and Day's grid: its date and load, deadlines, and the Unscheduled lane of tasks due that day
/// with no time. A task dropped on it gets that date and loses its time.
struct DayHead: View {
    @Environment(AppModel.self) private var model
    let column: TimeGridPage.Column
    let colors: [String: String]
    /// Day shows nine tasks in the lane before "+N more"; Week shows three.
    let single: Bool
    @Binding var selection: String?

    var body: some View {
        let (shown, hidden) = visibleRows(column.untimed, most: single ? 9 : 3)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(Calendar.current.shortWeekdaySymbols[column.day.weekday % 7])
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(.secondary)
                DayNumber(day: column.day, isToday: column.isToday, dimmed: column.isPast)
                Spacer(minLength: 0)
                DayLoadText(load: column.load, dayLength: model.calendarGrid.dayLength)
            }
            ForEach(column.deadlines) { task in
                Text("◆ \(task["title"].string ?? "")")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help("Deadline")
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(shown) { task in
                    CalendarTaskLine(task: task, colors: colors, selection: $selection)
                }
                if hidden > 0 {
                    MoreButton(tasks: Array(column.untimed.dropFirst(shown.count)), colors: colors,
                               selection: $selection)
                }
            }
            .padding(1)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .help("Unscheduled: due this day, no time")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Unscheduled")
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .taskDrop("lane:\(column.day)", .slot(column.day, minutes: nil))
        .border(.separator, width: 0.5)
    }
}

import DustpanCore
import SwiftUI

/// One day in Month: its date and load, deadlines, then as many task lines as fit and "+N more".
/// A task dropped on it gets that date and keeps its time.
struct MonthCell: View {
    @Environment(AppModel.self) private var model
    let cell: MonthPage.Cell
    let colors: [String: String]
    @Binding var selection: String?
    @State private var height = 0.0

    var body: some View {
        let fit = Int((height - CalendarMetrics.headerHeight) / CalendarMetrics.lineHeight)
        let (shown, hidden) = visibleRows(cell.tasks, most: max(1, fit - cell.deadlines.count))
        VStack(alignment: .leading, spacing: 1) {
            MonthDayHeader(cell: cell, dayLength: model.calendarGrid.dayLength)
            ForEach(cell.deadlines) { task in
                Text("◆ \(task["title"].string ?? "")")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help("Deadline")
            }
            ForEach(shown) { task in
                CalendarTaskLine(task: task, colors: colors, selection: $selection)
            }
            if hidden > 0 {
                MoreButton(tasks: Array(cell.tasks.dropFirst(shown.count)), colors: colors, selection: $selection)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(.quinary.opacity(cell.inMonth ? 0 : 1))
        .border(.separator, width: 0.5)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { height = $0 }
        .taskDrop("calendar:\(cell.day)", .day(cell.day))
    }
}

import DustpanCore
import SwiftUI

/// One day on Week and Day's grid: its blocks side by side where they overlap, "+N more" for a crowded cluster,
/// and, while a task is dragged over it, a ghost where it would land.
struct TimeColumn: View {
    @Environment(AppModel.self) private var model
    let column: TimeGridPage.Column
    let colors: [String: String]
    @Binding var selection: String?

    var body: some View {
        BlockLayout {
            ForEach(column.blocks) { block in
                CalendarBlock(block: block, colors: colors, selection: $selection)
                    .blockSpot(top: block.start, length: block.length, lane: block.lane, lanes: block.lanes)
            }
            ForEach(column.more) { more in
                MoreButton(tasks: more.tasks, colors: colors, selection: $selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .blockSpot(top: more.start, length: minBlockMinutes, lane: more.lane, lanes: more.lanes)
            }
            if case .slot(column.day, let start) = model.dropMark {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.tint.opacity(0.3))
                    .allowsHitTesting(false)
                    .blockSpot(top: start, length: max(minBlockMinutes, draggedLength))
            }
        }
        .background {
            TimelineView(.everyMinute) { context in
                GridBackground(grid: model.calendarGrid,
                               pastUntil: column.isPast ? dayMinutes : column.isToday ? minuteOfDay(context.date) : 0)
            }
        }
        .overlay {
            if column.isToday { NowLine() }
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onDrop(of: [.text], delegate: SlotDrop(model: model, day: column.day))
    }

    /// The dragged task's estimate, or the 30 minutes an unestimated block is drawn.
    private var draggedLength: Int {
        let minutes = model.drag.flatMap { model.snapshot.allTasks[$0.taskId]?["estimate_minutes"].int } ?? 0
        return minutes > 0 ? Int(minutes) : defaultBlockMinutes
    }
}

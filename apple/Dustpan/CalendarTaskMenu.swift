import DustpanCore
import SwiftUI

/// A calendar task's menu: the main window's row menu, with the moves in time (greyed when they'd change nothing)
/// instead of the list moves. Month offers only the day moves. No Labels item yet.
struct CalendarTaskMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.calendarActions) private var actions
    let task: Row

    var body: some View {
        let open = task["completed_at"].isNull
        Button("Edit…") { model.openFromCalendar(task.id) }
        Button(open ? "Complete" : "Reopen") { model.toggle(task) }
        if task["recurrence"].isTruthy && open {
            Button("Skip to Next Occurrence") { model.skip(task) }
        }
        if open {
            Divider()
            ForEach(gridMoves(task, gridStart: model.calendarGrid.startHour * 60, onGrid: actions.onGrid),
                    id: \.move) { move, target in
                Button(move.title) { if let target { actions.move(task.id, target, move.title) } }
                    .keyboardShortcut(move.shortcut)
                    .disabled(target == nil)
            }
            Divider()
            Button("Due Today") { model.drop(task.id, on: .day(model.today)) }
            Button("Due Tomorrow") { model.drop(task.id, on: .day(model.today + 1)) }
            MoveToMenu(taskId: task.id)
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete([task]) }
    }
}

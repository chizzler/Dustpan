import DustpanCore
import SwiftUI

extension View {
    /// The calendar's keys on its selected task, as on the desktop: j and k step through the shown tasks,
    /// Return opens, c completes or reopens, Delete deletes, Esc unselects, the arrows and u move it in time.
    /// The selection holds through every rebuild; a task that leaves the view hands it to its neighbour.
    func calendarKeys(selection: Binding<String?>, order: [String]) -> some View {
        modifier(CalendarKeys(selection: selection, order: order))
    }
}

private struct CalendarKeys: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.calendarActions) private var actions
    @Binding var selection: String?
    let order: [String]
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onChange(of: selection) { if selection != nil { focused = true } }
            .onChange(of: order, handOn)
            .onKeyPress(characters: ["j", "k"], phases: .down) { press in step(press.characters == "j" ? 1 : -1) }
            .onKeyPress(.return, action: open)
            .onKeyPress(characters: ["c", "C"], phases: .down) { _ in toggle() }
            .onKeyPress(characters: ["u"], phases: .down) { _ in run(.unschedule) }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                GridMove(arrow: press.key, modifiers: press.modifiers).map(run) ?? .ignored
            }
            .onDeleteCommand(perform: delete)
            .onExitCommand(perform: unselect)
    }

    private var task: Row? { selection.flatMap { model.snapshot.allTasks[$0] } }

    private func step(_ by: Int) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let index = selection.flatMap(order.firstIndex) ?? (by > 0 ? -1 : order.count)
        selection = order[min(order.count - 1, max(0, index + by))]
        return .handled
    }

    private func open() -> KeyPress.Result {
        guard let selection else { return .ignored }
        model.openFromCalendar(selection)
        return .handled
    }

    private func toggle() -> KeyPress.Result {
        guard let task else { return .ignored }
        model.toggle(task)
        return .handled
    }

    private func run(_ move: GridMove) -> KeyPress.Result {
        guard let task, task["completed_at"].isNull else { return .ignored }
        let moves = gridMoves(task, gridStart: model.calendarGrid.startHour * 60, onGrid: actions.onGrid)
        guard let found = moves.first(where: { $0.move == move }) else { return .ignored }
        if let target = found.target { actions.move(task.id, target, move.title) }
        return .handled
    }

    private func delete() {
        if let task { model.delete([task]) }
    }

    private func unselect() { selection = nil }

    /// The selected task left the view: its neighbour takes the selection.
    private func handOn(_ old: [String], _ new: [String]) {
        guard let selection, !new.contains(selection) else { return }
        let index = old.firstIndex(of: selection) ?? 0
        self.selection = new.isEmpty ? nil : new[min(index, new.count - 1)]
    }
}

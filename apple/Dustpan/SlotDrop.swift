import DustpanCore
import SwiftUI

/// A day's time column: a task dropped on it starts at the 15-minute slot under the pointer, shown by a ghost first.
struct SlotDrop: DropDelegate {
    let model: AppModel
    let day: Day

    private func slot(_ info: DropInfo) -> Int {
        let minutes = Int(info.location.y / CalendarMetrics.perMinute) / slotMinutes * slotMinutes
        return min(lastSlot, max(0, minutes))
    }

    func validateDrop(info: DropInfo) -> Bool { model.drag != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.drag != nil else { return DropProposal(operation: .forbidden) }
        model.mark(.slot(day, slot(info)))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.unmark() }

    func performDrop(info: DropInfo) -> Bool {
        defer { model.endDrag() }
        guard let drag = model.drag else { return false }
        model.drop(drag.taskId, on: .slot(day, minutes: slot(info)))
        return true
    }
}

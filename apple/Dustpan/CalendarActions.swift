import DustpanCore
import SwiftUI

/// What the calendar window gives its task lines and blocks: whether they're on the time grid, and a move by key
/// or menu, which takes the view with the task when it leaves the days shown.
struct CalendarActions {
    var onGrid = false
    var move: @MainActor (_ taskId: String, _ target: DropTarget, _ name: String) -> Void = { _, _, _ in }
}

extension EnvironmentValues {
    @Entry var calendarActions = CalendarActions()
}

extension DropTarget {
    /// The day a calendar move puts the task on, if it changes the day.
    var day: Day? {
        switch self {
        case .day(let day), .slot(let day, _): day
        case .stretch(_, let start): start?.day
        case .place, .project, .label: nil
        }
    }
}

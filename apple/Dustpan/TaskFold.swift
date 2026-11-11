import SwiftUI

/// The focused list's selected task, when it has subtasks: what View ▸ Fold Subtasks acts on.
struct TaskFold: Hashable {
    let taskId: String
    let folded: Bool
}

extension FocusedValues {
    @Entry var taskFold: TaskFold?
}

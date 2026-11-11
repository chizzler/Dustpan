import SwiftUI

/// View ▸ Fold Subtasks (⌘←) and Unfold Subtasks (⌘→), for the selected task, as Finder folds a list's folders.
/// Menu commands: the List's outline takes a bare ← itself, before onKeyPress sees it.
struct FoldCommand: View {
    let model: AppModel
    @FocusedValue(\.taskFold) private var fold

    var body: some View {
        Button("Fold Subtasks") { set(true) }
            .keyboardShortcut(.leftArrow)
            .disabled(fold?.folded != false)
        Button("Unfold Subtasks") { set(false) }
            .keyboardShortcut(.rightArrow)
            .disabled(fold?.folded != true)
    }

    private func set(_ folded: Bool) {
        guard let fold else { return }
        withAnimation { model.setFolded(fold.taskId, folded) }
    }
}

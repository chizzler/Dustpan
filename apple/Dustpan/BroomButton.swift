import DustpanCore
import SwiftUI

/// On an open parent with completed subtasks showing: clears them from this Mac's project lists, with Undo.
struct BroomButton: View {
    @Environment(AppModel.self) private var model
    let completed: [Row]

    var body: some View {
        Button(action: sweep) {
            Label {
                Text("Clear Completed Subtasks")
            } icon: {
                BroomIcon().frame(width: 14, height: 14)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Clear completed subtasks from this list")
    }

    private func sweep() { withAnimation { model.sweep(completed) } }
}

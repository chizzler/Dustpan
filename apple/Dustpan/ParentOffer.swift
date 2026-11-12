import DustpanCore
import SwiftUI

/// After the last open subtask is completed: "All subtasks of “Plan trip” are done", with Complete (⌘Return) and
/// a close button (Esc). Not plain Return, as on the desktop: as a window shortcut it took the Add field's Return,
/// and the list's table keeps Return to itself. Nothing is written until Complete. It goes when the parent stops
/// being ready, when the tick is undone, or on another page.
struct ParentOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let parent = model.readyToComplete {
            HStack(spacing: 10) {
                Image(systemName: "checklist.checked").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("All subtasks of “\(parent["title"].string ?? "")” are done")
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Complete", action: accept)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Complete the parent (⌘Return)")
                Button("Not Now", systemImage: "xmark", action: decline)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Not now (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func accept() { withAnimation { model.acceptOffer() } }
    private func decline() { model.declineOffer() }
}

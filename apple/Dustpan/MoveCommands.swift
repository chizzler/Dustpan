import DustpanCore
import SwiftUI

/// Edit ▸ Move Up to Outdent, for the focused list.
struct MoveCommands: View {
    @FocusedValue(\.listMoves) private var moves

    var body: some View {
        button(.up)
        button(.down)
        button(.top)
        button(.bottom)
        button(.indent)
        button(.outdent)
    }

    private func button(_ move: Nudge) -> some View {
        Button(move.title) { moves?.run(move) }
            .keyboardShortcut(move.shortcut)
            .disabled(moves?.can(move) != true)
    }
}

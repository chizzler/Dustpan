import DustpanCore
import SwiftUI

extension Nudge {
    var title: String {
        switch self {
        case .up: "Move Up"
        case .down: "Move Down"
        case .top: "Move to Top"
        case .bottom: "Move to Bottom"
        case .indent: "Indent"
        case .outdent: "Outdent"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .up: KeyboardShortcut(.upArrow, modifiers: .option)
        case .down: KeyboardShortcut(.downArrow, modifiers: .option)
        case .top: KeyboardShortcut(.upArrow, modifiers: [.option, .shift])
        case .bottom: KeyboardShortcut(.downArrow, modifiers: [.option, .shift])
        case .indent: KeyboardShortcut("]", modifiers: .command)
        case .outdent: KeyboardShortcut("[", modifiers: .command)
        }
    }
}

/// The moves the focused list offers Edit ▸ Move Up and the rest: its selected task's, or a sidebar row's.
/// They're menu commands because a List's table takes ⌥↑ and ⌥↓ itself, before onKeyPress sees them.
struct ListMoves {
    let can: (Nudge) -> Bool
    let run: (Nudge) -> Void
}

extension FocusedValues {
    @Entry var listMoves: ListMoves?
}

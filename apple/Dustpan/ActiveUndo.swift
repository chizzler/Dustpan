import SwiftUI

/// Each window keeps its own Undo, as on the Mac: the model registers with the active window's undo manager.
struct ActiveUndo: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .onChange(of: appearsActive, initial: true, adopt)
            .onChange(of: undoManager, adopt)
    }

    private func adopt() {
        if appearsActive { model.undoManager = undoManager }
    }
}

extension View {
    func activeUndo() -> some View { modifier(ActiveUndo()) }
}

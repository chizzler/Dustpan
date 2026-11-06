import SwiftUI

@main
struct DustpanApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Dustpan", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .task { await model.listen() }
                .task { await model.remind() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New View…") { model.editingView = ViewDraft() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.setupProblem != nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Sync Now") { Task { await model.sync() } }
                    .keyboardShortcut("r")
                    .disabled(model.setupProblem != nil)
            }
        }
    }
}

import SwiftUI

@main
struct DustpanApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Dustpan", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Sync Now") { Task { await model.sync() } }
                    .keyboardShortcut("r")
                    .disabled(model.setupProblem != nil)
            }
        }
    }
}

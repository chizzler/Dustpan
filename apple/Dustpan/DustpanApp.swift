import SwiftUI

@main
struct DustpanApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()
    @AppStorage("outlineSpike") private var outlineSpike = false

    init() {
        // Notes and quick add are Markdown-like: curly quotes and em dashes would change what they say.
        // Edit ▸ Substitutions turns them back on.
        UserDefaults.standard.register(defaults: [
            "NSAutomaticQuoteSubstitutionEnabled": false, "NSAutomaticDashSubstitutionEnabled": false,
        ])
    }

    var body: some Scene {
        Window("Dustpan", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    appDelegate.model = model
                    model.startServices()
                }
        }
        .windowResizability(.contentSize)
        Window("Calendar", id: CalendarWindow.id) {
            CalendarWindow()
                .environment(model)
        }
        .defaultSize(width: 900, height: 700)
        Settings {
            SettingsView()
                .environment(model)
        }
        .commands {
            TextEditingCommands()
            CommandGroup(replacing: .help) {
                Button("Welcome to Dustpan") { model.showsWelcome = true }
                    .disabled(model.setupProblem != nil)
            }
            CommandGroup(after: .newItem) {
                Button("New View…") { model.editingView = ViewDraft() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.setupProblem != nil || model.showsWelcome)
                Button("New Project…") { model.editingProject = ProjectDraft() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(model.setupProblem != nil || model.showsWelcome)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                MoveCommands()
            }
            CommandGroup(after: .sidebar) {
                FoldCommand(model: model)
                Divider()
                CalendarButton(model: model)
                    .keyboardShortcut("k")
                    .disabled(model.showsWelcome)
                Button("Filter…", action: model.openFilter)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.setupProblem != nil || model.showsWelcome)
                ForEach(Page.optional, id: \.self) { page in
                    let hidden = model.hiddenPages.contains(page.key ?? "")
                    Button(hidden ? "Show \(page.name)" : "Hide \(page.name)") { model.setHidden(page, !hidden) }
                        .disabled(model.setupProblem != nil)
                }
                Divider()
            }
            CommandGroup(after: .toolbar) {
                #if DEBUG
                Toggle("Outline Task List (Spike)", isOn: $outlineSpike)
                #endif
                Button("Sync Now") { Task { await model.sync() } }
                    .keyboardShortcut("r")
                    .disabled(!model.isConnected)
            }
        }
    }
}

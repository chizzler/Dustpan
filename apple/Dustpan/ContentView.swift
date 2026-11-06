import DustpanCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let problem = model.setupProblem {
            ContentUnavailableView {
                Label("Dustpan isn't set up", systemImage: "gearshape")
            } description: {
                Text("\(problem)\n\nPut OPENTODO_URL and OPENTODO_TOKEN in ~/.config/dustpan/config, then reopen Dustpan.")
            }
            .frame(minWidth: 480, minHeight: 320)
        } else {
            NavigationSplitView {
                Sidebar()
            } detail: {
                TaskList(page: model.page ?? .inbox)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { SyncStatus() }
            }
            .frame(minWidth: 640, minHeight: 400)
        }
    }
}

struct SyncStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.status {
        case .idle:
            Button("Sync", systemImage: "arrow.clockwise") { Task { await model.sync() } }
                .help("Sync now (⌘R)")
        case .syncing:
            ProgressView().controlSize(.small).help("Syncing…")
        case .offline(let message):
            Button("Offline", systemImage: "wifi.slash") { Task { await model.sync() } }
                .labelStyle(.titleAndIcon)
                .help("Offline: \(message). Click to try again.")
        case .failed(let message):
            Button("Sync error", systemImage: "exclamationmark.triangle") { Task { await model.sync() } }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
                .help("\(message). Click to try again.")
        }
    }
}

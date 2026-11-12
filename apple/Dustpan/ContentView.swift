import DustpanCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("outlineSpike") private var outlineSpike = false

    var body: some View {
        @Bindable var model = model
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
                // A page of its own: selection and focus start fresh.
                Group {
                    switch model.page ?? .today {
                    case .inbox where outlineSpike: OutlinePage(page: .inbox)
                    case .project(let id) where outlineSpike: OutlinePage(page: .project(id))
                    case .inbox: TaskList(page: .inbox)
                    case .project(let id): TaskList(page: .project(id))
                    case .archived(let id): ArchivedPage(projectId: id)
                    case .trash: TrashPage()
                    case let page: GroupedTaskList(page: page)
                    }
                }
                .id(model.page)
                .safeAreaInset(edge: .top, spacing: 0) { ParentOffer() }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { CalendarButton(model: model) }
                ToolbarItem(placement: .primaryAction) { SyncStatus() }
            }
            .overlay(alignment: .bottom) { ToastView() }
            .sheet(item: $model.editing, content: TaskEditor.init)
            .sheet(item: $model.editingView, content: ViewEditor.init)
            .sheet(item: $model.editingProject, content: ProjectEditor.init)
            .sheet(item: $model.editingSection, content: SectionEditor.init)
            .sheet(item: $model.editingLabel, content: LabelEditor.init)
            .activeUndo()
            .task(reopenCalendar)
            .frame(minWidth: 640, minHeight: 400)
        }
    }

    /// The calendar comes back with the app when it was open.
    private func reopenCalendar() {
        if model.calendarOpen { openWindow(id: CalendarWindow.id) }
    }
}

struct SyncStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.status {
        case .idle:
            Button("Sync", systemImage: "arrow.clockwise") { Task { await model.sync() } }
                .help(idleHelp)
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

extension SyncStatus {
    /// "Synced 14:02 · live · 2 waiting. Sync now (⌘R)"
    private var idleHelp: String {
        var parts = [model.lastSynced.map { "Synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not synced yet"]
        if model.live { parts.append("live") }
        if model.waiting > 0 { parts.append("\(model.waiting) waiting") }
        return parts.joined(separator: " · ") + ". Sync now (⌘R)"
    }
}

/// The latest action's message, with Undo when it has one. Goes after 5 seconds.
struct ToastView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// With the calendar open, the toast shows in the window that's in front.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            if let toast = model.toast, appearsActive { bubble(toast) }
        }
        .animation(.snappy, value: model.toast)
        .task(id: model.toast?.id, expire)
    }

    private func bubble(_ toast: Toast) -> some View {
        HStack(spacing: 12) {
            Text(toast.message).lineLimit(2)
            if toast.undoable {
                Button("Undo", action: undo).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 16)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    private func undo() { undoManager?.undo() }

    private func expire() async {
        guard let id = model.toast?.id else { return }
        try? await Task.sleep(for: .seconds(5))
        if model.toast?.id == id { model.toast = nil }
    }
}

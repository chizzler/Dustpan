import DustpanCore
import SwiftUI

/// Deleted tasks and projects, newest first. Restore works offline. Deleting for good waits for the server, unless
/// the data here has never been on one.
struct TrashPage: View {
    @Environment(AppModel.self) private var model
    @State private var purging: [TrashItem] = []
    @State private var confirmsPurge = false

    var body: some View {
        let items = model.trash
        Group {
            if items.isEmpty {
                ContentUnavailableView("The Trash is empty", systemImage: "trash",
                                       description: Text(retentionText))
            } else {
                List {
                    Text(retentionText)
                        .foregroundStyle(.secondary)
                    ForEach(items) { item in
                        TrashRow(item: item, waiting: model.purging.contains(item.target)) { ask([item]) }
                    }
                }
            }
        }
        .navigationTitle("Trash")
        .toolbar {
            ToolbarItem {
                Button("Empty Trash…", systemImage: "trash.slash") { ask(items) }
                    .help("Delete everything in the Trash for good")
                    .disabled(items.isEmpty)
            }
        }
        .confirmationDialog(purgeTitle, isPresented: $confirmsPurge, presenting: purging) { items in
            Button("Delete for Good", role: .destructive) { model.deleteForGood(items) }
        } message: { items in
            Text(purgeMessage(items))
        }
    }

    private var retentionText: String {
        model.trashRetention > 0 ? "Deleted for good after \(model.trashRetention) days."
            : "Kept until you delete them for good."
    }

    private func ask(_ items: [TrashItem]) {
        purging = items.filter { !model.purging.contains($0.target) }
        confirmsPurge = !purging.isEmpty
    }

    private var purgeTitle: String {
        purging.count == 1 ? "Delete “\(purging[0].title)” for good?" : "Delete all \(purging.count) items for good?"
    }

    private func purgeMessage(_ items: [TrashItem]) -> String {
        let fate = switch model.purgeMode {
        case .local: "deleted permanently"
        case .server: "removed from every device and the server"
        case .onReconnect: "removed from every device and the server when you reconnect"
        }
        guard items.count == 1 else { return "They're \(fate). This can't be undone." }
        return (items[0].isProject ? "Its tasks go with it. "
            : "Any deleted subtasks go with it, including those deleted separately. ") + "It's \(fate), and can't be undone."
    }
}

private struct TrashRow: View {
    @Environment(AppModel.self) private var model
    let item: TrashItem
    /// Its permanent delete is queued: nothing more to do with it here.
    let waiting: Bool
    let purge: () -> Void

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text(details).font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                if item.isProject {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(Color(hex: item.color) ?? .secondary)
                        .imageScale(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Restore") { model.restore(item) }
            Button("Delete for Good…", systemImage: "trash.slash", action: purge)
                .labelStyle(.iconOnly)
                .help("Delete for good")
        }
        .disabled(waiting)
        .contextMenu {
            Button("Restore") { model.restore(item) }
            Button("Delete for Good…", role: .destructive, action: purge)
        }
    }

    /// "Work · with 2 subtasks · deleted Thu 12 Nov, 14:02 · 30 days left"
    private var details: String {
        let deleted = Date(timeIntervalSince1970: Double(item.deletedAt) / 1000)
        let days = remainingDays(deletedAt: item.deletedAt, retention: model.trashRetention, now: wallMs())
        let parts: [String?] = [
            item.isProject ? "Project" : item.projectName ?? "Inbox",
            item.subtasks > 0 ? "with \(item.subtasks) subtask\(item.subtasks == 1 ? "" : "s")" : nil,
            "deleted " + deleted.formatted(.dateTime.weekday().day().month().hour().minute()),
            waiting ? "deleting for good…" : days.map { "\($0) day\($0 == 1 ? "" : "s") left" },
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

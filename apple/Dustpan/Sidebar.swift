import DustpanCore
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Projects whose sub-projects are folded away. Everything starts open.
    @State private var collapsed: Set<String> = []
    @State private var deleting: Row?
    @State private var confirmsDelete = false

    var body: some View {
        @Bindable var model = model
        let today = isoToday()
        let snap = model.snapshot
        List(selection: $model.page) {
            Label("Today", systemImage: "star")
                .badge(todayCount(snap.tasks, today: model.today))
                .tag(Page.today)
            Label("Upcoming", systemImage: "calendar")
                .tag(Page.upcoming)
            Label("Inbox", systemImage: "tray")
                .badge(countOpen(snap, nil, today: today))
                .tag(Page.inbox)
            Section("Projects") {
                ProjectRows(nodes: snap.projects, today: today, collapsed: $collapsed)
            }
            Section {
                let ctx = snap.filterContext(today: model.today)
                ForEach(snap.views) { view in
                    Label(view["name"].string ?? "", systemImage: "line.3.horizontal.decrease.circle")
                        .badge((try? runQuery(view["query"].string ?? "", ctx, snap.tasks).count) ?? 0)
                        .tag(Page.view(view.id))
                        .contextMenu {
                            Button("Edit View…") { model.editingView = ViewDraft(view: view) }
                            Button("Delete View…", role: .destructive) {
                                deleting = view
                                confirmsDelete = true
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Views")
                    Spacer()
                    Button("New View", systemImage: "plus") { model.editingView = ViewDraft() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("New view (⇧⌘N)")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        .confirmationDialog("Delete view “\(deleting?["name"].string ?? "")”?", isPresented: $confirmsDelete,
                            presenting: deleting) { view in
            Button("Delete View", role: .destructive) { model.deleteView(view) }
        } message: { _ in
            Text("The view goes from every device. Your tasks stay.")
        }
    }
}

private struct ProjectRows: View {
    @Environment(AppModel.self) private var model
    let nodes: [Node]
    let today: String
    @Binding var collapsed: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                row(node)
            } else {
                DisclosureGroup(isExpanded: expanded(node.id)) {
                    ProjectRows(nodes: node.children, today: today, collapsed: $collapsed)
                } label: {
                    row(node)
                }
            }
        }
    }

    private func row(_ node: Node) -> some View {
        Label {
            Text(node.row["name"].string ?? "")
        } icon: {
            Image(systemName: "circle.fill")
                .foregroundStyle(Color(hex: node.row["color"].string) ?? .secondary)
                .imageScale(.small)
        }
        .badge(countOpen(model.snapshot, node.id, today: today))
        .tag(Page.project(node.id))
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding {
            !collapsed.contains(id)
        } set: { open in
            if open { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }
}

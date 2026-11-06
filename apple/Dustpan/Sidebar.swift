import DustpanCore
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Projects whose sub-projects are folded away. Everything starts open.
    @State private var collapsed: Set<String> = []

    var body: some View {
        @Bindable var model = model
        let today = isoToday()
        List(selection: $model.page) {
            Label("Inbox", systemImage: "tray")
                .badge(countOpen(model.snapshot, nil, today: today))
                .tag(Page.inbox)
            Section("Projects") {
                ProjectRows(nodes: model.snapshot.projects, today: today, collapsed: $collapsed)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
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

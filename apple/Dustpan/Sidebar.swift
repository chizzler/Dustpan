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
            LabelRows()
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

/// Live labels in sidebar order, with their open-task counts. Drag to reorder.
private struct LabelRows: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: Row?
    @State private var confirmsDelete = false
    @State private var merging: (source: Row, target: Row)?
    @State private var confirmsMerge = false

    var body: some View {
        let labels = model.snapshot.labelsInOrder
        let counts = labelCounts(model.snapshot.tasks, today: model.today)
        let twins = duplicateLabels(labels)
        Section {
            ForEach(labels.enumerated(), id: \.element.id) { index, label in
                row(label, count: counts[label.id] ?? 0, twin: twins.contains(label.id))
                    .contextMenu { menu(label, index: index, labels: labels) }
            }
            .onMove { from, to in
                guard let from = from.first, from != to, from + 1 != to else { return }
                // to counts the list with the moved label still in it.
                model.moveLabel(labels[from], to: to > from ? to - 1 : to)
            }
        } header: {
            HStack {
                Text("Labels")
                Spacer()
                Button("New Label", systemImage: "plus") { model.editingLabel = LabelDraft() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("New label")
            }
        }
        .labelDeleteConfirmation(deleting, isPresented: $confirmsDelete) { model.deleteLabel($0) }
        .confirmationDialog(mergeTitle, isPresented: $confirmsMerge, presenting: merging) { pair in
            Button("Merge") { model.mergeLabel(pair.source, into: pair.target) }
        } message: { pair in
            let uses = model.uses(of: pair.source)
            Text("\(uses) task\(uses == 1 ? "" : "s") change, and “\(pair.source["name"].string ?? "")” is deleted.")
        }
    }

    private func row(_ label: Row, count: Int, twin: Bool) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(label["name"].string ?? "")
                if twin {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("Another label has this name. Merge them from this label's menu.")
                        .accessibilityLabel("Another label has this name")
                }
            }
        } icon: {
            Image(systemName: "tag.fill")
                .foregroundStyle(Color(hex: label["color"].string) ?? .secondary)
                .imageScale(.small)
        }
        .badge(count)
        .tag(Page.label(label.id))
    }

    @ViewBuilder
    private func menu(_ label: Row, index: Int, labels: [Row]) -> some View {
        Button("Edit Label…") { model.editingLabel = LabelDraft(label: label) }
        Button("Move Up") { model.moveLabel(label, step: -1) }
            .disabled(index == 0)
        Button("Move Down") { model.moveLabel(label, step: 1) }
            .disabled(index == labels.count - 1)
        Menu("Merge Into") {
            ForEach(labels.filter { $0.id != label.id }) { target in
                Button(target["name"].string ?? "") {
                    merging = (label, target)
                    confirmsMerge = true
                }
            }
        }
        .disabled(labels.count < 2)
        Divider()
        Button("Delete Label…", role: .destructive) {
            if model.uses(of: label) > 0 {
                deleting = label
                confirmsDelete = true
            } else {
                model.deleteLabel(label)
            }
        }
    }

    private var mergeTitle: String {
        guard let merging else { return "" }
        return "Merge “\(merging.source["name"].string ?? "")” into “\(merging.target["name"].string ?? "")”?"
    }
}

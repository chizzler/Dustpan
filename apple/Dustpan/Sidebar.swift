import DustpanCore
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    /// Projects whose sub-projects are folded away. Everything starts open.
    @State private var collapsed: Set<String> = []
    @State private var deleting: Row?
    @State private var confirmsDelete = false
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let today = isoToday()
        let snap = model.snapshot
        List(selection: $model.page) {
            Label("Today", systemImage: "star")
                .sidebarDropArea()
                .taskDrop("today", .day(model.today))
                .badge(todayCount(snap.tasks, today: model.today))
                .tag(Page.today)
                .listRowInsets(.vertical, 0)
            Label("Upcoming", systemImage: "calendar")
                .tag(Page.upcoming)
            Label("Inbox", systemImage: "tray")
                .sidebarDropArea()
                .taskDrop("inbox", .project(nil), opens: .inbox)
                .badge(countOpen(snap, nil, today: today))
                .tag(Page.inbox)
                .listRowInsets(.vertical, 0)
            Section {
                ProjectRows(nodes: snap.projects, today: today, collapsed: $collapsed)
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button("New Project", systemImage: "plus") { model.editingProject = ProjectDraft() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("New project (⌥⌘N)")
                }
            }
            LabelRows()
            Section {
                let ctx = snap.filterContext(today: model.today)
                ForEach(snap.views.enumerated(), id: \.element.id) { index, view in
                    Label(view["name"].string ?? "", systemImage: "line.3.horizontal.decrease.circle")
                        .badge((try? runQuery(view["query"].string ?? "", ctx, snap.tasks).count) ?? 0)
                        .tag(Page.view(view.id))
                        .contextMenu {
                            Button("Edit View…") { model.editingView = ViewDraft(view: view) }
                            Button("Move Up") { model.moveView(view, step: -1) }
                                .keyboardShortcut(Nudge.up.shortcut)
                                .disabled(index == 0)
                            Button("Move Down") { model.moveView(view, step: 1) }
                                .keyboardShortcut(Nudge.down.shortcut)
                                .disabled(index == snap.views.count - 1)
                            Divider()
                            Button("Delete View…", role: .destructive) {
                                deleting = view
                                confirmsDelete = true
                            }
                        }
                }
                .onMove { from, to in
                    guard let from = from.first, from != to, from + 1 != to else { return }
                    // to counts the list with the moved view still in it.
                    model.moveView(snap.views[from], to: to > from ? to - 1 : to)
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
            ArchivedRows()
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        // A project row's drag takes the click, so the list doesn't take the focus by itself.
        .focused($focused)
        .onChange(of: model.page) { focused = true }
        .focusedValue(\.listMoves, moves)
        // Here for every project delete: the sidebar's menus, the project editor and an archived project's page.
        .confirmationDialog("Delete project “\(model.deletingProject?["name"].string ?? "")”?",
                            isPresented: $model.confirmsProjectDelete, presenting: model.deletingProject) { project in
            Button("Delete Project", role: .destructive) { model.deleteProject(project.id) }
        } message: { project in
            let open = model.openTasks(in: project.id)
            Text((open == 1 ? "Its open task goes" : "Its \(open) open tasks go") + " with it, on every device. Sub-projects move up a level.")
        }
        .confirmationDialog("Delete view “\(deleting?["name"].string ?? "")”?", isPresented: $confirmsDelete,
                            presenting: deleting) { view in
            Button("Delete View", role: .destructive) { model.deleteView(view) }
        } message: { _ in
            Text("The view goes from every device. Your tasks stay.")
        }
    }
}

extension Sidebar {
    /// Move Up and Move Down for the selected project, view or label, among its siblings.
    private var moves: ListMoves? {
        let snap = model.snapshot
        let (index, count, step): (Int?, Int, (Int) -> Void)
        switch model.page {
        case .project(let id):
            let siblings = siblingProjects(id, snap.projects)
            (index, count, step) = (siblings.firstIndex { $0.id == id }, siblings.count, { model.moveProject(id, step: $0) })
        case .view(let id):
            guard let view = snap.views.first(where: { $0.id == id }) else { return nil }
            (index, count, step) = (snap.views.firstIndex { $0.id == id }, snap.views.count, { model.moveView(view, step: $0) })
        case .label(let id):
            guard let label = snap.labels[id] else { return nil }
            let labels = snap.labelsInOrder
            (index, count, step) = (labels.firstIndex { $0.id == id }, labels.count, { model.moveLabel(label, step: $0) })
        default: return nil
        }
        guard let index else { return nil }
        return ListMoves(can: { $0 == .up ? index > 0 : $0 == .down && index < count - 1 }) { move in
            if move == .up || move == .down { step(move == .up ? -1 : 1) }
        }
    }
}

/// The projects beside projectId, itself included.
private func siblingProjects(_ projectId: String, _ nodes: [Node]) -> [Node] {
    if nodes.contains(where: { $0.id == projectId }) { return nodes }
    return nodes.lazy.map { siblingProjects(projectId, $0.children) }.first { !$0.isEmpty } ?? []
}

/// A project row in the sidebar: the tree flattened in display order, as the task list does it.
private struct ProjectLine: Identifiable {
    let node: Node
    let depth: Int
    let parentId: String?
    let index: Int
    let siblings: Int
    var id: String { node.id }
}

/// The project tree as plain List rows, indented and with their own disclosure arrows. An outline row's arrow
/// and indent sit outside the row's view, where a drop gets a meaningless location and the List its own highlight.
private struct ProjectRows: View {
    @Environment(AppModel.self) private var model
    let nodes: [Node]
    let today: String
    @Binding var collapsed: Set<String>

    var body: some View {
        let lines = flatten(nodes, depth: 0, parent: nil)
        // By project id, not position: a row that moves keeps its identity, and its selection, in the List.
        ForEach(lines.enumerated(), id: \.element.id) { i, line in
            ProjectRow(line: line, first: i == 0, next: i + 1 < lines.count ? lines[i + 1] : nil, today: today,
                       collapsed: $collapsed)
        }
    }

    private func flatten(_ nodes: [Node], depth: Int, parent: String?) -> [ProjectLine] {
        nodes.enumerated().flatMap { index, node in
            [ProjectLine(node: node, depth: depth, parentId: parent, index: index, siblings: nodes.count)]
                + (collapsed.contains(node.id) ? [] : flatten(node.children, depth: depth + 1, parent: node.id))
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let line: ProjectLine
    let first: Bool
    let next: ProjectLine?
    let today: String
    @Binding var collapsed: Set<String>

    var body: some View {
        let node = line.node
        let name = node.row["name"].string ?? ""
        let open = !collapsed.contains(node.id)
        let shown = open ? node.children.map(\.id) : []
        HStack(spacing: 2) {
            // A ZStack, not a Group: an empty Group is no view, so a leaf would lose the arrow's room.
            ZStack {
                if !node.children.isEmpty {
                    Button(open ? "Collapse" : "Expand", systemImage: "chevron.right", action: toggle)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .frame(width: projectArrowWidth)
            Label {
                Text(name)
            } icon: {
                Image(systemName: "circle.fill")
                    .foregroundStyle(Color(hex: node.row["color"].string) ?? .secondary)
                    .imageScale(.small)
            }
        }
        .padding(.leading, Double(line.depth) * projectIndent)
        // Inside the drag: outside it, the badge breaks the List's clicks after a drag (macOS 27).
        .badge(countOpen(model.snapshot, node.id, today: today))
        .projectRow(ProjectSpot(id: node.id, parentId: line.parentId, children: shown, depth: line.depth, first: first,
                                next: next.map { ($0.node.id, $0.depth) }), name: name)
        .tag(Page.project(node.id))
        .contextMenu {
            Button("Edit Project…") { model.editingProject = ProjectDraft(project: node.row) }
            Button("New Sub-project…") { model.editingProject = ProjectDraft(parentId: node.id) }
            Button("Add Section…") { model.editingSection = SectionDraft(projectId: node.id) }
            Divider()
            Button("Move Up") { model.moveProject(node.id, step: -1) }
                .keyboardShortcut(Nudge.up.shortcut)
                .disabled(line.index == 0)
            Button("Move Down") { model.moveProject(node.id, step: 1) }
                .keyboardShortcut(Nudge.down.shortcut)
                .disabled(line.index == line.siblings - 1)
            Divider()
            Button("Archive") { model.archiveProject(node.id) }
            Button("Delete Project…", role: .destructive) { model.askToDelete(node.row) }
        }
        .listRowInsets(.vertical, 0)
    }

    private func toggle() {
        let id = line.node.id
        withAnimation { if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) } }
    }
}

/// Archived projects, flat, with their paths. Only when there are some.
private struct ArchivedRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let archived = model.snapshot.archivedProjects
        if !archived.isEmpty {
            Section("Archived") {
                ForEach(archived, id: \.row.id) { project, path in
                    Label {
                        Text(path)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(Color(hex: project["color"].string) ?? .secondary)
                            .imageScale(.small)
                    }
                    .tag(Page.archived(project.id))
                    .contextMenu {
                        Button("Unarchive") { model.unarchiveProject(project.id) }
                        Divider()
                        Button("Delete Project…", role: .destructive) { model.askToDelete(project) }
                    }
                }
            }
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
        .sidebarDropArea()
        .taskDrop("label:\(label.id)", .label(label.id))
        .badge(count)
        .tag(Page.label(label.id))
        .listRowInsets(.vertical, 0)
    }

    @ViewBuilder
    private func menu(_ label: Row, index: Int, labels: [Row]) -> some View {
        Button("Edit Label…") { model.editingLabel = LabelDraft(label: label) }
        Button("Move Up") { model.moveLabel(label, step: -1) }
            .keyboardShortcut(Nudge.up.shortcut)
            .disabled(index == 0)
        Button("Move Down") { model.moveLabel(label, step: 1) }
            .keyboardShortcut(Nudge.down.shortcut)
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

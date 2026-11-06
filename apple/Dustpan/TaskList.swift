import DustpanCore
import SwiftUI

struct TaskList: View {
    @Environment(AppModel.self) private var model
    let page: Page
    @State private var selection: Set<String> = []
    /// The list whose Add field has the focus.
    @FocusState private var adding: Place?

    var body: some View {
        let (title, projectId) = model.listHeading(page)
        let sections = projectSections(model.snapshot, projectId)
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections.enumerated(), id: \.offset) { _, section in
                    let place = Place(projectId: projectId, sectionId: section.id)
                    let items = flatten(section.tasks, depth: 0, parent: nil)
                    let list = section.isList ? DropList(projectId: projectId, sectionId: section.id,
                                                         slots: openSlots(section.tasks)) : nil
                    if section.name.isEmpty {
                        rows(items, list)
                        addRow(place, section, list)
                    } else {
                        Section {
                            rows(items, list)
                            addRow(place, section, list)
                        } header: {
                            heading(section.name, list)
                        }
                    }
                }
            }
            .onChange(of: model.flash) { _, id in
                guard let id else { return }
                selection = [id]
                withAnimation { proxy.scrollTo(id) }
            }
        }
        .taskMenus(selection: $selection)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Task", systemImage: "plus") { adding = Place(projectId: projectId) }
                    .keyboardShortcut("n")
                    .help("Add a task (⌘N)")
            }
        }
    }

    private func rows(_ items: [ListItem], _ list: DropList?) -> some View {
        ForEach(items) { item in
            PlacedTaskRow(item: item, list: item.isOpen ? list : nil)
        }
    }

    @ViewBuilder
    private func addRow(_ place: Place, _ section: DustpanCore.Section, _ list: DropList?) -> some View {
        if section.isList {
            AddTaskField(place: place, focus: $adding)
                .selectionDisabled()
                .listDrop(list, at: .end)
        }
    }

    /// A section's heading: a drop there goes to the top of the section.
    private func heading(_ name: String, _ list: DropList?) -> some View {
        Text(name).listDrop(list, at: .head)
    }

    private func flatten(_ nodes: [Node], depth: Int, parent: String?) -> [ListItem] {
        nodes.flatMap { node in
            [ListItem(node: node, slot: Slot(node.id, depth, parent))]
                + flatten(node.children, depth: depth + 1, parent: node.id)
        }
    }
}

/// A task in a project list, in display order.
private struct ListItem: Identifiable {
    let node: Node
    let slot: Slot
    var id: String { node.id }
    var isOpen: Bool { node.row["completed_at"].isNull }
}

/// A task row in a project or the Inbox: indented, draggable, and a drop target when the list takes drops.
private struct PlacedTaskRow: View {
    @Environment(AppModel.self) private var model
    let item: ListItem
    let list: DropList?
    @State private var height: Double = 28

    var body: some View {
        let task = item.node.row
        let id = task.id
        let drop = mark
        TaskRow(task: task, labels: model.snapshot.labels) {
            withAnimation { model.toggle(task) }
        }
        .taskDrag(task, subtasks: openBelow(item.node), indent: Double(item.slot.depth) * indentWidth)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { height = $0 }
        .overlay(alignment: .bottomLeading) {
            if let drop, drop.prev == id { DropLine(depth: drop.depth) }
        }
        .overlay(alignment: .topLeading) {
            if let drop, drop.prev == nil, drop.next == id { DropLine(depth: drop.depth) }
        }
        .overlay {
            if drop?.ring == id {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.tint, lineWidth: 2).padding(-2).allowsHitTesting(false)
            }
        }
        .flashes(id)
        .modifier(RowDrop(list: list, index: list?.slots.firstIndex(of: item.slot), height: height))
        .labelPicker(for: task)
    }

    /// The drop shown in this row's list.
    private var mark: Drop? {
        guard let list, case .list(list.key, let drop) = model.dropMark else { return nil }
        return drop
    }

    private func openBelow(_ node: Node) -> Int {
        node.children.reduce(0) { $0 + ($1.row["completed_at"].isNull ? 1 + openBelow($1) : 0) }
    }
}

private struct RowDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let list: DropList?
    let index: Int?
    let height: Double

    func body(content: Content) -> some View {
        if let list, let index {
            content.onDrop(of: [.text], delegate: ListDrop(model: model, list: list) { y in
                .row(index, dropZone(y, height: height))
            })
        } else {
            content
        }
    }
}

extension View {
    /// A list's heading or Add field as a drop target. Its line shows here when the list is empty.
    @ViewBuilder
    func listDrop(_ list: DropList?, at hit: ListHit) -> some View {
        if let list { modifier(ListEndDrop(list: list, hit: hit)) } else { self }
    }
}

private struct ListEndDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let list: DropList
    let hit: ListHit

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .overlay(alignment: .topLeading) {
                if case .end = hit, case .list(list.key, let drop) = model.dropMark, drop.prev == nil, drop.next == nil {
                    DropLine(depth: 0)
                }
            }
            .onDrop(of: [.text], delegate: ListDrop(model: model, list: list) { _ in hit })
    }
}

extension View {
    /// The row menu, double-click and keys of a list of tasks, keyed by task id.
    /// L opens the label picker on the selected task; Delete deletes the selection; Esc clears it.
    func taskMenus(selection: Binding<Set<String>>) -> some View { modifier(TaskMenus(selection: selection)) }
}

private struct TaskMenus: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<String>

    func body(content: Content) -> some View {
        content.contextMenu(forSelectionType: String.self) { ids in
            let tasks = ids.compactMap { model.snapshot.allTasks[$0] }
            if let task = tasks.first, tasks.count == 1 {
                Button("Edit…") { model.editing = task }
                Button(task["completed_at"].isNull ? "Complete" : "Reopen") { model.toggle(task) }
                if task["recurrence"].isTruthy && task["completed_at"].isNull {
                    Button("Skip to Next Occurrence") { model.skip(task) }
                }
                Button("Labels…") { model.labelling = task.id }
                Divider()
            }
            if !tasks.isEmpty {
                Button(tasks.count == 1 ? "Delete" : "Delete \(tasks.count) Tasks", role: .destructive) {
                    model.delete(tasks)
                }
            }
        } primaryAction: { ids in
            model.editing = ids.first.flatMap { model.snapshot.allTasks[$0] }
        }
        .onKeyPress(characters: ["l", "L"], phases: .down) { _ in
            guard selection.count == 1, let id = selection.first, model.snapshot.allTasks[id] != nil else {
                return .ignored
            }
            model.labelling = id
            return .handled
        }
        .onDeleteCommand {
            model.delete(selection.compactMap { model.snapshot.allTasks[$0] })
        }
        .onExitCommand { selection = [] }
    }
}

/// The last row of a list: type a title and press Return to add a task there, due on due when it's set.
struct AddTaskField: View {
    @Environment(AppModel.self) private var model
    let place: Place
    var due: JSON = nil
    /// A label page's label, which new tasks get.
    var labels: [String] = []
    var focus: FocusState<Place?>.Binding
    @State private var title = ""

    var body: some View {
        let preview = model.quickAddPreview(title)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.tint).accessibilityHidden(true)
                TextField("Add task", text: $title, prompt: Text("Add task, like “Call Sam tomorrow 3pm #Work @phone p1”"))
                    .textFieldStyle(.plain)
                    .focused(focus, equals: place)
                    .onSubmit {
                        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        if model.add(title, to: place, due: due, labels: labels) { title = "" }
                        focus.wrappedValue = place
                    }
                    .onKeyPress(.escape) {
                        title = ""
                        focus.wrappedValue = nil
                        return .handled
                    }
            }
            if !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .accessibilityLabel("Will set: \(preview)")
            }
        }
        .padding(.vertical, 2)
    }
}

struct TaskRow: View {
    let task: Row
    let labels: [String: Row]
    /// For a task listed away from its project: "Project" or "Project › Parent task".
    var place: String?
    /// The label page this row is on: its own chip is left out.
    var labelPage: String?
    let toggle: () -> Void

    var body: some View {
        let done = !task["completed_at"].isNull
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(done ? "Reopen" : "Complete", systemImage: done ? "checkmark.circle.fill" : "circle",
                   action: toggle)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(priorityColor(task["priority"].int))
                .bold(task["priority"].int.map { $0 < 4 } ?? false)
                .contentShape(.circle)
                .help(done ? "Reopen" : "Complete")
            VStack(alignment: .leading, spacing: 3) {
                Text(task["title"].string ?? "")
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                details.font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var details: some View {
        let due = formatDue(task["due"])
        let estimate = task["estimate_minutes"].int
        let chips = shownLabels(task["labels"], labels, skip: labelPage)
        let rule = task["recurrence"].string.flatMap { $0.isEmpty ? nil : $0 }
        let deadline = task["deadline"].string.flatMap(Day.init)
        if due != nil || estimate != nil || !chips.isEmpty || rule != nil || place != nil || deadline != nil {
            HStack(spacing: 10) {
                if let due {
                    Label(due.text, systemImage: "calendar")
                        .foregroundStyle(due.state == .overdue ? .red : due.state == .today ? .green : .secondary)
                }
                if let rule {
                    Image(systemName: "repeat")
                        .foregroundStyle(.secondary)
                        .help(rule)
                        .accessibilityLabel("Repeats \(rule)")
                }
                if let deadline {
                    let late = deadline.description < isoToday() && task["completed_at"].isNull
                    Label("Deadline \(formatDay(deadline))", systemImage: "flag.pattern.checkered")
                        .foregroundStyle(late ? .red : .secondary)
                }
                if let estimate {
                    Label(formatMinutes(Int(estimate)), systemImage: "timer").foregroundStyle(.secondary)
                }
                ForEach(chips.prefix(rowChips)) { label in
                    LabelChip(name: label["name"].string ?? "", color: label["color"].string)
                }
                if chips.count > rowChips {
                    Text("+\(chips.count - rowChips)")
                        .foregroundStyle(.secondary)
                        .help(chips.map { $0["name"].string ?? "" }.joined(separator: ", "))
                }
                if let place {
                    Spacer()
                    Text(place).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

/// p1 red, p2 orange, p3 blue; p4 is no priority.
func priorityColor(_ priority: Int64?) -> Color {
    switch priority {
    case 1: .red
    case 2: .orange
    case 3: .blue
    default: .secondary
    }
}

extension Color {
    /// "#rrggbb" or "#rgb", as the server stores colours. Nil for anything else.
    init?(hex: String?) {
        guard var hex = hex, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

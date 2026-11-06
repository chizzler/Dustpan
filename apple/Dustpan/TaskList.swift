import DustpanCore
import SwiftUI

struct TaskList: View {
    @Environment(AppModel.self) private var model
    let page: Page
    @State private var selection: Set<String> = []
    /// The list whose Add field has the focus.
    @FocusState private var adding: Place?

    var body: some View {
        let (title, projectId) = heading
        let sections = projectSections(model.snapshot, projectId)
        List(selection: $selection) {
            ForEach(sections.enumerated(), id: \.offset) { _, section in
                let place = Place(projectId: projectId, sectionId: section.id)
                if section.name.isEmpty {
                    rows(section.tasks)
                    addRow(place, section)
                } else {
                    Section(section.name) {
                        rows(section.tasks)
                        addRow(place, section)
                    }
                }
            }
        }
        .taskMenus(selection: selection)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Task", systemImage: "plus") { adding = Place(projectId: projectId) }
                    .keyboardShortcut("n")
                    .help("Add a task (⌘N)")
            }
        }
    }

    /// The page's title and project. A project that's gone shows the Inbox.
    private var heading: (String, String?) {
        if case .project(let id) = page, let node = model.projectsById[id] {
            return (node.row["name"].string ?? "", id)
        }
        return ("Inbox", nil)
    }

    private func rows(_ nodes: [Node]) -> some View {
        ForEach(flatten(nodes, depth: 0), id: \.node.id) { item in
            TaskRow(task: item.node.row, labels: model.snapshot.labels) {
                withAnimation { model.toggle(item.node.row) }
            }
            .padding(.leading, CGFloat(item.depth) * 24)
            .labelPicker(for: item.node.row)
        }
    }

    @ViewBuilder
    private func addRow(_ place: Place, _ section: DustpanCore.Section) -> some View {
        if section.isList {
            AddTaskField(place: place, focus: $adding)
                .selectionDisabled()
        }
    }

    private func flatten(_ nodes: [Node], depth: Int) -> [(node: Node, depth: Int)] {
        nodes.flatMap { [($0, depth)] + flatten($0.children, depth: depth + 1) }
    }
}

extension View {
    /// The row menu, double-click and keys of a list of tasks, keyed by task id.
    /// L opens the label picker on the selected task; Delete deletes the selection.
    func taskMenus(selection: Set<String>) -> some View { modifier(TaskMenus(selection: selection)) }
}

private struct TaskMenus: ViewModifier {
    @Environment(AppModel.self) private var model
    let selection: Set<String>

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
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(.tint).accessibilityHidden(true)
            TextField("Add task", text: $title)
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

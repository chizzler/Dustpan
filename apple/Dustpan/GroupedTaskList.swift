import DustpanCore
import SwiftUI

/// Today, Upcoming, Anytime, Completed, Filter, a label or a saved view: tasks under headings, each named with its place.
struct GroupedTaskList: View {
    @Environment(AppModel.self) private var model
    let page: Page
    @State private var selection: Set<String> = []
    @FocusState private var adding: Place?
    /// How much of the Completed page is shown.
    @State private var completedLimit = logbookPage

    private struct Content {
        var title: String
        var groups: [ViewGroup] = []
        var query: String?
        var error: String?
        var warnings: [String] = []
        /// Where the Add field puts new tasks, when the page has one.
        var addDue: JSON?
        /// The labels the Add field gives new tasks.
        var addLabels: [String] = []
        var empty: String
        /// The Filter page's line under the query: what it finds, or why it can't run.
        var status: String?
        var failed = false
        /// Completed's Show More, when there's more.
        var more: String?
    }

    var body: some View {
        let content = self.content
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if let query = content.query {
                    Text(query)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .selectionDisabled()
                }
                if let error = content.error {
                    Label("This query can't run here: \(error)", systemImage: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                        .selectionDisabled()
                }
                ForEach(content.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .selectionDisabled()
                }
                if content.groups.isEmpty && content.error == nil && !content.empty.isEmpty {
                    Text(content.empty).foregroundStyle(.secondary).selectionDisabled()
                }
                ForEach(content.groups) { group in
                    if group.heading.isEmpty {
                        rows(group.tasks)
                    } else {
                        Section {
                            rows(group.tasks)
                        } header: {
                            heading(group)
                        }
                    }
                }
                if let more = content.more {
                    Button(more, action: showMore)
                        .frame(maxWidth: .infinity)
                        .selectionDisabled()
                }
                if let due = content.addDue {
                    AddTaskField(place: Place(projectId: nil), due: due, labels: content.addLabels, focus: $adding)
                        .selectionDisabled()
                }
            }
            .onChange(of: model.flash) { _, id in
                guard let id, content.groups.contains(where: { $0.tasks.contains { $0.id == id } }) else { return }
                selection = [id]
                withAnimation { proxy.scrollTo(id) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let status = content.status { FilterBar(status: status, failed: content.failed) }
        }
        .taskMenus(selection: $selection)
        .navigationTitle(content.title)
        .toolbar {
            if content.addDue != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Task", systemImage: "plus") { adding = Place(projectId: nil) }
                        .keyboardShortcut("n")
                        .help("Add a task (⌘N)")
                }
            }
            if case .label(let id) = page, let label = model.snapshot.labels[id] {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit Label", systemImage: "pencil") { model.editingLabel = LabelDraft(label: label) }
                        .help("Edit this label")
                }
            }
            if case .view(let id) = page, let view = model.snapshot.views.first(where: { $0.id == id }) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit View", systemImage: "slider.horizontal.3") { model.editingView = ViewDraft(view: view) }
                        .help("Edit this view")
                }
            }
        }
    }

    private var content: Content {
        let snap = model.snapshot, today = model.today
        switch page {
        case .today:
            return Content(title: "Today", groups: todayGroups(snap.tasks, today: today),
                           addDue: ["date": .string(today.description)], empty: "Nothing due today.")
        case .upcoming:
            return Content(title: "Upcoming", groups: upcomingGroups(snap.tasks, today: today),
                           addDue: ["date": .string((today + 1).description)], empty: "Nothing coming up.")
        case .view(let id):
            guard let view = snap.views.first(where: { $0.id == id }) else {
                return Content(title: "View", empty: "This view is gone.")
            }
            let result = runView(view, snap.filterContext(today: today), snap.tasks, labels: snap.labelsInOrder,
                                 projects: snap.projectPaths)
            return Content(title: view["name"].string ?? "", groups: result.groups, query: view["query"].string,
                           error: result.error, warnings: result.warnings, empty: "No tasks match.")
        case .label(let id):
            guard let label = snap.labels[id] else { return Content(title: "Label", empty: "This label is gone.") }
            return Content(title: label["name"].string ?? "",
                           groups: labelGroups(label, snap.tasks, today: today, labels: snap.labelsInOrder,
                                               projects: snap.projectPaths),
                           addDue: .null, addLabels: [id],
                           empty: "No open tasks have this label. Add one below, or press L on any task.")
        case .anytime:
            return Content(title: "Anytime",
                           groups: anytimeGroups(snap.tasks, today: today, labels: snap.labelsInOrder,
                                                 projects: snap.projectPaths),
                           addDue: .null, empty: "Nothing undated. Tasks with no date, deadline or start show here.")
        case .completed:
            let found = logbook(snap.tasks, limit: completedLimit, today: today,
                                dayStart: snap.filterContext(today: today).dayStart)
            let older = found.total - found.groups.reduce(0) { $0 + $1.tasks.count }
            return Content(title: "Completed", groups: found.groups, empty: "Nothing completed yet.",
                           more: older > 0 ? "Show \(min(logbookPage, older)) More (\(older) older)" : nil)
        case .filter:
            let query = model.filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return Content(title: "Filter", empty: "",
                               status: "Type a query, or add conditions. @ suggests labels, # projects.")
            }
            let result = filterResults(query, snap.filterContext(today: today), snap.tasks, labels: snap.labelsInOrder,
                                       projects: snap.projectPaths)
            if let error = result.error { return Content(title: "Filter", empty: "", status: error, failed: true) }
            return Content(title: "Filter", groups: result.groups, warnings: result.warnings, empty: "No tasks match.",
                           status: "\(result.count) open task\(result.count == 1 ? "" : "s") match")
        case .inbox, .project, .archived, .trash:
            return Content(title: "", empty: "")
        }
    }

    private func showMore() { completedLimit += logbookPage }

    private var labelPage: String? {
        if case .label(let id) = page { id } else { nil }
    }

    private func rows(_ tasks: [Row]) -> some View {
        ForEach(tasks) { task in
            TaskRow(task: task, labels: model.snapshot.labels, place: model.snapshot.place(of: task),
                    showPlace: { model.showInProject(task) }, progress: model.progress[task.id], labelPage: labelPage) {
                withAnimation { model.toggle(task) }
            }
            .taskDrag(task)
            .flashes(task.id)
            .labelPicker(for: task)
        }
    }

    /// A day's heading on Today and Upcoming takes drops: the task becomes due that day.
    @ViewBuilder
    private func heading(_ group: ViewGroup) -> some View {
        let day: Day? = switch page {
        case .today: group.key == "today" ? model.today : nil
        case .upcoming: Day(group.key)
        default: nil
        }
        if let day {
            Text(group.heading).taskDrop("day:\(day)", .day(day))
        } else {
            Text(group.heading)
        }
    }
}

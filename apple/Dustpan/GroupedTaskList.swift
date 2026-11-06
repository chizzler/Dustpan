import DustpanCore
import SwiftUI

/// Today, Upcoming or a saved view: tasks under headings, each named with its place.
struct GroupedTaskList: View {
    @Environment(AppModel.self) private var model
    let page: Page
    @State private var selection: Set<String> = []
    @FocusState private var adding: Place?

    private struct Content {
        var title: String
        var groups: [ViewGroup] = []
        var query: String?
        var error: String?
        var warnings: [String] = []
        /// Where the Add field puts new tasks, when the page has one.
        var addDue: JSON?
        var empty: String
    }

    var body: some View {
        let content = self.content
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
            if content.groups.isEmpty && content.error == nil {
                Text(content.empty).foregroundStyle(.secondary).selectionDisabled()
            }
            ForEach(content.groups) { group in
                if group.heading.isEmpty {
                    rows(group.tasks)
                } else {
                    Section(group.heading) { rows(group.tasks) }
                }
            }
            if let due = content.addDue {
                AddTaskField(place: Place(projectId: nil), due: due, focus: $adding)
                    .selectionDisabled()
            }
        }
        .taskMenus()
        .navigationTitle(content.title)
        .toolbar {
            if content.addDue != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Task", systemImage: "plus") { adding = Place(projectId: nil) }
                        .keyboardShortcut("n")
                        .help("Add a task (⌘N)")
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
        case .inbox, .project:
            return Content(title: "", empty: "")
        }
    }

    private func rows(_ tasks: [Row]) -> some View {
        ForEach(tasks) { task in
            TaskRow(task: task, labels: model.snapshot.labels, place: model.snapshot.place(of: task)) {
                withAnimation { model.toggle(task) }
            }
        }
    }
}

import DustpanCore
import SwiftUI

/// Create a saved view, or edit one. Save writes only what changed.
struct ViewEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let view: Row?
    @State private var name: String
    @State private var query: String
    @State private var groupBy: ViewGroupBy
    @State private var sortBy: ViewSortBy
    @State private var sortDir: ViewSortDir
    @State private var showCompleted: Bool
    @State private var problem: String?

    init(draft: ViewDraft) {
        view = draft.view
        let (groupBy, sortBy, sortDir) = draft.view.map(viewOptions) ?? (.project, .due, .asc)
        _name = State(initialValue: draft.view?["name"].string ?? "")
        _query = State(initialValue: draft.view?["query"].string ?? draft.query)
        _groupBy = State(initialValue: groupBy)
        _sortBy = State(initialValue: sortBy)
        _sortDir = State(initialValue: sortDir)
        _showCompleted = State(initialValue: draft.view?["show_completed"] == true)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                QueryField(query: $query)
                queryHint
            }
            Section {
                Picker("Group by", selection: $groupBy) {
                    ForEach(ViewGroupBy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Sort by", selection: $sortBy) {
                    ForEach(ViewSortBy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Order", selection: $sortDir) {
                    Text("Ascending").tag(ViewSortDir.asc)
                    Text("Descending").tag(ViewSortDir.desc)
                }
                .pickerStyle(.segmented)
                Toggle("Show completed tasks", isOn: $showCompleted)
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .navigationTitle(view == nil ? "New View" : "Edit View")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(view == nil ? "Create" : "Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Under the query: why it doesn't parse, or how many open tasks it matches now.
    @ViewBuilder
    private var queryHint: some View {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let snap = model.snapshot
            switch Result(catching: { () throws(FilterError) in
                try runQuery(text, snap.filterContext(today: model.today), snap.tasks)
            }) {
            case .success(let found):
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(found.count) open task\(found.count == 1 ? "" : "s") match").foregroundStyle(.secondary)
                    ForEach(found.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
            case .failure(let error):
                Text(error.message).foregroundStyle(.red)
            }
        }
    }

    /// Everything for a new view; only what changed for an existing one.
    private var changes: ViewEdit {
        let fields = ViewEdit(name: name, query: query, groupBy: groupBy, sortBy: sortBy, sortDir: sortDir,
                              showCompleted: showCompleted)
        guard let view else { return fields }
        let (g, s, d) = viewOptions(view)
        var edit = ViewEdit()
        if name.trimmingCharacters(in: .whitespacesAndNewlines) != view["name"].string { edit.name = name }
        if query.trimmingCharacters(in: .whitespacesAndNewlines) != view["query"].string { edit.query = query }
        if groupBy != g { edit.groupBy = groupBy }
        if sortBy != s { edit.sortBy = sortBy }
        if sortDir != d { edit.sortDir = sortDir }
        if showCompleted != (view["show_completed"] == true) { edit.showCompleted = showCompleted }
        return edit
    }

    private func save() {
        do {
            try model.saveView(view, changes)
            dismiss()
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
        }
    }
}

extension ViewGroupBy {
    var label: String {
        switch self {
        case .project: "Project"
        case .due: "Due date"
        case .priority: "Priority"
        case .label: "Label"
        case .none: "Nothing"
        }
    }
}

extension ViewSortBy {
    var label: String {
        switch self {
        case .due: "Due date"
        case .priority: "Priority"
        case .position: "Manual order"
        case .created: "Date added"
        case .deadline: "Deadline"
        case .title: "Title"
        }
    }
}

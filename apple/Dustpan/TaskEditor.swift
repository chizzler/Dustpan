import DustpanCore
import SwiftUI

/// Edit a task's title, priority, due date, project and section. Save writes only what changed, in one batch.
struct TaskEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: Row
    @State private var title: String
    @State private var priority: Int64
    @State private var hasDue: Bool
    /// The due being edited. Without one, today at 09:00 for when Due date is turned on.
    @State private var due: DueDraft
    @State private var place: Place
    @State private var problem: String?

    init(task: Row) {
        self.task = task
        _title = State(initialValue: task["title"].string ?? "")
        _priority = State(initialValue: task["priority"].int.flatMap { (1...4).contains($0) ? $0 : nil } ?? 4)
        let stored = DueDraft(task["due"])
        _hasDue = State(initialValue: stored != nil)
        _due = State(initialValue: stored ?? DueDraft(date: Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now))
        _place = State(initialValue: Place(projectId: task["project_id"].string, sectionId: task["section_id"].string))
    }

    var body: some View {
        Form {
            TextField("Title", text: $title)
            Picker("Priority", selection: $priority) {
                ForEach(Int64(1)...4, id: \.self) { p in
                    Label(p == 4 ? "None" : "Priority \(p)", systemImage: "flag.fill")
                        .foregroundStyle(priorityColor(p))
                        .tag(p)
                }
            }
            dueFields
            Picker("Project", selection: $place.projectId) {
                Text("Inbox").tag(String?.none)
                ForEach(model.flatProjects, id: \.node.id) { item in
                    Text(String(repeating: "    ", count: item.depth) + (item.node.row["name"].string ?? ""))
                        .tag(Optional(item.node.id))
                }
            }
            .onChange(of: place.projectId) { place.sectionId = nil }
            if let projectId = place.projectId, let sections = model.snapshot.sectionsByProject[projectId],
               !sections.isEmpty {
                Picker("Section", selection: $place.sectionId) {
                    Text("No section").tag(String?.none)
                    ForEach(sections) { Text($0["name"].string ?? "").tag(Optional($0.id)) }
                }
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var dueFields: some View {
        Toggle("Due date", isOn: $hasDue)
        if hasDue {
            DatePicker("Date", selection: $due.date, displayedComponents: due.hasTime ? [.date, .hourAndMinute] : .date)
                .environment(\.timeZone, due.zone)
            Toggle("Time", isOn: $due.hasTime)
            if let zone = due.zoneName {
                LabeledContent("Time zone", value: zone)
            }
        }
    }

    /// Only the fields that changed. A due that reads the same isn't written again.
    private var changes: TaskEdit {
        var edit = TaskEdit()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != task["title"].string { edit.title = trimmed }
        if priority != task["priority"].int ?? 4 { edit.priority = priority }
        let newDue = hasDue ? due.json : .null
        if newDue != DueDraft(task["due"])?.json ?? .null { edit.due = newDue }
        if place != Place(projectId: task["project_id"].string, sectionId: task["section_id"].string) {
            edit.place = place
        }
        return edit
    }

    private func save() {
        do {
            try model.edit(task.id, changes)
            dismiss()
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
        }
    }
}

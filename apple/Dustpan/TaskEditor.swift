import DustpanCore
import SwiftUI

/// Edit a task's title, priority, due date, repeat, project and section. Save writes only what changed, in one batch.
/// Reminders change at once: they're entities of their own.
struct TaskEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: Row
    @State private var title: String
    @State private var priority: Int64
    @State private var hasDue: Bool
    /// The due being edited. Without one, today at 09:00 for when Due date is turned on.
    @State private var due: DueDraft
    @State private var recurrence: String
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
        _recurrence = State(initialValue: task["recurrence"].string ?? "")
        _place = State(initialValue: Place(projectId: task["project_id"].string, sectionId: task["section_id"].string))
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title)
                Picker("Priority", selection: $priority) {
                    ForEach(Int64(1)...4, id: \.self) { p in
                        Label(p == 4 ? "None" : "Priority \(p)", systemImage: "flag.fill")
                            .foregroundStyle(priorityColor(p))
                            .tag(p)
                    }
                }
            }
            Section {
                dueFields
                repeatFields
            }
            Section {
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
            }
            reminders
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
            // Without a due date there's nothing to repeat from.
            .onChange(of: hasDue) { if !hasDue { recurrence = "" } }
        if hasDue {
            Group {
                LabeledContent("Date") { DayPicker(date: $due.date) }
                Toggle("Time", isOn: $due.hasTime)
                if due.hasTime {
                    DatePicker("At", selection: $due.date, displayedComponents: .hourAndMinute)
                    if let zone = due.zoneName {
                        LabeledContent("Time zone", value: zone)
                    }
                }
            }
            .environment(\.timeZone, due.zone)
        }
    }

    @ViewBuilder
    private var repeatFields: some View {
        TextField("Repeat", text: $recurrence, prompt: Text("every weekday"))
        if case let (hint, detail)? = repeatHint {
            VStack(alignment: .leading, spacing: 2) {
                Text(hint)
                if let detail { Text(detail).font(.caption) }
            }
            .foregroundStyle(.secondary)
        }
        if task["recurrence"].isTruthy && task["completed_at"].isNull {
            Button("Skip to Next Occurrence") { moveOn(model.skip) }
            Button("Split Off This Occurrence") { moveOn(model.detach) }
                .help("Make this occurrence a task of its own, and move the repeat on")
        }
    }

    /// Under the rule: its next dates, or why it doesn't parse.
    private var repeatHint: (String, String?)? {
        let text = recurrence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return task["recurrence"].isTruthy ? ("Doesn't repeat", nil) : nil }
        do throws(RuleError) {
            let rule = try Rule(parsing: text)
            guard hasDue, let day = due.json["date"].string.flatMap(Day.init) else {
                return ("Due on the first matching day", nil)
            }
            let dates = rule.preview(due: day, today: model.today)
            return dates.isEmpty ? ("No more after this one", nil)
                : ("Then " + dates.map { formatDay($0) }.joined(separator: ", "), nil)
        } catch {
            return ("Not a repeat rule", error.message)
        }
    }

    private var reminders: some View {
        Section("Reminders") {
            let rows = model.snapshot.remindersByTask[task.id] ?? []
            ForEach(rows) { ReminderRow(reminder: $0, act: act) }
            if rows.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            Menu("Add Reminder") {
                ForEach(relativePresets, id: \.self) { minutes in
                    Button(offsetLabel(minutes)) {
                        act { try model.addReminder(to: task.id, offsetMinutes: minutes) }
                    }
                }
                Divider()
                Button("At a Time…") { act { try model.addReminder(to: task.id, at: suggestedTime) } }
            }
            .fixedSize()
        }
    }

    /// For a new reminder at a time: the due time when it's still ahead, else the next whole hour.
    private var suggestedTime: Date {
        if task["due"]["time"].isTruthy, let instant = dueInstant(task["due"]).map(Date.init(ms:)), instant > .now {
            return instant
        }
        return Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0),
                                         matchingPolicy: .nextTime) ?? .now
    }

    private func act(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
        }
    }

    /// Skip or split off: acts on the task as stored, so unsaved changes here are dropped.
    private func moveOn(_ action: (Row) -> Void) {
        dismiss()
        action(task)
    }

    /// Only the fields that changed. A due or rule that reads the same isn't written again.
    private var changes: TaskEdit {
        var edit = TaskEdit()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != task["title"].string { edit.title = trimmed }
        if priority != task["priority"].int ?? 4 { edit.priority = priority }
        let newDue = hasDue ? due.json : .null
        if newDue != DueDraft(task["due"])?.json ?? .null { edit.due = newDue }
        let rule = recurrence.trimmingCharacters(in: .whitespacesAndNewlines)
        if ((try? Rule(parsing: rule))?.canonical ?? rule) != task["recurrence"].string ?? "" {
            edit.recurrence = rule
        }
        if place != Place(projectId: task["project_id"].string, sectionId: task["section_id"].string) {
            edit.place = place
        }
        return edit
    }

    private func save() {
        act {
            try model.edit(task.id, changes)
            dismiss()
        }
    }
}

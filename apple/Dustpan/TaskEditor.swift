import DustpanCore
import SwiftUI

/// Edit a task's fields. Save writes only what changed, in one batch.
/// Reminders and subtasks change at once: they're entities of their own.
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
    /// Label ids, or names of labels Save creates.
    @State private var labels: [String]
    @State private var showsLabelPicker = false
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var estimate: String
    @State private var subtask = ""
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
        _labels = State(initialValue: task["labels"].array?.compactMap(\.string) ?? [])
        let storedDeadline = task["deadline"].string.flatMap(Day.init)
        _hasDeadline = State(initialValue: storedDeadline != nil)
        _deadline = State(initialValue: (storedDeadline ?? Day(.now)).noon)
        _estimate = State(initialValue: estimateText(task["estimate_minutes"].int))
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
                labelField
            }
            Section {
                dueFields
                repeatFields
            }
            Section {
                Toggle("Deadline", isOn: $hasDeadline)
                if hasDeadline {
                    LabeledContent("On") { DayPicker(date: $deadline) }
                }
                TextField("Estimate", text: $estimate, prompt: Text("30m or 1h30"))
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
            subtasks
            Section {
                Button("Delete Task", role: .destructive) {
                    dismiss()
                    model.delete([task])
                }
                .help("Delete this task and its subtasks. Undo brings them back.")
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

    /// Chips with ×, and + for the picker.
    private var labelField: some View {
        LabeledContent("Labels") {
            FlowLayout {
                ForEach(labels, id: \.self) { ref in
                    let label = model.snapshot.labels[ref]
                    LabelChip(name: label?["name"].string ?? ref, color: label?["color"].string) {
                        labels.removeAll { $0 == ref }
                    }
                }
                Button("Add Label", systemImage: "plus") { showsLabelPicker = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Add a label")
                    .popover(isPresented: $showsLabelPicker, arrowEdge: .bottom) { LabelPicker(refs: $labels) }
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
                MonthCalendar(date: $due.date, zone: due.zone)
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
                if task["deadline"].isTruthy {
                    Divider()
                    ForEach(deadlinePresets, id: \.self) { minutes in
                        Button(deadlineOffsetLabel(minutes)) {
                            act { try model.addReminder(to: task.id, deadlineOffset: minutes) }
                        }
                    }
                }
                Divider()
                Button("At a Time…") { act { try model.addReminder(to: task.id, at: suggestedTime) } }
            }
            .fixedSize()
        }
    }

    /// The task's own subtasks, completed ones struck through, and a line to add one.
    private var subtasks: some View {
        Section("Subtasks") {
            let children = model.snapshot.allTasks.values
                .filter { $0["parent_id"].string == task.id && $0["deleted_at"].isNull }
                .sorted { a, b in
                    let pa = a["position"].number ?? 0, pb = b["position"].number ?? 0
                    return pa != pb ? pa < pb : a.id < b.id
                }
            ForEach(children) { child in
                let done = !child["completed_at"].isNull
                HStack {
                    Button(done ? "Reopen" : "Complete", systemImage: done ? "checkmark.circle.fill" : "circle") {
                        model.toggle(child)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(priorityColor(child["priority"].int))
                    Text(child["title"].string ?? "")
                        .strikethrough(done)
                        .foregroundStyle(done ? .secondary : .primary)
                }
            }
            TextField("Add a subtask", text: $subtask)
                .onSubmit {
                    act {
                        try model.addSubtask(subtask, to: task.id)
                        subtask = ""
                    }
                }
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
        if labels != task["labels"].array?.compactMap(\.string) ?? [] { edit.labels = labels }
        let newDeadline: JSON = hasDeadline ? .string(Day(deadline).description) : .null
        if newDeadline != (task["deadline"].string.flatMap(Day.init).map { JSON.string($0.description) } ?? .null) {
            edit.deadline = newDeadline
        }
        return edit
    }

    private func save() {
        act {
            var edit = changes
            let minutes = try parseEstimate(estimate)
            if minutes != task["estimate_minutes"].int { edit.estimateMinutes = minutes.map(JSON.int) ?? .null }
            try model.edit(task.id, edit)
            dismiss()
        }
    }
}

extension Day {
    /// Noon on this day, here: a Date that names it in every nearby zone.
    var noon: Date {
        let (year, month, day) = parts
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }
}

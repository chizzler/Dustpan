import Foundation

// Local edits: plan the ops, apply them locally, queue them for upload. See spec/writes.md.

/// The fields of one entity an edit writes.
public struct Change: Equatable, Sendable {
    public var entity: String
    public var id: String
    public var patch: [String: JSON]

    public init(_ entity: String, _ id: String, _ patch: [String: JSON]) {
        (self.entity, self.id, self.patch) = (entity, id, patch)
    }
}

/// The edit can't be made: bad input, a missing target, or not supported yet.
public struct CannotEdit: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What an action did: the changes that undo it, and where a repeating task moved on to.
public struct Done: Sendable {
    public var undo: [Change] = []
    public var nextDue: Day?

    public init(undo: [Change] = [], nextDue: Day? = nil) { (self.undo, self.nextDue) = (undo, nextDue) }
}

/// The server's bound on one value, as the JSON it receives.
let maxValueBytes = 64 * 1024

/// The task fields `Writer.edit` takes. Nil leaves a field alone.
public struct TaskEdit: Equatable, Sendable {
    public var title: String?
    /// Markdown. The web app folds it into its rich-text notes_doc, which Dustpan never writes.
    public var notes: String?
    public var priority: Int64?
    /// .null clears it.
    public var due: JSON?
    /// A rule to parse; "" stops the repeat.
    public var recurrence: String?
    public var place: Place?
    /// Ids of live labels, or names: a name with no label creates one in the same batch.
    public var labels: [String]?
    /// Minutes, or .null for none.
    public var estimateMinutes: JSON?
    /// "YYYY-MM-DD", or .null for none.
    public var deadline: JSON?

    public init(title: String? = nil, notes: String? = nil, priority: Int64? = nil, due: JSON? = nil,
                recurrence: String? = nil, place: Place? = nil, labels: [String]? = nil, estimateMinutes: JSON? = nil,
                deadline: JSON? = nil) {
        (self.title, self.notes, self.priority, self.due, self.recurrence) = (title, notes, priority, due, recurrence)
        self.place = place
        (self.labels, self.estimateMinutes, self.deadline) = (labels, estimateMinutes, deadline)
    }

    public var isEmpty: Bool { self == TaskEdit() }
}

/// Where a task lives: a project (nil is the Inbox) and a section of it.
public struct Place: Hashable, Sendable {
    public var projectId: String?
    public var sectionId: String?

    public init(projectId: String?, sectionId: String? = nil) {
        (self.projectId, self.sectionId) = (projectId, sectionId)
    }
}

let positionGap: Double = 1000
/// The server's bound on an estimate, in minutes: a week.
public let maxEstimate: Int64 = 10080

/// A due value the server accepts, or CannotEdit.
func checkDue(_ due: JSON) throws(CannotEdit) -> JSON {
    if due.isNull { return due }
    guard let object = due.object, Set(object.keys).isSubset(of: ["date", "time", "tz"]) else {
        throw CannotEdit("Unknown due date fields")
    }
    guard let date = due["date"].string, isRealDate(date) else { throw CannotEdit("That isn't a valid date or time") }
    if let time = object["time"] {
        guard let text = time.string, text.count == 5, parseTime(text) != nil else {
            throw CannotEdit("That isn't a valid date or time")
        }
    } else if object["tz"] != nil {
        throw CannotEdit("A time zone needs a time")
    }
    return due
}

/// YYYY-MM-DD, and the day exists.
func isRealDate(_ text: String) -> Bool { Day(text) != nil }

/// A position as JSON: a whole number stays an integer, as the other clients write it.
func position(_ value: Double) -> JSON {
    value.rounded() == value && abs(value) < 9e15 ? .int(Int64(value)) : .double(value)
}

extension String? {
    var json: JSON { map(JSON.string) ?? .null }
}

/// Every live task below taskId. Safe against cycles.
func descendants(of taskId: String, in tasks: [String: Row]) -> [Row] {
    var children: [String: [Row]] = [:]
    for task in tasks.values where isLive(task) {
        if let parent = task["parent_id"].string { children[parent, default: []].append(task) }
    }
    var found: [Row] = [], stack = [taskId], seen: Set = [taskId]
    while let next = stack.popLast() {
        for child in children[next] ?? [] where seen.insert(child.id).inserted {
            found.append(child)
            stack.append(child.id)
        }
    }
    return found
}

public final class Writer {
    let store: Store
    let clock: HybridClock
    let now: () -> Int64
    let fixedToday: (() -> Day)?

    public init(store: Store, clock: HybridClock? = nil, now: @escaping () -> Int64 = wallMs,
                today: (() -> Day)? = nil) {
        self.store = store
        self.now = now
        self.fixedToday = today
        self.clock = clock ?? HybridClock(store: store, now: now)
    }

    /// The logical today, after the user's day start.
    public func today() throws -> Day {
        if let fixedToday { return fixedToday() }
        let dayStart = dayStartMinutes(try store.rows("user_prefs")["me"]?["day_start"] ?? .null)
        return logicalToday(dayStart: dayStart, now: Date(ms: now()))
    }

    /// Run plan in one transaction and write the changes it returns as one batch, with one timestamp.
    @discardableResult
    func commit<T>(_ plan: () throws -> ([Change], T)) throws -> T {
        try store.transaction {
            var (changes, result) = try plan()
            changes = try completedBy(changes)
            changes = try sectorClears(changes)
            changes += try defaultReminders(changes)
            changes += try reminderFollowUps(changes)
            guard !changes.isEmpty else { return result }
            let ts = try clock.stamp()
            let device = try store.device()
            let ops = changes.flatMap { change in
                change.patch.sorted { $0.key < $1.key }.map { field, value in
                    Op(id: newId(), entity: change.entity, entityId: change.id, field: field, value: value,
                       ts: ts, device: device)
                }
            }
            for op in ops { try store.apply(op) }
            try store.outboxAdd(ops)
            return result
        }
    }

    func commit(_ plan: () throws -> [Change]) throws {
        try commit { (try plan(), ()) }
    }

    // MARK: reads inside a plan

    func liveTask(_ tasks: [String: Row], _ id: String) throws -> Row {
        guard let task = tasks[id], isLive(task) else { throw CannotEdit("That task no longer exists") }
        return task
    }

    func checkProject(_ projectId: String?) throws {
        guard let projectId else { return }
        guard let project = try store.rows("project")[projectId], isLive(project), !project["archived"].isTruthy else { throw CannotEdit("That project no longer exists") }
    }

    func checkSection(_ sectionId: String?, in projectId: String?) throws {
        guard let sectionId else { return }
        guard let section = try store.rows("section")[sectionId], isLive(section),
              section["project_id"].string == projectId else {
            throw CannotEdit("That section isn't in the project")
        }
    }

    /// The wall time, unless some task's position is already past it: then the largest position + 1000.
    func newPosition(_ tasks: [String: Row]) -> JSON {
        let now = now()
        let top = tasks.values.compactMap { $0["position"].number }.max()
        if let top, top >= Double(now) { return position(top + positionGap) }
        return .int(now)
    }

    /// Past the last open top-level task of one list, or the wall time when it's empty.
    func endOfList(_ tasks: [String: Row], projectId: String?, sectionId: String?, skip: String) -> JSON {
        let positions = tasks.values.filter { t in
            t.id != skip && isLive(t) && t["completed_at"].isNull && !t["parent_id"].isTruthy
                && t["project_id"].string == projectId && t["section_id"].string == sectionId
        }.compactMap { $0["position"].number }
        return positions.max().map { position($0 + positionGap) } ?? .int(now())
    }

    // MARK: rules every batch follows

    /// A write of completed_at carries completed_by: us when completing, null when reopening.
    func completedBy(_ changes: [Change]) throws -> [Change] {
        let me = try store.meta("user_id")
        return changes.map { change in
            guard change.entity == "task", let completed = change.patch["completed_at"],
                  change.patch["completed_by"] == nil else { return change }
            var change = change
            change.patch["completed_by"] = completed.isNull ? .null : me
            return change
        }
    }

    /// One "when" at a time: a do-on date or a start clears a task's sector in the same batch. The deadline stays.
    func sectorClears(_ changes: [Change]) throws -> [Change] {
        let tasks = try store.rows("task")
        return changes.map { change in
            let dated = !(change.patch["due"] ?? .null).isNull || (change.patch["start"] ?? .null).isTruthy
            guard change.entity == "task", change.patch["sector"] == nil, dated,
                  tasks[change.id]?["sector"].isTruthy == true else { return change }
            var change = change
            change.patch["sector"] = ""
            return change
        }
    }

    /// Every field each task gets in this batch, by task id.
    func taskPatches(_ changes: [Change]) -> [String: [String: JSON]] {
        var patches: [String: [String: JSON]] = [:]
        for change in changes where change.entity == "task" {
            patches[change.id, default: [:]].merge(change.patch) { _, new in new }
        }
        return patches
    }

    /// A task that gets its first due date gets the user's default reminder, in the same batch.
    func defaultReminders(_ changes: [Change]) throws -> [Change] {
        let scheduled = taskPatches(changes).filter { $0.value["due"]?.object != nil }
        let defaults = ReminderDefaults(prefs: try store.rows("user_prefs")["me"]?.values ?? [:])
        guard !scheduled.isEmpty, let userId = try store.meta("user_id").string, !defaults.isEmpty else { return [] }
        let tasks = try store.rows("task")
        let reminders = try store.rows("reminder")
        let batch = changes.filter { $0.entity == "reminder" }
        return scheduled.sorted { $0.key < $1.key }.flatMap { taskId, patch in
            let own = reminders.values.filter { $0["task_id"].string == taskId }
            return planDefaultReminder(
                userId: userId, taskId: taskId, before: tasks[taskId]?.values, patch: patch,
                reminders: Dictionary(uniqueKeysWithValues: own.map { ($0.id, $0.values) }),
                batch: batch, defaults: defaults, now: now())
        }
    }

    /// Relative reminders follow their task's due, and deadline reminders its deadline, in the same batch.
    func reminderFollowUps(_ changes: [Change]) throws -> [Change] {
        let patches = taskPatches(changes).filter { $0.value["due"] != nil || $0.value["deadline"] != nil }
        guard !patches.isEmpty else { return [] }
        // A reminder whose firing time the batch already writes keeps that value.
        let written = Set(changes.filter { $0.entity == "reminder" && $0.patch["fire_at"] != nil }.map(\.id))
        return try store.rows("reminder").values.sorted { $0.id < $1.id }.compactMap { reminder in
            guard isLive(reminder), !written.contains(reminder.id),
                  let taskPatch = reminder["task_id"].string.flatMap({ patches[$0] }) else { return nil }
            let fireAt: JSON
            switch reminder["kind"].string {
            case "relative":
                guard let due = taskPatch["due"] else { return nil }
                fireAt = relativeFireAt(due, reminder["offset_minutes"])
            case "deadline":
                guard let deadline = taskPatch["deadline"] else { return nil }
                fireAt = deadlineFireAt(deadline, reminder["offset_minutes"])
            default:
                return nil
            }
            var patch: [String: JSON] = ["fire_at": fireAt]
            if fireAt != reminder["fire_at"] {
                if !reminder["delivered_at"].isNull { patch["delivered_at"] = .null }
                if !reminder["dismissed_at"].isNull { patch["dismissed_at"] = .null }
            }
            return Change("reminder", reminder.id, patch)
        }
    }

    // MARK: actions

    /// Add a task at the end of its list. A subtask takes its parent's project and no section. Returns its id.
    @discardableResult
    public func addTask(_ title: String, projectId: String? = nil, sectionId: String? = nil,
                        parentId: String? = nil, due: JSON = nil, labels: [String] = []) throws -> String {
        let taskId = newId()
        try commit {
            var patch = try newTask(title, projectId: projectId, sectionId: sectionId, parentId: parentId, due: due)
            let (ids, created) = try resolveLabels(labels)
            patch["labels"] = .array(ids.map(JSON.string))
            return created + [Change("task", taskId, patch)]
        }
        return taskId
    }

    /// The fields of a new task at the end of its list. A subtask takes its parent's project and no section.
    func newTask(_ title: String, projectId: String?, sectionId: String?, parentId: String?,
                 due: JSON) throws -> [String: JSON] {
        let tasks = try store.rows("task")
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CannotEdit("A task needs a title") }
        var (projectId, sectionId) = (projectId, sectionId)
        if let parentId {
            projectId = try liveTask(tasks, parentId)["project_id"].string
            sectionId = nil
        }
        try checkProject(projectId)
        try checkSection(sectionId, in: projectId)
        var patch: [String: JSON] = [
            "title": .string(title), "description": "", "project_id": projectId.json,
            "parent_id": parentId.json, "priority": 4, "due": try checkDue(due),
            "labels": [], "position": newPosition(tasks), "created_at": .int(now()), "completed_at": nil,
            "deleted_at": nil, "estimate_minutes": nil,
        ]
        if let sectionId { patch["section_id"] = .string(sectionId) }
        return patch
    }

    /// Complete a task and its open descendants, or roll a repeating task to its next occurrence.
    public func complete(_ taskId: String) throws -> Done {
        try commit {
            let tasks = try store.rows("task")
            let task = try liveTask(tasks, taskId)
            guard task["completed_at"].isNull else { return ([], Done()) }
            let now = now()
            if let rule = seriesRule(task),
               let rolled = try planCompletion(task, rule, tasks: tasks.values, now: now, today: today()) {
                return (rolled.changes, undoMove(task, rolled, now: now))
            }
            let done = [task] + descendants(of: taskId, in: tasks).filter { $0["completed_at"].isNull }
            return (done.map { Change("task", $0.id, ["completed_at": .int(now)]) },
                    Done(undo: done.map { Change("task", $0.id, ["completed_at": nil]) }))
        }
    }

    /// Move a repeating task to its next occurrence without completing it.
    public func skip(_ taskId: String) throws -> Done {
        try moveOn(taskId, refusal: "Only an open repeating task can be skipped",
                   last: "This is the last occurrence. Complete or delete it instead", planSkip)
    }

    /// "This occurrence only": a standalone copy of the current occurrence, and the series moves on.
    public func detach(_ taskId: String) throws -> Done {
        try moveOn(taskId, refusal: "Only an open repeating task has occurrences",
                   last: "This is the last occurrence. Edit the task itself instead", planDetach)
    }

    private func moveOn(_ taskId: String, refusal: String, last: String,
                        _ plan: (Row, Rule, Int64, Day) throws -> MoveOn?) throws -> Done {
        try commit {
            let task = try liveTask(try store.rows("task"), taskId)
            guard let rule = seriesRule(task) else { throw CannotEdit(refusal) }
            let now = now()
            guard let moved = try plan(task, rule, now, try today()) else { throw CannotEdit(last) }
            return (moved.changes, undoMove(task, moved, now: now))
        }
    }

    /// Undo for a series that moved on: its old dates back, and the record or copy deleted.
    private func undoMove(_ series: Row, _ moved: MoveOn, now: Int64) -> Done {
        let patch = moved.changes.first { $0.id == series.id }?.patch ?? [:]
        var undo = [Change("task", series.id, Dictionary(uniqueKeysWithValues: patch.keys.map { ($0, series[$0]) }))]
        if let created = moved.createdId { undo.append(Change("task", created, ["deleted_at": .int(now)])) }
        return Done(undo: undo, nextDue: moved.next)
    }

    /// Reopen one completed task. Its subtasks stay as they are.
    public func reopen(_ taskId: String) throws -> Done {
        try commit {
            let task = try liveTask(try store.rows("task"), taskId)
            guard !task["completed_at"].isNull else { return ([], Done()) }
            return ([Change("task", taskId, ["completed_at": nil])],
                    Done(undo: [Change("task", taskId, ["completed_at": .int(now())])]))
        }
    }

    /// Delete a task and its subtasks. Undo brings them back.
    public func deleteTask(_ taskId: String) throws -> Done {
        try commit {
            let tasks = try store.rows("task")
            let gone = [try liveTask(tasks, taskId)] + descendants(of: taskId, in: tasks)
            let now = now()
            return (gone.map { Change("task", $0.id, ["deleted_at": .int(now)]) },
                    Done(undo: gone.map { Change("task", $0.id, ["deleted_at": nil]) }))
        }
    }

    /// Apply the undo changes of an earlier action, as a new batch.
    public func revert(_ undo: [Change]) throws {
        try commit { undo }
    }

    /// Write the changed fields of one task, in one batch.
    public func edit(_ taskId: String, _ edit: TaskEdit) throws {
        try commit { try planEdit(taskId, edit) }
    }

    /// The changes edit makes, for use inside another plan.
    func planEdit(_ taskId: String, _ edit: TaskEdit) throws -> [Change] {
        let tasks = try store.rows("task")
        let task = try liveTask(tasks, taskId)
        var patch: [String: JSON] = [:]
        var out: [Change] = []
        if let title = edit.title {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw CannotEdit("A task needs a title") }
            patch["title"] = .string(title)
        }
        if let notes = edit.notes {
            let note = String(notes.reversed().drop(while: \.isWhitespace).reversed())
            // The server's bound on one value, as the JSON it receives.
            guard JSON.string(note).data.count <= maxValueBytes else {
                throw CannotEdit("Notes are too long: the limit is 64 KB")
            }
            patch["description"] = .string(note)
        }
        if let priority = edit.priority {
            guard (1...4).contains(priority) else { throw CannotEdit("Priority is 1 to 4") }
            patch["priority"] = .int(priority)
        }
        if let due = edit.due {
            patch["due"] = try checkDue(due)
            if due.isNull && task["recurrence"].isTruthy && edit.recurrence == nil { patch["recurrence"] = .null }
            if !due.isNull && task["start"].string == "someday" { patch["start"] = .null }
        }
        if let text = edit.recurrence?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if text.isEmpty {
                patch["recurrence"] = .null
            } else {
                let rule: Rule
                do { rule = try Rule(parsing: text) } catch { throw CannotEdit("Repeat: \(error)") }
                patch["recurrence"] = .string(rule.canonical)
                // A rule needs a due date: the first occurrence from today.
                if (patch["due"] ?? task["due"]).isNull {
                    patch["due"] = ["date": .string(rule.first(from: try today()).description)]
                }
            }
        }
        if let labels = edit.labels {
            let (ids, created) = try resolveLabels(labels)
            patch["labels"] = .array(ids.map(JSON.string))
            out += created
        }
        if let minutes = edit.estimateMinutes {
            if !minutes.isNull {
                guard let n = minutes.int, (1...maxEstimate).contains(n) else {
                    throw CannotEdit("An estimate is 1 minute to 1 week")
                }
            }
            patch["estimate_minutes"] = minutes
        }
        if let deadline = edit.deadline {
            if !deadline.isNull {
                guard let text = deadline.string, isRealDate(text) else { throw CannotEdit("That isn't a valid date") }
            }
            patch["deadline"] = deadline
        }
        if let place = edit.place {
            out += try planMove(tasks, task, to: place, into: &patch)
        }
        // New labels come first in the batch, so they exist before the task refers to them.
        return patch.isEmpty ? out : out + [Change("task", taskId, patch)]
    }

    /// Add a move to patch. Returns the changes for descendants.
    func planMove(_ tasks: [String: Row], _ task: Row, to place: Place,
                  into patch: inout [String: JSON]) throws -> [Change] {
        let (projectId, sectionId) = (place.projectId, place.sectionId)
        let movedProject = projectId != task["project_id"].string
        try checkProject(projectId)
        try checkSection(sectionId, in: projectId)
        if !movedProject && sectionId == task["section_id"].string && !task["parent_id"].isTruthy { return [] }

        if movedProject { patch["project_id"] = projectId.json }
        if sectionId != task["section_id"].string { patch["section_id"] = sectionId.json }
        if task["parent_id"].isTruthy { patch["parent_id"] = .null }
        patch["position"] = endOfList(tasks, projectId: projectId, sectionId: sectionId, skip: task.id)
        return carrySubtree(tasks, task.id, to: projectId)
    }

    /// Subtasks follow their parent into another project, out of its sections.
    func carrySubtree(_ tasks: [String: Row], _ taskId: String, to projectId: String?) -> [Change] {
        descendants(of: taskId, in: tasks).filter { $0["project_id"].string != projectId }.map { d in
            var patch: [String: JSON] = ["project_id": projectId.json]
            if d["section_id"].isTruthy { patch["section_id"] = .null }
            return Change("task", d.id, patch)
        }
    }

    // MARK: reminders

    /// A reminder offsetMinutes from the task's due time. Returns its id.
    @discardableResult
    public func addReminder(_ taskId: String, offsetMinutes: Int64) throws -> String {
        try checkOffset(offsetMinutes)
        return try addReminder(taskId, kind: "relative", offset: .int(offsetMinutes)) {
            relativeFireAt($0["due"], .int(offsetMinutes))
        }
    }

    /// A reminder offsetMinutes from 09:00 on the task's deadline. Returns its id.
    @discardableResult
    public func addReminder(_ taskId: String, deadlineOffset offsetMinutes: Int64) throws -> String {
        try checkOffset(offsetMinutes)
        return try addReminder(taskId, kind: "deadline", offset: .int(offsetMinutes)) {
            deadlineFireAt($0["deadline"], .int(offsetMinutes))
        }
    }

    /// A reminder at a moment of its own (unix ms). Returns its id.
    @discardableResult
    public func addReminder(_ taskId: String, at fireAt: Int64) throws -> String {
        try addReminder(taskId, kind: "absolute", offset: nil) { _ in .int(fireAt) }
    }

    private func addReminder(_ taskId: String, kind: String, offset: JSON, fireAt: (Row) -> JSON) throws -> String {
        let reminderId = newId()
        try commit {
            let task = try liveTask(try store.rows("task"), taskId)
            return [Change("reminder", reminderId, [
                "task_id": .string(taskId), "kind": .string(kind), "offset_minutes": offset, "fire_at": fireAt(task),
                "delivered_at": nil, "dismissed_at": nil, "created_at": .int(now()), "deleted_at": nil,
            ])]
        }
        return reminderId
    }

    private func checkOffset(_ minutes: Int64) throws {
        guard abs(minutes) <= maxReminderOffset else {
            throw CannotEdit("A reminder can be at most a year from the due time")
        }
    }

    /// A relative or deadline reminder at another offset from its task's due time or deadline.
    public func setOffset(_ reminderId: String, minutes: Int64) throws {
        try checkOffset(minutes)
        try commit {
            guard let reminder = try store.rows("reminder")[reminderId], isLive(reminder),
                  reminder["kind"] == "relative" || reminder["kind"] == "deadline" else {
                throw CannotEdit("That reminder no longer exists")
            }
            let task = try liveTask(try store.rows("task"), reminder["task_id"].string ?? "")
            let fireAt = reminder["kind"] == "deadline" ? deadlineFireAt(task["deadline"], .int(minutes))
                : relativeFireAt(task["due"], .int(minutes))
            return [Change("reminder", reminderId, ["offset_minutes": .int(minutes), "fire_at": fireAt,
                                                     "delivered_at": nil, "dismissed_at": nil])]
        }
    }

    public func deleteReminder(_ reminderId: String) throws {
        try changeReminder(reminderId, ["deleted_at": .int(now())])
    }

    /// Fire at until: a snooze, or a new time for a reminder at a moment of its own.
    public func snooze(_ reminderId: String, until: Int64) throws {
        try changeReminder(reminderId, ["fire_at": .int(until), "delivered_at": nil, "dismissed_at": nil])
    }

    /// Silence the current firing.
    public func dismiss(_ reminderId: String) throws {
        try changeReminder(reminderId, ["dismissed_at": .int(now())])
    }

    private func changeReminder(_ reminderId: String, _ patch: [String: JSON]) throws {
        try commit {
            guard let reminder = try store.rows("reminder")[reminderId], isLive(reminder) else {
                throw CannotEdit("That reminder no longer exists")
            }
            return [Change("reminder", reminderId, patch)]
        }
    }

    // MARK: saved views

    /// A list view, last in the sidebar. Returns its id.
    @discardableResult
    public func addView(_ edit: ViewEdit) throws -> String {
        let fields = try checkView(edit)
        guard fields["name"] != nil, fields["query"] != nil else { throw CannotEdit("A view needs a name and a query") }
        let viewId = newId()
        try commit {
            let now = now()
            let last = try store.rows("view").values.filter(isLive).compactMap { $0["position"].number }.max()
            var view: [String: JSON] = [
                "name": fields["name"]!, "query": fields["query"]!, "kind": "list",
                "group_by": fields["group_by"] ?? "project", "sort_by": fields["sort_by"] ?? "due",
                "sort_dir": fields["sort_dir"] ?? "asc", "pinned": true,
                "position": position(max(Double(now), (last ?? 0) + 1)), "color": .string(defaultViewColor),
                "panels": [], "created_at": .int(now), "deleted_at": nil,
            ]
            // Display options only when they differ from the defaults, like the web app.
            if fields["show_completed"] == true { view["show_completed"] = true }
            return [Change("view", viewId, view)]
        }
        return viewId
    }

    /// Write the changed fields of a view, in one batch.
    public func editView(_ viewId: String, _ edit: ViewEdit) throws {
        let fields = try checkView(edit)
        try commit {
            guard let view = try store.rows("view")[viewId], isLive(view) else {
                throw CannotEdit("That view no longer exists")
            }
            let patch = fields.filter { name, value in
                (view.values[name] ?? (name == "show_completed" ? false : .null)) != value
            }
            return patch.isEmpty ? [] : [Change("view", viewId, patch)]
        }
    }

    /// Undo brings it back.
    public func deleteView(_ viewId: String) throws -> Done {
        try commit {
            guard let view = try store.rows("view")[viewId], isLive(view) else {
                throw CannotEdit("That view no longer exists")
            }
            return ([Change("view", viewId, ["deleted_at": .int(now())])],
                    Done(undo: [Change("view", viewId, ["deleted_at": nil])]))
        }
    }

    /// The view fields as written: a name, a query that parses, known options.
    private func checkView(_ edit: ViewEdit) throws -> [String: JSON] {
        var out: [String: JSON] = [:]
        if let name = edit.name?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard !name.isEmpty else { throw CannotEdit("A view needs a name") }
            out["name"] = .string(name)
        }
        if let query = edit.query?.trimmingCharacters(in: .whitespacesAndNewlines) {
            do {
                guard try parseFilter(query) != nil else { throw CannotEdit("A view needs a query") }
            } catch let error as FilterError {
                throw CannotEdit(error.message)
            }
            out["query"] = .string(query)
        }
        if let groupBy = edit.groupBy { out["group_by"] = .string(groupBy.rawValue) }
        if let sortBy = edit.sortBy { out["sort_by"] = .string(sortBy.rawValue) }
        if let sortDir = edit.sortDir { out["sort_dir"] = .string(sortDir.rawValue) }
        if let showCompleted = edit.showCompleted { out["show_completed"] = .bool(showCompleted) }
        return out
    }
}

/// The view fields `Writer.addView` and `editView` take. Nil leaves a field alone.
public struct ViewEdit: Equatable, Sendable {
    public var name: String?
    public var query: String?
    public var groupBy: ViewGroupBy?
    public var sortBy: ViewSortBy?
    public var sortDir: ViewSortDir?
    public var showCompleted: Bool?

    public init(name: String? = nil, query: String? = nil, groupBy: ViewGroupBy? = nil, sortBy: ViewSortBy? = nil,
                sortDir: ViewSortDir? = nil, showCompleted: Bool? = nil) {
        (self.name, self.query, self.groupBy, self.sortBy, self.sortDir, self.showCompleted) =
            (name, query, groupBy, sortBy, sortDir, showCompleted)
    }

    public var isEmpty: Bool { self == ViewEdit() }
}

// MARK: - Labels (spec/labels.md)

extension Writer {
    /// plan, also returning a Done whose undo puts back every field the changes write.
    func undoable(_ plan: () throws -> [Change]) throws -> Done {
        try commit {
            let changes = try plan()
            var rows: [String: [String: Row]] = [:]
            var undo: [Change] = []
            for change in changes {
                if rows[change.entity] == nil { rows[change.entity] = try store.rows(change.entity) }
                if let row = rows[change.entity]?[change.id] {
                    undo.append(Change(change.entity, change.id,
                                       Dictionary(uniqueKeysWithValues: change.patch.keys.map { ($0, row[$0]) })))
                }
            }
            return (changes, Done(undo: undo))
        }
    }

    func liveLabels() throws -> [Row] { try store.rows("label").values.filter(isLive) }

    func liveLabel(_ labelId: String) throws -> Row {
        guard let label = try store.rows("label")[labelId], isLive(label) else {
            throw CannotEdit("That label no longer exists")
        }
        return label
    }

    /// A name a label may take: not empty, and no other label's, ignoring case.
    func labelName(_ name: String, for labelId: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CannotEdit("A label needs a name") }
        if let other = exactLabel(try liveLabels().filter { $0.id != labelId }, name) {
            throw CannotEdit("There's already a label called “\(other["name"].string ?? "")”")
        }
        return name
    }

    /// The first colour no label uses, else one by the clock.
    func freeColour(_ used: Set<String>, now: Int64) -> String {
        labelColours.first { !used.contains($0.hex) }?.hex ?? labelColours[Int(now % Int64(labelColours.count))].hex
    }

    /// Label ids in the order given, and the changes creating the missing ones.
    ///
    /// refs are ids of live labels, or names. Names ignore case, then spaces, dashes and underscores.
    /// With two labels of one name, the first in sidebar order wins.
    func resolveLabels(_ refs: [String]) throws -> ([String], [Change]) {
        var labels = try liveLabels().sorted { a, b in
            let pa = a["position"].number ?? 0, pb = b["position"].number ?? 0
            if pa != pb { return pa < pb }
            let ca = a["created_at"].number ?? 0, cb = b["created_at"].number ?? 0
            return ca != cb ? ca < cb : bytesLess(a.id, b.id)
        }
        var known = Set(labels.map(\.id))
        var used = Set(labels.compactMap { $0["color"].string })
        var ids: [String] = [], created: [Change] = []
        for ref in refs {
            let name = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            var labelId = known.contains(ref) ? ref
                : labels.first { labelKey($0["name"].string ?? "", fold: false) == labelKey(name, fold: false) }?.id
                ?? labels.first { labelKey($0["name"].string ?? "", fold: true) == labelKey(name, fold: true) }?.id
            if labelId == nil {
                guard !name.isEmpty else { continue }
                let id = newId(), now = now()
                let colour = freeColour(used, now: now)
                used.insert(colour)
                let fields: [String: JSON] = ["name": .string(name), "color": .string(colour), "position": .int(now),
                                              "created_at": .int(now), "deleted_at": nil]
                labels.append(Row(id: id, values: fields))
                known.insert(id)
                created.append(Change("label", id, fields))
                labelId = id
            }
            if let labelId, !ids.contains(labelId) { ids.append(labelId) }
        }
        return (ids, created)
    }

    /// A label, last in the sidebar. Returns its id.
    @discardableResult
    public func addLabel(_ name: String, color: String? = nil) throws -> String {
        let labelId = newId()
        try commit {
            let used = Set(try liveLabels().compactMap { $0["color"].string })
            let now = now()
            return [Change("label", labelId, [
                "name": .string(try labelName(name)), "color": .string(color ?? freeColour(used, now: now)),
                "position": .int(now), "created_at": .int(now), "deleted_at": nil,
            ])]
        }
        return labelId
    }

    /// Rename or recolour. One op per changed field; no task is written, since tasks hold ids.
    public func editLabel(_ labelId: String, name: String? = nil, color: String? = nil) throws -> Done {
        try undoable {
            let label = try liveLabel(labelId)
            var patch: [String: JSON] = [:]
            if let name, name.trimmingCharacters(in: .whitespacesAndNewlines) != label["name"].string {
                patch["name"] = .string(try labelName(name, for: labelId))
            }
            if let color, color != label["color"].string {
                guard color.wholeMatch(of: /#[0-9a-fA-F]{6}/) != nil else { throw CannotEdit("That isn't a colour") }
                patch["color"] = .string(color)
            }
            return patch.isEmpty ? [] : [Change("label", labelId, patch)]
        }
    }

    /// Put a label at index of the sidebar's labels, counted without it.
    public func moveLabel(_ labelId: String, to index: Int) throws -> Done {
        try undoable {
            _ = try liveLabel(labelId)
            return reorder("label", try liveLabels(), labelId, to: index)
        }
    }

    /// One place up (-1) or down (+1) in the sidebar. Nothing at an edge.
    public func moveLabel(_ labelId: String, step: Int) throws -> Done {
        try undoable {
            _ = try liveLabel(labelId)
            return self.step("label", try liveLabels().sorted(by: orderLess), labelId, by: step)
        }
    }

    /// Tombstone a label and take its id off every live task, one op per task.
    public func deleteLabel(_ labelId: String) throws -> Done {
        try undoable {
            _ = try liveLabel(labelId)
            let changes = carrying(try store.rows("task").values, labelId).map { task in
                Change("task", task.id, ["labels": .array(labelIds(task).filter { $0 != labelId }.map(JSON.string))])
            }
            return changes + [Change("label", labelId, ["deleted_at": .int(now())])]
        }
    }

    /// Every live task with source carries target instead, once. Then source is deleted.
    public func mergeLabels(_ sourceId: String, into targetId: String) throws -> Done {
        try undoable {
            guard sourceId != targetId else { throw CannotEdit("A label can't merge into itself") }
            _ = try liveLabel(sourceId)
            _ = try liveLabel(targetId)
            let changes = carrying(try store.rows("task").values, sourceId).map { task in
                var seen: Set<String> = []
                let merged = labelIds(task).map { $0 == sourceId ? targetId : $0 }.filter { seen.insert($0).inserted }
                return Change("task", task.id, ["labels": .array(merged.map(JSON.string))])
            }
            return changes + [Change("label", sourceId, ["deleted_at": .int(now())])]
        }
    }

    /// Add labels (ids, or names that create one) and remove ids, from the task's current array.
    /// Reads the array in the same transaction as the write, so edits on a row never lose a label.
    public func changeTaskLabels(_ taskId: String, add: [String] = [], remove: Set<String> = []) throws -> Done {
        try undoable {
            let current = labelIds(try liveTask(try store.rows("task"), taskId))
            let (added, created) = try resolveLabels(add)
            var seen: Set<String> = []
            let wanted = (current + added).filter { seen.insert($0).inserted && !remove.contains($0) }
            if wanted == current { return [] }
            return created + [Change("task", taskId, ["labels": .array(wanted.map(JSON.string))])]
        }
    }
}

// MARK: - The sidebar's order: projects, labels, views (spec/dragdrop.md, "In the sidebar")

extension Writer {
    /// The position writes that put movedId at index of rows, counted without it.
    func reorder(_ entity: String, _ rows: [Row], _ movedId: String, to index: Int) -> [Change] {
        planOrder(rows.map { (id: $0.id, position: $0["position"].number ?? 0) }, moving: movedId, to: index,
                  fallback: Double(now())).map { Change(entity, $0.id, ["position": position($0.position)]) }
    }

    /// One place up (-1) or down (+1) among rows, in sidebar order. Nothing at an edge.
    func step(_ entity: String, _ rows: [Row], _ movedId: String, by step: Int) -> [Change] {
        guard let index = rows.firstIndex(where: { $0.id == movedId }).map({ $0 + step }),
              rows.indices.contains(index) else { return [] }
        return reorder(entity, rows, movedId, to: index)
    }

    /// The live, unarchived projects under parentId, in sidebar order.
    func projectSiblings(_ projects: [String: Row], _ parentId: String?) -> [Row] {
        projects.values.filter { isLive($0) && !$0["archived"].isTruthy && $0["parent_id"].string == parentId }
            .sorted(by: orderLess)
    }

    func liveProject(_ projects: [String: Row], _ projectId: String) throws -> Row {
        guard let project = projects[projectId], isLive(project) else {
            throw CannotEdit("That project no longer exists")
        }
        return project
    }

    /// Every live project below projectId. Safe against cycles.
    func projectDescendants(_ projectId: String, _ projects: [String: Row]) -> Set<String> {
        var children: [String: [String]] = [:]
        for p in projects.values where isLive(p) {
            if let parent = p["parent_id"].string { children[parent, default: []].append(p.id) }
        }
        var found: Set<String> = [], stack = [projectId]
        while let id = stack.popLast() {
            for child in children[id] ?? [] where child != projectId && found.insert(child).inserted {
                stack.append(child)
            }
        }
        return found
    }

    /// A parent a project may go under: live, not archived, and not the project or below it. Nil is the top level.
    func checkParent(_ projects: [String: Row], _ parentId: String?, for projectId: String? = nil) throws {
        guard let parentId else { return }
        guard let parent = projects[parentId], isLive(parent), !parent["archived"].isTruthy else {
            throw CannotEdit("That parent project no longer exists")
        }
        if let projectId, parentId == projectId || projectDescendants(projectId, projects).contains(parentId) {
            throw CannotEdit("A project can't go under itself")
        }
    }

    /// Last among the live projects under parentId: the web app's rule, + 1 rather than a gap.
    func lastProjectPosition(_ projects: [String: Row], _ parentId: String?, skip: String? = nil) -> JSON {
        let last = projects.values.filter { $0.id != skip && isLive($0) && $0["parent_id"].string == parentId }
            .compactMap { $0["position"].number }.max()
        return position(max(Double(now()), (last ?? 0) + 1))
    }

    /// A project, last at the top level or under parentId, in the first colour no live project uses. Returns its id.
    @discardableResult
    public func addProject(_ name: String, under parentId: String? = nil, color: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CannotEdit("A project needs a name") }
        let projectId = newId()
        try commit {
            let projects = try store.rows("project")
            try checkParent(projects, parentId)
            let used = Set(projects.values.filter(isLive).compactMap { $0["color"].string })
            return [Change("project", projectId, [
                "name": .string(name),
                "color": .string(color ?? projectColours.first { !used.contains($0.hex) }?.hex ?? projectColours[0].hex),
                "position": lastProjectPosition(projects, parentId), "archived": false,
                "parent_id": parentId.map(JSON.string) ?? nil, "created_at": .int(now()), "deleted_at": nil,
            ])]
        }
        return projectId
    }

    /// Put a project under parentId (nil: the top level), right before or after a sibling, or last.
    /// One batch: the parent when it changes, and the positions. Never under itself or below it.
    public func placeProject(_ projectId: String, under parentId: String?, before: String? = nil,
                             after: String? = nil) throws -> Done {
        try undoable {
            let projects = try store.rows("project")
            let project = try liveProject(projects, projectId)
            let siblings = projectSiblings(projects, parentId)
            let order = siblings.map(\.id).filter { $0 != projectId }
            let index = before.flatMap { order.firstIndex(of: $0) }
                ?? after.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? order.count
            var changes = reorder("project", siblings, projectId, to: index)
            if parentId != project["parent_id"].string {
                try checkParent(projects, parentId, for: projectId)
                changes.insert(Change("project", projectId, ["parent_id": parentId.map(JSON.string) ?? nil]), at: 0)
            }
            return changes
        }
    }

    /// One place up (-1) or down (+1) among its siblings.
    public func moveProject(_ projectId: String, step: Int) throws -> Done {
        try undoable {
            let projects = try store.rows("project")
            let project = try liveProject(projects, projectId)
            return self.step("project", projectSiblings(projects, project["parent_id"].string), projectId, by: step)
        }
    }

    /// The views the sidebar lists, in its order. Dashboards keep their positions.
    func listViews(_ viewId: String) throws -> [Row] {
        let views = try store.rows("view")
        guard let view = views[viewId], isLive(view) else { throw CannotEdit("That view no longer exists") }
        return views.values.filter(isListView).sorted(by: viewOrderLess)
    }

    /// Put a view at index of the sidebar's views, counted without it.
    public func moveView(_ viewId: String, to index: Int) throws -> Done {
        try undoable { reorder("view", try listViews(viewId), viewId, to: index) }
    }

    /// One place up (-1) or down (+1) in the sidebar. Nothing at an edge.
    public func moveView(_ viewId: String, step: Int) throws -> Done {
        try undoable { self.step("view", try listViews(viewId), viewId, by: step) }
    }
}

// MARK: - Projects and sections (spec/projects.md)

/// The project fields `Writer.editProject` takes. Nil leaves a field alone.
public struct ProjectEdit: Equatable, Sendable {
    public var name: String?
    /// A hex colour, "#rrggbb".
    public var color: String?
    /// `.some(nil)` is the top level.
    public var parentId: String??

    public init(name: String? = nil, color: String? = nil, parentId: String?? = nil) {
        (self.name, self.color, self.parentId) = (name, color, parentId)
    }
}

extension Writer {
    /// Write the changed fields of a project, as one batch. A new parent also writes a position, last among
    /// the new siblings.
    public func editProject(_ projectId: String, _ edit: ProjectEdit) throws -> Done {
        try undoable {
            let projects = try store.rows("project")
            let project = try liveProject(projects, projectId)
            var patch: [String: JSON] = [:]
            if let name = edit.name {
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw CannotEdit("A project needs a name") }
                if name != project["name"].string { patch["name"] = .string(name) }
            }
            if let color = edit.color, color != project["color"].string {
                guard color.wholeMatch(of: /#[0-9a-fA-F]{6}/) != nil else { throw CannotEdit("Not a colour: \(color)") }
                patch["color"] = .string(color)
            }
            if let parentId = edit.parentId, parentId != project["parent_id"].string {
                try checkParent(projects, parentId, for: projectId)
                patch["parent_id"] = parentId.map(JSON.string) ?? .null
                patch["position"] = lastProjectPosition(projects, parentId, skip: projectId)
            }
            return patch.isEmpty ? [] : [Change("project", projectId, patch)]
        }
    }

    /// Archive a project and every live sub-project below it.
    public func archiveProject(_ projectId: String) throws -> Done {
        try commit {
            let projects = try store.rows("project")
            let project = try liveProject(projects, projectId)
            let ids = ([project] + projectDescendants(projectId, projects).compactMap { projects[$0] })
                .filter { !$0["archived"].isTruthy }.map(\.id)
            // Undo writes false, never null: archived is a boolean even where it was never set.
            return (ids.map { Change("project", $0, ["archived": true]) },
                    Done(undo: ids.map { Change("project", $0, ["archived": false]) }))
        }
    }

    /// Unarchive one project. Its archived sub-projects stay archived, as in the web app.
    public func unarchiveProject(_ projectId: String) throws -> Done {
        try undoable {
            let project = try liveProject(try store.rows("project"), projectId)
            return project["archived"].isTruthy ? [Change("project", projectId, ["archived": false])] : []
        }
    }

    /// Tombstone a project. Its direct sub-projects move up to its parent. Its tasks keep project_id.
    public func deleteProject(_ projectId: String) throws -> Done {
        try undoable {
            let projects = try store.rows("project")
            let parentId = try liveProject(projects, projectId)["parent_id"].string
            let lifted = projects.values
                .filter { isLive($0) && $0["parent_id"].string == projectId && $0.id != projectId }
                .sorted { bytesLess($0.id, $1.id) }
                .map { Change("project", $0.id, ["parent_id": parentId == $0.id ? nil : parentId.map(JSON.string) ?? nil]) }
            return lifted + [Change("project", projectId, ["deleted_at": .int(now())])]
        }
    }

    /// The project's live sections, in order.
    func liveSections(_ projectId: String?) throws -> [Row] {
        try store.rows("section").values.filter { isLive($0) && $0["project_id"].string == projectId }
            .sorted(by: orderLess)
    }

    func liveSection(_ sectionId: String) throws -> Row {
        guard let section = try store.rows("section")[sectionId], isLive(section) else {
            throw CannotEdit("That section no longer exists")
        }
        return section
    }

    func sectionName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CannotEdit("A section needs a name") }
        return name
    }

    /// A section, last in its project. Returns its id.
    @discardableResult
    public func addSection(_ name: String, to projectId: String?) throws -> String {
        let name = try sectionName(name)
        let sectionId = newId()
        try commit {
            guard let projectId else { throw CannotEdit("The Inbox has no sections") }
            try checkProject(projectId)
            let last = try liveSections(projectId).compactMap { $0["position"].number }.max()
            return [Change("section", sectionId, [
                "name": .string(name), "project_id": .string(projectId),
                "position": last.map { position($0 + positionGap) } ?? .int(now()),
                "created_at": .int(now()), "deleted_at": nil,
            ])]
        }
        return sectionId
    }

    public func renameSection(_ sectionId: String, to name: String) throws -> Done {
        let name = try sectionName(name)
        return try undoable {
            try liveSection(sectionId)["name"].string == name ? [] : [Change("section", sectionId, ["name": .string(name)])]
        }
    }

    /// One place up (-1) or down (+1) among its project's sections. Nothing at an edge.
    public func moveSection(_ sectionId: String, step: Int) throws -> Done {
        try undoable {
            let sections = try liveSections(try liveSection(sectionId)["project_id"].string)
            return self.step("section", sections, sectionId, by: step)
        }
    }

    /// Tombstone a section. Its live open tasks go to "No section", in the same batch.
    public func deleteSection(_ sectionId: String) throws -> Done {
        try undoable {
            _ = try liveSection(sectionId)
            let tasks = try store.rows("task").values
                .filter { isLive($0) && $0["completed_at"].isNull && $0["section_id"].string == sectionId }
                .sorted { bytesLess($0.id, $1.id) }
            return [Change("section", sectionId, ["deleted_at": .int(now())])]
                + tasks.map { Change("task", $0.id, ["section_id": nil]) }
        }
    }
}

// MARK: - Drag and drop (spec/dragdrop.md)

extension Writer {
    /// Apply a drop target to an open task, as one batch.
    /// Returns Done whose undo restores every field written. Nothing changed: an empty undo.
    public func drop(_ taskId: String, on target: DropTarget) throws -> Done {
        try undoable {
            let tasks = try store.rows("task")
            let task = try liveTask(tasks, taskId)
            guard task["completed_at"].isNull else { throw CannotEdit("Only open tasks can be moved") }
            switch target {
            case .place(let place):
                return try planPlace(tasks, task, place)
            case .project(let projectId):
                return try planEdit(taskId, TaskEdit(place: Place(projectId: projectId)))
            case .day(let day):
                let due = task["due"]
                if due["date"].string == day.description { return [] }
                var fields = due.object ?? [:]
                fields["date"] = .string(day.description)
                return try planEdit(taskId, TaskEdit(due: .object(fields)))
            case .label(let labelId):
                _ = try liveLabel(labelId)
                let labels = labelIds(task)
                if labels.contains(labelId) { return [] }
                return [Change("task", taskId, ["labels": .array((labels + [labelId]).map(JSON.string))])]
            }
        }
    }

    /// The changes that put an open task at a Placement: one position write, unless the list needs renumbering.
    /// The list is a parent's open subtasks, or the open top-level tasks of one section.
    func planPlace(_ tasks: [String: Row], _ task: Row, _ place: Placement) throws -> [Change] {
        let (projectId, sectionId, parentId) = (place.projectId, place.sectionId, place.parentId)
        try checkProject(projectId)
        if parentId == nil { try checkSection(sectionId, in: projectId) }
        let open = tasks.values.filter { t in
            isLive(t) && t["completed_at"].isNull && t["project_id"].string == projectId
        }
        var parents: [String: String?] = [:]
        func walk(_ nodes: [Node], _ parent: String?) {
            for node in nodes {
                parents[node.id] = .some(parent)
                walk(node.children, node.id)
            }
        }
        walk(buildTree(open) { $0["parent_id"].string }, nil)
        if let parentId {
            let below = Set(descendants(of: task.id, in: tasks).map(\.id))
            if parents[parentId] == nil || parentId == task.id || below.contains(parentId) {
                throw CannotEdit("A task can't go under itself")
            }
        }
        let sections = Set(try store.rows("section").values.filter { s in
            isLive(s) && s["project_id"].string == projectId
        }.map(\.id))
        func sectionOf(_ t: Row) -> String? { t["section_id"].string.flatMap { sections.contains($0) ? $0 : nil } }

        let siblings = open.filter { t in
            guard let shown = parents[t.id] else { return false }
            return parentId == nil ? shown == nil && sectionOf(t) == sectionId : shown == parentId
        }
        let others = siblings.sorted(by: orderLess).map(\.id).filter { $0 != task.id }
        let anchor = place.before ?? place.after
        var index = others.count
        if let anchor {
            guard let i = others.firstIndex(of: anchor) else { throw CannotEdit("That task is no longer in the list") }
            index = i + (place.after != nil ? 1 : 0)
        }

        var patch: [String: JSON] = [:], out: [Change] = []
        let sameProject = projectId == task["project_id"].string
        if !sameProject {
            patch["project_id"] = projectId.json
            out = carrySubtree(tasks, task.id, to: projectId)
        }
        // In its own project the parent is the one the tree shows; a stale reference stays unwritten.
        let currentParent = sameProject ? parents[task.id] ?? nil : task["parent_id"].string
        if parentId != currentParent { patch["parent_id"] = parentId.json }
        if parentId == nil && sectionId != (sameProject ? sectionOf(task) : task["section_id"].string) {
            patch["section_id"] = sectionId.json
        } else if parentId != nil && !sameProject && task["section_id"].isTruthy {
            patch["section_id"] = .null  // that section belongs to the old project
        }
        // A task from another list isn't among siblings, so it always gets a position here.
        let moves = planOrder(siblings.map { (id: $0.id, position: $0["position"].number ?? 0) }, moving: task.id,
                              to: index, fallback: Double(now()))
        return moves.map { move in
            Change("task", move.id, (move.id == task.id ? patch : [:]).merging(["position": position(move.position)]) { $1 })
        } + out
    }
}

// MARK: - Quick add (spec/quickadd.md)

extension Writer {
    /// What a quick-add line sets, read with the user's preferences.
    public func parseLine(_ line: String) throws -> QuickAddResult {
        let projects = try store.rows("project").values.filter(isLive)
        return parseQuickAdd(line, quickAddContext(prefs: try store.rows("user_prefs")["me"]?.values ?? [:],
                                              projects: Array(projects), today: try today(), now: clockNow()))
    }

    /// HH:MM on this device now.
    private func clockNow() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date(ms: now()))
        return clockText(c.hour ?? 0, c.minute ?? 0)
    }

    /// Add a task from a quick-add line, in one batch with its new labels, reminders and time spent.
    ///
    /// The page's project and section, or due date, apply unless the line sets its own. labels: the page's label ids,
    /// added to any the line names. A subtask (parentId) always takes its parent's project. Returns its id.
    @discardableResult
    public func quickAdd(_ line: String, projectId: String? = nil, sectionId: String? = nil, due: JSON = nil,
                         parentId: String? = nil, labels: [String] = []) throws -> String {
        let taskId = newId()
        try commit {
            let parsed = try parseLine(line)
            let live = Set(try liveLabels().map(\.id))
            let (ids, created) = try resolveLabels(labels.filter(live.contains) + parsed.labels)
            let ownPlace = parsed.projectId != nil
            var task = try newTask(parsed.title, projectId: ownPlace ? parsed.projectId : projectId,
                                   sectionId: ownPlace ? nil : sectionId, parentId: parentId,
                                   due: parsed.due.isNull && !parsed.someday && parsed.sector == nil ? due : parsed.due)
            task["labels"] = .array(ids.map(JSON.string))
            if let priority = parsed.priority { task["priority"] = .int(Int64(priority)) }
            if let minutes = parsed.estimateMinutes { task["estimate_minutes"] = .int(Int64(minutes)) }
            // Optional fields are written only when set.
            let extras: [String: JSON?] = [
                "deadline": parsed.deadline.map { .string($0.description) },
                "start": parsed.someday ? "someday" : nil,
                "evening": parsed.evening ? true : nil,
                "day_part": parsed.evening ? nil : parsed.dayPart.map(JSON.string),
                "energy": parsed.energy.map(JSON.string),
                "sector": parsed.sector.map(JSON.string),
                "recurrence": parsed.recurrence.map(JSON.string),
            ]
            for case let (name, value?) in extras { task[name] = value }
            var changes = created + [Change("task", taskId, task)]
            let today = try today(), now = clockNow()
            for typed in parsed.reminders {
                changes.append(Change("reminder", newId(), typedReminder(taskId, due: task["due"] ?? nil, typed,
                                                                          today: today, now: now)))
            }
            if let spent = parsed.spentMinutes, let me = try store.meta("user_id").string {
                let end = self.now()
                changes.append(Change("time_entry", newId(), [
                    "task_id": .string(taskId), "user_id": .string(me), "started_at": .int(end - Int64(spent) * 60_000),
                    "ended_at": .int(end), "device_id": .string(try store.device()), "note": "", "created_at": .int(end),
                    "deleted_at": nil,
                ]))
            }
            return changes
        }
        return taskId
    }

    /// A reminder typed in quick add, resolved against the task's due.
    private func typedReminder(_ taskId: String, due: JSON, _ typed: TypedReminder, today: Day,
                               now: String) -> [String: JSON] {
        var fields: [String: JSON] = [
            "task_id": .string(taskId), "delivered_at": nil, "dismissed_at": nil, "created_at": .int(self.now()),
            "deleted_at": nil,
        ]
        switch resolveReminder(typed, due: due, today: today, now: now) {
        case .relative(let minutes):
            (fields["kind"], fields["offset_minutes"]) = ("relative", .int(Int64(minutes)))
            fields["fire_at"] = relativeFireAt(due, .int(Int64(minutes)))
        case .absolute(let day, let time):
            (fields["kind"], fields["offset_minutes"]) = ("absolute", nil)
            fields["fire_at"] = dueInstant(["date": .string(day.description), "time": .string(time)]).map(JSON.int) ?? nil
        }
        return fields
    }
}

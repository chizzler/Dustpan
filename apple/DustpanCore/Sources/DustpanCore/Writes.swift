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
}

/// The task fields `Writer.edit` takes: title, priority, due, repeat rule, project and section.
public struct TaskEdit: Equatable, Sendable {
    public var title: String?
    public var priority: Int64?
    /// nil leaves the due alone; .null clears it.
    public var due: JSON?
    /// A rule to parse; "" stops the repeat.
    public var recurrence: String?
    public var place: Place?

    public init(title: String? = nil, priority: Int64? = nil, due: JSON? = nil, recurrence: String? = nil,
                place: Place? = nil) {
        (self.title, self.priority, self.due, self.recurrence, self.place) = (title, priority, due, recurrence, place)
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
                        parentId: String? = nil, due: JSON = nil) throws -> String {
        let taskId = newId()
        try commit {
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
            return [Change("task", taskId, patch)]
        }
        return taskId
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

    /// Apply the undo changes of an earlier action, as a new batch.
    public func revert(_ undo: [Change]) throws {
        try commit { undo }
    }

    /// Write the changed fields of one task, in one batch.
    public func edit(_ taskId: String, _ edit: TaskEdit) throws {
        try commit {
            let tasks = try store.rows("task")
            let task = try liveTask(tasks, taskId)
            var patch: [String: JSON] = [:]
            var out: [Change] = []
            if let title = edit.title {
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { throw CannotEdit("A task needs a title") }
                patch["title"] = .string(title)
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
            if let place = edit.place {
                out = try planMove(tasks, task, to: place, into: &patch)
            }
            return patch.isEmpty ? out : out + [Change("task", taskId, patch)]
        }
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
        // Subtasks follow their parent into another project, out of its sections.
        return descendants(of: task.id, in: tasks).filter { $0["project_id"].string != projectId }.map { d in
            var patch: [String: JSON] = ["project_id": projectId.json]
            if d["section_id"].isTruthy { patch["section_id"] = .null }
            return Change("task", d.id, patch)
        }
    }

    // MARK: reminders

    /// A reminder offsetMinutes from the task's due time. Returns its id.
    @discardableResult
    public func addReminder(_ taskId: String, offsetMinutes: Int64) throws -> String {
        guard abs(offsetMinutes) <= maxReminderOffset else {
            throw CannotEdit("A reminder can be at most a year from the due time")
        }
        let reminderId = newId()
        try commit {
            let task = try liveTask(try store.rows("task"), taskId)
            return [Change("reminder", reminderId, [
                "task_id": .string(taskId), "kind": "relative", "offset_minutes": .int(offsetMinutes),
                "fire_at": relativeFireAt(task["due"], .int(offsetMinutes)), "delivered_at": nil,
                "dismissed_at": nil, "created_at": .int(now()), "deleted_at": nil,
            ])]
        }
        return reminderId
    }

    public func deleteReminder(_ reminderId: String) throws {
        try changeReminder(reminderId, ["deleted_at": .int(now())])
    }

    /// Fire again at until.
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
}

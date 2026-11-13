import Foundation

// Reminders that follow their task's dates, and default reminders.
// See docs/reminders.md and docs/default-reminders.md. The default reminder rule is
// a port of web/src/lib/defaultReminder.ts, checked against defaultReminder.vectors.json.

let maxReminderOffset: Int64 = 525_600  // one year either side, in minutes

/// A relative reminder fires at the due instant plus offset minutes. Null without a due.
func relativeFireAt(_ due: JSON, _ offset: JSON, localZone: TimeZone = .current) -> JSON {
    guard due.isTruthy, let instant = dueInstant(due, localZone: localZone) else { return .null }
    return .int(instant + (offset.int ?? 0) * 60_000)
}

/// A deadline reminder fires at 09:00 local on the deadline plus offset minutes. Null without a deadline.
func deadlineFireAt(_ deadline: JSON, _ offset: JSON) -> JSON {
    guard deadline.isTruthy, let instant = dueInstant(["date": deadline]) else { return .null }
    return .int(instant + (offset.int ?? 0) * 60_000)
}

/// A stored default: whole minutes within a year, else nil.
func parseDefault(_ value: JSON) -> Int64? {
    guard let text = value.string, text.wholeMatch(of: /-?\d{1,7}/) != nil, let n = Int64(text) else { return nil }
    return abs(n) <= maxReminderOffset ? n : nil
}

/// The user_prefs string for a default reminder's offset.
func formatDefault(_ minutes: Int64) -> String { String(minutes) }

/// A custom offset typed in Settings: "15m", "2h", "3d before", "30 min after", "+45m". Signed minutes, nil if it
/// isn't one or is more than a year. A bare duration is before the due time; "after" or "+" makes it after.
public func parseCustomOffset(_ text: String) -> Int64? {
    let raw = text.trimmingCharacters(in: .whitespaces).lowercased()
    if raw == "0" || raw == "at due time" { return 0 }
    let units = "m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks"
    guard let match = raw.wholeMatch(of: try! Regex(#"([+-])?\s*(\d{1,7})\s*("# + units + #")?(?:\s*(before|after))?"#))
    else { return nil }
    let sign = match.output[1].substring, direction = match.output[4].substring
    if sign != nil && direction != nil { return nil }
    let scale: Int64 = switch match.output[3].substring?.first {
    case "h": 60
    case "d": 1440
    case "w": 10080
    default: 1
    }
    let minutes = Int64(match.output[2].substring!)! * scale
    guard minutes <= maxReminderOffset else { return nil }
    if minutes == 0 { return 0 }
    return direction == "after" || sign == "+" ? minutes : -minutes
}

/// The default reminders, in minutes from the due time: nil for none.
public struct ReminderDefaults: Equatable {
    public var timed: Int64?
    public var dated: Int64?

    /// From a user_prefs row's values.
    public init(prefs: [String: JSON]) {
        timed = parseDefault(prefs["reminder_default_timed"] ?? .null)
        dated = parseDefault(prefs["reminder_default_dated"] ?? .null)
    }

    var isEmpty: Bool { timed == nil && dated == nil }

    func offset(for due: JSON) -> Int64? { isTimed(due) ? timed : dated }
}

private func dueValue(_ value: JSON) -> JSON? {
    if let date = value["date"].string, !date.isEmpty { value } else { nil }
}

private func isTimed(_ due: JSON) -> Bool { due["time"].string.map { !$0.isEmpty } ?? false }

/// The reminder changes one write adds for one task.
///
/// - before: the stored task's values, or nil when the write creates it.
/// - patch: every field the write sets on the task.
/// - reminders: this person's stored reminders of the task, by id.
/// - batch: reminder changes already in the same write.
func planDefaultReminder(userId: String, taskId: String, before: [String: JSON]?, patch: [String: JSON],
                         reminders: [String: [String: JSON]], batch: [Change], defaults: ReminderDefaults, now: Int64,
                         fireAt: (JSON, JSON) -> JSON = { relativeFireAt($0, $1) }) -> [Change] {
    guard let due = patch["due"] else { return [] }
    let rid = defaultReminderId(userId: userId, taskId: taskId)
    var merged = reminders
    for change in batch {
        let prev = merged[change.id]
        if prev == nil && change.patch["task_id"]?.string != taskId { continue }
        merged[change.id, default: [:]].merge(change.patch) { _, new in new }
    }
    let rows = merged.filter { $0.value["task_id", default: .null].isNull || $0.value["task_id"]?.string == taskId }
    let own = rows[rid]
    func value(_ row: [String: JSON]?, _ key: String) -> JSON { row?[key] ?? .null }
    func isRelative(_ row: [String: JSON]) -> Bool { (row["kind"]?.string ?? "relative") == "relative" }

    let oldDue = dueValue(value(before, "due"))
    guard let newDue = dueValue(due) else { return [] }
    if let oldDue {
        // The kind of due changed and the default reminder is untouched.
        guard isTimed(oldDue) != isTimed(newDue), let own, !value(own, "deleted_at").isTruthy, isRelative(own),
              let src = defaults.offset(for: oldDue), let dst = defaults.offset(for: newDue),
              value(own, "offset_minutes").int == src, src != dst
        else { return [] }
        return [Change("reminder", rid, ["offset_minutes": .int(dst), "fire_at": fireAt(newDue, .int(dst)),
                                         "delivered_at": nil, "dismissed_at": nil])]
    }
    guard let offset = defaults.offset(for: newDue) else { return [] }
    let after = (before ?? [:]).merging(patch) { _, new in new }
    if value(after, "completed_at").isTruthy || value(after, "deleted_at").isTruthy || after["habit"] == true {
        return []
    }
    if rows.values.contains(where: { !value($0, "deleted_at").isTruthy && isRelative($0) }) { return [] }
    // A default reminder the person deleted stays deleted; one Undo removed (no offset left) may come back.
    if let own, !value(own, "deleted_at").isTruthy || !value(own, "offset_minutes").isNull { return [] }
    return [Change("reminder", rid, [
        "task_id": .string(taskId), "kind": "relative", "offset_minutes": .int(offset),
        "fire_at": fireAt(newDue, .int(offset)), "delivered_at": nil, "dismissed_at": nil,
        "created_at": .int(now), "deleted_at": nil,
    ])]
}

// MARK: - The editor

/// Offsets from the due time offered in the editor, in minutes.
public let relativePresets: [Int64] = [0, -10, -30, -60, -1440]
/// Offsets from 09:00 on the deadline.
public let deadlinePresets: [Int64] = [0, -1440]

/// "At due time", "30 minutes before", "2 hours after", "1 day before".
public func offsetLabel(_ minutes: Int64) -> String {
    if minutes == 0 { return "At due time" }
    var n = abs(minutes)
    let unit: String
    if n % 1440 == 0 {
        (n, unit) = (n / 1440, "day")
    } else if n % 60 == 0 {
        (n, unit) = (n / 60, "hour")
    } else {
        unit = "minute"
    }
    return "\(n) \(unit)\(n == 1 ? "" : "s") \(minutes < 0 ? "before" : "after")"
}

/// "On the deadline", "1 day before the deadline".
public func deadlineOffsetLabel(_ minutes: Int64) -> String {
    minutes == 0 ? "On the deadline" : offsetLabel(minutes) + " the deadline"
}

/// One line for a reminder in the editor.
public func describe(reminder r: Row) -> String {
    let offset = r["offset_minutes"].int ?? 0
    switch r["kind"].string {
    case "relative": return offsetLabel(offset)
    case "deadline": return deadlineOffsetLabel(offset)
    default:
        guard let fireAt = r["fire_at"].int else { return "No time" }
        return Date(ms: fireAt).formatted(.dateTime.weekday().day().month().year().hour().minute())
    }
}

extension Date {
    public init(ms: Int64) { self.init(timeIntervalSince1970: Double(ms) / 1000) }

    /// Unix milliseconds, as the server stores instants.
    public var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }
}

// MARK: - Firing

/// Dismissed for the current firing. A dismissal older than fire_at was for an earlier one.
func isDismissed(_ r: Row) -> Bool {
    guard let dismissed = r["dismissed_at"].int, let fireAt = r["fire_at"].int else { return false }
    return dismissed >= fireAt
}

/// Fired, live, not dismissed, and its task is live and open.
func isDue(_ r: Row, task: Row?, now: Int64) -> Bool {
    guard isLive(r), let fireAt = r["fire_at"].int, fireAt <= now, !isDismissed(r), let task else { return false }
    return task["completed_at"].isNull && isLive(task)
}

/// A task whose project, or any project above it, is deleted. Its reminders don't fire.
func inTrash(_ task: Row, _ projects: [String: Row]) -> Bool {
    var seen = Set<String>()
    var projectId = task["project_id"].string
    while let id = projectId, !id.isEmpty, seen.insert(id).inserted {
        guard let project = projects[id] else { return false }
        if !project["deleted_at"].isNull { return true }
        projectId = project["parent_id"].string
    }
    return false
}

/// A reminder to show, with its task.
public struct Alert: Sendable {
    public let reminder: Row
    public let task: Row
}

public struct ReminderCheck: Sendable {
    /// Newly due.
    public var show: [Alert] = []
    /// Reminder ids shown before and no longer due: dismissed or snoozed anywhere, or the task completed.
    public var withdraw: [String] = []
    /// The next firing after now.
    public var next: Int64?
}

/// On the first check, reminders that fired longer ago than this are marked as seen, not shown.
let staleReminderMs: Int64 = 24 * 60 * 60_000

/// Which reminders to show and withdraw, once per firing on this device.
/// The "notified" meta key maps reminder id to the fire_at already shown.
public func checkReminders(_ store: Store, now: Int64) throws -> ReminderCheck {
    try store.transaction {
        let tasks = try store.rows("task"), projects = try store.rows("project")
        let stored = try store.meta("notified")
        let firstRun = stored.isNull
        let notified = stored.object ?? [:]
        var current: [String: JSON] = [:]
        var check = ReminderCheck()
        for reminder in try store.rows("reminder").values.sorted(by: { $0.id < $1.id }) {
            guard let fireAt = reminder["fire_at"].int else { continue }
            if fireAt > now {
                if isLive(reminder) { check.next = min(check.next ?? fireAt, fireAt) }
                continue
            }
            let task = reminder["task_id"].string.flatMap { tasks[$0] }
            guard isDue(reminder, task: task, now: now), let task, !inTrash(task, projects) else { continue }
            current[reminder.id] = .int(fireAt)
            if notified[reminder.id]?.int == fireAt || (firstRun && now - fireAt > staleReminderMs) { continue }
            check.show.append(Alert(reminder: reminder, task: task))
        }
        check.withdraw = notified.keys.filter { current[$0] == nil }.sorted()
        if current != notified || firstRun { try store.setMeta("notified", .object(current)) }
        return check
    }
}

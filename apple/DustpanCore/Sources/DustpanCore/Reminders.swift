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

struct ReminderDefaults: Equatable {
    var timed: Int64?
    var dated: Int64?

    /// From a user_prefs row's values.
    init(prefs: [String: JSON]) {
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

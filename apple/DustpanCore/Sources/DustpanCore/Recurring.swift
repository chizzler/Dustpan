import Foundation

// Repeating tasks: what completing, skipping and detaching write.
// A port of web/src/lib/recurring.ts. Every value is a function of inputs all devices share
// (series id, rule, due date, occurrence date), so devices acting on the same occurrence offline
// write identical entities and converge. See docs/recurrence.md.

/// Optional fields an occurrence copy carries only when the series has them set.
private let copiedWhenSet = ["section_id", "deadline", "start", "day_part", "energy"]

/// What a series moving on writes: the changes, the record or copy it made, and its next due date.
struct MoveOn {
    var changes: [Change]
    var createdId: String?
    var next: Day
}

/// The parsed rule of an open, live series, or nil.
func seriesRule(_ task: Row) -> Rule? {
    guard let text = task["recurrence"].string, !text.isEmpty,
          !task["completed_at"].isTruthy, !task["deleted_at"].isTruthy else { return nil }
    return try? Rule(parsing: text)
}

/// The day of the occurrence the series stands on. Nil when its due date isn't a real day.
func occurrenceDay(_ series: Row, today: Day) -> Day? {
    let due = series["due"]
    return due.isTruthy ? due["date"].string.flatMap(Day.init) : today
}

/// Completed occurrence records of a series. Detached copies, reopened and skipped records don't count.
func completedOccurrences(_ seriesId: String, _ tasks: some Sequence<Row>, except day: Day?) -> Int {
    tasks.count { t in
        guard t["series_id"].string == seriesId, t["completed_at"].isTruthy, !t["deleted_at"].isTruthy,
              let date = t["due"]["date"].string, let d = Day(date), !t["skipped"].isTruthy, d != day
        else { return false }
        return t.id == occurrenceId(seriesId, d)
    }
}

/// The series' due on another day, keeping its time and zone.
private func moveDue(_ due: JSON, to day: Day) -> JSON {
    var moved: [String: JSON] = ["date": .string(day.description)]
    if due["time"].isTruthy {
        moved["time"] = due["time"]
        if due["tz"].isTruthy { moved["tz"] = due["tz"] }
    }
    return .object(moved)
}

/// The series on its next occurrence. A deadline and a start date move by the same days.
private func moveDates(_ series: Row, from current: Day, to next: Day) -> [String: JSON] {
    var out: [String: JSON] = ["due": moveDue(series["due"], to: next)]
    if let deadline = series["deadline"].string.flatMap(Day.init) {
        out["deadline"] = .string(shift(deadline, from: current, to: next).description)
    }
    if let start = series["start"].string.flatMap(Day.init) {
        out["start"] = .string(shift(start, from: current, to: next).description)
    }
    return out
}

/// Fields an occurrence copy inherits from its series.
private func copy(of series: Row, now: Int64) -> [String: JSON] {
    let v = series.values
    var out: [String: JSON] = [
        "title": v["title"] ?? "", "description": v["description"] ?? "",
        "project_id": series["project_id"], "parent_id": series["parent_id"],
        "priority": v["priority"] ?? 4, "due": series["due"], "labels": series["labels"].array.map(JSON.array) ?? [],
        "created_at": .int(now), "deleted_at": nil, "estimate_minutes": series["estimate_minutes"],
        "recurrence": nil, "series_id": .string(series.id),
    ]
    if series["position"].number != nil { out["position"] = series["position"] }
    for name in copiedWhenSet where series[name].isTruthy { out[name] = series[name] }
    if series["evening"].isTruthy { out["evening"] = true }
    // Custom field values, null included.
    for (name, value) in v where name.hasPrefix("fields.") { out[name] = value }
    return out
}

private func occurrence(of series: Row, on day: Day, now: Int64, completed: Bool) -> [String: JSON] {
    var record = copy(of: series, now: now)
    record["due"] = series["due"].isTruthy ? series["due"] : ["date": .string(day.description)]
    record["completed_at"] = completed ? .int(now) : nil
    return record
}

private func refuseBadDue() -> CannotEdit { CannotEdit("This task's due date isn't a real day") }

/// Completing the current occurrence: its record, and the series moves on. Nil at the end condition.
func planCompletion(_ series: Row, _ rule: Rule, tasks: some Sequence<Row>, now: Int64, today: Day) throws -> MoveOn? {
    guard let day = occurrenceDay(series, today: today) else { throw refuseBadDue() }
    let done = completedOccurrences(series.id, tasks, except: day)
    let due = series["due"].isTruthy ? day : nil
    guard let next = rule.following(due: due, today: today, completedOn: today, done: done) else { return nil }
    let recordId = occurrenceId(series.id, day)
    var record = occurrence(of: series, on: day, now: now, completed: true)
    if series["habit"].isTruthy { record["skipped"] = false }
    return MoveOn(changes: [Change("task", recordId, record),
                            Change("task", series.id, moveDates(series, from: day, to: next))],
                  createdId: recordId, next: next)
}

/// The occurrence after the current one for skip and detach. Nil past "until".
private func nextOnSkip(_ series: Row, _ rule: Rule, day: Day, today: Day) -> Day? {
    let next = rule.next(due: series["due"].isTruthy ? day : nil, today: today, completedOn: today)
    if let until = rule.until, next > until { return nil }
    return next
}

/// Skipping the current occurrence. A habit also records the skipped day. Nil on the last occurrence.
func planSkip(_ series: Row, _ rule: Rule, now: Int64, today: Day) throws -> MoveOn? {
    guard let day = occurrenceDay(series, today: today) else { throw refuseBadDue() }
    guard let next = nextOnSkip(series, rule, day: day, today: today) else { return nil }
    let move = Change("task", series.id, moveDates(series, from: day, to: next))
    guard series["habit"].isTruthy else { return MoveOn(changes: [move], next: next) }
    var record = occurrence(of: series, on: day, now: now, completed: true)
    record["skipped"] = true
    let recordId = occurrenceId(series.id, day)
    return MoveOn(changes: [Change("task", recordId, record), move], createdId: recordId, next: next)
}

/// "This occurrence only": a standalone open copy of the current occurrence, and the series moves on.
func planDetach(_ series: Row, _ rule: Rule, now: Int64, today: Day) throws -> MoveOn? {
    guard let day = occurrenceDay(series, today: today) else { throw refuseBadDue() }
    guard let next = nextOnSkip(series, rule, day: day, today: today) else { return nil }
    let copyId = detachedId(series.id, day)
    return MoveOn(changes: [Change("task", copyId, occurrence(of: series, on: day, now: now, completed: false)),
                            Change("task", series.id, moveDates(series, from: day, to: next))],
                  createdId: copyId, next: next)
}

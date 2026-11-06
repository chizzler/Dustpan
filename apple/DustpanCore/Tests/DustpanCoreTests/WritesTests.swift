import Foundation
import Testing
@testable import DustpanCore

/// A writer on an empty store, with a fixed clock.
@Suite struct WritesTests {
    let store: Store
    let writer: Writer
    let now: Int64 = 1_000_000

    init() throws {
        store = try memoryStore()
        let now = now
        writer = Writer(store: store, clock: HybridClock(store: store, now: { now }), now: { now },
                        today: { Day("2026-11-02")! })
        try store.setMeta("user_id", "me")
    }

    func seed(_ entity: String, _ id: String, _ fields: [String: JSON]) throws {
        for (name, value) in fields {
            try store.apply(Op(id: "\(id)-\(name)-1", entity: entity, entityId: id, field: name, value: value,
                               ts: 1, device: "other"))
        }
    }

    func task(_ id: String) throws -> Row { try #require(try store.rows("task")[id]) }
    func outbox() throws -> [Op] { try store.outboxBatch(limit: 1000).map(\.op) }

    @Test func addWritesEveryFieldInOneStampedBatch() throws {
        try seed("project", "p1", ["name": "Home"])
        let id = try writer.addTask("  Buy milk ", projectId: "p1")
        let row = try task(id)
        #expect(row["title"] == "Buy milk")
        #expect(row["project_id"] == "p1")
        #expect(row["priority"] == 4)
        #expect(row.values["section_id"] == nil)
        let ops = try outbox()
        #expect(Set(ops.map(\.ts)).count == 1)
        #expect(Set(ops.map(\.device)) == [try store.device()])
        #expect(Set(ops.map(\.id)).count == ops.count)
        #expect(Set(ops.map(\.field)) == ["title", "description", "project_id", "parent_id", "priority", "due",
                                         "labels", "position", "created_at", "completed_at", "completed_by", "deleted_at",
                                         "estimate_minutes"])
    }

    @Test func addGoesPastATaskMovedBeyondNow() throws {
        try seed("task", "t1", ["title": "Far", "position": .int(now + 5_000)])
        #expect(try task(try writer.addTask("New"))["position"] == .int(now + 6_000))
    }

    @Test func addRefusesEmptyTitleAndMissingProject() throws {
        #expect(throws: CannotEdit.self) { try writer.addTask("   ") }
        #expect(throws: CannotEdit.self) { try writer.addTask("x", projectId: "nope") }
        #expect(try store.outboxCount() == 0)
    }

    @Test func subtaskTakesParentsProjectAndNoSection() throws {
        try seed("project", "p1", ["name": "Work"])
        try seed("task", "t1", ["title": "Parent", "project_id": "p1", "section_id": "s1"])
        let row = try task(try writer.addTask("Child", sectionId: "s1", parentId: "t1"))
        #expect(row["project_id"] == "p1" && row["parent_id"] == "t1")
        #expect(row.values["section_id"] == nil)
    }

    @Test func completeCascadesToOpenDescendants() throws {
        try seed("task", "a", ["title": "A", "completed_at": nil])
        try seed("task", "b", ["title": "B", "parent_id": "a", "completed_at": nil])
        try seed("task", "c", ["title": "C", "parent_id": "b", "completed_at": nil])
        try seed("task", "d", ["title": "D", "parent_id": "a", "completed_at": 5])
        let done = try writer.complete("a")
        #expect(done.undo.map(\.id).sorted() == ["a", "b", "c"])
        #expect(try task("c")["completed_by"] == "me")
        #expect(try task("d")["completed_at"] == 5)
    }

    @Test func undoReopensWhatCompleteClosed() throws {
        try seed("task", "a", ["title": "A", "completed_at": nil])
        try seed("task", "b", ["title": "B", "parent_id": "a", "completed_at": nil])
        try writer.revert(try writer.complete("a").undo)
        #expect(try task("a")["completed_at"].isNull)
        #expect(try task("b")["completed_by"].isNull)
    }

    @Test func completingASeriesRecordsTheOccurrenceAndMovesOn() throws {
        try seed("task", "s", ["title": "Water plants", "recurrence": "every 3 days", "priority": 2,
                               "due": ["date": "2026-11-01", "time": "08:00"], "deadline": "2026-11-03",
                               "fields.f1": "x"])
        let done = try writer.complete("s")
        let series = try task("s")
        #expect(series["completed_at"].isNull)
        #expect(series["due"] == ["date": "2026-11-04", "time": "08:00"])
        #expect(series["deadline"] == "2026-11-06")
        #expect(done.nextDue == Day("2026-11-04"))
        let record = try task(occurrenceId("s", Day("2026-11-01")!))
        #expect(record["series_id"] == "s" && record["recurrence"].isNull)
        #expect(record["due"] == ["date": "2026-11-01", "time": "08:00"])
        #expect(record["completed_by"] == "me" && record["priority"] == 2)
        #expect(record["fields.f1"] == "x" && record["deadline"] == "2026-11-03")
        #expect(Set(try outbox().map(\.ts)).count == 1)
    }

    @Test func undoOfASeriesCompletionPutsItBack() throws {
        try seed("task", "s", ["title": "S", "recurrence": "every day", "due": ["date": "2026-11-02"]])
        let done = try writer.complete("s")
        try writer.revert(done.undo)
        #expect(try task("s")["due"] == ["date": "2026-11-02"])
        #expect(try task(occurrenceId("s", Day("2026-11-02")!))["deleted_at"].isTruthy)
    }

    @Test func lastOccurrenceCompletesTheSeries() throws {
        try seed("task", "s", ["title": "S", "recurrence": "every day for 1 time", "due": ["date": "2026-11-02"]])
        let done = try writer.complete("s")
        #expect(!(try task("s")["completed_at"].isNull))
        #expect(done.nextDue == nil)
    }

    @Test func skipMovesOnWithoutARecordAndAHabitRecordsIt() throws {
        try seed("task", "s", ["title": "S", "recurrence": "every day", "due": ["date": "2026-11-02"]])
        #expect(try writer.skip("s").nextDue == Day("2026-11-03"))
        #expect(try task("s")["due"] == ["date": "2026-11-03"])
        #expect(try store.rows("task")[occurrenceId("s", Day("2026-11-02")!)] == nil)
        try seed("task", "h", ["title": "H", "recurrence": "every day", "due": ["date": "2026-11-02"], "habit": true])
        try writer.skip("h")
        #expect(try task(occurrenceId("h", Day("2026-11-02")!))["skipped"] == true)
    }

    @Test func skipRefusesTheLastOccurrenceAndPlainTasks() throws {
        try seed("task", "s", ["title": "S", "recurrence": "every day until 2026-11-02", "due": ["date": "2026-11-02"]])
        try seed("task", "p", ["title": "P"])
        #expect(throws: CannotEdit.self) { try writer.skip("s") }
        #expect(throws: CannotEdit.self) { try writer.detach("p") }
        #expect(try store.outboxCount() == 0)
    }

    @Test func detachMakesAnOpenCopy() throws {
        try seed("task", "s", ["title": "S", "recurrence": "every week", "due": ["date": "2026-11-02"]])
        try writer.detach("s")
        let copy = try task(detachedId("s", Day("2026-11-02")!))
        #expect(copy["completed_at"].isNull && copy["series_id"] == "s" && copy["title"] == "S")
        #expect(try task("s")["due"] == ["date": "2026-11-09"])
    }

    @Test func settingARuleStoresItCanonicalAndDatesAnUndatedTask() throws {
        try seed("task", "a", ["title": "A", "due": nil])
        try writer.edit("a", TaskEdit(recurrence: "Every  Mon, fri"))
        #expect(try task("a")["recurrence"] == "every monday, friday")
        #expect(try task("a")["due"] == ["date": "2026-11-02"])  // a Monday
        #expect(throws: CannotEdit.self) { try writer.edit("a", TaskEdit(recurrence: "every blue moon")) }
        try writer.edit("a", TaskEdit(recurrence: ""))
        #expect(try task("a")["recurrence"].isNull)
    }

    @Test func reminderActions() throws {
        let due: JSON = ["date": "2026-11-06", "time": "15:00"]
        try seed("task", "a", ["title": "A", "due": due])
        let rid = try writer.addReminder("a", offsetMinutes: -10)
        func reminder() throws -> Row { try #require(try store.rows("reminder")[rid]) }
        #expect(try reminder()["fire_at"] == .int(dueInstant(due)! - 10 * 60_000))
        try writer.dismiss(rid)
        #expect(try reminder()["dismissed_at"] == .int(now))
        try writer.snooze(rid, until: now + 600_000)
        #expect(try reminder()["dismissed_at"].isNull && reminder()["fire_at"] == .int(now + 600_000))
        try writer.deleteReminder(rid)
        #expect(try reminder()["deleted_at"] == .int(now))
        #expect(throws: CannotEdit.self) { try writer.dismiss(rid) }
        #expect(throws: CannotEdit.self) { try writer.addReminder("a", offsetMinutes: 600_000) }
    }

    @Test func viewsAreCheckedWrittenEditedAndDeleted() throws {
        #expect(throws: CannotEdit.self) { try writer.addView(ViewEdit(name: "V", query: "p1 &")) }
        #expect(throws: CannotEdit.self) { try writer.addView(ViewEdit(name: " ", query: "p1")) }
        let id = try writer.addView(ViewEdit(name: " Urgent ", query: "p1", showCompleted: false))
        let view = try #require(try store.rows("view")[id])
        #expect(view["name"] == "Urgent" && view["kind"] == "list" && view["group_by"] == "project")
        #expect(view.values["show_completed"] == nil && view["position"] == .int(now))
        try writer.editView(id, ViewEdit(name: "Urgent", query: "p1 | p2", showCompleted: false))
        #expect(try outbox().filter { $0.entityId == id && $0.field == "query" }.count == 2)
        #expect(try outbox().filter { $0.entityId == id && $0.field == "name" }.count == 1)
        #expect(try outbox().filter { $0.field == "show_completed" }.isEmpty)
        let done = try writer.deleteView(id)
        #expect(try store.rows("view")[id]?["deleted_at"] == .int(now))
        try writer.revert(done.undo)
        #expect(try store.rows("view")[id]?["deleted_at"].isNull == true)
    }

    @Test func remindersAtATimeAndNewOffsets() throws {
        let due: JSON = ["date": "2026-11-06", "time": "15:00"]
        try seed("task", "a", ["title": "A", "due": due])
        let at = try writer.addReminder("a", at: 123_000)
        let absolute = try #require(try store.rows("reminder")[at])
        #expect(absolute["kind"] == "absolute" && absolute["fire_at"] == 123_000 && absolute["offset_minutes"].isNull)
        let rid = try writer.addReminder("a", offsetMinutes: 0)
        try writer.dismiss(rid)
        try writer.setOffset(rid, minutes: -60)
        let moved = try #require(try store.rows("reminder")[rid])
        #expect(moved["offset_minutes"] == -60 && moved["fire_at"] == .int(dueInstant(due)! - 3_600_000))
        #expect(moved["dismissed_at"].isNull)
        #expect(throws: CannotEdit.self) { try writer.setOffset(at, minutes: -10) }
    }

    @Test func addWithADueDateAndReopen() throws {
        let id = try writer.addTask("Call", due: ["date": "2026-11-02"])
        #expect(try task(id)["due"] == ["date": "2026-11-02"])
        _ = try writer.complete(id)
        let done = try writer.reopen(id)
        #expect(try task(id)["completed_at"].isNull && task(id)["completed_by"].isNull)
        try writer.revert(done.undo)
        #expect(try task(id)["completed_at"] == .int(now))
    }

    @Test func editWritesOnlyChangedFields() throws {
        try seed("task", "a", ["title": "A", "priority": 4])
        try writer.edit("a", TaskEdit(priority: 1))
        #expect(try outbox().map(\.field) == ["priority"])
        #expect(throws: CannotEdit.self) { try writer.edit("a", TaskEdit(title: "  ")) }
        #expect(throws: CannotEdit.self) { try writer.edit("a", TaskEdit(priority: 5)) }
    }

    @Test func clearingDueEndsTheRepeatAndSettingItUnparks() throws {
        try seed("task", "a", ["title": "A", "recurrence": "every day", "due": ["date": "2026-11-01"]])
        try writer.edit("a", TaskEdit(due: .null))
        #expect(try task("a")["recurrence"].isNull)
        try seed("task", "b", ["title": "B", "start": "someday"])
        try writer.edit("b", TaskEdit(due: ["date": "2026-11-02"]))
        #expect(try task("b")["start"].isNull)
    }

    @Test(arguments: [
        ["date": "2026-02-30"], ["date": "2026-11-01", "time": "9:00"],
        ["date": "2026-11-01", "tz": "Europe/Berlin"], ["date": "2026-11-01", "x": 1],
    ] as [JSON])
    func badDueIsRefused(_ due: JSON) throws {
        try seed("task", "a", ["title": "A"])
        #expect(throws: CannotEdit.self) { try writer.edit("a", TaskEdit(due: due)) }
    }

    @Test func dueChangeMovesRelativeRemindersInTheSameBatch() throws {
        try seed("task", "a", ["title": "A", "due": ["date": "2026-11-01", "time": "10:00"]])
        try seed("reminder", "r1", ["task_id": "a", "kind": "relative", "offset_minutes": -30,
                                    "fire_at": 1, "delivered_at": 2, "dismissed_at": nil])
        try seed("reminder", "r2", ["task_id": "a", "kind": "absolute", "fire_at": 7])
        let due: JSON = ["date": "2026-11-02", "time": "10:00", "tz": "Australia/Sydney"]
        try writer.edit("a", TaskEdit(due: due))
        let r1 = try #require(try store.rows("reminder")["r1"])
        #expect(r1["fire_at"] == .int(dueInstant(due)! - 30 * 60_000))
        #expect(r1["delivered_at"].isNull)
        #expect(r1.clocks["fire_at"]?.ts == (try task("a")).clocks["due"]?.ts)
        #expect(try store.rows("reminder")["r2"]?["fire_at"] == 7)
        #expect(!(try outbox()).contains { $0.entityId == "r1" && $0.field == "dismissed_at" })
    }

    @Test func schedulingAddsTheDefaultReminderOnce() throws {
        try seed("user_prefs", "me", ["reminder_default_timed": "-30", "reminder_default_dated": ""])
        try seed("task", "a", ["title": "A", "due": nil])
        let due: JSON = ["date": "2026-11-06", "time": "15:00"]
        try writer.edit("a", TaskEdit(due: due))
        let reminder = try #require(try store.rows("reminder")[defaultReminderId(userId: "me", taskId: "a")])
        #expect(reminder["offset_minutes"] == -30)
        #expect(reminder["fire_at"] == .int(dueInstant(due)! - 30 * 60_000))
        try writer.edit("a", TaskEdit(due: ["date": "2026-11-07", "time": "15:00"]))
        #expect(try store.rows("reminder").count == 1)
    }

    @Test func aDateClearsTheSectorInTheSameBatch() throws {
        try seed("task", "t1", ["title": "Budget", "sector": "2026-W45"])
        try seed("task", "t2", ["title": "Other"])
        try writer.edit("t1", TaskEdit(due: ["date": "2026-11-06"]))
        try writer.edit("t2", TaskEdit(due: ["date": "2026-11-06"]))
        #expect(try task("t1")["sector"] == "")
        #expect(!(try outbox()).contains { $0.entityId == "t2" && $0.field == "sector" })
        #expect(Set(try outbox().filter { $0.entityId == "t1" }.map(\.ts)).count == 1)
    }

    @Test func moveToAnotherProjectCarriesTheSubtree() throws {
        try seed("project", "p1", ["name": "One"])
        try seed("project", "p2", ["name": "Two"])
        try seed("section", "s2", ["name": "Doing", "project_id": "p2"])
        try seed("task", "x", ["title": "Other", "project_id": "p2", "section_id": "s2", "position": 50])
        try seed("task", "a", ["title": "A", "project_id": "p1", "section_id": "s1", "parent_id": "root",
                               "position": 1])
        try seed("task", "b", ["title": "B", "project_id": "p1", "section_id": "s1", "parent_id": "a"])
        try writer.edit("a", TaskEdit(place: Place(projectId: "p2", sectionId: "s2")))
        let a = try task("a"), b = try task("b")
        #expect(a["project_id"] == "p2" && a["section_id"] == "s2" && a["parent_id"].isNull)
        #expect(a["position"] == 1050)
        #expect(b["project_id"] == "p2" && b["section_id"].isNull && b["parent_id"] == "a")
    }

    @Test func moveToTheInbox() throws {
        try seed("project", "p1", ["name": "One"])
        try seed("task", "a", ["title": "A", "project_id": "p1"])
        try writer.edit("a", TaskEdit(place: Place(projectId: nil)))
        #expect(try task("a")["project_id"].isNull)
        try writer.edit("a", TaskEdit(place: Place(projectId: nil)))
        #expect(try outbox().filter { $0.field == "project_id" }.count == 1)
    }

    @Test func moveRefusesASectionOfAnotherProjectAndArchivedProjects() throws {
        try seed("project", "p1", ["name": "One"])
        try seed("project", "old", ["name": "Old", "archived": true])
        try seed("section", "s9", ["name": "Elsewhere", "project_id": "p9"])
        try seed("task", "a", ["title": "A", "project_id": "p1"])
        #expect(throws: CannotEdit.self) { try writer.edit("a", TaskEdit(place: Place(projectId: "p1", sectionId: "s9"))) }
        #expect(throws: CannotEdit.self) { try writer.edit("a", TaskEdit(place: Place(projectId: "old"))) }
    }

    @Test func localEditBeatsANewerLookingRemoteOpAlreadySeen() throws {
        try seed("task", "a", ["title": "A"])
        try store.apply(Op(id: "r", entity: "task", entityId: "a", field: "title", value: "Remote",
                           ts: now + 60_000, device: "zzz"))
        try writer.clock.receive(now + 60_000)
        try writer.edit("a", TaskEdit(title: "Mine"))
        #expect(try task("a")["title"] == "Mine")
    }
}

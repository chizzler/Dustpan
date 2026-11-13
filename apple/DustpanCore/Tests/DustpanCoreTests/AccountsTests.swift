import Foundation
import Testing
@testable import DustpanCore

// Standalone data meeting an account, switching accounts, and local permanent deletion.
// Ports of the desktop's StandaloneConnectTest, AccountChangeDuringSyncTest (test_sync.py),
// LocalPurgeTest and PendingPurgeAccountSwitchTest (test_trash.py) and StandalonePrefsAndIdentityTest (test_writes.py).

private let serverURL = URL(string: "https://todo.example.com")!

private func sentOps(_ request: JSON) -> [Op] { (request["ops"].array ?? []).compactMap(Op.init(json:)) }

private func expectAccountChanged(_ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected the account to have changed")
    } catch Syncer.Failure.accountChanged {
    } catch {
        Issue.record("expected accountChanged, got \(error)")
    }
}

private func task(_ id: String) -> TrashItem.Target { .init(entity: "task", id: id) }

@Suite struct StandaloneConnectTests {
    let store: Store
    let writer: Writer

    init() throws {
        store = try memoryStore()
        writer = Writer(store: store, clock: HybridClock(store: store, now: { 1_000_000 }), now: { 1_000_000 },
                        today: { Day("2026-11-12")! })
    }

    @Test func connectingLaterAdoptsTheAccountCompactsEditsAndUploadsInOrder() async throws {
        try writer.setPrefs(["reminder_default_timed": -30, "reminder_default_dated": -1440, "time_format": "24h"])
        let proj = try writer.addProject("Home")
        let sec = try writer.addSection("Chores", to: proj)
        let timed = try writer.quickAdd("Pay rent 2026-11-20 09:00 15m/1h", projectId: proj, sectionId: sec)
        try writer.edit(timed, TaskEdit(title: "Pay rent v2"))
        try writer.edit(timed, TaskEdit(title: "Pay rent final"))
        let doneTask = try writer.addTask("Wash dishes", projectId: proj)
        _ = try writer.complete(doneTask)
        let gone = try writer.addTask("Temporary scratch")
        _ = try writer.deleteTask(gone)
        try purgeLocal(store, [task(gone)])
        let oldReminder = defaultReminderId(userId: localUser, taskId: timed)
        try store.setMeta("notified", .object([oldReminder: 999]))

        let alice = FakeServer([["cursor": 25, "serverTime": 1_000_000]], userId: "u_alice",
                               accountKey: accountKey(url: serverURL, token: "ot_1"))
        _ = try await Syncer(store: store, server: alice, clock: writer.clock).run()

        #expect(try store.meta("user_id") == "u_alice")
        #expect(try store.outboxCount() == 0)
        let sent = sentOps(alice.requests[0])

        // Superseded title edits went as one op with the last title; the purged task never went.
        let titles = sent.filter { $0.entity == "task" && $0.entityId == timed && $0.field == "title" }
        #expect(titles.map(\.value) == ["Pay rent final"])
        #expect(!sent.contains { $0.entityId == gone })

        // The local actor became u_alice: completions, time entries, default reminders.
        #expect(try store.rows("task")[doneTask]?["completed_by"] == "u_alice")
        #expect(sent.contains { $0.entityId == doneTask && $0.field == "completed_by" && $0.value == "u_alice" })
        #expect(try store.rows("time_entry").values.map { $0["user_id"] } == ["u_alice"])
        #expect(sent.contains { $0.entity == "time_entry" && $0.field == "user_id" && $0.value == "u_alice" })
        let newReminder = defaultReminderId(userId: "u_alice", taskId: timed)
        #expect(try store.rows("reminder")[oldReminder] == nil)
        #expect(try store.rows("reminder")[newReminder] != nil)
        #expect(try store.meta("notified") == .object([newReminder: 999]))

        // So the default reminder still follows a change to a date-only due.
        try writer.edit(timed, TaskEdit(due: ["date": "2026-11-20"]))
        #expect(try store.rows("reminder")[newReminder]?["offset_minutes"] == -1440)

        // Tasks go before time entries.
        let entities = sent.map(\.entity)
        #expect(entities.lastIndex(of: "task")! < entities.firstIndex(of: "time_entry")!)
        // Preferences nobody touched weren't sent.
        #expect(Set(sent.filter { $0.entity == "user_prefs" }.map(\.field))
            == ["reminder_default_timed", "reminder_default_dated", "time_format"])
    }

    @Test func connectingLaterMergesWithTheServersDataKeepingBothSides() async throws {
        try writer.setPrefs(["time_format": "24h"])
        let localProject = try writer.addProject("Local Project")
        let localTask = try writer.addTask("Local Task", projectId: localProject)
        func op(_ id: String, _ entity: String, _ entityId: String, _ field: String, _ value: JSON) -> JSON {
            Op(id: id, entity: entity, entityId: entityId, field: field, value: value, ts: 500, device: "web").json
        }
        let alice = FakeServer([
            ["ops": [op("s1", "project", "srv_proj", "name", "Server Project"),
                     op("s2", "task", "srv_task", "title", "Server Task"),
                     op("s3", "task", "srv_task", "project_id", "srv_proj")], "cursor": 3, "hasMore": true],
            ["ops": [op("s4", "user_prefs", "me", "week_start", "sun")], "cursor": 4],
        ], userId: "u_alice")
        _ = try await Syncer(store: store, server: alice).run()
        #expect(Set(try store.rows("project").keys) == [localProject, "srv_proj"])
        #expect(Set(try store.rows("task").keys) == [localTask, "srv_task"])
        let prefs = try #require(try store.rows("user_prefs")["me"])
        #expect(prefs["time_format"] == "24h" && prefs["week_start"] == "sun")
        #expect(sentOps(alice.requests[0]).contains { $0.entityId == localTask })
    }

    @Test func aLargeUploadKeepsEntitiesWholeAndSurvivesSkewOverManyBatches() async throws {
        let far: Int64 = 10_000_000
        let writer = Writer(store: store, clock: HybridClock(store: store, now: { far }), now: { far },
                            today: { Day("2026-11-12")! })
        // Enough tasks that the time entry's fields straddle a 500-op boundary once tasks go first.
        _ = try writer.addTask("Task 0")
        let perTask = try store.outboxCount()
        let before = try store.outboxCount()
        _ = try writer.quickAdd("Boundary work 20m/1h")
        let entryOps = try store.rows("time_entry").values.first!.values.count
        let quickOps = try store.outboxCount() - before - entryOps
        var count = 1
        while (perTask * count + quickOps) % 500 < 500 - entryOps + 1 || (perTask * count + quickOps) % 500 > 499
            || perTask * count + quickOps < 1000 {
            _ = try writer.addTask("Task \(count)")
            count += 1
        }
        let total = count + 1

        var entries: Set<String> = [], accepted: Set<String> = [], skewedOnce: Set<String> = []
        let check: (JSON) throws -> JSON = { body in
            let ops = sentOps(body)
            for id in Set(ops.filter { $0.entity == "time_entry" }.map(\.entityId)) {
                let fields = Set(ops.filter { $0.entity == "time_entry" && $0.entityId == id }.map(\.field))
                #expect(fields.isSuperset(of: ["task_id", "user_id", "started_at"]), "time entry split across batches")
            }
            var rejected: [JSON] = []
            for op in ops where op.ts > 2_000_000 && skewedOnce.insert(op.id).inserted {
                rejected.append(["id": .string(op.id), "reason": "clock_skew", "serverTime": 1_000_000])
            }
            let refused = Set(rejected.compactMap { $0["id"].string })
            for op in ops where !refused.contains(op.id) {
                if op.entity == "task" && op.field == "title" { accepted.insert(op.entityId) }
                if op.entity == "time_entry" { entries.insert(op.entityId) }
            }
            return ["rejected": .array(rejected), "serverTime": 1_000_000, "cursor": .int(Int64(accepted.count))]
        }
        let alice = FakeServer(planned: Array(repeating: check, count: 20), userId: "u_alice")
        _ = try await Syncer(store: store, server: alice).run()
        #expect(accepted.count == total)
        #expect(entries.count == 1)
        #expect(try store.outboxCount() == 0)
    }

    @Test func anotherAccountIsRefusedUntilMigratedThenEverythingIsRekeyed() async throws {
        let proj = try writer.addProject("Work")
        let sec = try writer.addSection("Next", to: proj)
        let label = try writer.addLabel("urgent")
        let series = try writer.addTask("Standup", projectId: proj, sectionId: sec, due: ["date": "2026-11-10"])
        try writer.edit(series, TaskEdit(recurrence: "every day", labels: ["urgent"]))
        _ = try writer.complete(series)
        let oldRecord = occurrenceId(series, Day("2026-11-10")!)
        try writer.setPrefs(["reminder_default_dated": -1440])
        _ = try writer.addTask("Tax", projectId: proj, due: ["date": "2026-11-20"])
        try store.setMeta(foldedTasksKey, [.string(series)])
        try store.setMeta(clearedSubtasksKey, .object([oldRecord: [1_000_000, .string(series)]]))

        _ = try await Syncer(store: store, server: FakeServer([["cursor": 10]], userId: "u1",
                                                              accountKey: accountKey(url: serverURL, token: "tok_u1"))).run()
        // A new token for the same account just works.
        _ = try await Syncer(store: store, server: FakeServer([["cursor": 10]], userId: "u1",
                                                              accountKey: accountKey(url: serverURL, token: "tok_u1_new"))).run()
        // Another account needs Settings to decide.
        let u2 = FakeServer([["cursor": 1]], userId: "u2", accountKey: accountKey(url: serverURL, token: "tok_u2"))
        do {
            _ = try await Syncer(store: store, server: u2).run()
            Issue.record("another account was accepted")
        } catch Syncer.Failure.accountMismatch {}

        try migrateAccount(store, userId: "u2", accountKey: [.string(serverURL.absoluteString), "x"])
        _ = try await Syncer(store: store, server: FakeServer([["cursor": 50]], userId: "u2",
                                                              accountKey: accountKey(url: serverURL, token: "tok_u2"))).run()
        #expect(try store.meta("user_id") == "u2")
        let projects = try store.rows("project")
        #expect(projects[proj] == nil && projects.count == 1)
        let newProject = projects.keys.first!
        let tasks = try store.rows("task")
        let newSeries = try #require(tasks.values.first { $0["title"] == "Standup" && $0["recurrence"].isTruthy }).id
        #expect(tasks[newSeries]?["project_id"] == .string(newProject))
        #expect(tasks[occurrenceId(newSeries, Day("2026-11-10")!)] != nil)
        let newTax = try #require(tasks.values.first { $0["title"] == "Tax" }).id
        #expect(try store.rows("reminder")[defaultReminderId(userId: "u2", taskId: newTax)] != nil)
        #expect(try store.rows("label")[label] == nil)
        #expect(try store.meta(foldedTasksKey) == [.string(newSeries)])

        // Replacing keeps the device and nothing else.
        let device = try store.device()
        try resetForAccount(store, userId: "u3")
        #expect(try store.device() == device)
        #expect(try store.allFields().isEmpty)
        #expect(try store.meta("user_id") == "u3")
    }
}

/// An account switch while a sync waits on the network mustn't mix the two accounts.
@Suite struct AccountChangeDuringSyncTests {
    let store: Store
    let writer: Writer

    init() async throws {
        store = try memoryStore()
        writer = Writer(store: store, now: { 1_000 })
        _ = try writer.addTask("Old account task")
        _ = try await Syncer(store: store, server: Self.server("u1", [{ _ in ["cursor": 5] }])).run()
    }

    static func server(_ user: String, _ planned: [(JSON) throws -> JSON]) -> FakeServer {
        FakeServer(planned: planned, userId: user, accountKey: accountKey(url: serverURL, token: "tok_\(user)"))
    }

    @Test func migratingDuringTheRequestKeepsNothingAndSendsNothingMoreToTheOldAccount() async throws {
        let store = store
        let old = Self.server("u1", [
            { _ in
                try migrateAccount(store, userId: "u2", accountKey: [.string(serverURL.absoluteString), "k2"])
                return ["ops": [remote("stale", "title", "From u1", 2)], "cursor": 9, "hasMore": true]
            },
            { _ in ["cursor": 10] },
        ])
        // An unsent edit, so the old sync has a reason to come back for a second batch.
        _ = try writer.addTask("Edit before switch")
        await expectAccountChanged { _ = try await Syncer(store: store, server: old).run() }
        #expect(old.requests.count == 1)
        #expect(try store.rows("task")["stale"] == nil)
        #expect(try store.meta("cursor") == 0)
        #expect(try store.meta("user_id") == "u2")
        let titles = Set(try store.outboxBatch(limit: 1000).map(\.op).filter { $0.field == "title" }.compactMap(\.value.string))
        #expect(titles == ["Old account task", "Edit before switch"])

        let new = Self.server("u2", [{ _ in ["cursor": 1] }])
        _ = try await Syncer(store: store, server: new).run()
        #expect(Set(sentOps(new.requests[0]).filter { $0.field == "title" }.compactMap(\.value.string))
            == ["Old account task", "Edit before switch"])
        #expect(try store.outboxCount() == 0)
    }

    @Test func replacingDuringTheRequestKeepsNothing() async throws {
        let store = store
        let old = Self.server("u1", [{ _ in
            try resetForAccount(store, userId: "u2", accountKey: [.string(serverURL.absoluteString), "k2"])
            return ["ops": [remote("stale", "title", "From u1", 2)], "cursor": 9]
        }])
        await expectAccountChanged { _ = try await Syncer(store: store, server: old).run() }
        #expect(try store.rows("task").isEmpty)
        #expect(try store.meta("cursor") == 0)
    }

    @Test func migratingDuringAPurgeStopsBeforeTheSecondExchange() async throws {
        let store = store
        let id = try store.rows("task").keys.first!
        _ = try writer.deleteTask(id)
        try queuePurges(store, [task(id)])
        let old = Self.server("u1", [{ _ in [:] }, { _ in ["cursor": 10] }])
        old.onPurge = { _ in try migrateAccount(store, userId: "u2", accountKey: [.string(serverURL.absoluteString), "k2"]) }
        await expectAccountChanged { _ = try await Syncer(store: store, server: old).run() }
        #expect(old.requests.count == 1)
        #expect(try store.meta("user_id") == "u2")
    }
}

@Suite struct LocalPurgeTests {
    let store: Store
    let writer: Writer
    let clockNow: Clockwork

    final class Clockwork: @unchecked Sendable { var now: Int64 = 1_000_000 }

    init() throws {
        store = try memoryStore()
        let clockNow = Clockwork()
        self.clockNow = clockNow
        writer = Writer(store: store, clock: HybridClock(store: store, now: { clockNow.now }), now: { clockNow.now },
                        today: { Day("2026-11-12")! })
    }

    func seed(_ entity: String, _ id: String, _ fields: [String: JSON]) throws {
        for (name, value) in fields {
            try store.apply(Op(id: "\(id)-\(name)", entity: entity, entityId: id, field: name, value: value, ts: 1,
                               device: "other"))
        }
    }

    func outbox() throws -> [Op] { try store.outboxBatch(limit: 10_000).map(\.op) }

    @Test func aTaskTakesItsDeletedDescendantsItsRowsAndItsQueuedOps() throws {
        let p = try writer.addProject("Work")
        let parent = try writer.addTask("Parent", projectId: p, due: ["date": "2026-11-05", "time": "09:00"])
        let child = try writer.addTask("Child", parentId: parent)
        let separate = try writer.addTask("Deleted earlier", parentId: parent)
        let kept = try writer.addTask("Keep me", projectId: p)
        let reminder = try writer.addReminder(parent, offsetMinutes: -10)
        try seed("time_entry", "te1", ["task_id": .string(parent), "user_id": "me", "started_at": 100, "ended_at": 200])
        try seed("comment", "c1", ["task_id": .string(child), "author_id": "me", "body": "note"])
        clockNow.now = 2_000_000
        _ = try writer.deleteTask(separate)
        clockNow.now = 3_000_000
        _ = try writer.deleteTask(parent)
        try queuePurges(store, [task(parent)])
        try store.setMeta("held_ops", [Op(id: "h1", entity: "task", entityId: parent, field: "title", value: "x", ts: 1,
                                          device: "d").json])

        #expect(try purgeLocal(store, [task(parent)]) == 6)
        #expect(Set(try store.rows("task").keys) == [kept])
        #expect(try store.rows("reminder").isEmpty && store.rows("time_entry").isEmpty && store.rows("comment").isEmpty)
        #expect(try pendingPurges(store).isEmpty)
        #expect(try store.meta("held_ops") == [])
        #expect(try !outbox().contains { [parent, child, separate, reminder].contains($0.entityId) })
    }

    @Test func aProjectTakesItsSectionsTasksAndWhatGoesWithThem() throws {
        let p = try writer.addProject("Drop")
        let sec = try writer.addSection("Todo", to: p)
        let inside = try writer.addTask("Live inside deleted project", projectId: p, sectionId: sec)
        let reminder = try writer.addReminder(inside, at: 5_000_000)
        try seed("project_prefs", p, ["feed_seen_at": 100])
        let other = try writer.addTask("Inbox stays")
        _ = try writer.deleteProject(p)

        #expect(try purgeLocal(store, [.init(entity: "project", id: p)]) >= 5)
        #expect(try store.rows("project").isEmpty && store.rows("section").isEmpty)
        #expect(Set(try store.rows("task").keys) == [other])
        #expect(try store.rows("reminder")[reminder] == nil)
        #expect(try store.rows("project_prefs").isEmpty)
        #expect(try outbox().allSatisfy { $0.entityId == other })
    }

    @Test func liveOrMissingTargetsAreSkippedAndLeaveThePendingList() throws {
        let open = try writer.addTask("Still open")
        try queuePurges(store, [task(open), task("missing")])
        #expect(try purgeLocal(store, [task(open), task("missing")]) == 0)
        #expect(try store.rows("task")[open] != nil)
        #expect(try pendingPurges(store).isEmpty)
    }

    @Test func switchingAccountDeletesItemsWaitingForAPurgeInsteadOfUploadingThem() throws {
        let keep = try writer.addTask("Keep")
        let gone = try writer.addTask("Delete for good")
        _ = try writer.addTask("Deleted subtask", parentId: gone)
        _ = try writer.deleteTask(gone)
        try queuePurges(store, [task(gone)])

        try migrateAccount(store, userId: "u2")
        #expect(Set(try store.rows("task").values.compactMap { $0["title"].string }) == ["Keep"])
        #expect(Set(try outbox().filter { $0.field == "title" }.compactMap(\.value.string)) == ["Keep"])
        #expect(try pendingPurges(store).isEmpty)
        #expect(try store.rows("task")[keep] == nil)  // re-keyed as usual
    }
}

@Suite struct StandalonePrefsTests {
    let store: Store
    let writer: Writer

    init() throws {
        store = try memoryStore()
        writer = Writer(store: store, clock: HybridClock(store: store, now: { 1_000_000 }), now: { 1_000_000 },
                        today: { Day("2026-11-02")! })
    }

    @Test func defaultRemindersCompletionsAndTimeEntriesWorkWithoutAnAccount() throws {
        #expect(try store.meta("user_id").isNull)
        try writer.setPrefs(["reminder_default_timed": -15, "reminder_default_dated": -1440])
        let id = try writer.quickAdd("Call Alex 2026-11-06 10:00 25m/1h")
        let reminder = try #require(try store.rows("reminder")[defaultReminderId(userId: localUser, taskId: id)])
        #expect(reminder["offset_minutes"] == -15)
        #expect(try store.rows("time_entry").values.map { $0["user_id"] } == ["local"])
        _ = try writer.complete(id)
        #expect(try store.rows("task")[id]?["completed_by"] == "local")
    }

    @Test func setPrefsWritesOnlyWhatChangesAndChecksValues() throws {
        // Choosing the defaults on an empty store writes nothing, keeping untouched fields out of a later sync.
        try writer.setPrefs(["time_format": "system", "date_format": "system", "week_start": "system",
                             "day_start": "00:00", "reminder_default_timed": .null, "time_sectors": false])
        #expect(try store.outboxCount() == 0)

        try writer.setPrefs(["time_format": "24h", "week_start": "sun", "day_start": "04:00", "time_sectors": true,
                             "language": "de"])
        let prefs = try #require(try store.rows("user_prefs")["me"])
        #expect(prefs["time_format"] == "24h" && prefs["week_start"] == "sun" && prefs["day_start"] == "04:00")
        #expect(prefs["time_sectors"] == "on" && prefs["language"] == "de")
        #expect(prefs.values["date_format"] == nil)

        for bad: [String: JSON] in [["time_format": "ampm"], ["day_start": "07:00"], ["reminder_default_timed": 9_999_999]] {
            #expect(throws: CannotEdit.self) { try writer.setPrefs(bad) }
        }
    }
}

@Suite struct JoinPlanTests {
    @Test func standaloneAdoptsTheSameAccountKeepsAndAnotherAsksUnlessThereIsNothingToLose() throws {
        let store = try memoryStore()
        #expect(try joinPlan(store, userId: "u1") == .adopt)
        try store.setMeta("user_id", "local")
        #expect(try joinPlan(store, userId: "u1") == .adopt)
        try store.setMeta("user_id", "u1")
        #expect(try joinPlan(store, userId: "u1") == .same)
        #expect(try joinPlan(store, userId: "u2") == .replace)
        _ = try Writer(store: store).addTask("Mine")
        #expect(try joinPlan(store, userId: "u2") == nil)
    }
}

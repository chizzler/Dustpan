import Foundation
import Testing
@testable import DustpanCore

// The Trash. A port of tests/test_trash.py.

private func row(_ id: String, _ values: [String: JSON]) -> Row { Row(id: id, values: values) }
private func byId(_ rows: [Row]) -> [String: Row] { Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }) }
private func task(_ id: String) -> TrashItem.Target { .init(entity: "task", id: id) }

@Suite struct TrashItemsTests {
    @Test func listsDeletedItemsNewestFirstAndFoldsSubtasks() {
        let projects = byId([row("p", ["name": "Work", "deleted_at": 20, "color": "#abcdef"])])
        let tasks = byId([
            row("a", ["title": "Parent", "deleted_at": 30, "project_id": "p"]),
            row("b", ["title": "Child", "deleted_at": 30, "parent_id": "a"]),
            row("c", ["deleted_at": 30, "parent_id": "b"]),
            row("d", ["title": "Earlier", "deleted_at": 10, "parent_id": "a"]),
            row("live", ["project_id": "p"]),
        ])
        let items = trashItems(tasks: tasks, projects: projects)
        #expect(items.map(\.target.id) == ["a", "p", "d"])
        #expect(items[0].subtasks == 2 && items[0].projectName == "Work")
        #expect(items[1].color == "#abcdef")
    }

    @Test func cyclesAndSelfParentsStillHaveAVisibleRestoreTarget() {
        let tasks = byId([
            row("a", ["deleted_at": 10, "parent_id": "b"]),
            row("b", ["deleted_at": 10, "parent_id": "a"]),
            row("self", ["deleted_at": 10, "parent_id": "self"]),
        ])
        let items = trashItems(tasks: tasks, projects: [:])
        #expect(items.count == 2)
        #expect(items.map(\.subtasks).sorted() == [0, 1])
    }

    @Test func retentionRoundsUpAndNeverGoesNegative() {
        for (now, expected): (Int64, Int64) in [(100, 30), (101, 30), (100 + dayMs, 29), (100 + 30 * dayMs - 1, 1),
                                                (100 + 30 * dayMs, 0), (100 + 31 * dayMs, 0)] {
            #expect(remainingDays(deletedAt: 100, retention: 30, now: now) == expected)
        }
        #expect(remainingDays(deletedAt: 100, retention: 0, now: 200) == nil)
    }
}

@Suite struct TrashWritesTests {
    let store: Store
    let writer: Writer

    init() throws {
        store = try memoryStore()
        writer = Writer(store: store, clock: HybridClock(store: store, now: { 1_000_000 }), now: { 1_000_000 },
                        today: { Day("2026-11-12")! })
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

    @Test func restoreKeepsFieldsAndRestoresOnlyTheSubtreeDeletedTogether() throws {
        try seed("project", "p", ["name": "Work"])
        try seed("section", "s", ["project_id": "p"])
        try seed("task", "a", ["title": "Parent", "project_id": "p", "section_id": "s", "deleted_at": 10,
                               "description": "Notes", "completed_at": 5, "priority": 1])
        try seed("task", "b", ["parent_id": "a", "project_id": "p", "deleted_at": 10])
        try seed("task", "c", ["parent_id": "b", "project_id": "p", "deleted_at": 10])
        try seed("task", "old", ["parent_id": "a", "deleted_at": 9])
        let done = try writer.restoreTask("a")
        for id in ["a", "b", "c"] { #expect(try task(id)["deleted_at"].isNull) }
        #expect(try task("old")["deleted_at"] == 9)
        let a = try task("a")
        #expect(a["section_id"] == "s" && a["description"] == "Notes" && a["completed_at"] == 5 && a["priority"] == 1)
        #expect(Set(try outbox().map(\.field)) == ["deleted_at"])
        try writer.revert(done.undo)
        #expect(try ["a", "b", "c"].map { try task($0)["deleted_at"] } == [10, 10, 10])
    }

    @Test func restoreToInboxMovesTheWholeSubtreeAndUndoPutsItBack() throws {
        try seed("project", "p", ["deleted_at": 20])
        try seed("section", "s", ["project_id": "p"])
        try seed("task", "a", ["project_id": "p", "section_id": "s", "deleted_at": 10, "parent_id": "gone"])
        try seed("task", "b", ["project_id": "p", "parent_id": "a", "deleted_at": 10])
        let done = try writer.restoreTask("a")
        #expect(done.undo.first?.patch["project_id"] == "p")
        for id in ["a", "b"] {
            #expect(try task(id)["project_id"].isNull)
            #expect(try task(id)["section_id"].isNull)
        }
        #expect(try task("a")["parent_id"].isNull)
        #expect(try task("b")["parent_id"] == "a")
        #expect(Set(try snapshot(store).tasks.map(\.id)) == ["a", "b"])
        try writer.revert(done.undo)
        #expect(try task("a")["section_id"] == "s")
        #expect(try task("b")["project_id"] == "p")
        #expect(try task("a")["parent_id"] == "gone")
    }

    @Test func missingProjectAlsoRestoresToInbox() throws {
        try seed("task", "a", ["project_id": "missing", "deleted_at": 10])
        _ = try writer.restoreTask("a")
        #expect(try task("a")["project_id"].isNull)
    }

    @Test func deletedOrMissingParentIsClearedButALiveParentIsKept() throws {
        try seed("task", "gone", ["deleted_at": 20])
        try seed("task", "live", ["title": "Live"])
        for parent in ["gone", "missing", "live"] {
            let id = "child-" + parent
            try seed("task", id, ["parent_id": .string(parent), "deleted_at": 10])
            _ = try writer.restoreTask(id)
            #expect(try task(id)["parent_id"] == (parent == "live" ? "live" : .null))
        }
    }

    @Test func staleSectionIsCleared() throws {
        try seed("project", "p", ["name": "Work"])
        try seed("section", "gone", ["project_id": "p", "deleted_at": 20])
        try seed("section", "other", ["project_id": "elsewhere"])
        for section in ["gone", "missing", "other"] {
            try seed("task", section, ["project_id": "p", "section_id": .string(section), "deleted_at": 10])
            _ = try writer.restoreTask(section)
            #expect(try task(section)["section_id"].isNull)
        }
    }

    @Test func projectRestoreRevealsTasksButNotSeparatelyDeletedOnes() throws {
        try seed("project", "p", ["name": "Work", "deleted_at": 20])
        try seed("task", "a", ["project_id": "p"])
        try seed("task", "b", ["project_id": "p", "deleted_at": 10])
        #expect(try snapshot(store).tasks.isEmpty)
        let done = try writer.restoreProject("p")
        #expect(try snapshot(store).tasks.map(\.id) == ["a"])
        #expect(try outbox().count == 1)
        try writer.revert(done.undo)
        #expect(try store.rows("project")["p"]?["deleted_at"] == 20)
    }

    @Test func restoringLiveOrMissingItemsIsRefused() throws {
        try seed("task", "live", ["deleted_at": nil])
        try seed("project", "live", ["deleted_at": nil])
        for id in ["missing", "live"] {
            #expect(throws: CannotEdit.self) { try writer.restoreTask(id) }
            #expect(throws: CannotEdit.self) { try writer.restoreProject(id) }
        }
        #expect(try store.outboxCount() == 0)
    }
}

@Suite struct PurgeTests {
    let store: Store
    let writer: Writer
    let server = FakeServer([])

    init() throws {
        store = try memoryStore()
        writer = Writer(store: store, clock: HybridClock(store: store, now: { 1_000_000 }), now: { 1_000_000 },
                        today: { Day("2026-11-12")! })
        try store.setMeta("user_id", "me")
        for id in ["a", "b", "c"] {
            try store.apply(Op(id: id, entity: "task", entityId: id, field: "deleted_at", value: 10, ts: 1, device: "other"))
        }
    }

    func pending() throws -> Set<TrashItem.Target> { try pendingPurges(store) }

    @Test func queueDeduplicatesIncludingWithinOneRequest() throws {
        try queuePurges(store, [task("a"), task("a")])
        try queuePurges(store, [task("a"), task("b")])
        #expect(try store.meta(pendingPurgesKey) == [["task", "a"], ["task", "b"]])
    }

    @Test func successWaitsForSyncMarkersBeforeRemovingLocalData() async throws {
        try queuePurges(store, [task("a")])
        #expect(try await sendPurges(store, server) == 1)
        #expect(server.purges == [task("a")])
        #expect(try store.rows("task")["a"] != nil)
        #expect(try pending().isEmpty)
    }

    @Test func offlinePreservesRemainingRequestsButNotCompletedOnes() async throws {
        try queuePurges(store, ["a", "b", "c"].map(task))
        server.onPurge = { if $0.id == "b" { throw ApiError.offline("offline") } }
        await #expect(throws: ApiError.self) { try await sendPurges(store, server) }
        #expect(try pending() == [task("b"), task("c")])
        server.onPurge = { _ in }
        #expect(try await sendPurges(store, server) == 2)
    }

    @Test func temporaryErrorsAreRetainedForRetry() async throws {
        for status in [401, 429, 500, 503] {
            try queuePurges(store, [task("a")])
            server.onPurge = { _ in throw ApiError.server(status: status, code: "http_error", message: "try later") }
            await #expect(throws: ApiError.self) { try await sendPurges(store, server) }
            #expect(try pending().contains(task("a")))
        }
    }

    @Test func alreadyGoneOrRestoredOnServerRequestsAreDropped() async throws {
        for (status, code) in [(404, "not_found"), (409, "not_deleted")] {
            try queuePurges(store, [task("a")])
            server.onPurge = { _ in throw ApiError.server(status: status, code: code, message: "gone") }
            #expect(try await sendPurges(store, server) == 0)
            #expect(try pending().isEmpty)
        }
    }

    @Test func locallyRestoredOrMissingTargetsAreNotSent() async throws {
        _ = try writer.restoreTask("a")
        try queuePurges(store, [task("a"), task("missing")])
        #expect(try await sendPurges(store, server) == 0)
        #expect(server.purges.isEmpty)
        #expect(try pending().isEmpty)
    }

    @Test func forbiddenIsDroppedButReportedToTheCaller() async throws {
        try queuePurges(store, [task("a")])
        server.onPurge = { _ in throw ApiError.server(status: 403, code: "forbidden", message: "not allowed") }
        await #expect(throws: ApiError.self) { try await sendPurges(store, server) }
        #expect(try pending().isEmpty)
    }

    @Test func requestsQueuedDuringTheNetworkCallAreNotLost() async throws {
        try queuePurges(store, [task("a")])
        let store = store
        server.onPurge = { _ in try queuePurges(store, [task("b")]) }
        _ = try await sendPurges(store, server)
        #expect(try pending() == [task("b")])
    }

    @Test func unsentOrHeldEditsDelayPurge() async throws {
        let id = try writer.addTask("New")
        _ = try writer.deleteTask(id)
        try queuePurges(store, [task(id)])
        #expect(try await sendPurges(store, server) == 0)
        let held = try store.outboxBatch(limit: 1000)
        try store.outboxRemove(held.map(\.seq))
        try store.setMeta("held_ops", .array(held.map(\.op.json)))
        #expect(try await sendPurges(store, server) == 0)
        #expect(server.purges.isEmpty)
        #expect(try pending().contains(task(id)))
    }
}

@Suite struct SyncTrashTests {
    let store: Store

    init() throws {
        store = try memoryStore()
    }

    @Test func retentionIsRememberedIncludingDisabledAndAbsentValues() async throws {
        for (response, expected): (JSON, JSON) in [(["trashRetentionDays": 7], 7), ([:], 7), (["trashRetentionDays": 0], 0)] {
            _ = try await Syncer(store: store, server: FakeServer([response])).run()
            #expect(try store.meta(trashRetentionKey) == expected)
        }
    }

    @Test func purgeRunsAfterDeleteUploadAndThenPullsMarkers() async throws {
        let writer = Writer(store: store, now: { 1000 })
        let id = try writer.addTask("Temporary")
        _ = try writer.deleteTask(id)
        try queuePurges(store, [task(id)])
        let server = FakeServer([[:], ["purged": [["entity": "task", "entityId": .string(id)]], "cursor": 10]])
        let store = store
        server.onPurge = { [unowned server] target in
            #expect(target == task(id))
            #expect(server.requests.count == 1)
            let unsent = try store.outboxCount()
            #expect(unsent == 0)
            #expect(server.requests[0]["ops"].array?.contains { $0["field"] == "deleted_at" && $0["value"] == 1000 } == true)
        }
        let result = try await Syncer(store: store, server: server).run()
        #expect(result.purged == 1)
        #expect(try store.rows("task").isEmpty)
        #expect(try pendingPurges(store).isEmpty)
        #expect(try store.meta("cursor") == 10)
    }

    @Test func serverLimitHoldsDeleteAndPurgeUntilNextSync() async throws {
        let writer = Writer(store: store, now: { 1000 })
        let id = try writer.addTask("Temporary")
        _ = try await Syncer(store: store, server: FakeServer([])).run()
        _ = try writer.deleteTask(id)
        try queuePurges(store, [task(id)])
        let server = FakeServer(planned: [{ body in
            ["rejected": .array((body["ops"].array ?? []).map { ["id": $0["id"], "reason": "limit_ops_hour"] })]
        }])
        #expect(try await Syncer(store: store, server: server).run().held == 1)
        #expect(server.purges.isEmpty)
        #expect(try pendingPurges(store).contains(task(id)))
        server.responses = [{ _ in [:] }, { _ in ["purged": [["entity": "task", "entityId": .string(id)]]] }]
        #expect(try await Syncer(store: store, server: server).run().purged == 1)
        #expect(server.purges == [task(id)])
    }

    @Test func cascadedMarkersRemoveAllNamedEntitiesAndTheirOutboxOps() async throws {
        let entities = [("project", "p"), ("task", "a"), ("task", "b"), ("section", "s"), ("reminder", "r")]
        for (entity, id) in entities {
            let op = Op(id: id, entity: entity, entityId: id, field: "deleted_at", value: 10, ts: 10, device: "other")
            try store.apply(op)
            try store.outboxAdd([op])
        }
        let markers = JSON.array(entities.map { ["entity": .string($0.0), "entityId": .string($0.1)] })
        let result = try await Syncer(store: store, server: FakeServer([["purged": markers]])).run()
        #expect(result.purged == 5)
        #expect(try store.allFields().isEmpty)
        #expect(try store.outboxCount() == 0)
    }
}

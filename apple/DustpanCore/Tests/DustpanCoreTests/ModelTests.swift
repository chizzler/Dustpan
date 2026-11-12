import Testing
@testable import DustpanCore

func row(_ id: String, parent: String? = nil, position: Int64 = 0, parentTs: Int64 = 0, parentDevice: String = "d") -> Row {
    var r = Row(id: id, values: ["parent_id": parent.map(JSON.string) ?? .null, "position": .int(position)])
    r.clocks["parent_id"] = FieldClock(ts: parentTs, device: parentDevice)
    return r
}

/// A tree as a string, e.g. "y(x)" or "a b(c)".
func shape(_ nodes: [Node]) -> String {
    nodes.map { $0.children.isEmpty ? $0.id : "\($0.id)(\(shape($0.children)))" }.joined(separator: " ")
}

@Suite struct BuildTree {
    func tree(_ rows: [Row]) -> String { shape(buildTree(rows) { $0["parent_id"].string }) }

    @Test func siblingsSortByPositionThenId() {
        #expect(tree([row("b", position: 1), row("a", position: 1), row("c", position: 0)]) == "c a b")
    }

    @Test func missingParentIsARoot() {
        #expect(tree([row("a", parent: "gone")]) == "a")
    }

    @Test func twoCycleRootsAtNewestParentClock() {
        #expect(tree([row("x", parent: "y", parentTs: 10), row("y", parent: "x", parentTs: 20)]) == "y(x)")
    }

    @Test func cycleTieBreaksOnDeviceThenId() {
        #expect(tree([row("x", parent: "y", parentTs: 5, parentDevice: "b"),
                      row("y", parent: "x", parentTs: 5, parentDevice: "a")]) == "x(y)")
        #expect(tree([row("x", parent: "y", parentTs: 5), row("y", parent: "x", parentTs: 5)]) == "y(x)")
    }

    @Test func threeCycleWithATail() {
        let rows = [row("a", parent: "b", parentTs: 1), row("b", parent: "c", parentTs: 3),
                    row("c", parent: "a", parentTs: 2), row("tail", parent: "a")]
        #expect(tree(rows) == "b(a(c tail))")
    }

    @Test func selfParentIsARoot() {
        #expect(tree([row("a", parent: "a")]) == "a")
    }
}

@Suite struct SnapshotTests {
    let store: Store
    let counter = Counter()

    final class Counter: @unchecked Sendable { var ts: Int64 = 0 }

    init() throws { store = try memoryStore() }

    func put(_ entity: String, _ id: String, _ fields: KeyValuePairs<String, JSON>) throws {
        for (name, value) in fields {
            counter.ts += 1
            try store.apply(Op(id: "\(counter.ts)", entity: entity, entityId: id, field: name, value: value,
                               ts: counter.ts, device: "d"))
        }
    }

    @Test func hidesDeletedCompletedAndOrphanedTasks() throws {
        try put("project", "p", ["name": "P"])
        try put("project", "gone", ["name": "Gone", "deleted_at": 1])
        try put("task", "open", ["title": "Open", "project_id": "p"])
        try put("task", "done", ["title": "Done", "project_id": "p", "completed_at": 1])
        try put("task", "deleted", ["title": "Deleted", "project_id": "p", "deleted_at": 1])
        try put("task", "orphan", ["title": "Orphan", "project_id": "gone"])
        try put("task", "inbox", ["title": "Inbox", "project_id": nil])
        let snap = try snapshot(store)
        #expect(snap.tasksByProject["p"]?.map(\.id) == ["open"])
        #expect(snap.tasksByProject[nil]?.map(\.id) == ["inbox"])
        #expect(snap.projects.map(\.id) == ["p"])
    }

    @Test func archivedParentLiftsChildProjectToTop() throws {
        try put("project", "parent", ["name": "Parent", "archived": true])
        try put("project", "child", ["name": "Child", "parent_id": "parent"])
        #expect(try snapshot(store).projects.map(\.id) == ["child"])
    }

    @Test func staleSectionFallsBackToNoSection() throws {
        try put("project", "p", ["name": "P"])
        try put("project", "q", ["name": "Q"])
        try put("section", "s", ["name": "S", "project_id": "p", "position": 1])
        try put("section", "old", ["name": "Old", "project_id": "p", "deleted_at": 1])
        try put("section", "other", ["name": "Other", "project_id": "q"])
        for (tid, sid) in [("a", "s"), ("b", "old"), ("c", "other"), ("d", "unknown")] {
            try put("task", tid, ["title": .string(tid), "project_id": "p", "section_id": .string(sid)])
        }
        let sections = projectSections(try snapshot(store), "p")
        #expect(sections.map(\.id) == [nil, "s"])
        #expect(sections.map { $0.tasks.map(\.id).sorted() } == [["b", "c", "d"], ["a"]])
    }

    @Test func subtaskFollowsParentSectionAndCompletedParentReleasesIt() throws {
        try put("project", "p", ["name": "P"])
        try put("section", "s", ["name": "S", "project_id": "p"])
        try put("task", "parent", ["title": "Parent", "project_id": "p", "section_id": "s"])
        try put("task", "child", ["title": "Child", "project_id": "p", "parent_id": "parent"])
        #expect(shape(projectSections(try snapshot(store), "p")[1].tasks) == "parent(child)")
        try put("task", "parent", ["completed_at": 1])
        #expect(shape(projectSections(try snapshot(store), "p")[0].tasks) == "child")
    }

    @Test func completedSubtasksStayBeneathOpenParents() throws {
        try put("project", "p", ["name": "P"])
        try put("task", "parent", ["title": "Parent", "project_id": "p", "position": 1])
        try put("task", "done", ["title": "Done", "project_id": "p", "parent_id": "parent", "completed_at": 10, "position": 1])
        try put("task", "nested", ["title": "Nested", "project_id": "p", "parent_id": "done", "completed_at": 10])
        try put("task", "open", ["title": "Open", "project_id": "p", "parent_id": "parent", "position": 2])
        try put("task", "top_done", ["title": "Top done", "project_id": "p", "completed_at": 10])
        #expect(shape(projectSections(try snapshot(store), "p")[0].tasks) == "parent(open done(nested))")
    }

    @Test func completedSubtaskStaysUntilClearedAndReappearsAfterRecompletion() throws {
        try put("project", "p", ["name": "P"])
        try put("task", "parent", ["title": "Parent", "project_id": "p"])
        try put("task", "done", ["title": "Done", "project_id": "p", "parent_id": "parent", "completed_at": 10])
        try put("task", "nested", ["title": "Nested", "project_id": "p", "parent_id": "done", "completed_at": 10])
        try put("task", "open", ["title": "Open", "project_id": "p", "parent_id": "parent"])
        let snap = try snapshot(store)
        let cleared = sweeping([snap.allTasks["done"]!], all: snap.allTasks, into: [:])
        #expect(cleared == ["done": [10, "parent"], "nested": [10, "done"]])
        #expect(shape(projectSections(snap, "p", cleared: cleared)[0].tasks) == "parent(open)")
        try put("task", "done", ["completed_at": nil])
        #expect(shape(projectSections(try snapshot(store), "p", cleared: cleared)[0].tasks) == "parent(done open)")
        try put("task", "done", ["completed_at": 20])
        #expect(shape(projectSections(try snapshot(store), "p", cleared: cleared)[0].tasks) == "parent(open done)")
    }

    @Test func completedSubtasksSinkBelowOpenOnesAtEveryLevel() throws {
        try put("project", "p", ["name": "P"])
        try put("task", "parent", ["title": "Parent", "project_id": "p"])
        for (tid, pos, done) in [("a", 1, JSON.int(5)), ("b", 2, nil), ("c", 3, .int(6)), ("d", 4, nil)] {
            try put("task", tid, ["title": .string(tid), "project_id": "p", "parent_id": "parent", "position": .int(Int64(pos)),
                                  "completed_at": done])
        }
        try put("task", "b1", ["title": "b1", "project_id": "p", "parent_id": "b", "position": 1, "completed_at": 7])
        try put("task", "b2", ["title": "b2", "project_id": "p", "parent_id": "b", "position": 2])
        let snap = try snapshot(store)
        #expect(shape(projectSections(snap, "p")[0].tasks) == "parent(b(b2 b1) d a c)")
        #expect(snap.allTasks["a"]?["position"] == 1 && snap.allTasks["c"]?["position"] == 3)
    }

    @Test func settlingTasksKeepTheirPlace() throws {
        try put("project", "p", ["name": "P"])
        try put("task", "parent", ["title": "Parent", "project_id": "p"])
        for (tid, pos, done) in [("a", 1, JSON.int(5)), ("b", 2, nil), ("c", 3, .int(6)), ("d", 4, nil)] {
            try put("task", tid, ["title": .string(tid), "project_id": "p", "parent_id": "parent", "position": .int(Int64(pos)),
                                  "completed_at": done])
        }
        // a was just ticked (it was open), d was just reopened (it was done)
        let sections = projectSections(try snapshot(store), "p", settling: ["a": false, "d": true])
        #expect(shape(sections[0].tasks) == "parent(a b c d)")
    }

    @Test func openChildOfCompletedParentIsTopLevel() throws {
        try put("project", "p", ["name": "P"])
        try put("task", "done", ["title": "Done", "project_id": "p", "completed_at": 10])
        try put("task", "open", ["title": "Open", "project_id": "p", "parent_id": "done"])
        #expect(shape(projectSections(try snapshot(store), "p")[0].tasks) == "open")
    }

    @Test func inboxSplitsOffPlannedTasks() throws {
        try put("task", "loose", ["title": "Loose", "project_id": nil])
        try put("task", "dated", ["title": "Dated", "project_id": nil, "due": ["date": "2026-11-03"]])
        try put("task", "child", ["title": "Child", "project_id": nil, "parent_id": "dated"])
        let snap = try snapshot(store)
        let sections = projectSections(snap, nil)
        #expect(sections.map(\.name) == ["", "Planned, no project"])
        #expect(shape(sections[0].tasks) == "loose")
        #expect(shape(sections[1].tasks) == "dated(child)")
        #expect(!sections[1].isList)
        #expect(countOpen(snap, nil, today: "2026-11-01") == 1)
    }

    @Test func countSkipsParkedAndDeferred() throws {
        try put("project", "p", ["name": "P"])
        try put("task", "now", ["title": "Now", "project_id": "p"])
        try put("task", "someday", ["title": "Someday", "project_id": "p", "start": "someday"])
        try put("task", "later", ["title": "Later", "project_id": "p", "start": "2026-12-01"])
        try put("task", "started", ["title": "Started", "project_id": "p", "start": "2026-10-01"])
        #expect(countOpen(try snapshot(store), "p", today: "2026-11-01") == 2)
    }
}

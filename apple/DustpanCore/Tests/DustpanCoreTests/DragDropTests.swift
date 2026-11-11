import Foundation
import Testing
@testable import DustpanCore

// A section as a project list shows it:
//   a
//     a1
//       a1x
//     a2
//   b
//   c
private let rows = [Slot("a", 0), Slot("a1", 1, "a"), Slot("a1x", 2, "a1"), Slot("a2", 1, "a"), Slot("b", 0), Slot("c", 0)]

private func hit(_ id: String, _ zone: Zone) -> ListHit { .row(rows.firstIndex { $0.id == id }!, zone) }

private func drop(_ hit: ListHit, depth: Int = 0, moving: String = "x", rows: [Slot] = rows) -> Drop {
    resolveDrop(rows, projectId: "p1", sectionId: "s1", hit: hit, depth: depth, moving: moving)
}

private func spot(_ parent: String? = nil, before: String? = nil, after: String? = nil) -> DropTarget {
    .place(Placement("p1", "s1", parent: parent, before: before, after: after))
}

@Suite struct DragDropTests {
    /// OpenTodo's listDrop.dropZone, and Pragmatic's hitbox table.
    @Test func zones() {
        #expect([0, 9, 10, 30, 31, 40].map { dropZone($0, height: 40) }
                 == [.before, .before, .inside, .inside, .after, .after])
        #expect([0, 19, 20, 40].map { dropZone($0, height: 40, inside: false) } == [.before, .before, .after, .after])
        #expect([-30, 0, 11, 13, 30, 40].map { dropLevel($0, indent: 24) } == [-1, 0, 0, 1, 1, 2])
    }

    /// The gaps either side of a task, at its own level, leave it where it is. Another level or gap moves it.
    @Test func leavesInPlaceOnlyAtItsOwnGapAndLevel() {
        for d in [drop(hit("b", .before), moving: "b"), drop(hit("a2", .after), moving: "b"), drop(hit("c", .before), moving: "b")] {
            #expect(leavesInPlace(d, rows, moving: "b"))
        }
        #expect(!leavesInPlace(drop(hit("c", .after), moving: "b"), rows, moving: "b"))
        #expect(!leavesInPlace(drop(hit("a2", .after), depth: 1, moving: "b"), rows, moving: "b"))  // into a, after a2
        #expect(!leavesInPlace(drop(hit("a", .inside), moving: "b"), rows, moving: "b"))
        // A subtask dragged out to the top level, from its own gap, moves.
        #expect(leavesInPlace(drop(hit("a2", .before), depth: 1, moving: "a2"), rows, moving: "a2"))
        #expect(!leavesInPlace(drop(hit("b", .before), depth: 0, moving: "a2"), rows, moving: "a2"))
    }

    @Test func beforeAndAfterAtTheRowsLevel() {
        #expect(drop(hit("b", .before)).target == spot(before: "b"))
        #expect(drop(hit("a2", .before), depth: 1).target == spot("a", before: "a2"))
        // Before a2 is also after a1x, so a deeper pointer lands under a1.
        #expect(drop(hit("a2", .before), depth: 5).target == spot("a1", after: "a1x"))
        #expect(drop(hit("b", .after)).target == spot(before: "c"))
        #expect(drop(hit("c", .after)).target == spot(after: "c"))
    }

    @Test func insideMakesTheLastSubtask() {
        let found = drop(hit("b", .inside))
        #expect(found.target == spot("b"))
        #expect(found.ring == "b")
    }

    /// OpenTodo's dropTarget rule: the line under a parent sits above its first child.
    @Test func afterAnOpenParentIsTheTopOfItsSubtasks() {
        for depth in [0, 1, 3] { #expect(drop(hit("a", .after), depth: depth).target == spot("a", before: "a1")) }
    }

    /// Pragmatic's reparent: after a2, the end of a's subtasks, the level is 0 or 1.
    @Test func thePointerPicksTheLevelWhereGroupsClose() {
        #expect(drop(hit("a2", .after), depth: 1).target == spot("a", after: "a2"))
        #expect(drop(hit("a2", .after), depth: 0).target == spot(before: "b"))
        // Clamped: never deeper than the row above, never shallower than the row below.
        #expect(drop(hit("a2", .after), depth: 4).depth == 1)
        #expect(drop(hit("a2", .after), depth: -2).depth == 0)
        // After a1x three levels close: under a1, under a, or the top level.
        #expect(drop(hit("a1x", .after), depth: 2).target == spot("a1", after: "a1x"))
        #expect(drop(hit("a1x", .after), depth: 1).target == spot("a", before: "a2"))
    }

    @Test func theEndOfAListAfterASubtree() {
        let short = Array(rows.prefix(4))
        #expect(drop(.end, depth: 0, rows: short).target == spot(after: "a"))
        #expect(drop(.end, depth: 2, rows: short).target == spot("a", after: "a2"))
    }

    @Test func headingAndEmptyList() {
        #expect(drop(.head, depth: 3).target == spot(before: "a"))
        #expect(drop(.head, rows: []).target == spot())
        #expect(drop(.end, depth: 2, rows: []).target == spot())
    }

    /// Dragging a in place: its rows stand for the gap, so sideways movement only changes its level.
    @Test func theDraggedSubtreeIsTheGapItLeft() {
        let found = drop(hit("a1", .inside), depth: 0, moving: "a")
        #expect(found.ring == nil)
        #expect(found.target == spot(before: "b"))
        // Drag a2 left in place: out of a, before b.
        #expect(drop(hit("a2", .before), depth: 0, moving: "a2").target == spot(before: "b"))
        // Or keep it under a, after a1.
        #expect(drop(hit("a2", .after), depth: 1, moving: "a2").target == spot("a", after: "a1"))
    }

    /// A task's own subtasks are no target for it; the drop lands in the gap it left.
    @Test func neverUnderItself() {
        for (id, zone) in [("a1", Zone.inside), ("a1x", .inside), ("a2", .after)] {
            guard case .place(let place) = drop(hit(id, zone), depth: 2, moving: "a").target else {
                Issue.record("not a place")
                continue
            }
            #expect(!["a", "a1", "a2", "a1x"].contains(place.parentId))
        }
    }

    @Test func theLineSitsBelowPrev() {
        let found = drop(hit("a2", .after), depth: 0)
        #expect(found.prev == "a2" && found.next == "b" && found.depth == 0)
        let top = drop(.head)
        #expect(top.prev == nil && top.next == "a")
    }

    /// An outline view proposes a parent and a child; the same rules decide what that means.
    @Test func outlineProposals() {
        func outline(_ parent: String?, before: String? = nil, inside: Bool = false, moving: String = "x") -> Drop? {
            resolveDrop(rows, projectId: "p1", sectionId: "s1", parent: parent, before: before, inside: inside, moving: moving)
        }
        #expect(outline("b", inside: true)?.ring == "b")
        #expect(outline("b", inside: true)?.target == spot("b"))
        #expect(outline("a", before: "a2")?.target == spot("a", before: "a2"))
        #expect(outline("a")?.target == spot("a", after: "a2"))
        #expect(outline(nil, before: "b")?.target == spot(before: "b"))
        #expect(outline(nil)?.target == spot(after: "c"))
        // A row without subtasks takes the task as its first.
        #expect(outline("a1x", before: nil)?.target == spot("a1x"))
        // Never under itself; before its own subtree is the gap it left.
        #expect(outline("a1", moving: "a") == nil)
        #expect(outline(nil, before: "a1", moving: "a")?.target == spot(before: "b"))
        #expect(outline("gone") == nil)
    }

    @Test func openSlotsSkipCompletedRows() {
        let done = Row(id: "d", values: ["completed_at": 5])
        let tree = [Node(row: Row(id: "a"), children: [Node(row: Row(id: "a1")), Node(row: done)]), Node(row: Row(id: "b"))]
        #expect(openSlots(tree) == [Slot("a", 0), Slot("a1", 1, "a"), Slot("b", 0)])
        #expect(openSlots(tree, folded: ["a"]) == [Slot("a", 0), Slot("b", 0)])
    }

    @Test func describesEachKindOfChange() {
        let names = ["p1": "Home", "p2": "Work", "s1": "Doing", "a": "Plan trip", "l1": "errand"]
        func text(_ target: DropTarget, _ fields: [String: JSON] = [:]) -> String {
            describeDrop(target, task: Row(id: "t", values: fields), names: names) { _ in "Thu 5 Nov" }
        }
        #expect(text(.day(Day("2026-11-05")!)) == "Due Thu 5 Nov")
        #expect(text(.project(nil), ["project_id": "p1"]) == "Moved to Inbox")
        #expect(text(.project("p2"), ["project_id": "p1"]) == "Moved to Work")
        #expect(text(.label("l1")) == "Added errand")
        #expect(text(.place(Placement("p1", nil, parent: "a")), ["project_id": "p1"]) == "Moved under “Plan trip”")
        #expect(text(.place(Placement("p1", nil)), ["project_id": "p1", "parent_id": "a"]) == "Moved out of “Plan trip”")
        #expect(text(.place(Placement("p1", "s1")), ["project_id": "p1"]) == "Moved to Doing")
        #expect(text(.place(Placement("p2", nil)), ["project_id": "p1"]) == "Moved to Work")
        #expect(text(.place(Placement("p1", "s1", before: "b")), ["project_id": "p1", "section_id": "s1"])
                == "Order changed")
    }
}

/// Keyboard moves: the port of test_dragdrop.py's NudgeTest.
@Suite struct NudgeTests {
    private func move(_ id: String, _ how: Nudge) -> Placement? {
        nudge(rows, projectId: "p1", sectionId: "s1", taskId: id, how)
    }

    private func spot(_ parent: String? = nil, before: String? = nil, after: String? = nil) -> Placement {
        Placement("p1", "s1", parent: parent, before: before, after: after)
    }

    @Test func upAndDownAmongSiblings() {
        #expect(move("b", .up) == spot(before: "a"))
        #expect(move("b", .down) == spot(after: "c"))
        #expect(move("a2", .up) == spot("a", before: "a1"))
    }

    @Test func topAndBottom() {
        #expect(move("c", .top) == spot(before: "a"))
        #expect(move("a", .bottom) == spot(after: "c"))
    }

    /// The first task and ⌥↑: nothing changes.
    @Test func nothingAtTheEdges() {
        let cases: [(String, Nudge)] = [("a", .up), ("a", .top), ("c", .down), ("c", .bottom), ("a2", .down),
                                        ("a1x", .up), ("a", .indent), ("a1", .indent), ("b", .outdent), ("gone", .up)]
        for (id, how) in cases { #expect(move(id, how) == nil, "\(id) \(how)") }
    }

    /// The last subtask of the task above at its level, which may have subtasks already.
    @Test func indentUnderTheSiblingAbove() {
        #expect(move("b", .indent) == spot("a"))
        #expect(move("a2", .indent) == spot("a1"))
    }

    @Test func outdentRightAfterTheOldParent() {
        #expect(move("a1x", .outdent) == spot("a", after: "a1"))
        #expect(move("a1", .outdent) == spot(after: "a"))
    }
}

/// Writer.drop: the ports of test_writes.py's drop tests and test_labels.py's label drops.
@Suite struct DropWriteTests {
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

    func place(_ project: String?, _ section: String? = nil, parent: String? = nil, before: String? = nil,
               after: String? = nil) -> DropTarget {
        .place(Placement(project, section, parent: parent, before: before, after: after))
    }

    @Test func moveWithinAndBetweenLists() throws {
        try seed("project", "p1", ["name": "Home"])
        try seed("section", "s1", ["name": "Doing", "project_id": "p1"])
        for (id, position, extra) in [("a", 1000, [:]), ("b", 2000, [:]), ("c", 3000, [:]),
                                      ("d", 1000, ["section_id": "s1"]), ("e", 500, ["parent_id": "a"])]
            as [(String, Int64, [String: JSON])] {
            try seed("task", id, ["title": .string(id), "project_id": "p1", "position": .int(position)]
                .merging(extra) { $1 })
        }
        let before = try store.outboxCount()
        _ = try writer.drop("c", on: place("p1", before: "a"))
        #expect(try store.outboxCount() - before == 1)
        #expect(try task("c")["position"] == 0)
        _ = try writer.drop("b", on: place("p1", "s1", after: "d"))
        #expect(try task("b")["section_id"] == "s1" && task("b")["position"] == 2000)
        _ = try writer.drop("d", on: place("p1", parent: "a"))
        #expect(try task("d")["parent_id"] == "a" && task("d")["position"] == 1500)
        _ = try writer.drop("e", on: place("p1", after: "c"))
        #expect(try task("e")["parent_id"] == .null && task("e")["position"] == 500)
        for (id, bad) in [("a", place("p1", parent: "a")), ("a", place("p1", parent: "d")), ("a", place("p1", "nope")),
                          ("a", place("p1", before: "gone"))] {
            #expect(throws: CannotEdit.self) { try writer.drop(id, on: bad) }
        }
    }

    @Test func undoPutsBackEveryField() throws {
        try seed("project", "p1", ["name": "Home"])
        try seed("task", "a", ["title": "A", "project_id": "p1", "position": 1000])
        try seed("task", "b", ["title": "B", "project_id": "p1", "position": 2000])
        let done = try writer.drop("b", on: place("p1", parent: "a"))
        #expect(try task("b")["parent_id"] == "a")
        #expect(done.undo == [Change("task", "b", ["parent_id": .null, "position": 2000])])
        try writer.revert(done.undo)
        #expect(try task("b")["parent_id"] == .null && task("b")["position"] == 2000)
    }

    @Test func intoAnotherProjectCarriesTheSubtree() throws {
        try seed("project", "p1", ["name": "Home"])
        try seed("project", "p2", ["name": "Work"])
        try seed("section", "s1", ["name": "Doing", "project_id": "p1"])
        try seed("task", "a", ["title": "A", "project_id": "p1", "section_id": "s1", "position": 1])
        try seed("task", "a1", ["title": "A1", "project_id": "p1", "section_id": "s1", "parent_id": "a"])
        try seed("task", "x", ["title": "X", "project_id": "p2", "position": 500])
        _ = try writer.drop("a", on: place("p2", parent: "x"))
        let (a, a1) = (try task("a"), try task("a1"))
        #expect(a["project_id"] == "p2" && a["section_id"] == .null && a["parent_id"] == "x")
        #expect(a1["project_id"] == "p2" && a1["section_id"] == .null && a1["parent_id"] == "a")
        // A subtask dropped on the Inbox in the sidebar leaves its parent and project.
        _ = try writer.drop("a1", on: .project(nil))
        #expect(try task("a1")["project_id"] == .null && task("a1")["parent_id"] == .null)
    }

    @Test func onADayKeepsTheTimeAndUnparks() throws {
        try seed("task", "a", ["title": "A", "due": ["date": "2026-11-03", "time": "14:30", "tz": "Europe/Berlin"]])
        try seed("task", "b", ["title": "B", "start": "someday"])
        _ = try writer.drop("a", on: .day(Day("2026-11-05")!))
        #expect(try task("a")["due"] == ["date": "2026-11-05", "time": "14:30", "tz": "Europe/Berlin"])
        _ = try writer.drop("b", on: .day(Day("2026-11-02")!))
        #expect(try task("b")["due"] == ["date": "2026-11-02"] && task("b")["start"] == .null)
    }

    @Test func onADayClearsTheSector() throws {
        try seed("task", "t1", ["title": "Budget", "sector": "2026-W45"])
        _ = try writer.drop("t1", on: .day(Day("2026-11-06")!))
        #expect(try task("t1")["due"] == ["date": "2026-11-06"] && task("t1")["sector"] == "")
    }

    @Test func aDropThatChangesNothingWritesNothing() throws {
        try seed("project", "p1", ["name": "Home"])
        try seed("task", "a", ["title": "A", "project_id": "p1", "position": 1000, "due": ["date": "2026-11-05"]])
        let before = try store.outboxCount()
        for target in [DropTarget.day(Day("2026-11-05")!), .project("p1"), place("p1")] {
            #expect(try writer.drop("a", on: target).undo.isEmpty)
        }
        #expect(try store.outboxCount() == before)
        try seed("task", "done", ["title": "Done", "project_id": "p1", "completed_at": 5])
        #expect(throws: CannotEdit.self) { try writer.drop("done", on: .project(nil)) }
    }

    @Test func onALabelAddsItAndNothingElse() throws {
        try seed("label", "call", ["name": "call"])
        try seed("label", "errand", ["name": "errand"])
        try seed("task", "t4", ["title": "Four", "labels": ["call"], "position": 7, "due": ["date": "2026-11-09"]])
        let done = try writer.drop("t4", on: .label("errand"))
        #expect(try task("t4")["labels"] == ["call", "errand"])
        #expect(Set(try store.outboxBatch(limit: 100).map(\.op).filter { $0.entityId == "t4" }.map(\.field)) == ["labels"])
        try writer.revert(done.undo)
        #expect(try task("t4")["labels"] == ["call"])
        // Already there: nothing written. A deleted label is refused.
        let count = try store.outboxCount()
        #expect(try writer.drop("t4", on: .label("call")).undo.isEmpty)
        #expect(try store.outboxCount() == count)
        _ = try writer.deleteLabel("call")
        #expect(throws: CannotEdit.self) { try writer.drop("t4", on: .label("call")) }
    }
}

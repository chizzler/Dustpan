import Foundation
import Testing
@testable import DustpanCore

/// labels.py's rules, ordering.py's moves and the label writes: ports of test_labels.py and test_ordering.py.
@Suite struct LabelRulesTests {
    func label(_ id: String, _ name: String, _ position: Int64 = 0) -> Row {
        Row(id: id, values: ["name": .string(name), "position": .int(position)])
    }

    var labels: [Row] { [label("a", "errand", 1), label("b", "Deep work", 2), label("c", "Café", 3), label("d", "waiting", 4)] }

    func names(_ rows: [Row]) -> [String] { rows.map { $0["name"].string ?? "" } }

    @Test func findRanksStartThenWordThenInsideThenLetters() {
        #expect(names(findLabels(labels, "")) == ["errand", "Deep work", "Café", "waiting"])
        #expect(names(findLabels(labels, "w")) == ["waiting", "Deep work"])
        #expect(names(findLabels(labels, "rr")) == ["errand"])
        #expect(names(findLabels(labels, "dw")) == ["Deep work"])
        #expect(names(findLabels(labels, "nothing")) == [])
    }

    @Test func findIgnoresCaseAndAccents() {
        #expect(names(findLabels(labels, "CAFE")) == ["Café"])
        #expect(names(findLabels(labels, "cafè")) == ["Café"])
    }

    @Test func recentFirstThenSidebarOrder() {
        #expect(names(pickerOrder(labels, recent: ["d", "gone", "b"])) == ["waiting", "Deep work", "errand", "Café"])
        #expect(rememberLabels(["a", "b"], ["c", "b"]) == ["b", "c", "a"])
        #expect(rememberLabels((0..<20).map(String.init), ["x"]).count == 8)
    }

    @Test func duplicatesIgnoreCase() {
        #expect(duplicateLabels([label("a", "errand"), label("b", " Errand "), label("c", "call")]) == ["a", "b"])
    }

    @Test func shownKeepsTaskOrderHidesUnknownAndThePageLabel() {
        let byId = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
        #expect(names(shownLabels(["d", "zzz", "a", "d"], byId)) == ["waiting", "errand"])
        #expect(names(shownLabels(["d", "a"], byId, skip: "a")) == ["waiting"])
    }

    // OpenSpec manual-ordering, "Fractional insertion and renumbering".

    @Test func oneWriteAtTheMidpoint() {
        let moves = planOrder([("a", 1000), ("b", 2000), ("x", 3000)], moving: "x", to: 1, fallback: 0)
        #expect(moves.map(\.id) == ["x"] && moves.map(\.position) == [1500])
    }

    @Test func endsAndEmptyLists() {
        let items: [(id: String, position: Double)] = [("a", 1000), ("b", 2000)]
        #expect(planOrder(items, moving: "x", to: 0, fallback: 0).map(\.position) == [0])
        #expect(planOrder(items, moving: "x", to: 9, fallback: 0).map(\.position) == [3000])
        #expect(planOrder([], moving: "x", to: 0, fallback: 77).map(\.position) == [77])
    }

    @Test func noMoveWritesNothing() {
        #expect(planOrder([("a", 1), ("x", 2), ("b", 3)], moving: "x", to: 1, fallback: 0).isEmpty)
    }

    @Test func equalNeighboursRenumberTheSmallestWindow() {
        let items: [(id: String, position: Double)] = [("a", 1000), ("b", 2000), ("c", 2000), ("d", 5000)]
        let changes = Dictionary(uniqueKeysWithValues: planOrder(items, moving: "x", to: 2, fallback: 0).map { ($0.id, $0.position) })
        var all = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.position) })
        all.merge(changes) { _, new in new }
        #expect(all.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key) == ["a", "b", "x", "c", "d"])
        #expect(changes["a"] == nil && changes["d"] == nil)
    }

    @Test func estimates() throws {
        #expect(try parseEstimate("") == nil)
        #expect(try parseEstimate("30m") == 30)
        #expect(try parseEstimate("1h30") == 90)
        #expect(try parseEstimate("1h 30m") == 90)
        #expect(try parseEstimate("1.5h") == 90)
        #expect(try parseEstimate("45") == 45)
        #expect(try parseEstimate("2H") == 120)
        for bad in ["0", "1h60", "soon", "200h"] {
            #expect(throws: CannotEdit.self) { try parseEstimate(bad) }
        }
        #expect([30, 90, 120, nil].map { estimateText($0) } == ["30m", "1h30", "2h", ""])
    }
}

@Suite struct LabelWritesTests {
    let store: Store
    let writer: Writer
    let now: Int64 = 1_000_000

    init() throws {
        store = try memoryStore()
        let now = now
        writer = Writer(store: store, clock: HybridClock(store: store, now: { now }), now: { now },
                        today: { Day("2026-11-02")! })
        try store.setMeta("user_id", "me")
        try seed("label", "errand", ["name": "errand", "color": "#ef4444", "position": 1])
        try seed("label", "call", ["name": "call", "color": "#f97316", "position": 2])
        try seed("task", "t1", ["title": "One", "labels": ["errand"]])
        try seed("task", "t2", ["title": "Two", "labels": ["call", "errand"]])
        try seed("task", "t3", ["title": "Gone", "labels": ["errand"], "deleted_at": 5])
    }

    func seed(_ entity: String, _ id: String, _ fields: [String: JSON]) throws {
        for (name, value) in fields {
            try store.apply(Op(id: "\(id)-\(name)-1", entity: entity, entityId: id, field: name, value: value,
                               ts: 1, device: "other"))
        }
    }

    func labels(of taskId: String) throws -> [String] { labelIds(try #require(try store.rows("task")[taskId])) }
    func label(_ id: String) throws -> Row { try #require(try store.rows("label")[id]) }
    func outbox() throws -> [Op] { try store.outboxBatch(limit: 1000).map(\.op) }

    @Test func addTakesTheFirstUnusedColourAndRefusesANameInUse() throws {
        let row = try label(try writer.addLabel("  Garden "))
        #expect(row["name"] == "Garden" && row["color"] == .string(labelColours[2].hex))
        #expect(throws: CannotEdit("There's already a label called “errand”")) { try writer.addLabel("ERRAND") }
        #expect(throws: CannotEdit.self) { try writer.addLabel("  ") }
    }

    @Test func renameIsOneOpAndNeverTouchesTasks() throws {
        let done = try writer.editLabel("errand", name: "errands", color: "#22c55e")
        #expect(Set(try outbox().map { "\($0.entity).\($0.field)" }) == ["label.name", "label.color"])
        #expect(try labels(of: "t1") == ["errand"])
        #expect(throws: CannotEdit.self) { try writer.editLabel("errand", name: "Call") }
        // Changing only the case of its own name is fine.
        _ = try writer.editLabel("errand", name: "Errands")
        try writer.revert(done.undo)
        #expect(try label("errand")["color"] == "#ef4444")
    }

    @Test func move() throws {
        _ = try writer.moveLabel("call", step: -1)
        #expect(try store.rows("label").values.sorted(by: orderLess).map(\.id) == ["call", "errand"])
        let before = try outbox().count
        #expect(try writer.moveLabel("call", step: -1).undo.isEmpty)  // already first
        #expect(try outbox().count == before)
    }

    @Test func deleteTakesTheIdOffLiveTasksAndUndoPutsItBack() throws {
        let done = try writer.deleteLabel("errand")
        #expect(try labels(of: "t1") == [] && labels(of: "t2") == ["call"])
        #expect(try labels(of: "t3") == ["errand"])  // deleted tasks are left alone
        #expect(!(try label("errand")["deleted_at"].isNull))
        try writer.revert(done.undo)
        #expect(try labels(of: "t1") == ["errand"] && labels(of: "t2") == ["call", "errand"])
        #expect(try label("errand")["deleted_at"].isNull)
    }

    @Test func mergeRewritesOnceAndDeletesTheSource() throws {
        _ = try writer.mergeLabels("errand", into: "call")
        #expect(try labels(of: "t1") == ["call"] && labels(of: "t2") == ["call"])
        #expect(!(try label("errand")["deleted_at"].isNull))
        #expect(throws: CannotEdit.self) { try writer.mergeLabels("call", into: "call") }
    }

    @Test func changeTaskLabelsReadsTheCurrentArray() throws {
        _ = try writer.changeTaskLabels("t1", add: ["call"])
        _ = try writer.changeTaskLabels("t1", add: ["Garden"], remove: ["errand"])
        let names = try store.rows("label").mapValues { $0["name"].string ?? "" }
        #expect(try labels(of: "t1").map { names[$0] } == ["call", "Garden"])
        let before = try outbox().count
        let done = try writer.changeTaskLabels("t1", add: ["call"])  // already there: nothing written
        #expect(try outbox().count == before && done.undo.isEmpty)
    }

    @Test func editTakesIdsOrNamesAndCreatesLabelsFirst() throws {
        try writer.edit("t1", TaskEdit(labels: ["call", "Errand", "New one"]))
        let ids = try labels(of: "t1")
        #expect(Array(ids.prefix(2)) == ["call", "errand"])
        #expect(try label(ids[2])["name"] == "New one")
        let ops = try outbox()
        let firstLabel = try #require(ops.firstIndex { $0.entity == "label" })
        let firstTask = try #require(ops.firstIndex { $0.field == "labels" })
        #expect(firstLabel < firstTask)
    }

    @Test func addOnALabelPageGivesTheLabel() throws {
        let id = try writer.addTask("Post", labels: ["errand"])
        let row = try #require(try store.rows("task")[id])
        #expect(labelIds(row) == ["errand"])
    }

    @Test func labelPageListsOpenTasksAndCounts() throws {
        try seed("task", "t4", ["title": "Done", "labels": ["errand"], "completed_at": 9])
        try seed("task", "t5", ["title": "Later", "labels": ["errand"], "start": "someday"])
        let tasks = try store.rows("task").values.filter(isLive)
        let groups = labelGroups(try label("errand"), Array(tasks), today: Day("2026-11-02")!, labels: [],
                                 projects: [])
        #expect(groups.flatMap(\.tasks).map(\.id).sorted() == ["t1", "t2"])
        #expect(labelCounts(Array(tasks), today: Day("2026-11-02")!) == ["errand": 2, "call": 1])
    }
}

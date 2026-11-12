import Foundation
import Testing
@testable import DustpanCore

// Reordering the sidebar: the drop rule for its rows, and the writes for projects, labels and views.
// A port of tests/test_sidebar_order.py.

@Suite struct PlaceItemTests {
    @Test func beforeAfterAndInside() {
        #expect(placeItem("b", parent: nil, children: [], zone: .before, moving: "x") == ItemPlace(nil, before: "b"))
        #expect(placeItem("b", parent: "p", children: [], zone: .after, moving: "x") == ItemPlace("p", after: "b"))
        #expect(placeItem("b", parent: nil, children: ["c"], zone: .inside, moving: "x") == ItemPlace("b"))
    }

    @Test func afterAnOpenParentIsItsFirstChild() {
        #expect(placeItem("b", parent: nil, children: ["c", "d"], zone: .after, moving: "x") == ItemPlace("b", before: "c"))
        #expect(placeItem("b", parent: nil, children: ["x", "d"], zone: .after, moving: "x") == ItemPlace("b", before: "d"))
        #expect(placeItem("b", parent: nil, children: ["x"], zone: .after, moving: "x") == ItemPlace("b"))
    }

    @Test func neverOntoItselfOrItsSubtree() {
        #expect(placeItem("x", parent: nil, children: [], zone: .before, moving: "x") == nil)
        #expect(placeItem("c", parent: "x", children: [], zone: .inside, moving: "x", below: ["c"]) == nil)
    }
}

@Suite struct SidebarWritesTests {
    let store: Store
    let writer: Writer

    init() throws {
        store = try memoryStore()
        writer = Writer(store: store, clock: HybridClock(store: store, now: { 1_000_000 }), now: { 1_000_000 },
                        today: { Day("2026-11-07")! })
        try store.setMeta("user_id", "me")
        for (i, id) in ["work", "home", "garden"].enumerated() {
            try seed("project", id, ["name": .string(id.capitalized), "position": .int(Int64(i + 1) * 1000),
                                     "parent_id": nil, "archived": false])
        }
        try seed("project", "shed", ["name": "Shed", "position": 1000, "parent_id": "garden", "archived": false])
        for (i, id) in ["a", "b", "c"].enumerated() {
            try seed("label", id, ["name": .string(id), "position": .int(Int64(i + 1) * 1000)])
        }
        for (i, id) in ["v1", "v2", "v3"].enumerated() {
            try seed("view", id, ["name": .string(id), "query": "today", "position": .int(Int64(i + 1) * 1000),
                                  "kind": "list"])
        }
    }

    func seed(_ entity: String, _ id: String, _ fields: [String: JSON]) throws {
        for (name, value) in fields {
            try store.apply(Op(id: "\(id)-\(name)-1", entity: entity, entityId: id, field: name, value: value,
                               ts: 1, device: "other"))
        }
    }

    func outbox() throws -> [Op] { try store.outboxBatch(limit: 1000).map(\.op) }

    func order(_ entity: String, under parent: String? = nil) throws -> [String] {
        try store.rows(entity).values
            .filter { isLive($0) && (entity != "project" || $0["parent_id"].string == parent) }
            .sorted(by: orderLess).map(\.id)
    }

    @Test func placeProjectAmongSiblings() throws {
        _ = try writer.placeProject("garden", under: nil, before: "work")
        #expect(try order("project") == ["garden", "work", "home"])
    }

    @Test func nestAndUnnestAProjectWithUndo() throws {
        let done = try writer.placeProject("home", under: "garden", after: "shed")
        #expect(try order("project") == ["work", "garden"])
        #expect(try order("project", under: "garden") == ["shed", "home"])
        _ = try writer.placeProject("shed", under: nil, after: "work")
        #expect(try order("project") == ["work", "shed", "garden"])
        try writer.revert(done.undo)
        #expect(try store.rows("project")["home"]?["parent_id"].isNull == true)
    }

    @Test func aProjectCantGoUnderItselfOrBelow() throws {
        #expect(throws: CannotEdit.self) { try writer.placeProject("garden", under: "shed") }
        #expect(throws: CannotEdit.self) { try writer.placeProject("garden", under: "garden") }
    }

    @Test func moveProjectStaysAmongSiblings() throws {
        _ = try writer.moveProject("home", step: -1)
        #expect(try order("project") == ["home", "work", "garden"])
        let before = try outbox().count
        #expect(try writer.moveProject("shed", step: -1).undo.isEmpty)  // an only child: nowhere to go
        #expect(try outbox().count == before)
    }

    @Test func moveLabelAndView() throws {
        _ = try writer.moveLabel("c", to: 0)
        #expect(try order("label") == ["c", "a", "b"])
        _ = try writer.moveView("v1", to: 2)
        #expect(try order("view") == ["v2", "v3", "v1"])
        _ = try writer.moveView("v1", step: -1)
        #expect(try order("view") == ["v2", "v1", "v3"])
        #expect(try writer.moveView("v2", step: -1).undo.isEmpty)
    }

    @Test func aMoveWritesOnlyPositions() throws {
        let before = try outbox().count
        _ = try writer.moveLabel("c", to: 1)
        #expect(Set(try outbox()[before...].map(\.field)) == ["position"])
    }
}

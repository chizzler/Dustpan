import Foundation
import Testing
@testable import DustpanCore

// Creating projects. A port of the add_project tests in tests/test_projects.py.

@Suite struct ProjectsTests {
    let store: Store
    let writer: Writer
    let now: Int64 = 1_000_000

    init() throws {
        store = try memoryStore()
        writer = Writer(store: store, clock: HybridClock(store: store, now: { 1_000_000 }), now: { 1_000_000 },
                        today: { Day("2026-11-09")! })
        try store.setMeta("user_id", "me")
    }

    func seed(_ entity: String, _ id: String, _ fields: [String: JSON]) throws {
        for (name, value) in fields {
            try store.apply(Op(id: "\(id)-\(name)-1", entity: entity, entityId: id, field: name, value: value,
                               ts: 1, device: "other"))
        }
    }

    func outbox() throws -> [Op] { try store.outboxBatch(limit: 1000).map(\.op) }

    @Test func addProjectWritesEveryFieldLastAmongSiblings() throws {
        try seed("project", "p1", ["name": "Home", "color": .string(projectColours[0].hex), "position": .int(now + 7),
                                   "parent_id": nil, "archived": false])
        let projectId = try writer.addProject("  Garden ", under: "p1")
        let row = try #require(try store.rows("project")[projectId])
        #expect(row["name"].string == "Garden")
        #expect(row["parent_id"].string == "p1")
        #expect(row["position"].int == now)  // no sibling under p1
        #expect(row["archived"] == false)
        #expect(row["deleted_at"].isNull)
        #expect(row["color"].string == projectColours[1].hex)  // the first colour no project uses
        let top = try writer.addProject("Work")
        #expect(try store.rows("project")[top]?["position"].int == now + 8)  // past p1, + 1 like the web app
        #expect(Set(try outbox().filter { $0.entityId == top }.map(\.ts)).count == 1)
    }

    @Test func addProjectRefusesEmptyNameAndArchivedOrMissingParent() throws {
        try seed("project", "old", ["name": "Old", "archived": true])
        #expect(throws: CannotEdit.self) { try writer.addProject("  ") }
        #expect(throws: CannotEdit.self) { try writer.addProject("x", under: "old") }
        #expect(throws: CannotEdit.self) { try writer.addProject("x", under: "missing") }
        #expect(try outbox().isEmpty)
    }
}

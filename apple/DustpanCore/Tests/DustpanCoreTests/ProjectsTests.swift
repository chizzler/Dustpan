import Foundation
import Testing
@testable import DustpanCore

// Projects and sections. A port of tests/test_projects.py.

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

    /// What the outbox writes, by entity id and field.
    func written() throws -> [String: JSON] {
        Dictionary(try outbox().map { ("\($0.entityId).\($0.field)", $0.value) }, uniquingKeysWith: { _, last in last })
    }

    func project(_ id: String) throws -> Row { try #require(try store.rows("project")[id]) }
    func section(_ id: String) throws -> Row { try #require(try store.rows("section")[id]) }
    func task(_ id: String) throws -> Row { try #require(try store.rows("task")[id]) }

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

    @Test func editProjectWritesOnlyChangesAndUndoes() throws {
        try seed("project", "p1", ["name": "Home", "color": "#ef4444", "parent_id": nil])
        #expect(try writer.editProject("p1", ProjectEdit(name: "Home", color: "#ef4444")).undo.isEmpty)
        #expect(try outbox().isEmpty)
        let done = try writer.editProject("p1", ProjectEdit(name: " House ", color: "#3b82f6"))
        #expect(try written() == ["p1.name": "House", "p1.color": "#3b82f6"])
        try writer.revert(done.undo)
        #expect(try project("p1")["name"].string == "Home")
        #expect(try project("p1")["color"].string == "#ef4444")
    }

    @Test func editProjectRefusesEmptyNameAndBadColour() throws {
        try seed("project", "p1", ["name": "Home"])
        #expect(throws: CannotEdit.self) { try writer.editProject("p1", ProjectEdit(name: " ")) }
        #expect(throws: CannotEdit.self) { try writer.editProject("p1", ProjectEdit(color: "red")) }
        #expect(try outbox().isEmpty)
    }

    @Test func moveProjectWritesParentAndLastPosition() throws {
        try seed("project", "a", ["name": "A", "parent_id": nil, "position": 1])
        try seed("project", "b", ["name": "B", "parent_id": nil, "position": 2])
        try seed("project", "c", ["name": "C", "parent_id": "b", "position": .int(now + 50)])
        _ = try writer.editProject("a", ProjectEdit(parentId: "b"))
        #expect(try written() == ["a.parent_id": "b", "a.position": .int(now + 51)])
    }

    @Test func moveProjectRefusesItselfAndItsDescendants() throws {
        try seed("project", "a", ["name": "A", "parent_id": nil])
        try seed("project", "b", ["name": "B", "parent_id": "a"])
        try seed("project", "c", ["name": "C", "parent_id": "b"])
        for parent in ["a", "c"] {
            #expect(throws: CannotEdit.self) { try writer.editProject("a", ProjectEdit(parentId: .some(parent))) }
        }
        _ = try writer.editProject("c", ProjectEdit(parentId: .some(nil)))
        #expect(try project("c")["parent_id"].isNull)
    }

    @Test func archiveCascadesAndUnarchiveDoesNot() throws {
        try seed("project", "a", ["name": "A", "parent_id": nil])
        try seed("project", "b", ["name": "B", "parent_id": "a"])
        try seed("project", "c", ["name": "C", "parent_id": "b", "archived": true])
        try seed("project", "d", ["name": "D", "parent_id": "b", "deleted_at": 5])
        let done = try writer.archiveProject("a")
        #expect(try written() == ["a.archived": true, "b.archived": true])
        _ = try writer.unarchiveProject("a")
        #expect(try project("a")["archived"] == false)
        #expect(try project("b")["archived"] == true)
        try writer.revert(done.undo)
        #expect(try project("b")["archived"] == false)  // false, not null
        #expect(try project("c")["archived"] == true)
    }

    @Test func archivedProjectsAreListedFlatByPath() throws {
        try seed("project", "a", ["name": "Work", "parent_id": nil])
        try seed("project", "b", ["name": "Old", "parent_id": "a", "archived": true])
        try seed("project", "c", ["name": "Attic", "parent_id": nil, "archived": true])
        let snap = try snapshot(store)
        #expect(snap.archivedProjects.map(\.path) == ["Attic", "Work › Old"])
        #expect(snap.projects.map(\.id) == ["a"])
        #expect(snap.projects[0].children.isEmpty)
    }

    @Test func deleteProjectLiftsSubProjectsAndKeepsTasks() throws {
        try seed("project", "top", ["name": "Top", "parent_id": nil])
        try seed("project", "mid", ["name": "Mid", "parent_id": "top"])
        try seed("project", "low", ["name": "Low", "parent_id": "mid"])
        try seed("task", "t1", ["title": "Task", "project_id": "mid", "completed_at": nil])
        let done = try writer.deleteProject("mid")
        #expect(try written() == ["low.parent_id": "top", "mid.deleted_at": .int(now)])
        #expect(try task("t1")["project_id"].string == "mid")
        let snap = try snapshot(store)
        #expect(!snap.tasks.contains { $0.id == "t1" })
        #expect(snap.projects[0].children.map(\.id) == ["low"])
        try writer.revert(done.undo)
        #expect(try project("low")["parent_id"].string == "mid")
        #expect(try snapshot(store).tasks.contains { $0.id == "t1" })
    }

    @Test func projectPathStopsAtDeletedAncestorsAndCycles() throws {
        try seed("project", "a", ["name": "A", "parent_id": nil, "deleted_at": 5])
        try seed("project", "b", ["name": "B", "parent_id": "a"])
        try seed("project", "c", ["name": "C", "parent_id": "b"])
        try seed("project", "x", ["name": "X", "parent_id": "y"])
        try seed("project", "y", ["name": "Y", "parent_id": "x"])
        let projects = try store.rows("project")
        #expect(projectPath("c", projects) == "B › C")
        #expect(projectPath("x", projects) == "Y › X")
    }

    // MARK: sections

    @Test func addSectionGoesLast() throws {
        try seed("project", "p1", ["name": "Home"])
        let first = try writer.addSection(" Kitchen ", to: "p1")
        #expect(try section(first)["position"].int == now)
        let second = try writer.addSection("Garden", to: "p1")
        #expect(try section(second)["position"].int == now + 1000)
        #expect(try section(first)["name"].string == "Kitchen")
        #expect(try section(first)["project_id"].string == "p1")
    }

    @Test func addSectionRefusesInboxArchivedProjectAndEmptyName() throws {
        try seed("project", "old", ["name": "Old", "archived": true])
        for projectId in [nil, "old", "missing"] as [String?] {
            #expect(throws: CannotEdit.self) { try writer.addSection("x", to: projectId) }
        }
        try seed("project", "p1", ["name": "Home"])
        #expect(throws: CannotEdit.self) { try writer.addSection(" ", to: "p1") }
        #expect(try outbox().isEmpty)
    }

    @Test func renameSection() throws {
        try seed("section", "s1", ["name": "Old", "project_id": "p1"])
        _ = try writer.editSection("s1", name: "Old")
        #expect(try outbox().isEmpty)
        let done = try writer.editSection("s1", name: " New ")
        #expect(try section("s1")["name"].string == "New")
        try writer.revert(done.undo)
        #expect(try section("s1")["name"].string == "Old")
    }

    @Test func sectionColourAndIcon() throws {
        try seed("project", "p1", ["name": "Home"])
        let plain = try writer.addSection("Backlog", to: "p1")
        #expect(try section(plain).values["color"] == nil && section(plain).values["icon"] == nil)
        let styled = try writer.addSection("Waiting", to: "p1", color: "#f59e0b", icon: "hourglass")
        #expect(try section(styled)["color"] == "#f59e0b" && section(styled)["icon"] == "hourglass")

        let done = try writer.editSection(styled, name: "Waiting", color: .some(nil), icon: .some(nil))
        #expect(try section(styled)["color"].isNull && section(styled)["icon"].isNull)
        try writer.revert(done.undo)
        #expect(try section(styled)["icon"] == "hourglass")

        #expect(throws: CannotEdit.self) { try writer.editSection(styled, name: "Waiting", icon: "no-such-icon") }
        #expect(throws: CannotEdit.self) { try writer.addSection("x", to: "p1", color: "amber") }
    }

    @Test func sectionEditKeepsAnIconThisClientCantDraw() throws {
        try seed("section", "s1", ["name": "Old", "project_id": "p1", "icon": "from-the-future"])
        _ = try writer.editSection("s1", name: "New", color: .some(nil), icon: .some("from-the-future"))
        #expect(try section("s1")["icon"] == "from-the-future" && section("s1")["name"] == "New")
    }

    @Test func moveSectionStepsOnePlace() throws {
        try seed("project", "p1", ["name": "Home"])
        for (i, id) in ["s1", "s2", "s3"].enumerated() {
            try seed("section", id, ["name": .string(id), "project_id": "p1", "position": .int(Int64(i + 1) * 1000)])
        }
        _ = try writer.moveSection("s1", step: -1)
        #expect(try outbox().isEmpty)
        _ = try writer.moveSection("s1", step: 1)
        #expect(projectSections(try snapshot(store), "p1").dropFirst().map(\.name) == ["s2", "s1", "s3"])
        #expect(try written() == ["s1.position": 2500])
    }

    @Test func deleteSectionClearsOpenTasksOnly() throws {
        try seed("section", "s1", ["name": "Kitchen", "project_id": "p1"])
        try seed("task", "open", ["title": "Open", "project_id": "p1", "section_id": "s1", "completed_at": nil])
        try seed("task", "done", ["title": "Done", "project_id": "p1", "section_id": "s1", "completed_at": 5])
        try seed("task", "gone", ["title": "Gone", "project_id": "p1", "section_id": "s1", "completed_at": nil,
                                  "deleted_at": 5])
        let done = try writer.deleteSection("s1")
        #expect(try written() == ["s1.deleted_at": .int(now), "open.section_id": nil])
        #expect(Set(try outbox().map(\.ts)).count == 1)
        try writer.revert(done.undo)
        #expect(try section("s1")["deleted_at"].isNull)
        #expect(try task("open")["section_id"].string == "s1")
    }
}

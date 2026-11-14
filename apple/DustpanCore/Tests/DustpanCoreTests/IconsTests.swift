import CoreGraphics
import Foundation
import Testing
@testable import DustpanCore

// Project icons and the Theme colour. A port of tests/test_icons.py. See spec/icons.md.

@Suite struct IconCatalogueTests {
    /// The desktop's icon folder, whose files ours copy.
    static let desktop: URL = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "desktop/dustpan/icons")
    }()

    static func resource(_ file: String) throws -> URL {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/DustpanCore/Resources/icons/\(file)")
        return url
    }

    @Test(arguments: ["paths.json", "lucide.json", "catalogue.json", "LICENSE-lucide.txt"])
    func filesAreTheDesktopsCopies(_ file: String) throws {
        // The desktop's tests check these against OpenTodo's clone and Lucide's downloads.
        #expect(try Data(contentsOf: Self.resource(file)) == Data(contentsOf: Self.desktop.appending(path: file)))
    }

    @Test(.enabled(if: Vectors.fileExists("web/src/ui/icons/catalogue.json")))
    func catalogueIsThePinnedCopy() throws {
        #expect(try String(contentsOf: Self.resource("catalogue.json"), encoding: .utf8)
            == (try Vectors.read("web/src/ui/icons/catalogue.json")))
    }

    @Test func allOfLucide() {
        #expect(Icons.version == "1.48.0")
        #expect(Icons.entries.count >= 1800)
        #expect(Icons.entries.count { $0.server } == Icons.server.count)
        let names = Set(Icons.entries.map(\.name))
        #expect(names.count == Icons.entries.count)
        #expect(Icons.server.isSubset(of: names))  // OpenTodo's old names, like trash-2, stay the names written
        #expect(!names.contains("trash"))
        #expect(!Icons.offered.contains { $0.name == Icons.labelMark })
    }

    @Test func categories() throws {
        #expect(Set(Icons.entries.map(\.category)) == Set(Icons.groups.map(\.id)))
        #expect(Icons.groups.allSatisfy { Icons.known($0.symbol) })
        let group = Icons.groupOf
        // OpenTodo's own: Lucide files the briefcase under transport.
        #expect([group["briefcase"], group["house"], group["dog"]] == ["work", "home", "animals"])
        #expect([group["user-cog"], group["cat"]] == ["people", "animals"])  // Lucide's account, a user
        for id in Icons.groups.map(\.id) {
            #expect(Icons.entries.count { $0.category == id } >= 10, "\(id)")
        }
        let home = Icons.entries.filter { $0.category == "home" }.map(\.server)
        #expect(home == home.sorted { $0 && !$1 })  // OpenTodo's first in each category
    }

    @Test func knownNames() {
        for name in ["sprout", "paw-print", "briefcase", "zodiac-leo", "home"] {  // home: Lucide's old name
            #expect(Icons.known(name), "\(name)")
        }
        for name in [nil, "", "Sprout", "not-an-icon"] as [String?] {
            #expect(!Icons.known(name))
        }
        #expect(Icons.title("paw-print") == "paw print")
    }
}

/// The web app's search tests (catalogue.test.tsx), on our port.
@Suite struct IconSearchTests {
    func names(_ query: String) -> [String] { Icons.search(query).map(\.name) }

    func entry(_ name: String) throws -> IconEntry { try #require(Icons.entries.first { $0.name == name }) }

    @Test func orderMatchesTheWebApp() {
        let dog = names("dog")
        #expect(dog.first == "dog")
        #expect(dog.contains("paw-print"))
        #expect(Set(["sprout", "flower"]).isSubset(of: names("plant")))
        #expect(names("food").contains("pizza"))
        #expect(names("").count == Icons.offered.count)
        #expect(names("zzzz-no-such-icon").isEmpty)
    }

    @Test func ranks() throws {
        let dog = try entry("dog")
        #expect(["dog", "do", "og", "pet", "animals", "car"].map { Icons.rank(dog, $0) } == [0, 1, 2, 3, 4, nil])
        let devices = Icons.entries.filter { $0.category == "devices" }
        #expect(!devices.isEmpty && devices.allSatisfy { Icons.rank($0, "devices") != nil })  // the category's label
        #expect(Icons.rank(try entry("dice-5"), "gaming") == 4)
    }

    @Test func openTodoIconsWinTies() {
        let found = Icons.search("car")
        #expect(found.first?.name == "car")
        let server = found.filter { Icons.rank($0, "car") == 1 }.map(\.server)
        #expect(server == server.sorted { $0 && !$1 })
    }
}

@Suite struct IconSuggestTests {
    @Test func wholeWordsFromTheName() {
        #expect(Icons.suggest("Car").prefix(2) == ["car", "car-front"])
        #expect(!Icons.suggest("Car").contains("carrot"))
        #expect(Icons.suggest("Dog walking").first == "dog")
        #expect(Icons.suggest("Books").contains("book"))  // a plural tries its singular
        #expect(Icons.suggest("Work").contains("briefcase"))
    }

    @Test func nothingToGoOn() {
        for name in ["", "  ", "a b", "Dustpan"] {
            #expect(Icons.suggest(name).isEmpty, "\(name)")
        }
        #expect(Icons.suggest("Work stuff").count <= 8)
    }
}

@Suite struct IconPathTests {
    @Test func everyIconDrawsInsideTheGrid() throws {
        for entry in Icons.entries {
            let path = try #require(Icons.path(entry.name))
            let box = path.boundingBoxOfPath
            #expect(!path.isEmpty && box.width + box.height > 0, "\(entry.name)")  // signal-zero is one dot: h.01
            #expect(CGRect(x: -0.5, y: -0.5, width: 25, height: 25).contains(box), "\(entry.name): \(box)")
        }
        #expect(Icons.path("not-an-icon") == nil)
    }

    @Test func elements() {
        #expect(svgPath(#"<circle cx="12" cy="12" r="10" />"#).boundingBoxOfPath == CGRect(x: 2, y: 2, width: 20, height: 20))
        #expect(svgPath(#"<rect width="18" height="18" x="3" y="3" rx="2" />"#).boundingBoxOfPath
            == CGRect(x: 3, y: 3, width: 18, height: 18))
        #expect(svgPath(#"<line x1="2" x2="22" y1="12" y2="12" />"#).currentPoint == CGPoint(x: 22, y: 12))
        #expect(svgPath(#"<polyline points="22 7 13.5 15.5 8.5 10.5 2 17" />"#).currentPoint == CGPoint(x: 2, y: 17))
    }

    @Test func pathCommands() {
        func box(_ d: String) -> CGRect { svgPath(#"<path d="\#(d)" />"#).boundingBoxOfPath }
        func end(_ d: String) -> CGPoint { svgPath(#"<path d="\#(d)" />"#).currentPoint }
        // Relative moves and lines, implicit repeats, h and v, and numbers that run together.
        #expect(end("m2 3 4 4h1v-2") == CGPoint(x: 7, y: 5))
        #expect(end("M1.5.5l1-1") == CGPoint(x: 2.5, y: -0.5))
        // A sweep of 0 from left to right goes anticlockwise on screen: through the bottom, as y points down.
        let lower = box("M2 12A10 10 0 0 0 22 12")
        #expect(abs(lower.minY - 12) < 0.01 && abs(lower.maxY - 22) < 0.01)
        let upper = box("M2 12a10 10 0 0 1 20 0")
        #expect(abs(upper.minY - 2) < 0.01 && abs(upper.maxY - 12) < 0.01)
        // A radius too small for the distance grows to fit; compact flags.
        let grown = box("M0 0a1 1 0 01 4 0")
        #expect(abs(grown.minY + 2) < 0.01)
        let arcEnd = end("M0 0a1 1 0 01 4 0")
        #expect(abs(arcEnd.x - 4) < 0.001 && abs(arcEnd.y) < 0.001)
        // Smooth curves reflect the last control point; z returns to the subpath's start.
        #expect(end("M0 0c0 2 4 2 4 0s4-2 4 0") == CGPoint(x: 8, y: 0))
        #expect(end("M3 3h4z") == CGPoint(x: 3, y: 3))
    }
}

@Suite struct IconWritesTests {
    let store: Store
    let writer: Writer

    init() throws {
        store = try memoryStore()
        writer = Writer(store: store, clock: HybridClock(store: store, now: { 1_000_000 }), now: { 1_000_000 },
                        today: { Day("2026-11-09")! })
        try store.setMeta("user_id", "me")
    }

    func seed(_ id: String, _ fields: [String: JSON]) throws {
        for (name, value) in fields {
            try store.apply(Op(id: "\(id)-\(name)-1", entity: "project", entityId: id, field: name, value: value,
                               ts: 1, device: "other"))
        }
    }

    func outbox() throws -> [Op] { try store.outboxBatch(limit: 1000).map(\.op) }
    func project(_ id: String) throws -> Row { try #require(try store.rows("project")[id]) }

    @Test func addProjectWithAndWithoutAnIcon() throws {
        let withIcon = try writer.addProject("Garden", icon: "sprout")
        #expect(try project(withIcon)["icon"].string == "sprout")
        let without = try writer.addProject("Work")
        #expect(!(try outbox().contains { $0.entityId == without && $0.field == "icon" }))
        #expect(throws: CannotEdit.self) { try writer.addProject("Bad", icon: "not-an-icon") }
    }

    @Test func editSetsClearsAndUndoes() throws {
        try seed("p1", ["name": "Home", "color": "#ef4444"])
        let done = try writer.editProject("p1", ProjectEdit(icon: "house"))
        #expect(try outbox().map { [$0.field: $0.value] } == [["icon": "house"]])
        try writer.revert(done.undo)
        #expect(try project("p1")["icon"].isNull)
        _ = try writer.editProject("p1", ProjectEdit(icon: "house"))
        _ = try writer.editProject("p1", ProjectEdit(icon: .some(nil)))
        #expect(try project("p1")["icon"].isNull)
        #expect(throws: CannotEdit.self) { try writer.editProject("p1", ProjectEdit(icon: "unicorn-rainbow")) }
    }

    /// A newer client's icon survives an edit of something else here.
    @Test func anUnknownStoredIconIsKeptWhenUnchanged() throws {
        try seed("p1", ["name": "Home", "color": "#ef4444", "icon": "from-the-future"])
        _ = try writer.editProject("p1", ProjectEdit(name: "House", color: "#ef4444", icon: "from-the-future"))
        #expect(try outbox().map(\.field) == ["name"])
        #expect(try project("p1")["icon"].string == "from-the-future")
    }

    /// No colour is the "Theme" choice. The writer still picks a colour when none is asked for.
    @Test func addWithThemeOrAutoColour() throws {
        let themed = try writer.addProject("Plain", color: .some(nil))
        #expect(try project(themed)["color"].isNull)
        #expect(try outbox().contains { $0.entityId == themed && $0.field == "color" && $0.value.isNull })
        let auto = try writer.addProject("Work")
        #expect(projectColours.map(\.hex).contains(try project(auto)["color"].string ?? ""))
        for bad in ["red", "#12345"] {
            #expect(throws: CannotEdit.self) { try writer.addProject("Bad", color: bad) }
        }
    }

    @Test func editToThemeAndBackWithUndo() throws {
        try seed("p1", ["name": "Home", "color": "#ef4444"])
        let done = try writer.editProject("p1", ProjectEdit(color: .some(nil)))
        #expect(try project("p1")["color"].isNull)
        try writer.revert(done.undo)
        #expect(try project("p1")["color"].string == "#ef4444")
        #expect(throws: CannotEdit.self) { try writer.editProject("p1", ProjectEdit(color: "red")) }
    }
}

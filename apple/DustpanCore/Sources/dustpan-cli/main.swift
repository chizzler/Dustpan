// Development commands, like the desktop client's:
//   dustpan-cli sync    sync once and print what came in
//   dustpan-cli tree    print projects, sections and tasks from the local copy
import DustpanCore
import Foundation

func syncOnce() async throws {
    let store = try Store(path: try databasePath())
    let result = try await Syncer(store: store, server: Api(config: try Config.load())).run()
    print("received \(result.received) ops, cursor \(try store.meta("cursor").text)")
    if result.refused > 0 { print("\(result.refused) local changes were not accepted") }
    if result.held > 0 { print("\(result.held) changes held back by a server limit") }
}

func printTasks(_ nodes: [Node], _ depth: Int) {
    for node in nodes {
        print(String(repeating: "    ", count: depth) + "- " + (node.row["title"].string ?? ""))
        printTasks(node.children, depth + 1)
    }
}

func printProject(_ snap: Snapshot, _ projectId: String?, _ name: String, _ depth: Int) {
    print(String(repeating: "  ", count: depth) + "# \(name)")
    for section in projectSections(snap, projectId) {
        if section.id != nil { print(String(repeating: "  ", count: depth) + "  ## \(section.name)") }
        printTasks(section.tasks, section.id == nil ? depth + 1 : depth + 2)
    }
}

func tree() throws {
    let snap = try snapshot(try Store(path: try databasePath()))
    printProject(snap, nil, "Inbox", 0)
    func walk(_ nodes: [Node], _ depth: Int) {
        for node in nodes {
            printProject(snap, node.id, node.row["name"].string ?? "", depth)
            walk(node.children, depth + 1)
        }
    }
    walk(snap.projects, 0)
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "sync": try await syncOnce()
    case "tree": try tree()
    default:
        print("usage: dustpan-cli sync | tree")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("dustpan-cli: \(error)\n".utf8))
    exit(1)
}

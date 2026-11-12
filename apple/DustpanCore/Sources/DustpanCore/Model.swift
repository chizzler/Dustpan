import Foundation

// What the UI shows, derived from the store. See spec/sync.md, "Display rules".
// Nothing here writes: odd states (missing parents, cycles, stale sections)
// are resolved for display only, the same way on every device.

public struct Node: Identifiable, Hashable, Sendable {
    public let row: Row
    public var children: [Node] = []
    public var id: String { row.id }
}

public struct Section: Identifiable, Hashable, Sendable {
    public let id: String?
    public let name: String
    public let tasks: [Node]
    /// A real list: tasks are added, ordered and dropped here.
    public var isList = true
}

public struct Snapshot: Sendable {
    public var projects: [Node] = []  // top level
    public var labels: [String: Row] = [:]
    /// Open tasks by project id; nil is no project.
    public var tasksByProject: [String?: [Row]] = [:]
    public var sectionsByProject: [String: [Row]] = [:]
    /// Live tasks outside archived and deleted projects, completed too.
    public var tasks: [Row] = []
    /// Every task by id.
    public var allTasks: [String: Row] = [:]
    /// Live reminders by task id, soonest first. Ones without a time come last.
    public var remindersByTask: [String: [Row]] = [:]
    /// Live list views, in sidebar order.
    public var views: [Row] = []
    /// Live projects, archived ones too: what a filter's names can refer to.
    public var liveProjects: [Row] = []
    /// Visible projects in sidebar order, as "Parent › Child", for headings.
    public var projectPaths: [(id: String, path: String)] = []
    /// Archived projects, flat, by path: what the sidebar lists under "Archived".
    public var archivedProjects: [(row: Row, path: String)] = []
    public var prefs: [String: JSON] = [:]

    /// Live labels in sidebar order.
    public var labelsInOrder: [Row] { labels.values.sorted(by: orderLess) }

    /// "Project" or "Project › Parent task", for a task listed away from its project.
    public func place(of task: Row) -> String {
        let project = task["project_id"].string
        var place = project.flatMap { id in projectPaths.first { $0.id == id }?.path } ?? "Inbox"
        if let parent = task["parent_id"].string.flatMap({ allTasks[$0] }), isLive(parent) {
            place += " › " + (parent["title"].string ?? "")
        }
        return place
    }

    /// For running filters on day.
    public func filterContext(today: Day) -> FilterContext {
        FilterContext(today: today, tasks: Array(allTasks.values), labels: Array(labels.values), projects: liveProjects,
                      weekStart: prefs["week_start"]?.string.flatMap { weekStartPrefs[$0] } ?? 1,
                      dayStart: dayStartMinutes(prefs["day_start"] ?? .null))
    }

    public init() {}
}

/// Code-point order, as the other clients sort ids.
func bytesLess(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

func orderLess(_ a: Row, _ b: Row) -> Bool {
    let pa = a["position"].number ?? 0, pb = b["position"].number ?? 0
    return pa != pb ? pa < pb : bytesLess(a.id, b.id)
}

/// a's parent_id was written after b's: newer clock, then greater device, then greater id.
func newerParentClock(_ a: Row, _ b: Row) -> Bool {
    let ca = a.clocks["parent_id"] ?? FieldClock(ts: 0, device: "")
    let cb = b.clocks["parent_id"] ?? FieldClock(ts: 0, device: "")
    return wins(ca.ts, ca.device, cb.ts, cb.device) || (ca == cb && bytesLess(b.id, a.id))
}

/// Nest rows by parentOf(row), a parent id or nil.
///
/// A row whose parent isn't in rows is a root. In a cycle, the member whose
/// parent_id has the newest clock becomes a root and the rest hang below it.
public func buildTree(_ rows: [Row], parentOf: (Row) -> String?) -> [Node] {
    let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var parent: [String: String] = [:]
    for row in byId.values {
        if let pid = parentOf(row), pid != row.id, byId[pid] != nil { parent[row.id] = pid }
    }

    for start in byId.keys.sorted(by: bytesLess) {
        var seen: [String] = []
        var node: String? = start
        while let current = node, !seen.contains(current) {
            seen.append(current)
            node = parent[current]
        }
        if let repeated = node {
            let cycle = seen[seen.firstIndex(of: repeated)!...]
            var root = cycle.first!
            for member in cycle.dropFirst() where newerParentClock(byId[member]!, byId[root]!) {
                root = member
            }
            parent[root] = nil
        }
    }

    var children: [String: [Row]] = [:]
    var roots: [Row] = []
    for row in byId.values {
        if let pid = parent[row.id] { children[pid, default: []].append(row) } else { roots.append(row) }
    }
    func nest(_ level: [Row]) -> [Node] {
        level.sorted(by: orderLess).map { Node(row: $0, children: nest(children[$0.id] ?? [])) }
    }
    return nest(roots)
}

func isLive(_ row: Row) -> Bool { row["deleted_at"].isNull }

/// Read everything the UI needs in one pass over the store.
public func snapshot(_ store: Store) throws -> Snapshot {
    let projects = try store.rows("project")
    let tasks = try store.rows("task")
    let sections = try store.rows("section")

    let visibleProjects = projects.values.filter { isLive($0) && !$0["archived"].isTruthy }
    let visibleIds = Set(visibleProjects.map(\.id))

    var snap = Snapshot()
    snap.labels = try store.rows("label").filter { isLive($0.value) }
    snap.allTasks = tasks
    snap.tasks = tasks.values.filter { task in
        guard isLive(task) else { return false }
        guard let pid = task["project_id"].string else { return true }
        return visibleIds.contains(pid)
    }
    for task in snap.tasks where task["completed_at"].isNull {
        snap.tasksByProject[task["project_id"].string, default: []].append(task)
    }
    for section in sections.values where isLive(section) {
        if let pid = section["project_id"].string { snap.sectionsByProject[pid, default: []].append(section) }
    }
    snap.sectionsByProject = snap.sectionsByProject.mapValues { $0.sorted(by: orderLess) }
    snap.projects = buildTree(visibleProjects) { $0["parent_id"].string }
    func walk(_ nodes: [Node], _ path: [String]) {
        for node in nodes {
            let here = path + [node.row["name"].string ?? ""]
            snap.projectPaths.append((node.id, here.joined(separator: " › ")))
            walk(node.children, here)
        }
    }
    walk(snap.projects, [])
    snap.liveProjects = projects.values.filter(isLive).sorted(by: orderLess)
    snap.archivedProjects = snap.liveProjects.filter { $0["archived"].isTruthy }
        .map { ($0, projectPath($0.id, projects)) }
        .sorted { a, b in
            let pa = a.path.lowercased(), pb = b.path.lowercased()
            return pa != pb ? pa < pb : bytesLess(a.row.id, b.row.id)
        }
    snap.views = try store.rows("view").values.filter(isListView).sorted(by: viewOrderLess)
    snap.prefs = try store.rows("user_prefs")["me"]?.values ?? [:]
    for reminder in try store.rows("reminder").values where isLive(reminder) {
        if let taskId = reminder["task_id"].string { snap.remindersByTask[taskId, default: []].append(reminder) }
    }
    snap.remindersByTask = snap.remindersByTask.mapValues { rows in
        rows.sorted { a, b in
            let fa = a["fire_at"].int ?? .max, fb = b["fire_at"].int ?? .max
            return fa != fb ? fa < fb : bytesLess(a.id, b.id)
        }
    }
    return snap
}

/// "Parent › Child": the project's name after its live ancestors'. Stops at a deleted ancestor and in a cycle.
public func projectPath(_ projectId: String, _ projects: [String: Row]) -> String {
    var names: [String] = [], seen: Set<String> = [], id: String? = projectId
    while let current = id, seen.insert(current).inserted, let row = projects[current], isLive(row) {
        names.append(row["name"].string ?? "")
        id = row["parent_id"].string
    }
    return names.reversed().joined(separator: " › ")
}

/// Sections of a project, each with its task trees. "No section" first.
///
/// For the Inbox (nil): its tasks, then the planned tasks without a project.
/// Completed subtasks stay beneath an open ancestor; completed top-level tasks belong only in Completed.
/// Completed subtasks stay beneath an open ancestor until swept (cleared), after their open siblings (sinkCompleted).
/// Completed top-level tasks belong only in Completed.
public func projectSections(_ snap: Snapshot, _ projectId: String?, cleared: [String: JSON] = [:],
                            settling: [String: Bool] = [:]) -> [Section] {
    let rows = snap.tasks.filter { t in
        t["project_id"].string == projectId && (t["completed_at"].isNull || completedSubtaskVisible(t, cleared: cleared))
    }
    let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func visibleParent(_ task: Row) -> String? {
        guard let parent = task["parent_id"].string.flatMap({ byId[$0] }) else { return nil }
        if task["completed_at"].isNull && !parent["completed_at"].isNull { return nil }
        return parent.id
    }
    let roots = sinkCompleted(buildTree(rows, parentOf: visibleParent).filter { $0.row["completed_at"].isNull },
                              settling: settling)

    guard let projectId else {
        let parentOf = { (id: String) in snap.allTasks[id] }
        let inbox = roots.filter { isInboxTask($0.row, parentOf: parentOf) }
        let planned = roots.filter { !isInboxTask($0.row, parentOf: parentOf) }
        return [Section(id: nil, name: "", tasks: inbox)]
            + (planned.isEmpty ? [] : [Section(id: nil, name: "Planned, no project", tasks: planned, isList: false)])
    }
    let sections = snap.sectionsByProject[projectId] ?? []
    let known = Set(sections.map(\.id))
    var grouped: [String?: [Node]] = [:]
    for node in roots {
        let sid = node.row["section_id"].string
        grouped[sid.flatMap { known.contains($0) ? $0 : nil }, default: []].append(node)
    }
    return [Section(id: nil, name: "", tasks: grouped[nil] ?? [])]
        + sections.map { Section(id: $0.id, name: $0["name"].string ?? "", tasks: grouped[$0.id] ?? []) }
}

/// The sidebar count: open, neither parked nor deferred. For the Inbox, its own tasks.
public func countOpen(_ snap: Snapshot, _ projectId: String?, today: String) -> Int {
    let rows = snap.tasksByProject[projectId] ?? []
    if projectId == nil { return rows.count { isInboxTask($0, parentOf: { snap.allTasks[$0] }) } }
    return rows.count { $0["completed_at"].isNull && isActive($0, today: today) }
}

// MARK: - From views.py

let maxParentDepth = 64

/// A project, a do-on date, a start date, Someday or a time sector. A deadline alone doesn't place a task.
func isPlaced(_ task: Row) -> Bool {
    !task["project_id"].isNull || task["due"].isTruthy || task["start"].isTruthy || task["sector"].isTruthy
}

/// Open, live and unplaced, and so is every parent that can be found.
func isInboxTask(_ task: Row, parentOf: (String) -> Row?) -> Bool {
    if !task["completed_at"].isNull || !task["deleted_at"].isNull || isPlaced(task) { return false }
    var parentId = task["parent_id"].string
    for _ in 0..<maxParentDepth {
        guard let parent = parentId.flatMap(parentOf) else { break }
        if isPlaced(parent) { return false }
        parentId = parent["parent_id"].string
    }
    return true
}

func isSomeday(_ task: Row) -> Bool { task["start"].string == "someday" }

func isDeferred(_ task: Row, today: String) -> Bool {
    guard let start = task["start"].string, !start.isEmpty, start != "someday" else { return false }
    return start > today
}

/// Neither parked nor deferred: what the planning views and counts consider.
func isActive(_ task: Row, today: String) -> Bool { !isSomeday(task) && !isDeferred(task, today: today) }

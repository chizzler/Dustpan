import Foundation

// The Trash: deleted tasks and projects, and deleting them for good. See spec/trash.md.
// Restoring is an ordinary write (Writer.restoreTask). A permanent delete is not. Data never connected to an account
// is deleted here at once (purgeLocal). Otherwise the server removes it, and every device, this one included, drops
// it when the next sync names it in `purged`, so the request is queued and sent after a sync has pushed the outbox.

let dayMs: Int64 = 86_400_000
public let defaultTrashRetention: Int64 = 30
/// Store meta: days an item stays in the Trash, as the server last said; 0 = never.
public let trashRetentionKey = "trash_retention_days"
/// Store meta: [[entity, id]] to delete permanently once the server can be reached.
public let pendingPurgesKey = "pending_purges"

public struct TrashItem: Identifiable, Hashable, Sendable {
    public struct Target: Hashable, Sendable {
        public let entity: String  // "task" or "project"
        public let id: String
    }

    public let target: Target
    public let title: String
    public let deletedAt: Int64
    /// For tasks: their project's name, nil for the Inbox.
    public var projectName: String?
    /// For projects.
    public var color: String?
    /// Deleted with this task, and restored with it.
    public var subtasks = 0

    public var id: Target { target }
    public var isProject: Bool { target.entity == "project" }
}

/// The deleted tasks below task that went with it: same deletion time, all the way down. Safe against cycles.
func deletedWith(_ task: Row, in tasks: [String: Row]) -> [Row] {
    var children: [String: [Row]] = [:]
    for t in tasks.values {
        if let parent = t["parent_id"].string, t["deleted_at"] == task["deleted_at"] { children[parent, default: []].append(t) }
    }
    var found: [Row] = [], stack = [task.id], seen: Set = [task.id]
    while let next = stack.popLast() {
        for child in children[next] ?? [] where seen.insert(child.id).inserted {
            found.append(child)
            stack.append(child.id)
        }
    }
    return found
}

/// Deleted projects and tasks, newest deletion first.
/// A subtask deleted with its parent is folded into the parent's item. The web app lists it on its own too.
/// Tasks of a deleted project aren't deleted themselves: they come back with the project, so only it is listed.
public func trashItems(tasks: [String: Row], projects: [String: Row]) -> [TrashItem] {
    var out = projects.values.compactMap { p -> TrashItem? in
        guard let deletedAt = p["deleted_at"].int else { return nil }
        return TrashItem(target: .init(entity: "project", id: p.id), title: p["name"].string ?? "Untitled project",
                         deletedAt: deletedAt, color: p["color"].string)
    }
    let deleted = tasks.values.filter { $0["deleted_at"].int != nil }
    func parent(of task: Row) -> String? {
        guard let parent = task["parent_id"].string.flatMap({ tasks[$0] }), parent["deleted_at"] == task["deleted_at"]
        else { return nil }
        return parent.id
    }
    for node in buildTree(deleted, parentOf: parent) {
        let t = node.row
        out.append(TrashItem(target: .init(entity: "task", id: t.id), title: t["title"].string ?? "Untitled",
                             deletedAt: t["deleted_at"].int!,
                             projectName: t["project_id"].string.flatMap { projects[$0] }.map { $0["name"].string ?? "" },
                             subtasks: deletedWith(t, in: tasks).count))
    }
    return out.sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : bytesLess($0.target.id, $1.target.id) }
}

/// Whole days until the server deletes an item for good, or nil when it never does.
public func remainingDays(deletedAt: Int64, retention: Int64, now: Int64) -> Int64? {
    guard retention > 0 else { return nil }
    let left = deletedAt + retention * dayMs - now
    return max(0, left > 0 ? (left + dayMs - 1) / dayMs : 0)
}

/// The days the server keeps an item in the Trash, as it last said, or 30 until it has.
public func trashRetention(_ store: Store, connected: Bool = true) throws -> Int64 {
    guard connected else { return 0 }
    return try store.meta(trashRetentionKey).int ?? defaultTrashRetention
}

func pendingList(_ store: Store) throws -> [TrashItem.Target] {
    try (store.meta(pendingPurgesKey).array ?? []).compactMap { pair in
        guard let pair = pair.array, pair.count == 2, let entity = pair[0].string, let id = pair[1].string else { return nil }
        return TrashItem.Target(entity: entity, id: id)
    }
}

func setPending(_ store: Store, _ targets: [TrashItem.Target]) throws {
    try store.setMeta(pendingPurgesKey, .array(targets.map { [.string($0.entity), .string($0.id)] }))
}

public func pendingPurges(_ store: Store) throws -> Set<TrashItem.Target> { Set(try pendingList(store)) }

/// Ask for a permanent delete of each target. Sent by the next sync.
public func queuePurges(_ store: Store, _ targets: [TrashItem.Target]) throws {
    try store.transaction {
        var have = try pendingList(store)
        for target in targets where !have.contains(target) { have.append(target) }
        try setPending(store, have)
    }
}

/// Send the queued permanent deletes. Returns how many the server took.
///
/// Call it after a sync has pushed the outbox, so the server already has the delete.
/// A request for something restored since, or already gone, is dropped. Temporary failures keep the request
/// and throw, so the caller can show the sync error. Acknowledgements remove only that request, never ones
/// queued during a call.
func sendPurges(_ store: Store, _ server: any SyncServer) async throws -> Int {
    var sent = 0
    for target in try pendingList(store) {
        var refused: Error?
        if let row = try store.rows(target.entity)[target.id], !row["deleted_at"].isNull {
            // A server limit, or an edit made during sync, may leave its delete unsent.
            let waiting = try store.outboxBatch(limit: try store.outboxCount()).map(\.op)
                + (try heldOps(store))
            if waiting.contains(where: { $0.entity == target.entity && $0.entityId == target.id }) { continue }
            do {
                try await server.purge(entity: target.entity, id: target.id)
                sent += 1
            } catch ApiError.server(let status, let code, let message) where [403, 404].contains(status) || code == "not_deleted" {
                if status == 403 { refused = ApiError.server(status: status, code: code, message: message) }
            }
            // Offline throws too, leaving this and all later requests queued.
        }
        try store.transaction { try setPending(store, try pendingList(store).filter { $0 != target }) }
        if let refused { throw refused }
    }
    return sent
}

let projectChildren = ["section", "field", "note", "rule"]
let taskChildren = ["reminder", "comment", "attachment", "time_entry"]

/// The trashed targets with what goes with them, as OpenTodo's expandPurge has it. A missing or restored target is
/// skipped. A project takes all its tasks, its sections and its project-scoped rows. A task takes its deleted
/// descendants, even ones deleted separately, and its reminders, comments, attachments and time entries.
func expandPurge(_ store: Store, _ targets: [TrashItem.Target]) throws -> [TrashItem.Target] {
    var cache: [String: [String: Row]] = [:]
    func rows(_ entity: String) throws -> [String: Row] {
        if let have = cache[entity] { return have }
        let fresh = try store.rows(entity)
        cache[entity] = fresh
        return fresh
    }
    let sortedTasks = try rows("task").values.sorted { $0.id < $1.id }
    var seen: Set<TrashItem.Target> = [], out: [TrashItem.Target] = [], tasks: [String] = []
    func add(_ entity: String, _ id: String) -> Bool {
        let target = TrashItem.Target(entity: entity, id: id)
        guard seen.insert(target).inserted else { return false }
        out.append(target)
        return true
    }
    for target in targets where ["task", "project", "note"].contains(target.entity) {
        guard let row = try rows(target.entity)[target.id], !row["deleted_at"].isNull,
              add(target.entity, target.id) else { continue }
        if target.entity == "task" { tasks.append(target.id) }
        guard target.entity == "project" else { continue }
        for task in sortedTasks where task["project_id"].string == target.id && add("task", task.id) {
            tasks.append(task.id)
        }
        for child in projectChildren {
            for row in try rows(child).values.sorted(by: { $0.id < $1.id }) where row["project_id"].string == target.id {
                _ = add(child, row.id)
            }
        }
        if try rows("project_prefs")[target.id] != nil { _ = add("project_prefs", target.id) }
    }
    var deletedChildren: [String: [String]] = [:]
    for task in sortedTasks where !task["deleted_at"].isNull {
        if let parent = task["parent_id"].string { deletedChildren[parent, default: []].append(task.id) }
    }
    var i = 0
    while i < tasks.count {
        for child in deletedChildren[tasks[i]] ?? [] where add("task", child) { tasks.append(child) }
        i += 1
    }
    let taskSet = Set(tasks)
    if !taskSet.isEmpty {
        for child in taskChildren {
            for row in try rows(child).values.sorted(by: { $0.id < $1.id })
            where row["task_id"].string.map(taskSet.contains) == true {
                _ = add(child, row.id)
            }
        }
    }
    return out
}

/// Delete trashed targets for good here, with what goes with them, in one transaction. Returns how many entities went.
@discardableResult
public func purgeLocal(_ store: Store, _ targets: [TrashItem.Target]) throws -> Int {
    try store.transaction {
        let expanded = try expandPurge(store, targets)
        let gone = Set(expanded)
        for target in expanded { try store.purge(entity: target.entity, id: target.id) }
        let held = try heldOps(store)
        if !held.isEmpty {
            try store.setMeta("held_ops", .array(held.filter {
                !gone.contains(.init(entity: $0.entity, id: $0.entityId))
            }.map(\.json)))
        }
        let drop = gone.union(targets)
        try setPending(store, try pendingList(store).filter { !drop.contains($0) })
        return expanded.count
    }
}

/// How Delete for Good goes.
public enum PurgeMode {
    /// At once: the data here has never been on a server.
    case local
    /// Through the server, on the next sync.
    case server
    /// Through the server, once reconnected: it may hold a copy, which would come back.
    case onReconnect
}

public func purgeMode(_ store: Store, connected: Bool) throws -> PurgeMode {
    if connected { return .server }
    return isLocalUser(try store.meta("user_id").string) ? .local : .onReconnect
}

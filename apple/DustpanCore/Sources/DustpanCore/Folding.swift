// Folding a task's subtasks away in project and Inbox lists. A port of the desktop's model.py.
// Kept on this device and never synced, as the web app keeps opentodo.collapsed. See spec/folding.md.

/// The meta key: ids of tasks whose subtasks are folded away.
public let foldedTasksKey = "folded_tasks"

/// The folded ids once taskId is folded or unfolded, without ids of tasks that are gone.
/// Kept in the order they were folded, so the stored list changes little.
public func foldedAfter(_ folded: [String], _ taskId: String, fold: Bool, tasks: [String: Row]) -> [String] {
    let kept = folded.filter { tasks[$0] != nil && $0 != taskId }
    return fold && tasks[taskId] != nil ? kept + [taskId] : kept
}

/// The folded ids with parentId and every task above it unfolded: a task put under parentId stays in sight.
public func unfoldedDownTo(_ folded: [String], _ parentId: String?, tasks: [String: Row]) -> [String] {
    var above: Set<String> = []
    var next = parentId
    // A cycle in the data ends the walk.
    while let id = next, above.insert(id).inserted {
        next = tasks[id]?["parent_id"].string
    }
    return folded.filter { !above.contains($0) }
}

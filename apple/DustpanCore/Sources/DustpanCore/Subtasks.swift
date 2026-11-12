import Foundation

// Completed subtasks in lists: kept beneath an open parent until swept, sunk below their open siblings, and counted
// in the parent's progress. A port of model.py's completed_subtask_visible, progress_map, is_ready, ready_parent
// and sink_completed. See spec/progress.md and spec/sync.md's display rules.

/// Store meta, per device: completed subtasks the broom swept from project lists,
/// as {task id: [completed_at, parent_id]}. Reopening or moving one brings it back.
public let clearedSubtasksKey = "cleared_completed_subtasks"

/// A completed subtask the broom hasn't swept since it was last completed or moved.
public func completedSubtaskVisible(_ task: Row, cleared: [String: JSON]) -> Bool {
    !task["completed_at"].isNull && task["parent_id"].isTruthy
        && cleared[task.id] != .array([task["completed_at"], task["parent_id"]])
}

/// The broom's record for completed tasks, each with its completed descendants, added to cleared.
public func sweeping(_ tasks: [Row], all: [String: Row], into cleared: [String: JSON]) -> [String: JSON] {
    var cleared = cleared
    for task in tasks where !task["completed_at"].isNull {
        for row in [task] + descendants(of: task.id, in: all) where !row["completed_at"].isNull {
            cleared[row.id] = .array([row["completed_at"], row["parent_id"]])
        }
    }
    return cleared
}

/// A parent's progress over its direct, live subtasks. swept: done ones the broom hid on this device, still counted.
public struct SubtaskProgress: Equatable, Sendable {
    public var done = 0
    public var total = 0
    public var swept = 0

    public init(done: Int = 0, total: Int = 0, swept: Int = 0) {
        (self.done, self.total, self.swept) = (done, total, swept)
    }

    /// Upstream's words: "3 of 5 subtasks completed", with " (2 swept)".
    public var text: String {
        "\(done) of \(total) subtask\(total > 1 ? "s" : "") completed" + (swept > 0 ? " (\(swept) swept)" : "")
    }
}

/// Each parent's progress, the web app's progressMap. Parents without live subtasks are absent.
public func progressMap(_ tasks: some Sequence<Row>, cleared: [String: JSON] = [:]) -> [String: SubtaskProgress] {
    var map: [String: SubtaskProgress] = [:]
    for task in tasks {
        guard let parent = task["parent_id"].string, isLive(task) else { continue }
        map[parent, default: SubtaskProgress()].total += 1
        if !task["completed_at"].isNull {
            map[parent]!.done += 1
            if !completedSubtaskVisible(task, cleared: cleared) { map[parent]!.swept += 1 }
        }
    }
    return map
}

/// An open, live parent whose live subtasks are all done: ready to be offered for completion.
/// Nothing completes it by itself (upstream design D5).
public func isReady(_ parent: Row?, tasks: [String: Row]) -> Bool {
    guard let parent, isLive(parent), parent["completed_at"].isNull else { return false }
    let children = tasks.values.filter { $0["parent_id"].string == parent.id && isLive($0) }
    return !children.isEmpty && children.allSatisfy { !$0["completed_at"].isNull }
}

/// After taskId was completed: its parent if that is now ready.
public func readyParent(_ taskId: String, tasks: [String: Row]) -> Row? {
    let parent = tasks[taskId]?["parent_id"].string.flatMap { tasks[$0] }
    return isReady(parent, tasks: tasks) ? parent : nil
}

/// Each task's completed subtasks after its open ones, both in their own order. Display only: positions don't change.
/// settling: tasks just ticked or reopened, with whether they sort as done, keeping their place until the window
/// lets them settle.
public func sinkCompleted(_ nodes: [Node], settling: [String: Bool] = [:]) -> [Node] {
    nodes.map { node in
        func done(_ n: Node) -> Bool { settling[n.id] ?? !n.row["completed_at"].isNull }
        var node = node
        let children = sinkCompleted(node.children, settling: settling)
        node.children = children.filter { !done($0) } + children.filter(done)
        return node
    }
}

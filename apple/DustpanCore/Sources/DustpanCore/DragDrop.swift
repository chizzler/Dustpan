import Foundation

// Drag and drop rules: where a drop lands, and what to say afterwards. A port of dragdrop.py. No UI here.
// See spec/dragdrop.md. A list hands in its rows as Slots and the pointer as a hit, a zone and a level;
// resolveDrop returns the Drop to show and write. Writer.drop turns a target into one batch.

/// A place in a project's (or the Inbox's) list: under parentId, or at the top level of sectionId.
/// before or after names a sibling; neither means the end of the list.
public struct Placement: Hashable, Sendable {
    public var projectId: String?
    public var sectionId: String?
    public var parentId: String?
    public var before: String?
    public var after: String?

    public init(_ projectId: String?, _ sectionId: String?, parent parentId: String? = nil,
                before: String? = nil, after: String? = nil) {
        (self.projectId, self.sectionId, self.parentId, self.before, self.after) =
            (projectId, sectionId, parentId, before, after)
    }
}

/// What a drop writes.
public enum DropTarget: Hashable, Sendable {
    /// A place in a list.
    case place(Placement)
    /// The end of a project's list, out of any section and parent. Nil is the Inbox.
    case project(String?)
    /// Due on that day, keeping any time and zone.
    case day(Day)
    /// The label added to the task's own. Its place, project and dates stay.
    case label(String)
}

/// A task row in display order: its depth in the tree and its parent.
public struct Slot: Hashable, Sendable {
    public let id: String
    public let depth: Int
    public let parentId: String?

    public init(_ id: String, _ depth: Int, _ parentId: String? = nil) {
        (self.id, self.depth, self.parentId) = (id, depth, parentId)
    }
}

public enum Zone: Sendable { case before, inside, after }

/// What the pointer is over in one list.
public enum ListHit: Sendable {
    /// The list's heading.
    case head
    /// Past its last row: the Add field.
    case end
    /// rows[index], in a zone.
    case row(Int, Zone)
}

/// A resolved drop: the target, and how to show it.
///
/// ring: the row to ring for a drop inside it. Otherwise a line at depth, below the row prev
/// (or above the row next, or at the list's end when it's empty).
public struct Drop: Hashable, Sendable {
    public var target: DropTarget
    public var ring: String?
    public var prev: String?
    public var next: String?
    public var depth = 0
}

/// The zone of a row for a pointer y points below its top. OpenTodo's listDrop.dropZone.
/// With nesting, the top and bottom quarters place before and after and the middle half nests inside.
/// Without it, the halves.
public func dropZone(_ y: Double, height: Double, inside: Bool = true) -> Zone {
    let f = height > 0 ? y / height : 0
    if !inside { return f < 0.5 ? .before : .after }
    return f < 0.25 ? .before : f > 0.75 ? .after : .inside
}

/// The tree level a dragged row's left edge, x points from the list's left, points at.
public func dropLevel(_ x: Double, indent: Double) -> Int { Int((x / indent).rounded(.toNearestOrEven)) }

/// rows minus taskId and everything under it, and the index where it was (nil when absent).
func withoutSubtree(_ rows: [Slot], _ taskId: String) -> ([Slot], Int?) {
    var kept: [Slot] = [], at: Int?, skip: Int?
    for slot in rows {
        if let depth = skip, slot.depth > depth { continue }
        skip = nil
        if slot.id == taskId {
            (at, skip) = (kept.count, slot.depth)
            continue
        }
        kept.append(slot)
    }
    return (kept, at)
}

/// The drop for a pointer over one list.
///
/// rows: the list's Slots in display order. depth: the level the pointer picks. moving: the dragged task's id.
/// A hit on the dragged task or its subtree means the gap it left, so dragging sideways in place
/// changes its level.
public func resolveDrop(_ rows: [Slot], projectId: String?, sectionId: String?, hit: ListHit, depth: Int,
                        moving: String) -> Drop {
    let (kept, at) = withoutSubtree(rows, moving)
    let gap: Int
    switch hit {
    case .head: gap = 0
    case .end: gap = kept.count
    case .row(let index, let zone):
        let slot = rows[index]
        if let i = kept.firstIndex(of: slot) {
            if zone == .inside {
                return Drop(target: .place(Placement(projectId, sectionId, parent: slot.id)), ring: slot.id)
            }
            gap = i + (zone == .after ? 1 : 0)
        } else {
            gap = at ?? kept.count
        }
    }
    return dropAtGap(kept, projectId: projectId, sectionId: sectionId, gap: gap, depth: depth)
}

/// The drop into the gap before rows[gap], at the level depth picks.
///
/// The level is held between the row below's depth (it can't be orphaned) and the row above's depth.
/// Below an open parent that range is just its children's level: the top of its subtasks.
func dropAtGap(_ rows: [Slot], projectId: String?, sectionId: String?, gap: Int, depth: Int) -> Drop {
    let prev = gap > 0 ? rows[gap - 1] : nil
    let next = gap < rows.count ? rows[gap] : nil
    let low = next?.depth ?? 0
    let depth = max(low, min(depth, max(prev?.depth ?? 0, low)))
    let target: Placement
    if let next, depth == next.depth {
        target = Placement(projectId, sectionId, parent: next.parentId, before: next.id)
    } else if var anchor = prev {
        // After the ancestor of prev (or prev itself) that sits at this level.
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while anchor.depth > depth, let up = anchor.parentId.flatMap({ byId[$0] }) { anchor = up }
        target = Placement(projectId, sectionId, parent: anchor.parentId, after: anchor.id)
    } else {
        target = Placement(projectId, sectionId)
    }
    return Drop(target: .place(target), prev: prev?.id, next: next?.id, depth: depth)
}

/// The toast after a drop. names maps task, section, project and label ids to titles and names.
public func describeDrop(_ target: DropTarget, task: Row, names: [String: String],
                         dayText: (Day) -> String) -> String {
    switch target {
    case .day(let day): return "Due " + dayText(day)
    case .project(let id): return "Moved to " + (id.flatMap { names[$0] } ?? "Inbox")
    case .label(let id): return "Added " + (names[id] ?? "the label")
    case .place(let place):
        let parent = task["parent_id"].string
        if let to = place.parentId, to != parent { return "Moved under “\(names[to] ?? "a task")”" }
        if place.projectId != task["project_id"].string {
            return "Moved to " + (place.projectId.flatMap { names[$0] } ?? "Inbox")
        }
        if place.parentId == nil, let parent { return "Moved out of “\(names[parent] ?? "its parent")”" }
        if place.parentId == nil && place.sectionId != task["section_id"].string {
            return "Moved to " + (place.sectionId.flatMap { names[$0] } ?? "No section")
        }
        return "Order changed"
    }
}

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
    /// The calendar's grid: due on that day at minutes from midnight, a floating time.
    /// Nil minutes is the day's Unscheduled lane: the date, no time.
    case slot(Day, minutes: Int?)
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

/// The drop for an outline view's proposal: under parent (nil is the top level), before the open row before,
/// or at the end of parent's children when before is nil. inside: on parent itself, as its last subtask.
/// As with a pointer, the dragged subtree stands for the gap it left, and nothing goes under it. Nil when it can't go there.
public func resolveDrop(_ rows: [Slot], projectId: String?, sectionId: String?, parent: String?, before: String?,
                        inside: Bool = false, moving: String) -> Drop? {
    let (kept, at) = withoutSubtree(rows, moving)
    var (depth, start) = (0, 0)
    if let parent {
        guard let p = kept.firstIndex(where: { $0.id == parent }) else { return nil }
        let hasChildren = p + 1 < kept.count && kept[p + 1].depth > kept[p].depth
        if inside || !hasChildren {
            return Drop(target: .place(Placement(projectId, sectionId, parent: parent)), ring: parent)
        }
        (depth, start) = (kept[p].depth + 1, p + 1)
    }
    let gap: Int
    if let before, let i = kept.firstIndex(where: { $0.id == before }) {
        gap = i
    } else if let before, rows.contains(where: { $0.id == before }) {
        gap = at ?? kept.count
    } else {
        gap = kept[start...].firstIndex { $0.depth < depth } ?? kept.count
    }
    return dropAtGap(kept, projectId: projectId, sectionId: sectionId, gap: gap, depth: depth)
}

/// True when drop would leave moving where it is: the gap it left, at its own level. Such a spot shows nothing.
public func leavesInPlace(_ drop: Drop, _ rows: [Slot], moving: String) -> Bool {
    let (kept, at) = withoutSubtree(rows, moving)
    guard drop.ring == nil, let at, let slot = rows.first(where: { $0.id == moving }) else { return false }
    return drop.depth == slot.depth && drop.prev == (at > 0 ? kept[at - 1].id : nil)
        && drop.next == (at < kept.count ? kept[at].id : nil)
}

/// A move by key or menu, without a pointer.
public enum Nudge: CaseIterable, Sendable { case up, down, top, bottom, indent, outdent }

/// The Placement a keyboard move gives a task in one list, or nil when it can't go that way.
///
/// Up, down, top and bottom stay among its siblings, as the web app's Alt+arrows do. Indent makes it the last
/// subtask of the sibling above. Outdent puts it right after its old parent, where dragging it left would.
public func nudge(_ rows: [Slot], projectId: String?, sectionId: String?, taskId: String, _ move: Nudge) -> Placement? {
    guard let slot = rows.first(where: { $0.id == taskId }) else { return nil }
    let siblings = rows.filter { $0.parentId == slot.parentId && $0.depth == slot.depth }
    guard let i = siblings.firstIndex(of: slot) else { return nil }
    let last = siblings.count - 1
    func place(_ parent: String? = slot.parentId, before: String? = nil, after: String? = nil) -> Placement {
        Placement(projectId, sectionId, parent: parent, before: before, after: after)
    }
    switch move {
    case .up where i > 0: return place(before: siblings[i - 1].id)
    case .down where i < last: return place(after: siblings[i + 1].id)
    case .top where i > 0: return place(before: siblings[0].id)
    case .bottom where i < last: return place(after: siblings[last].id)
    case .indent where i > 0: return place(siblings[i - 1].id)
    case .outdent:
        guard let parent = rows.first(where: { $0.id == slot.parentId }) else { return nil }
        return place(parent.parentId, after: parent.id)
    default: return nil
    }
}

/// The open rows of a task tree in display order, as Slots. Completed rows hold only completed children.
/// A folded task's subtasks are left out, so drops and moves treat it as a leaf.
public func openSlots(_ nodes: [Node], depth: Int = 0, parent: String? = nil, folded: Set<String> = []) -> [Slot] {
    nodes.filter { $0.row["completed_at"].isNull }.flatMap { node in
        [Slot(node.id, depth, parent)]
            + (folded.contains(node.id) ? [] : openSlots(node.children, depth: depth + 1, parent: node.id, folded: folded))
    }
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
    case .slot(let day, let minutes): return "Due " + dayText(day) + (minutes.map { " at " + hhmm($0) } ?? ", no time")
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

// MARK: - In the sidebar

/// Where a dragged sidebar project lands: under parentId (nil is the top level), right before or after a sibling,
/// or last when neither is named.
public struct ItemPlace: Hashable, Sendable {
    public var parentId: String?
    public var before: String?
    public var after: String?

    public init(_ parentId: String?, before: String? = nil, after: String? = nil) {
        (self.parentId, self.before, self.after) = (parentId, before, after)
    }
}

/// The ItemPlace for a drop on a sidebar row, or nil.
///
/// children: the row's shown children, in order. zone: before or after it, or inside to nest.
/// below: the ids under the dragged item. It can't land on itself or inside its own subtree.
/// After a row whose children are shown means above its first child, where the line is drawn.
public func placeItem(_ rowId: String, parent rowParent: String?, children: [String], zone: Zone, moving: String,
                      below: Set<String> = []) -> ItemPlace? {
    if rowId == moving || below.contains(rowId) { return nil }
    switch zone {
    case .inside: return ItemPlace(rowId)
    case .after where !children.isEmpty: return ItemPlace(rowId, before: children.first { $0 != moving })
    case .after: return ItemPlace(rowParent, after: rowId)
    case .before: return ItemPlace(rowParent, before: rowId)
    }
}

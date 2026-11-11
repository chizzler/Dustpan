import AppKit
import DustpanCore
import SwiftUI
import UniformTypeIdentifiers

// Drag and drop in the window: sources, targets and what they show. The rules are in DustpanCore's DragDrop.swift.
// See spec/dragdrop.md and the Mac guide. The delegates stay thin: they turn a pointer into a Drop and hand it to the model.

/// One level of nesting in a task list, in points.
let indentWidth: Double = 24

/// The task drag in progress. grabX is where the pointer held the row, from its indented left edge.
struct TaskDrag: Equatable {
    let taskId: String
    let grabX: Double
}

/// A sidebar project being dragged to reorder or nest it. below: the projects under it.
struct ProjectDrag: Equatable {
    let projectId: String
    let below: Set<String>
    /// Where it is now: its parent and the siblings either side.
    var parentId: String?
    var prev: String?
    var next: String?

    /// False when a drop would leave it where it is.
    func moves(to place: ItemPlace) -> Bool {
        guard place.parentId == parentId else { return true }
        if let before = place.before { return before != next }
        if let after = place.after { return after != prev }
        return next != nil
    }
}

/// A project row as a project drop sees it: its parent in the tree and its shown sub-projects, and for its marks,
/// its depth and the row below it.
struct ProjectSpot {
    let id: String
    let parentId: String?
    let children: [String]
    var depth = 0
    var first = false
    var next: (id: String, depth: Int)?
    var key: String { "project:\(id)" }
}

/// A sidebar project's indent per level, and the room its disclosure arrow takes.
let projectIndent = 12.0
let projectArrowWidth = 14.0

/// Where a project row's label starts, at a depth.
func projectLabelX(_ depth: Int) -> Double { Double(depth) * projectIndent + projectArrowWidth + 2 }

/// What the window shows for the drop under the pointer.
enum DropMark: Equatable {
    /// A line or ring in the list keyed list.
    case list(String, Drop)
    /// A sidebar row or heading that takes the drop, by its key.
    case target(String)
    /// A line above or below a sidebar row, or a ring inside it, for a project drag.
    case item(String, Zone)
}

/// One project or Inbox list as the pointer sees it.
struct DropList {
    let key: String
    let projectId: String?
    let sectionId: String?
    let slots: [Slot]

    init(projectId: String?, sectionId: String?, slots: [Slot]) {
        (self.projectId, self.sectionId, self.slots) = (projectId, sectionId, slots)
        key = "\(projectId ?? "inbox")/\(sectionId ?? "")"
    }

    func resolve(_ hit: ListHit, x: Double, drag: TaskDrag) -> Drop {
        resolveDrop(slots, projectId: projectId, sectionId: sectionId, hit: hit,
                    depth: dropLevel(x - drag.grabX, indent: indentWidth), moving: drag.taskId)
    }

    func nudge(_ taskId: String, _ move: Nudge) -> Placement? {
        DustpanCore.nudge(slots, projectId: projectId, sectionId: sectionId, taskId: taskId, move)
    }
}

/// A row, a heading or the Add field of a list: hit decides what the pointer is over from its local y.
struct ListDrop: DropDelegate {
    let model: AppModel
    let list: DropList
    /// The row's frame in the window.
    let frame: CGRect
    let hit: (_ y: Double) -> ListHit

    /// Nil in the List's margin left of the row, and where the task already is.
    private func found(_ info: DropInfo) -> Drop? {
        let local = pointer(in: frame) ?? info.location
        guard local.x >= 0, let drag = model.drag else { return nil }
        let drop = list.resolve(hit(local.y), x: local.x, drag: drag)
        return leavesInPlace(drop, list.slots, moving: drag.taskId) ? nil : drop
    }

    func validateDrop(info: DropInfo) -> Bool { model.drag != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let drop = found(info) else {
            model.unmark()
            return DropProposal(operation: .forbidden)
        }
        model.mark(.list(list.key, drop))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.unmark() }

    func performDrop(info: DropInfo) -> Bool {
        defer { model.endDrag() }
        guard let drag = model.drag, let drop = found(info) else { return false }
        model.drop(drag.taskId, on: drop.target)
        return true
    }
}

/// A sidebar row or a day heading: one target for the whole of it. Holding a drag over one with a page opens it.
struct TargetDrop: DropDelegate {
    let model: AppModel
    let key: String
    let target: DropTarget
    var page: Page?

    func validateDrop(info: DropInfo) -> Bool { model.drag != nil }

    func dropEntered(info: DropInfo) {
        guard model.drag != nil else { return }
        model.mark(.target(key))
        if let page { model.springLoad(page, from: key) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.drag != nil else { return DropProposal(operation: .forbidden) }
        model.mark(.target(key))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.unmark() }

    func performDrop(info: DropInfo) -> Bool {
        defer { model.endDrag() }
        guard let drag = model.drag else { return false }
        model.drop(drag.taskId, on: target)
        return true
    }
}

/// A project row in the sidebar: a task dropped on it moves there; a project dropped on it goes before, after
/// or inside it, by the zone of the row the pointer is in.
struct ProjectDrop: DropDelegate {
    let model: AppModel
    let spot: ProjectSpot
    /// The row's frame in the window.
    let frame: CGRect

    private var taskDrop: TargetDrop {
        TargetDrop(model: model, key: spot.key, target: .project(spot.id), page: .project(spot.id))
    }

    private func found(_ info: DropInfo) -> (zone: Zone, place: ItemPlace)? {
        guard let drag = model.projectDrag else { return nil }
        let local = pointer(in: frame) ?? info.location
        // In the List's margin left of the row, the List would draw its own highlight: not a target.
        guard local.x >= 0 else { return nil }
        let zone = dropZone(local.y, height: frame.height)
        // A place where it already is shows nothing: dropping there would change nothing.
        return placeItem(spot.id, parent: spot.parentId, children: spot.children, zone: zone,
                         moving: drag.projectId, below: drag.below).flatMap { drag.moves(to: $0) ? (zone, $0) : nil }
    }

    func validateDrop(info: DropInfo) -> Bool { model.projectDrag != nil || taskDrop.validateDrop(info: info) }

    func dropEntered(info: DropInfo) {
        if model.projectDrag == nil { taskDrop.dropEntered(info: info) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.projectDrag != nil else { return taskDrop.dropUpdated(info: info) }
        guard let found = found(info) else {
            model.unmark()
            return DropProposal(operation: .forbidden)
        }
        model.mark(.item(spot.key, found.zone))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.unmark() }

    func performDrop(info: DropInfo) -> Bool {
        guard let drag = model.projectDrag else { return taskDrop.performDrop(info: info) }
        defer { model.endDrag() }
        guard let found = found(info) else { return false }
        model.placeProject(drag.projectId, at: found.place)
        return true
    }
}

/// The pointer in a view's own coordinates, from the view's frame in the window. DropInfo's location can't be used
/// for this: in the List's margins beside a row, SwiftUI gives it in the List's coordinates.
@MainActor func pointer(in frame: CGRect) -> CGPoint? {
    guard frame != .zero, let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else {
        return nil
    }
    let p = content.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    return CGPoint(x: p.x - frame.minX, y: (content.isFlipped ? p.y : content.bounds.height - p.y) - frame.minY)
}

extension View {
    /// The whole row, edge to edge, takes the pointer: the list's own vertical row insets become padding inside it.
    /// In an inset, the List shows its own "drop on this row" highlight and the row's drop target sees the pointer
    /// outside itself.
    func fullRowDropArea() -> some View {
        padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .listRowInsets(.vertical, 0)
    }

    /// A sidebar row's whole height takes the pointer. The row itself needs `.listRowInsets(.vertical, 0)`:
    /// the sidebar reads row insets only on the row's outermost view, and it keeps its own row height, which
    /// this fills. In an inset, the drop gets a meaningless location and the List shows its own highlight.
    func sidebarDropArea() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(.rect)
    }

    /// A sidebar project row: dragged to reorder or nest it, and a target for tasks and other projects.
    func projectRow(_ spot: ProjectSpot, name: String) -> some View {
        modifier(ProjectRowModifier(spot: spot, name: name))
    }

    /// Let an open task's row be dragged. Remembers where the pointer holds it.
    /// The whole row width drags, so a press-and-drag never selects the rows it crosses. indent: its nesting.
    func taskDrag(_ task: Row, subtasks: Int = 0, indent: Double = 0) -> some View {
        modifier(TaskDragSource(task: task, subtasks: subtasks, indent: indent))
    }

    /// The row of a task just dropped flashes for 700 ms.
    func flashes(_ taskId: String) -> some View { modifier(Flash(taskId: taskId)) }

    /// A sidebar row or heading that takes a task drop, highlighted while it would.
    func taskDrop(_ key: String, _ target: DropTarget, opens page: Page? = nil) -> some View {
        modifier(TargetDropModifier(key: key, target: target, page: page))
    }
}

private struct TaskDragSource: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: Row
    let subtasks: Int
    let indent: Double

    func body(content: Content) -> some View {
        let row = content
            .padding(.leading, indent)
            .fullRowDropArea()
        if task["completed_at"].isNull {
            row
                .onContinuousHover { phase in
                    if case .active(let point) = phase { model.hoverX = point.x - indent }
                }
                // draggable, not onDrag: in a List, onDrag leaves the rows swallowing clicks after a drag (macOS 27).
                .draggable(begin()) {
                    DragPill(title: task["title"].string ?? "", subtasks: subtasks)
                }
                .opacity(model.drag?.taskId == task.id ? 0.4 : 1)
        } else {
            row
        }
    }

    /// The drag's payload. SwiftUI asks for it as the drag begins, more than once.
    private func begin() -> String {
        if model.drag?.taskId != task.id {
            model.startDrag(task.id, grabX: model.hoverX)
            endsAfterMouseUp(model)
        }
        return task.id
    }
}

/// A drop ends its drag. A drag let go anywhere else ends a moment after the mouse button is up: not at once,
/// as the drop can arrive after mouse-up, and a drop that finds no drag is refused and slides back.
/// (onDragSessionUpdated would say when, but doesn't fire for a List row's draggable, macOS 27.)
@MainActor private func endsAfterMouseUp(_ model: AppModel) {
    Task {
        while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))
        // Pressed again: another drag may have begun.
        if NSEvent.pressedMouseButtons & 1 == 0 { model.endDrag() }
    }
}

private struct ProjectRowModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let spot: ProjectSpot
    let name: String
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .sidebarDropArea()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .draggable(begin()) {
                DragPill(title: name, subtasks: 0)
            }
            .opacity(model.projectDrag?.projectId == spot.id ? 0.4 : 1)
            .onDrop(of: [.text], delegate: ProjectDrop(model: model, spot: spot, frame: frame))
            .background {
                let mark = EdgeInsets(top: 1, leading: projectLabelX(spot.depth) - 4, bottom: 1, trailing: 1)
                if model.dropMark == .target(spot.key) {
                    RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.25)).padding(mark)
                } else if model.dropMark == .item(spot.key, .inside) {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.tint, lineWidth: 2).padding(mark)
                }
            }
            // One line per gap, at the level the project lands on: "before" the row below draws here, as "after".
            .overlay(alignment: .topLeading) {
                if spot.first, model.dropMark == .item(spot.key, .before) { line(spot.depth) }
            }
            .overlay(alignment: .bottomLeading) {
                if model.dropMark == .item(spot.key, .after) {
                    line(spot.children.isEmpty ? spot.depth : spot.depth + 1)
                } else if let next = spot.next, model.dropMark == .item("project:\(next.id)", .before) {
                    line(next.depth)
                }
            }
    }

    private func line(_ depth: Int) -> some View {
        DropLine(depth: 0).padding(.leading, projectLabelX(depth))
    }

    /// The drag's payload, as for tasks.
    private func begin() -> String {
        if model.projectDrag?.projectId != spot.id {
            model.startProjectDrag(spot.id)
            endsAfterMouseUp(model)
        }
        return spot.key
    }
}

private struct Flash: ViewModifier {
    @Environment(AppModel.self) private var model
    let taskId: String

    func body(content: Content) -> some View {
        content
            .background {
                if model.flash == taskId {
                    RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.2)).padding(-2)
                }
            }
            .animation(.easeOut(duration: 0.3), value: model.flash == taskId)
    }
}

private struct TargetDropModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let key: String
    let target: DropTarget
    let page: Page?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onDrop(of: [.text], delegate: TargetDrop(model: model, key: key, target: target, page: page))
            .background {
                if model.dropMark == .target(key) {
                    RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.25)).padding(DropLine.rowMark)
                }
            }
    }
}

/// The drag preview: the title in a pill, with "+3" for the subtasks that travel with it.
struct DragPill: View {
    let title: String
    let subtasks: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            if subtasks > 0 { Text("+\(subtasks)").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: .capsule)
    }
}

/// The drop line: 2 points in the accent colour with a dot at its start, indented to the level the task lands on.
/// 6 points tall, so at a task row's edge it stays inside the row's padding: the next row would draw over
/// anything that crossed the boundary. Not shown with the nest ring, which already says where the task goes.
struct DropLine: View {
    let depth: Int
    /// Where a sidebar row's ring or fill sits: inside the row, so it isn't clipped, and just left of its icon.
    static let rowMark = EdgeInsets(top: 1, leading: -4, bottom: 1, trailing: 1)

    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(.tint, lineWidth: 2).frame(width: 6, height: 6)
            Rectangle().fill(.tint).frame(height: 2)
        }
        .padding(.leading, Double(depth) * indentWidth - 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

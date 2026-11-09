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
}

/// A project row as a project drop sees it: its parent in the tree and its shown sub-projects.
struct ProjectSpot {
    let id: String
    let parentId: String?
    let children: [String]
    var key: String { "project:\(id)" }
}

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
}

/// A row, a heading or the Add field of a list: hit decides what the pointer is over from its local y.
struct ListDrop: DropDelegate {
    let model: AppModel
    let list: DropList
    let hit: (_ y: Double) -> ListHit

    private func found(_ info: DropInfo) -> Drop? {
        model.drag.map { list.resolve(hit(info.location.y), x: info.location.x, drag: $0) }
    }

    func validateDrop(info: DropInfo) -> Bool { model.drag != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let drop = found(info) else { return DropProposal(operation: .forbidden) }
        model.mark(.list(list.key, drop))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.unmark() }

    func performDrop(info: DropInfo) -> Bool {
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
        model.mark(.target(key))
        if let page { model.springLoad(page, from: key) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.mark(.target(key))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.unmark() }

    func performDrop(info: DropInfo) -> Bool {
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
    let height: Double

    private var taskDrop: TargetDrop {
        TargetDrop(model: model, key: spot.key, target: .project(spot.id), page: .project(spot.id))
    }

    private func found(_ info: DropInfo) -> (zone: Zone, place: ItemPlace)? {
        guard let drag = model.projectDrag else { return nil }
        let zone = dropZone(info.location.y, height: height)
        return placeItem(spot.id, parent: spot.parentId, children: spot.children, zone: zone,
                         moving: drag.projectId, below: drag.below).map { (zone, $0) }
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
        guard let found = found(info) else { return false }
        model.placeProject(drag.projectId, at: found.place)
        return true
    }
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
            endsOnMouseUp(model)
        }
        return task.id
    }
}

/// A drag is over when the mouse button is up.
@MainActor private func endsOnMouseUp(_ model: AppModel) {
    Task {
        while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(100)) }
        model.endDrag()
    }
}

private struct ProjectRowModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let spot: ProjectSpot
    let name: String
    @State private var height: Double = 24

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { height = $0 }
            .draggable(begin()) {
                DragPill(title: name, subtasks: 0)
            }
            .opacity(model.projectDrag?.projectId == spot.id ? 0.4 : 1)
            .onDrop(of: [.text], delegate: ProjectDrop(model: model, spot: spot, height: height))
            .background {
                if model.dropMark == .target(spot.key) {
                    RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.25)).padding(-3)
                } else if model.dropMark == .item(spot.key, .inside) {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.tint, lineWidth: 2).padding(-3)
                }
            }
            .overlay(alignment: .top) {
                if model.dropMark == .item(spot.key, .before) { DropLine(depth: 0).offset(y: -2) }
            }
            .overlay(alignment: .bottom) {
                if model.dropMark == .item(spot.key, .after) { DropLine(depth: 0).offset(y: 2) }
            }
    }

    /// The drag's payload, as for tasks.
    private func begin() -> String {
        if model.projectDrag?.projectId != spot.id {
            model.startProjectDrag(spot.id)
            endsOnMouseUp(model)
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
                    RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.25)).padding(-3)
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

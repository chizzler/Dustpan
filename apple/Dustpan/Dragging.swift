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

/// What the window shows for the drop under the pointer.
enum DropMark: Equatable {
    /// A line or ring in the list keyed list.
    case list(String, Drop)
    /// A sidebar row or heading that takes the drop, by its key.
    case target(String)
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

extension View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        if task["completed_at"].isNull {
            row
                .onContinuousHover { phase in
                    if case .active(let point) = phase { model.hoverX = point.x - indent }
                }
                .onDrag {
                    model.startDrag(task.id, grabX: model.hoverX)
                    // SwiftUI's onDrag reports no end: the drag is over when the mouse button is up.
                    Task {
                        while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(100)) }
                        model.endDrag()
                    }
                    return NSItemProvider(object: task.id as NSString)
                } preview: {
                    DragPill(title: task["title"].string ?? "", subtasks: subtasks)
                }
                .opacity(model.drag?.taskId == task.id ? 0.4 : 1)
        } else {
            row
        }
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
struct DropLine: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(.tint, lineWidth: 2).frame(width: 8, height: 8)
            Rectangle().fill(.tint).frame(height: 2)
        }
        .padding(.leading, Double(depth) * indentWidth - 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

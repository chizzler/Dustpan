import AppKit
import DustpanCore
import SwiftUI

// SPIKE: a project or Inbox list on AppKit's NSOutlineView, to try its own drag and drop:
// the drop line, drops on a row, the level it proposes, autoscroll and opening collapsed rows on hover.
// Turned on with View ▸ Outline Task List (Spike). Rows are the same SwiftUI TaskRow, hosted.
// What a proposal means is DustpanCore's resolveDrop, as for the SwiftUI list.
// Not here yet: the row menu, keys, the Add field per section, the label picker, the Inbox's planned tasks.

struct OutlinePage: View {
    @Environment(AppModel.self) private var model
    let page: Page

    var body: some View {
        let (title, projectId) = model.listHeading(page)
        VStack(spacing: 0) {
            OutlineTaskList(model: model, projectId: projectId,
                            sections: projectSections(model.snapshot, projectId).filter(\.isList),
                            labels: model.snapshot.labels)
            Divider()
            OutlineAddField(place: Place(projectId: projectId))
        }
        .navigationTitle(title)
    }
}

/// Its own view, so focusing it doesn't rebuild the list.
private struct OutlineAddField: View {
    let place: Place
    @FocusState private var adding: Place?

    var body: some View {
        AddTaskField(place: place, focus: $adding)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

private struct OutlineTaskList: NSViewRepresentable {
    let model: AppModel
    let projectId: String?
    let sections: [DustpanCore.Section]
    let labels: [String: Row]

    func makeCoordinator() -> OutlineCoordinator { OutlineCoordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("task"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.usesAutomaticRowHeights = true
        outline.floatsGroupRows = false
        outline.indentationPerLevel = indentWidth
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.registerForDraggedTypes([.string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(OutlineCoordinator.open(_:))
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(projectId: projectId, sections: sections, labels: labels)
    }
}

/// A row of the outline: a section's heading, or a task with its subtasks.
final class OutlineItem: NSObject {
    let key: String
    let section: DustpanCore.Section
    let node: Node?
    let children: [OutlineItem]

    init(key: String, section: DustpanCore.Section, node: Node?, children: [OutlineItem]) {
        (self.key, self.section, self.node, self.children) = (key, section, node, children)
    }

    var isHeading: Bool { node == nil }
    var isOpenTask: Bool { node?.row["completed_at"].isNull ?? false }
}

/// The task row a hosting view shows. A named type, so rows can be reused.
private struct OutlineRow: View {
    let model: AppModel
    let task: Row
    let labels: [String: Row]

    var body: some View {
        TaskRow(task: task, labels: labels) { withAnimation { model.toggle(task) } }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(model)
    }
}

final class OutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: AppModel
    weak var outline: NSOutlineView?
    private var projectId: String?
    private var sections: [DustpanCore.Section] = []
    private var labels: [String: Row] = [:]
    /// Section headings and top-level tasks, as the outline's top level.
    private var roots: [OutlineItem] = []
    private var byKey: [String: OutlineItem] = [:]
    /// The open rows of each section, for resolveDrop.
    private var slots: [String?: [Slot]] = [:]
    /// Rows the user folded. Everything else is open after a reload.
    private var collapsed: Set<String> = []

    init(model: AppModel) { self.model = model }

    func update(projectId: String?, sections: [DustpanCore.Section], labels: [String: Row]) {
        guard projectId != self.projectId || sections != self.sections || labels != self.labels else { return }
        (self.projectId, self.sections, self.labels) = (projectId, sections, labels)
        byKey = [:]
        func tasks(_ nodes: [Node], in section: DustpanCore.Section) -> [OutlineItem] {
            nodes.map { node in
                let item = OutlineItem(key: node.id, section: section, node: node,
                                       children: tasks(node.children, in: section))
                byKey[node.id] = item
                return item
            }
        }
        roots = sections.flatMap { section in
            let heading = section.name.isEmpty ? [] : [OutlineItem(key: "section:\(section.id ?? "")", section: section,
                                                                   node: nil, children: [])]
            return heading + tasks(section.tasks, in: section)
        }
        slots = Dictionary(sections.map { ($0.id, openSlots($0.tasks)) }, uniquingKeysWith: { first, _ in first })

        guard let outline else { return }
        let selected = (outline.item(atRow: outline.selectedRow) as? OutlineItem)?.key
        outline.reloadData()
        func expand(_ items: [OutlineItem]) {
            for item in items where !item.children.isEmpty && !collapsed.contains(item.key) {
                outline.expandItem(item)
                expand(item.children)
            }
        }
        expand(roots)
        if let key = model.flash ?? selected, let item = byKey[key] {
            let row = outline.row(forItem: item)
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    @objc func open(_ sender: NSOutlineView) {
        guard let task = (sender.item(atRow: sender.clickedRow) as? OutlineItem)?.node?.row else { return }
        model.editing = task
    }

    // MARK: data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? OutlineItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? OutlineItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? OutlineItem)?.children.isEmpty ?? true)
    }

    // MARK: look

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? OutlineItem)?.isHeading ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? OutlineItem else { return nil }
        guard let task = item.node?.row else {
            let label = outlineView.makeView(withIdentifier: .init("heading"), owner: nil) as? NSTextField
                ?? NSTextField(labelWithString: "")
            label.identifier = .init("heading")
            label.stringValue = item.section.name
            return label
        }
        let row = OutlineRow(model: model, task: task, labels: labels)
        if let host = outlineView.makeView(withIdentifier: .init("task"), owner: nil) as? NSHostingView<OutlineRow> {
            host.rootView = row
            return host
        }
        let host = NSHostingView(rootView: row)
        host.identifier = .init("task")
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? OutlineItem)?.isHeading ?? true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? OutlineItem { collapsed.insert(item.key) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? OutlineItem { collapsed.remove(item.key) }
    }

    // MARK: drag source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? OutlineItem, item.isOpenTask else { return nil }
        return item.key as NSString
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        if let item = draggedItems.first as? OutlineItem { model.startDrag(item.key) }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model.endDrag()
    }

    // MARK: drop

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        drop(item as? OutlineItem, index) == nil ? [] : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?,
                     childIndex index: Int) -> Bool {
        guard let moving = model.drag?.taskId, let drop = drop(item as? OutlineItem, index) else { return false }
        model.drop(moving, on: drop.target)
        return true
    }

    /// What NSOutlineView's proposal means: under item (nil is the top level) before its child at index,
    /// or on item for -1.
    private func drop(_ item: OutlineItem?, _ index: Int) -> Drop? {
        guard let moving = model.drag?.taskId else { return nil }
        let section: DustpanCore.Section?
        let parent: String?
        let following: ArraySlice<OutlineItem>
        if let item {
            section = item.section
            if item.isHeading {
                return resolveDrop(slots[section?.id] ?? [], projectId: projectId, sectionId: section?.id, hit: .head,
                                   depth: 0, moving: moving)
            }
            parent = item.key
            following = index < 0 ? [] : item.children[index...]
        } else {
            // The top level: the section of the row above the gap, or the first.
            section = index > 0 ? roots[index - 1].section : sections.first
            parent = nil
            following = roots[index...].prefix { !$0.isHeading }
        }
        guard let section else { return nil }
        return resolveDrop(slots[section.id] ?? [], projectId: projectId, sectionId: section.id, parent: parent,
                           before: following.first(where: \.isOpenTask)?.key, inside: index < 0, moving: moving)
    }
}

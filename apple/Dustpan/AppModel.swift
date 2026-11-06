import DustpanCore
import Foundation
import Observation

enum Page: Hashable {
    case today
    case upcoming
    case inbox
    case project(String)
    case label(String)
    case view(String)
}

/// A label in the editor: an existing one, or a new one.
struct LabelDraft: Identifiable {
    let id = UUID()
    var label: Row?
}

/// A saved view in the editor: an existing one, or a new one (with a query to start from).
struct ViewDraft: Identifiable {
    let id = UUID()
    var view: Row?
    var query = ""
}

/// A short message at the foot of the window, with Undo when the action can be undone.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var undoable = false
}

/// The window's state: the local copy as last read, how sync is going, and the edits made here.
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle
        case syncing
        case offline(String)
        case failed(String)
    }

    static let pollInterval = Duration.seconds(30)
    /// Polling relaxes while the live stream is connected.
    static let livePollInterval = Duration.seconds(5 * 60)
    /// Several quick edits share one exchange.
    static let editSyncDelay = Duration.milliseconds(250)

    private(set) var snapshot = Snapshot()
    private(set) var status = Status.idle
    private(set) var lastSynced: Date?
    /// Local changes not yet accepted by the server.
    private(set) var waiting = 0
    /// The live stream is connected.
    private(set) var live = false
    var toast: Toast?
    /// The task open in the editor.
    var editing: Row?
    /// The saved view open in its editor.
    var editingView: ViewDraft?
    /// The label open in its editor.
    var editingLabel: LabelDraft?
    /// The task whose row shows the label picker.
    var labelling: String?
    /// The window's, so Undo works from the toast, Edit ▸ Undo and the editor alike.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Why the app can't start: no config, or no database.
    private(set) var setupProblem: String?
    var page: Page? = .today
    /// The task being dragged, and the drop under the pointer.
    private(set) var drag: TaskDrag?
    private(set) var dropMark: DropMark?
    /// The task just dropped: its row flashes and comes into view.
    private(set) var flash: String?
    /// Where the pointer is over the row it hovers, from the row's left: a drag's grab point.
    @ObservationIgnored var hoverX: Double = 0
    @ObservationIgnored private var markTick = 0
    @ObservationIgnored private var spring: Task<Void, Never>?
    /// A sync waits until the drop, so the page isn't rebuilt under the pointer.
    @ObservationIgnored private var syncAfterDrag = false

    private let store: Store?
    private let api: Api?
    private let syncer: Syncer?
    private let writer: Writer?
    private var syncAgain = false
    private var lastSync = ContinuousClock.now
    private var editSync: Task<Void, Never>?
    private let notifier = Notifier()
    /// Reminders are checked once notifications are allowed.
    private var reminding = false

    init() {
        do {
            let config = try Config.load()
            let store = try Store(path: try databasePath())
            let api = Api(config: config)
            (self.store, self.api) = (store, api)
            syncer = Syncer(store: store, server: api)
            writer = Writer(store: store)
            refresh()
        } catch {
            (store, api, syncer, writer) = (nil, nil, nil, nil)
            setupProblem = "\(error)"
        }
        notifier.model = self
    }

    // MARK: sync

    /// Sync at start, then every 30 seconds, or every 5 minutes while the live stream is up.
    func start() async {
        guard syncer != nil else { return }
        await sync()
        #if DEBUG
        await screenshotsIfAsked()
        #endif
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            let interval = live ? Self.livePollInterval : Self.pollInterval
            if lastSync.duration(to: .now) >= interval - .seconds(1) { await sync() }
        }
    }

    /// Keep the live stream open: sync on connecting, and when another device writes.
    func listen() async {
        guard let api, let store, let device = try? store.transaction({ try store.device() }) else { return }
        for await event in api.liveEvents(device: device) {
            switch event {
            case .connected:
                live = true
                await sync()
            case .ops(let cursor):
                if cursor.map({ $0 > (try? store.meta("cursor").int) ?? 0 }) ?? true { await sync() }
            case .disconnected:
                live = false
            }
        }
    }

    /// Exchange with the server. A call while one runs makes it go round again.
    func sync() async {
        guard let syncer else { return }
        guard drag == nil else {
            syncAfterDrag = true
            return
        }
        guard status != .syncing else {
            syncAgain = true
            return
        }
        repeat {
            syncAgain = false
            status = .syncing
            do {
                let result = try await syncer.run()
                status = .idle
                lastSynced = .now
                if result.refused > 0 {
                    show(Toast(message: "\(result.refused) change\(result.refused == 1 ? "" : "s") not accepted by the server"))
                }
            } catch ApiError.offline(let message) {
                status = .offline(message)
            } catch {
                status = .failed("\(error)")
            }
            refresh()
        } while syncAgain
        lastSync = .now
    }

    private func syncSoon() {
        guard editSync == nil else { return }
        editSync = Task {
            try? await Task.sleep(for: Self.editSyncDelay)
            editSync = nil
            await sync()
        }
    }

    private func refresh() {
        guard let store else { return }
        do {
            snapshot = try DustpanCore.snapshot(store)
            waiting = try store.outboxCount()
        } catch {
            status = .failed("\(error)")
        }
        checkReminders()
    }

    // MARK: reminders

    /// Show reminders as they come due: at the next firing or every 30 seconds, and after every change.
    func remind() async {
        guard store != nil, await notifier.requestPermission() else { return }
        reminding = true
        while !Task.isCancelled {
            let wait = checkReminders().map { Duration.milliseconds(max($0 - wallMs(), 1000)) } ?? Self.pollInterval
            try? await Task.sleep(for: min(wait, Self.pollInterval))
        }
    }

    /// Show what's newly due and withdraw what no longer is. Returns the next firing.
    @discardableResult
    private func checkReminders() -> Int64? {
        guard reminding, let store else { return nil }
        do {
            let check = try DustpanCore.checkReminders(store, now: wallMs())
            notifier.withdraw(check.withdraw)
            for alert in check.show {
                notifier.show(alert, body: formatDue(alert.task["due"]).map { "Due \($0.text)" }
                    ?? describe(reminder: alert.reminder))
            }
            return check.next
        } catch {
            status = .failed("\(error)")
            return nil
        }
    }

    func snooze(_ reminderId: String) {
        perform { try $0.snooze(reminderId, until: wallMs() + 10 * 60_000) }
    }

    func dismiss(_ reminderId: String) {
        perform { try $0.dismiss(reminderId) }
    }

    func addReminder(to taskId: String, offsetMinutes: Int64) throws {
        try apply { try $0.addReminder(taskId, offsetMinutes: offsetMinutes) }
    }

    /// A reminder at a time of its own.
    func addReminder(to taskId: String, at time: Date) throws {
        try apply { try $0.addReminder(taskId, at: time.ms) }
    }

    func setOffset(_ reminderId: String, minutes: Int64) throws {
        try apply { try $0.setOffset(reminderId, minutes: minutes) }
    }

    /// A reminder at a time of its own moves to another.
    func retime(_ reminderId: String, at time: Date) throws {
        try apply { try $0.snooze(reminderId, until: time.ms) }
    }

    func deleteReminder(_ reminderId: String) throws {
        try apply { try $0.deleteReminder(reminderId) }
    }

    /// Show a task in its list, open in the editor.
    func open(_ taskId: String) {
        guard let task = snapshot.allTasks[taskId], task["deleted_at"].isNull else { return }
        page = task["project_id"].string.map(Page.project) ?? .inbox
        editing = task
    }

    // MARK: edits

    /// Run a writer action, then show the change and sync soon. Throws CannotEdit, or a store error.
    @discardableResult
    private func apply<T>(_ action: (Writer) throws -> T) throws -> T {
        guard let writer else { throw CannotEdit("Dustpan isn't set up") }
        let result = try action(writer)
        refresh()
        syncSoon()
        return result
    }

    /// apply, showing why when the action can't be done.
    @discardableResult
    private func perform<T>(_ action: (Writer) throws -> T) -> T? {
        do {
            return try apply(action)
        } catch {
            show(Toast(message: (error as? CannotEdit)?.message ?? "\(error)"))
            return nil
        }
    }

    /// Add a task from a quick-add line at the end of a list. The page's place, due and labels fill in
    /// what the line leaves out. False when it can't be added.
    func add(_ line: String, to place: Place, due: JSON = nil, labels: [String] = []) -> Bool {
        perform {
            try $0.quickAdd(line, projectId: place.projectId, sectionId: place.sectionId, due: due, labels: labels)
        } != nil
    }

    func addSubtask(_ line: String, to parentId: String) throws {
        try apply { try $0.quickAdd(line, parentId: parentId) }
    }

    /// What a quick-add line will set besides the title, as "Tomorrow 15:00 · Work · @phone · p1".
    func quickAddPreview(_ line: String) -> String {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let parsed = try? writer?.parseLine(line) else {
            return ""
        }
        let reminders = parsed.reminders.count
        let parts: [String?] = [
            formatDue(parsed.due)?.text, parsed.someday ? "Someday" : nil, parsed.sector,
            parsed.evening ? "This evening" : nil, parsed.dayPart,
            parsed.deadline.map { "Deadline \(formatDay($0))" },
            parsed.projectId.map { id in snapshot.projectPaths.first { $0.id == id }?.path ?? "Project" },
        ] + parsed.labels.map { "@\($0)" } + [
            parsed.priority.map { "p\($0)" }, parsed.estimateMinutes.map(formatMinutes), parsed.recurrence,
            reminders > 0 ? "\(reminders) reminder\(reminders == 1 ? "" : "s")" : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// Delete tasks and their subtasks. One Undo brings them all back.
    func delete(_ tasks: [Row]) {
        guard let first = tasks.first else { return }
        let ids = tasks.map(\.id)
        undoable("Delete", { writer in
            var undo: [Change] = []
            for (index, id) in ids.enumerated() {
                do {
                    undo += try writer.deleteTask(id).undo
                } catch where index > 0 {
                    // A subtask of another selected task went with it.
                }
            }
            return Done(undo: undo)
        }) { _ in tasks.count == 1 ? "Deleted “\(first["title"].string ?? "")”" : "Deleted \(tasks.count) tasks" }
    }

    /// Create a view and show it, or edit one.
    func saveView(_ view: Row?, _ edit: ViewEdit) throws {
        if let view {
            guard !edit.isEmpty else { return }
            try apply { try $0.editView(view.id, edit) }
        } else {
            page = .view(try apply { try $0.addView(edit) })
        }
    }

    /// Undo brings it back.
    func deleteView(_ view: Row) {
        if page == .view(view.id) { page = .today }
        undoable("Delete View", { try $0.deleteView(view.id) }) { _ in "Deleted view “\(view["name"].string ?? "")”" }
    }

    func edit(_ taskId: String, _ edit: TaskEdit) throws {
        guard !edit.isEmpty else { return }
        try apply { try $0.edit(taskId, edit) }
        if let labels = edit.labels { rememberLabels(labels) }
    }

    func addReminder(to taskId: String, deadlineOffset minutes: Int64) throws {
        try apply { try $0.addReminder(taskId, deadlineOffset: minutes) }
    }

    // MARK: labels

    /// Labels assigned lately on this device first, then sidebar order.
    var labelsForPicker: [Row] {
        let recent = (try? store?.meta(recentLabelsKey).array?.compactMap(\.string)) ?? []
        return pickerOrder(Array(snapshot.labels.values), recent: recent)
    }

    /// Remember the labels just assigned, by id. Names of labels made in the same edit are found by name.
    private func rememberLabels(_ refs: [String]) {
        guard let store else { return }
        let ids = refs.compactMap { ref in
            snapshot.labels[ref] != nil ? ref : exactLabel(Array(snapshot.labels.values), ref)?.id
        }
        guard !ids.isEmpty else { return }
        let recent = (try? store.meta(recentLabelsKey).array?.compactMap(\.string)) ?? []
        try? store.setMeta(recentLabelsKey, .array(DustpanCore.rememberLabels(recent, ids).map(JSON.string)))
    }

    /// What the row's picker changed, as one batch with Undo.
    func changeLabels(of task: Row, add: [String], remove: Set<String>) {
        guard !add.isEmpty || !remove.isEmpty else { return }
        let title = task["title"].string ?? ""
        undoable("Change Labels", { try $0.changeTaskLabels(task.id, add: add, remove: remove) }) { _ in
            "Changed labels on “\(title)”"
        }
        rememberLabels(add)
    }

    /// Create a label and show it, or rename and recolour one.
    func saveLabel(_ label: Row?, name: String, color: String) throws {
        if let label {
            let done = try apply { try $0.editLabel(label.id, name: name, color: color) }
            if !done.undo.isEmpty { registerUndo("Edit Label", done) }
        } else {
            page = .label(try apply { try $0.addLabel(name, color: color) })
        }
    }

    func moveLabel(_ label: Row, step: Int) {
        undoable(step < 0 ? "Move Up" : "Move Down", { try $0.moveLabel(label.id, step: step) }, message: nil)
    }

    func moveLabel(_ label: Row, to index: Int) {
        undoable("Move Label", { try $0.moveLabel(label.id, to: index) }, message: nil)
    }

    func deleteLabel(_ label: Row) {
        if page == .label(label.id) { page = .today }
        undoable("Delete Label", { try $0.deleteLabel(label.id) }) { _ in
            "Deleted label “\(label["name"].string ?? "")”"
        }
    }

    func mergeLabel(_ source: Row, into target: Row) {
        if page == .label(source.id) { page = .label(target.id) }
        undoable("Merge Labels", { try $0.mergeLabels(source.id, into: target.id) }) { _ in
            "Merged “\(source["name"].string ?? "")” into “\(target["name"].string ?? "")”"
        }
    }

    /// Live tasks that carry a label: what deleting or merging it changes.
    func uses(of label: Row) -> Int { carrying(snapshot.allTasks.values, label.id).count }

    /// Complete an open task, or reopen a completed one. A repeating task moves on. Undo puts it back.
    func toggle(_ task: Row) {
        let title = task["title"].string ?? ""
        if task["completed_at"].isNull {
            undoable("Complete", { try $0.complete(task.id) }) { done in
                done.nextDue.map { "“\(title)” next due \(formatDay($0))" } ?? "Completed “\(title)”"
            }
        } else {
            undoable("Reopen", { try $0.reopen(task.id) }) { _ in "Reopened “\(title)”" }
        }
    }

    func skip(_ task: Row) {
        undoable("Skip", { try $0.skip(task.id) }, message: movedOn("Skipped"))
    }

    /// Split off this occurrence as a task of its own.
    func detach(_ task: Row) {
        undoable("Split Off", { try $0.detach(task.id) }, message: movedOn("Split off a copy"))
    }

    private func movedOn(_ verb: String) -> (Done) -> String {
        { done in "\(verb). Next due \(done.nextDue.map { formatDay($0) } ?? "")" }
    }

    /// Run an action and offer its Undo in the toast and in Edit ▸ Undo. Redo runs the action again.
    /// Without a message, there's no toast: Edit ▸ Undo alone.
    @discardableResult
    private func undoable(_ name: String, _ action: @escaping (Writer) throws -> Done,
                          message: ((Done) -> String)?) -> Done? {
        guard let done = perform(action), !done.undo.isEmpty else { return nil }
        if let message { show(Toast(message: message(done), undoable: undoManager != nil)) }
        undoManager?.registerUndo(withTarget: self) { model in
            model.toast = nil
            guard model.perform({ try $0.revert(done.undo) }) != nil else { return }
            model.undoManager?.registerUndo(withTarget: model) { $0.undoable(name, action, message: message) }
            model.undoManager?.setActionName(name)
        }
        undoManager?.setActionName(name)
        return done
    }

    /// Edit ▸ Undo for an edit made in a sheet. Redo isn't offered: the sheet's values are gone.
    private func registerUndo(_ name: String, _ done: Done) {
        undoManager?.registerUndo(withTarget: self) { model in model.perform { try $0.revert(done.undo) } }
        undoManager?.setActionName(name)
    }

    /// A new toast replaces the shown one, so Undo always means the latest action.
    private func show(_ toast: Toast) {
        self.toast = toast
    }

    // MARK: drag and drop

    /// A drag starts. Its source calls endDrag when it ends, dropped or not.
    func startDrag(_ taskId: String, grabX: Double = 0) {
        drag = TaskDrag(taskId: taskId, grabX: grabX)
    }

    func endDrag() {
        guard drag != nil else { return }
        drag = nil
        dropMark = nil
        spring?.cancel()
        if syncAfterDrag {
            syncAfterDrag = false
            Task { await sync() }
        }
    }

    func mark(_ mark: DropMark) {
        markTick += 1
        if dropMark != mark { dropMark = mark }
    }

    /// The pointer left a target. The mark goes unless another target takes over soon, so it doesn't flicker
    /// in the gaps between rows.
    func unmark() {
        let tick = markTick
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if markTick == tick {
                dropMark = nil
                spring?.cancel()
            }
        }
    }

    /// Holding a drag over a sidebar row for 700 ms opens its page, so the task can be placed exactly.
    func springLoad(_ page: Page, from key: String) {
        spring?.cancel()
        spring = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled && drag != nil && dropMark == .target(key) { self.page = page }
        }
    }

    /// Apply a drop as one batch with Undo, then flash the task where it landed.
    func drop(_ taskId: String, on target: DropTarget) {
        spring?.cancel()
        guard let task = snapshot.allTasks[taskId] else { return }
        let names = dropNames(target, task)
        if case .label(let id) = target, task["labels"].array?.contains(.string(id)) == true {
            show(Toast(message: "Already has @\(names[id] ?? "")"))
            return
        }
        let done = undoable("Move", { try $0.drop(taskId, on: target) }) { _ in
            describeDrop(target, task: task, names: names) { formatDay($0) }
        }
        guard done != nil else { return }
        flash = taskId
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if flash == taskId { flash = nil }
        }
    }

    /// The names describeDrop needs: projects, sections, tasks and labels the drop refers to.
    private func dropNames(_ target: DropTarget, _ task: Row) -> [String: String] {
        var ids = [task["parent_id"].string]
        switch target {
        case .place(let place): ids += [place.projectId, place.sectionId, place.parentId]
        case .project(let id): ids.append(id)
        case .label(let id): ids.append(id)
        case .day: break
        }
        let sections = snapshot.sectionsByProject.values.joined()
        var names: [String: String] = [:]
        for id in ids.compactMap({ $0 }) {
            names[id] = snapshot.liveProjects.first { $0.id == id }?["name"].string
                ?? sections.first { $0.id == id }?["name"].string
                ?? snapshot.labels[id]?["name"].string
                ?? snapshot.allTasks[id]?["title"].string
        }
        return names
    }

    // MARK: reads

    /// A list page's title and project. A project that's gone shows the Inbox.
    func listHeading(_ page: Page) -> (title: String, projectId: String?) {
        if case .project(let id) = page, let node = flatProjects.first(where: { $0.node.id == id })?.node {
            return (node.row["name"].string ?? "", id)
        }
        return ("Inbox", nil)
    }

    var today: Day { (try? writer?.today()) ?? Day(.now) }

    /// Every visible project by id, nested ones included.
    var projectsById: [String: Node] {
        Dictionary(uniqueKeysWithValues: flatProjects.map { ($0.node.id, $0.node) })
    }

    /// Visible projects in sidebar order, with their depth.
    var flatProjects: [(node: Node, depth: Int)] {
        func walk(_ nodes: [Node], _ depth: Int) -> [(node: Node, depth: Int)] {
            nodes.flatMap { [($0, depth)] + walk($0.children, depth + 1) }
        }
        return walk(snapshot.projects, 0)
    }
}

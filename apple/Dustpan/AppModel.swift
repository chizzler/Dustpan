import DustpanCore
import Foundation
import Observation

enum Page: Hashable {
    case today
    case upcoming
    case inbox
    case project(String)
    case view(String)
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
    /// The window's, so Undo works from the toast, Edit ▸ Undo and the editor alike.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Why the app can't start: no config, or no database.
    private(set) var setupProblem: String?
    var page: Page? = .today

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

    /// Add a task at the end of a list. False when it can't be added.
    func add(_ title: String, to place: Place, due: JSON = nil) -> Bool {
        perform { try $0.addTask(title, projectId: place.projectId, sectionId: place.sectionId, due: due) } != nil
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
    }

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
    private func undoable(_ name: String, _ action: @escaping (Writer) throws -> Done,
                          message: @escaping (Done) -> String) {
        guard let done = perform(action), !done.undo.isEmpty else { return }
        show(Toast(message: message(done), undoable: undoManager != nil))
        undoManager?.registerUndo(withTarget: self) { model in
            model.toast = nil
            guard model.perform({ try $0.revert(done.undo) }) != nil else { return }
            model.undoManager?.registerUndo(withTarget: model) { $0.undoable(name, action, message: message) }
            model.undoManager?.setActionName(name)
        }
        undoManager?.setActionName(name)
    }

    /// A new toast replaces the shown one, so Undo always means the latest action.
    private func show(_ toast: Toast) {
        self.toast = toast
    }

    // MARK: reads

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

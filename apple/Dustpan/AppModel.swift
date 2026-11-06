import DustpanCore
import Foundation
import Observation

enum Page: Hashable {
    case inbox
    case project(String)
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
    /// Why the app can't start: no config, or no database.
    private(set) var setupProblem: String?
    var page: Page? = .inbox

    private let store: Store?
    private let api: Api?
    private let syncer: Syncer?
    private let writer: Writer?
    private var syncAgain = false
    private var lastSync = ContinuousClock.now
    private var editSync: Task<Void, Never>?

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
    func add(_ title: String, to place: Place) -> Bool {
        perform { try $0.addTask(title, projectId: place.projectId, sectionId: place.sectionId) } != nil
    }

    func edit(_ taskId: String, _ edit: TaskEdit) throws {
        guard !edit.isEmpty else { return }
        try apply { try $0.edit(taskId, edit) }
    }

    /// Complete an open task, or reopen a completed one. Undo puts it back.
    func toggle(_ task: Row, undoManager: UndoManager?) {
        let title = task["title"].string ?? ""
        if task["completed_at"].isNull {
            undoable("Complete", "Completed “\(title)”", undoManager) { try $0.complete(task.id) }
        } else {
            undoable("Reopen", "Reopened “\(title)”", undoManager) { try $0.reopen(task.id) }
        }
    }

    /// Run an action and offer its Undo in the toast and in Edit ▸ Undo. Redo runs the action again.
    private func undoable(_ name: String, _ message: String, _ undoManager: UndoManager?,
                          _ action: @escaping (Writer) throws -> Done) {
        guard let done = perform(action), !done.undo.isEmpty else { return }
        show(Toast(message: message, undoable: undoManager != nil))
        undoManager?.registerUndo(withTarget: self) { model in
            model.toast = nil
            guard model.perform({ try $0.revert(done.undo) }) != nil else { return }
            undoManager?.registerUndo(withTarget: model) { $0.undoable(name, message, undoManager, action) }
            undoManager?.setActionName(name)
        }
        undoManager?.setActionName(name)
    }

    /// A new toast replaces the shown one, so Undo always means the latest action.
    private func show(_ toast: Toast) {
        self.toast = toast
    }

    // MARK: reads

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

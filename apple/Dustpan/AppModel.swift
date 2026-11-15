import DustpanCore
import Foundation
import Observation

enum Page: Hashable {
    case today
    case upcoming
    case inbox
    case project(String)
    /// An archived project: its page offers Unarchive.
    case archived(String)
    case label(String)
    case view(String)
    case anytime
    case completed
    case filter
    case trash
}

extension Page {
    /// Built-in pages that can be hidden from the sidebar on this device, never deleted.
    static let optional: [Page] = [.anytime, .completed, .filter, .trash]

    /// The key in store meta `hidden_pages`, the desktop client's.
    var key: String? {
        switch self {
        case .anytime: "anytime"
        case .completed: "completed"
        case .filter: "filter"
        case .trash: "trash"
        default: nil
        }
    }

    var name: String {
        switch self {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .inbox: "Inbox"
        case .anytime: "Anytime"
        case .completed: "Completed"
        case .filter: "Filter"
        case .trash: "Trash"
        default: ""
        }
    }

    var symbol: String {
        switch self {
        case .today: "star"
        case .upcoming: "calendar"
        case .inbox: "tray"
        case .view: "line.3.horizontal.decrease.circle"
        case .anytime: "square.stack"
        case .completed: "checkmark.circle"
        case .filter: "magnifyingglass"
        case .trash: "trash"
        default: "questionmark"
        }
    }
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

/// A project in the editor: an existing one, or a new one at the top level or under parentId.
struct ProjectDraft: Identifiable {
    let id = UUID()
    var project: Row?
    var parentId: String?
}

/// A section being edited: a new one in projectId, or the existing row as the editor opened.
struct SectionDraft: Identifiable {
    let id = UUID()
    let projectId: String
    var section: Row?
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
    /// Deleted tasks and projects, newest first.
    private(set) var trash: [TrashItem] = []
    /// Trash items whose permanent delete waits for the next sync.
    private(set) var purging: Set<TrashItem.Target> = []
    /// Days the server keeps an item in the Trash; 0 is until deleted for good, as standalone.
    private(set) var trashRetention = defaultTrashRetention
    /// How Delete for Good goes: here and now, or through the server.
    private(set) var purgeMode = PurgeMode.local
    private(set) var status = Status.idle
    private(set) var lastSynced: Date?
    /// Local changes not yet accepted by the server.
    private(set) var waiting = 0
    /// The live stream is connected.
    private(set) var live = false
    var toast: Toast?
    /// The task open in the editor.
    var editing: Row?
    /// The task open in the editor over the calendar window.
    var calendarEditing: Row?
    /// The calendar window is open. Kept on this device, so it reopens with the app.
    private(set) var calendarOpen = false
    /// The calendar shows completed tasks too. Kept on this device.
    private(set) var calendarShowsCompleted = false
    /// Day, Week or Month. Kept on this device.
    private(set) var calendarMode = CalendarMode.month
    /// The calendar's grid settings on this device: the day length its load is measured against.
    private(set) var calendarGrid = GridPrefs()
    /// The saved view open in its editor.
    var editingView: ViewDraft?
    /// The project open in its editor.
    var editingProject: ProjectDraft?
    /// The project whose delete waits for a yes.
    private(set) var deletingProject: Row?
    var confirmsProjectDelete = false
    /// The section being named.
    var editingSection: SectionDraft?
    /// The label open in its editor.
    var editingLabel: LabelDraft?
    /// The task whose row shows the label picker.
    var labelling: String?
    /// The window's, so Undo works from the toast, Edit ▸ Undo and the editor alike.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Why the app can't start: no database.
    private(set) var setupProblem: String?
    var page: Page? = .today {
        didSet {
            guard page != oldValue else { return }
            settling = [:]
            offeredParent = nil
        }
    }
    /// The optional pages hidden from the sidebar here, by key.
    private(set) var hiddenPages: Set<String> = []
    /// Tasks whose subtasks are folded away on this device, in the order they were folded.
    private(set) var foldedTasks: [String] = []
    /// Completed subtasks the broom swept from project lists on this device.
    private(set) var clearedSubtasks: [String: JSON] = [:]
    /// Each parent's progress over its direct subtasks, for the pie in its check.
    private(set) var progress: [String: SubtaskProgress] = [:]
    /// A parent whose last open subtask was just completed here: the list offers to complete it.
    private(set) var offeredParent: String?
    /// Tasks just ticked or reopened, with whether they still sort as done: they keep their place in project lists
    /// until 2 s after the last tick on the page, then settle together.
    private(set) var settling: [String: Bool] = [:]
    @ObservationIgnored private var settle: Task<Void, Never>?
    /// The Filter page's query, kept while other pages are shown.
    var filterQuery = ""
    /// Bumped to put the focus in the Filter page's query.
    private(set) var filterFocus = 0
    /// The task being dragged, and the drop under the pointer.
    private(set) var drag: TaskDrag?
    /// The sidebar project being dragged, apart from task drags.
    private(set) var projectDrag: ProjectDrag?
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
    private let writer: Writer?
    /// The OpenTodo server, while sync is on. Without one Dustpan runs standalone.
    private(set) var config: Config?
    @ObservationIgnored private var api: Api?
    @ObservationIgnored private var syncer: Syncer?
    @ObservationIgnored private var liveStream: Task<Void, Never>?
    /// An account change waits for the running sync to end. No sync starts meanwhile.
    private(set) var changingAccount = false
    private var syncAgain = false
    private var lastSync = ContinuousClock.now
    private var editSync: Task<Void, Never>?
    private let notifier = Notifier()
    /// Reminders are checked once notifications are allowed.
    private var reminding = false
    /// Asks, once per Mac, whether to open at login: the first time a reminder is waiting to fire.
    var offersOpenAtLogin = false

    init() {
        do {
            let store = try Store(path: try databasePath())
            self.store = store
            writer = Writer(store: store)
            let (config, warning) = Config.loadOptional()
            if let config { use(config) }
            if let warning { toast = Toast(message: warning) }
            refresh()
        } catch {
            (store, writer) = (nil, nil)
            setupProblem = "\(error)"
        }
        notifier.model = self
    }

    // MARK: sync

    var isConnected: Bool { config != nil }

    private func use(_ config: Config?) {
        self.config = config
        api = config.map { Api(config: $0) }
        syncer = api.flatMap { api in store.map { Syncer(store: $0, server: api) } }
    }

    /// Sync at start, then every 30 seconds, or every 5 minutes while the live stream is up. Standalone, it waits.
    func start() async {
        guard store != nil else { return }
        startLive()
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

    /// Keep the live stream open while connected: sync on connecting, and when another device writes.
    private func startLive() {
        stopLive()
        guard let api, let store, let device = try? store.transaction({ try store.device() }) else { return }
        liveStream = Task {
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
    }

    private func stopLive() {
        liveStream?.cancel()
        liveStream = nil
        live = false
    }

    /// Exchange with the server. A call while one runs makes it go round again.
    func sync() async {
        guard syncer != nil, !changingAccount else { return }
        guard drag == nil && projectDrag == nil else {
            syncAfterDrag = true
            return
        }
        guard status != .syncing else {
            syncAgain = true
            return
        }
        repeat {
            syncAgain = false
            guard let syncer, let store, !changingAccount else { break }
            let changes = store.changes
            status = .syncing
            do {
                let result = try await syncer.run()
                status = .idle
                lastSynced = .now
                if result.refused > 0 {
                    show(Toast(message: "\(result.refused) change\(result.refused == 1 ? "" : "s") not accepted by the server"))
                }
            } catch Syncer.Failure.accountChanged {
                // Changed elsewhere, by the command line say: go again under the new account.
                status = .idle
                syncAgain = true
            } catch ApiError.offline(let message) {
                status = .offline(message)
            } catch {
                status = .failed("\(error)")
            }
            // Nothing pulled, or the server out of reach: the pages stay as they are.
            if store.changes != changes { refresh() }
        } while syncAgain
        if status == .syncing { status = .idle }
        lastSync = .now
    }

    // MARK: the OpenTodo account

    /// Ask the server whose token it is.
    func verify(_ config: Config) async throws -> (userId: String, key: JSON?) {
        try await verifyAccount(Api(config: config))
    }

    /// How the data here meets userId's account, or nil when Settings must ask: it holds another account's data.
    func joinPlan(for userId: String) throws -> AccountJoin? {
        guard let store else { throw CannotEdit("Dustpan isn't set up") }
        return try DustpanCore.joinPlan(store, userId: userId)
    }

    /// Connect to config's account, changing the data here as how says, once no sync is running. No sync starts
    /// meanwhile.
    func connect(_ config: Config, userId: String, key: JSON?, _ how: AccountJoin) async throws {
        guard let store else { throw CannotEdit("Dustpan isn't set up") }
        changingAccount = true
        pauseSync()
        while status == .syncing { try? await Task.sleep(for: .milliseconds(50)) }
        do {
            try join(store, userId: userId, key: key, how)
            try config.save()
        } catch {
            changingAccount = false
            startLive()
            throw error
        }
        use(config)
        changingAccount = false
        status = .idle
        refresh()
        startLive()
        await sync()
    }

    /// Stop syncing and keep everything here: Dustpan runs standalone.
    func disconnect() throws {
        try Config.clear()
        pauseSync()
        use(nil)
        syncAgain = false
        status = .idle
        refresh()
    }

    /// The live stream and a pending edit's sync stop.
    private func pauseSync() {
        stopLive()
        editSync?.cancel()
        editSync = nil
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
            trash = trashItems(tasks: snapshot.allTasks, projects: try store.rows("project"))
            purging = try pendingPurges(store)
            trashRetention = try DustpanCore.trashRetention(store, connected: isConnected)
            purgeMode = try DustpanCore.purgeMode(store, connected: isConnected)
            waiting = try store.outboxCount()
            hiddenPages = Set(try store.meta(hiddenPagesKey).array?.compactMap(\.string) ?? [])
            foldedTasks = try store.meta(foldedTasksKey).array?.compactMap(\.string) ?? []
            clearedSubtasks = try store.meta(clearedSubtasksKey).object ?? [:]
            progress = progressMap(snapshot.allTasks.values, cleared: clearedSubtasks)
            calendarOpen = try store.meta(calendarOpenKey).bool == true
            calendarShowsCompleted = try store.meta(calendarShowCompletedKey).bool == true
            calendarGrid = GridPrefs(try store.meta(calendarGridKey))
            calendarMode = try store.meta(calendarViewKey).string.flatMap(CalendarMode.init) ?? .month
            settlePage()
        } catch {
            status = .failed("\(error)")
        }
        checkReminders()
    }

    /// A project archived, unarchived or deleted here or elsewhere: its page follows it.
    private func settlePage() {
        let archived = Set(snapshot.archivedProjects.map(\.row.id))
        switch page {
        case .project(let id) where projectsById[id] == nil:
            page = archived.contains(id) ? .archived(id) : .today
        case .archived(let id) where !archived.contains(id):
            page = projectsById[id] != nil ? .project(id) : .today
        default: break
        }
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
            if check.next != nil { offerOpenAtLogin() }
            return check.next
        } catch {
            status = .failed("\(error)")
            return nil
        }
    }

    private func offerOpenAtLogin() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: LoginItem.offeredKey), LoginItem.canChange else { return }
        defaults.set(true, forKey: LoginItem.offeredKey)
        offersOpenAtLogin = !LoginItem.isOn
    }

    /// The offer's yes. Settings ▸ General can change it later.
    func openAtLogin() {
        do {
            try LoginItem.set(true)
            toast = Toast(message: LoginItem.needsApproval ? "Allow Dustpan in Login Items to finish"
                                                            : "Dustpan opens at login")
        } catch {
            toast = Toast(message: "Couldn't open at login: \(error.localizedDescription)")
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

    /// Settings: write changed preferences. Throws CannotEdit saying what's wrong.
    func setPrefs(_ changes: [String: JSON]) throws {
        try apply { try $0.setPrefs(changes) }
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

    /// The title a quick-add line leaves and what it sets, as "→ Call Sam · Tomorrow 15:00 · Work · @phone · p1".
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
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        // The title too, so a word read as a date doesn't vanish unseen.
        return text.isEmpty ? "" : "→ \(parsed.title.isEmpty ? "(no title)" : parsed.title) · \(text)"
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

    /// Create a project and show it, or edit one.
    /// color nil is Theme. icon nil is none.
    func saveProject(_ project: Row?, name: String, color: String?, icon: String?, parentId: String??) throws {
        if let project {
            let edit = ProjectEdit(name: name, color: .some(color), icon: .some(icon), parentId: parentId)
            let done = try apply { try $0.editProject(project.id, edit) }
            if !done.undo.isEmpty { registerUndo("Edit Project", done) }
        } else {
            page = .project(try apply { try $0.addProject(name, under: parentId ?? nil, color: .some(color), icon: icon) })
        }
    }

    /// "Parent › Child", archived projects too.
    func projectPath(_ projectId: String) -> String {
        DustpanCore.projectPath(projectId, Dictionary(uniqueKeysWithValues: snapshot.liveProjects.map { ($0.id, $0) }))
    }

    /// The project and its live sub-projects, with Undo.
    func archiveProject(_ projectId: String) {
        let path = projectPath(projectId)
        undoable("Archive Project", { try $0.archiveProject(projectId) }) { _ in "Archived “\(path)”" }
    }

    func unarchiveProject(_ projectId: String) {
        let done = undoable("Unarchive Project", { try $0.unarchiveProject(projectId) }) { _ in
            "Unarchived “\(self.projectPath(projectId))”"
        }
        if done != nil { page = .project(projectId) }
    }

    /// Open tasks in a project, its sub-projects' apart: what deleting it hides.
    func openTasks(in projectId: String) -> Int {
        snapshot.allTasks.values.count { $0["deleted_at"].isNull && $0["completed_at"].isNull && $0["project_id"].string == projectId }
    }

    /// Delete a project, asking first when it has open tasks.
    func askToDelete(_ project: Row) {
        if openTasks(in: project.id) > 0 {
            deletingProject = project
            confirmsProjectDelete = true
        } else {
            deleteProject(project.id)
        }
    }

    /// Its sub-projects move up a level. Undo brings it back, with its tasks.
    func deleteProject(_ projectId: String) {
        let path = projectPath(projectId)
        undoable("Delete Project", { try $0.deleteProject(projectId) }) { _ in "Deleted “\(path)”" }
    }

    /// Add a section, last in its project, or edit one. color nil is none. icon nil is none.
    func saveSection(_ draft: SectionDraft, name: String, color: String?, icon: String?) throws {
        if let section = draft.section {
            let done = try apply { try $0.editSection(section, name: name, color: color, icon: icon) }
            if !done.undo.isEmpty { registerUndo("Edit Section", done) }
        } else {
            try apply { try $0.addSection(name, to: draft.projectId, color: color, icon: icon) }
        }
    }

    func moveSection(_ sectionId: String, step: Int) {
        undoable(step < 0 ? "Move Up" : "Move Down", { try $0.moveSection(sectionId, step: step) }, message: nil)
    }

    /// Its open tasks go to "No section". Undo puts them back.
    func deleteSection(_ section: Row) {
        let name = section["name"].string ?? ""
        undoable("Delete Section", { try $0.deleteSection(section.id) }) { done in
            let moved = done.undo.count - 1
            return "Deleted section “\(name)”" + (moved > 0 ? ". \(moved) task\(moved == 1 ? "" : "s") moved to No section" : "")
        }
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

    // MARK: the Trash

    /// Bring a task or project back, with Undo. A task whose project is gone goes to the Inbox.
    func restore(_ item: TrashItem) {
        let title = item.title
        if item.isProject {
            undoable("Restore", { try $0.restoreProject(item.target.id) }) { _ in "Restored “\(title)” with its tasks" }
        } else {
            undoable("Restore", { try $0.restoreTask(item.target.id) }) { done in
                done.undo.first?.patch["project_id"] != nil ? "Restored “\(title)” to the Inbox" : "Restored “\(title)”"
            }
        }
    }

    /// Delete each item for good. No Undo. Data never connected to an account goes at once. Otherwise the server
    /// may hold a copy, which would come back, so the request is queued for the next sync, after reconnecting if
    /// need be.
    func deleteForGood(_ items: [TrashItem]) {
        guard let store else { return }
        do {
            if purgeMode == .local {
                try purgeLocal(store, items.map(\.target))
            } else {
                try queuePurges(store, items.map(\.target))
            }
        } catch {
            show(Toast(message: "\(error)"))
            return
        }
        refresh()
        Task { await sync() }
    }

    // MARK: the calendar

    func setCalendarOpen(_ open: Bool) {
        if open != calendarOpen, saveMeta(calendarOpenKey, .bool(open)) { calendarOpen = open }
    }

    func setCalendarShowsCompleted(_ on: Bool) {
        if on != calendarShowsCompleted, saveMeta(calendarShowCompletedKey, .bool(on)) { calendarShowsCompleted = on }
    }

    /// The grid's hours and day length on this device, repaired as they're read.
    func setCalendarGrid(_ grid: GridPrefs) {
        let grid = GridPrefs(grid.json)
        if grid != calendarGrid, saveMeta(calendarGridKey, grid.json) { calendarGrid = grid }
    }

    func setCalendarMode(_ mode: CalendarMode) {
        if mode != calendarMode, saveMeta(calendarViewKey, .string(mode.rawValue)) { calendarMode = mode }
    }

    /// Show a task in the editor over the calendar.
    func openFromCalendar(_ taskId: String) {
        guard let task = snapshot.allTasks[taskId], task["deleted_at"].isNull else { return }
        calendarEditing = task
    }

    /// Device-local meta. False, with a toast, when the store refuses.
    private func saveMeta(_ key: String, _ value: JSON) -> Bool {
        guard let store else { return false }
        do {
            try store.setMeta(key, value)
            return true
        } catch {
            show(Toast(message: "\(error)"))
            return false
        }
    }

    // MARK: built-in pages

    /// The Filter page, with its query focused.
    func openFilter() {
        page = .filter
        filterFocus += 1
    }

    /// Label and project names for the query helper, in sidebar order.
    var queryNames: (labels: [String], projects: [String]) {
        (snapshot.labelsInOrder.map { $0["name"].string ?? "" }, flatProjects.map { $0.node.row["name"].string ?? "" })
    }

    /// The optional pages the sidebar lists: those not hidden, and a hidden one while it's open.
    var sidebarPages: [Page] {
        Page.optional.filter { !hiddenPages.contains($0.key ?? "") || $0 == page }
    }

    /// Fold a task's subtasks away in project lists, or show them. Kept on this device, never synced.
    func setFolded(_ taskId: String, _ fold: Bool) {
        saveFolds(foldedAfter(foldedTasks, taskId, fold: fold, tasks: snapshot.allTasks))
    }

    private func saveFolds(_ folded: [String]) {
        guard let store, folded != foldedTasks else { return }
        do {
            try store.setMeta(foldedTasksKey, .array(folded.map(JSON.string)))
            foldedTasks = folded
        } catch {
            show(Toast(message: "\(error)"))
        }
    }

    /// Hide an optional page from the sidebar on this device, with Undo; or show it again.
    func setHidden(_ page: Page, _ hidden: Bool) {
        guard let store, let key = page.key else { return }
        var keys = (try? store.meta(hiddenPagesKey).array?.compactMap(\.string)) ?? []
        keys.removeAll { $0 == key }
        if hidden { keys.append(key) }
        do {
            try store.setMeta(hiddenPagesKey, .array(keys.map(JSON.string)))
        } catch {
            show(Toast(message: "\(error)"))
            return
        }
        hiddenPages = Set(keys)
        if hidden && self.page == page { self.page = .today }
        undoManager?.registerUndo(withTarget: self) { $0.setHidden(page, !hidden) }
        undoManager?.setActionName(hidden ? "Hide \(page.name)" : "Show \(page.name)")
        if hidden {
            show(Toast(message: "\(page.name) is hidden. Bring it back from View ▸ Show \(page.name).",
                       undoable: undoManager != nil))
        }
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

    /// A project dropped on a sidebar row, as one batch with Undo.
    func placeProject(_ projectId: String, at place: ItemPlace) {
        let name = { (id: String?) in self.snapshot.liveProjects.first { $0.id == id }?["name"].string ?? "" }
        let oldParent = snapshot.liveProjects.first { $0.id == projectId }?["parent_id"].string
        undoable("Move Project", {
            try $0.placeProject(projectId, under: place.parentId, before: place.before, after: place.after)
        }) { _ in
            if place.parentId == oldParent { return "Order changed" }
            guard let parent = place.parentId else { return "Moved “\(name(projectId))” to the top level" }
            return "Moved “\(name(projectId))” under “\(name(parent))”"
        }
    }

    func moveProject(_ projectId: String, step: Int) {
        undoable(step < 0 ? "Move Up" : "Move Down", { try $0.moveProject(projectId, step: step) }, message: nil)
    }

    func moveView(_ view: Row, step: Int) {
        undoable(step < 0 ? "Move Up" : "Move Down", { try $0.moveView(view.id, step: step) }, message: nil)
    }

    func moveView(_ view: Row, to index: Int) {
        undoable("Move View", { try $0.moveView(view.id, to: index) }, message: nil)
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
    /// A subtask keeps its place for a moment; completing the last open one offers to complete its parent.
    func toggle(_ task: Row, offer: Bool = true) {
        let title = task["title"].string ?? ""
        if task["parent_id"].isTruthy { hold(task) }
        if task["completed_at"].isNull {
            let done = undoable("Complete", { try $0.complete(task.id) }) { done in
                done.nextDue.map { "“\(title)” next due \(formatDay($0))" } ?? "Completed “\(title)”"
            }
            if done != nil, offer, let parent = readyParent(task.id, tasks: snapshot.allTasks) { offeredParent = parent.id }
        } else {
            undoable("Reopen", { try $0.reopen(task.id) }) { _ in "Reopened “\(title)”" }
        }
    }

    /// The offered parent, while it's still ready: all its subtasks done and itself open.
    var readyToComplete: Row? {
        offeredParent.flatMap { snapshot.allTasks[$0] }.flatMap { isReady($0, tasks: snapshot.allTasks) ? $0 : nil }
    }

    /// Complete the offered parent. Its own parent isn't offered in turn.
    func acceptOffer() {
        guard let parent = readyToComplete else { return }
        offeredParent = nil
        toggle(parent, offer: false)
    }

    func declineOffer() { offeredParent = nil }

    /// A ticked or reopened subtask sorts as it did until the page has been still for 2 s.
    private func hold(_ task: Row) {
        if settling[task.id] == nil { settling[task.id] = !task["completed_at"].isNull }
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            settling = [:]
        }
    }

    /// The broom: hide these completed subtasks, and the completed ones under them, from this Mac's project lists.
    /// They stay in Completed. Undo brings them back.
    func sweep(_ tasks: [Row]) {
        let before = clearedSubtasks
        guard saveCleared(sweeping(tasks, all: snapshot.allTasks, into: before)) else { return }
        show(Toast(message: "Cleared completed subtasks", undoable: undoManager != nil))
        undoManager?.registerUndo(withTarget: self) { model in
            model.toast = nil
            _ = model.saveCleared(before)
        }
        undoManager?.setActionName("Clear Completed Subtasks")
    }

    private func saveCleared(_ cleared: [String: JSON]) -> Bool {
        guard saveMeta(clearedSubtasksKey, .object(cleared)) else { return false }
        clearedSubtasks = cleared
        progress = progressMap(snapshot.allTasks.values, cleared: cleared)
        return true
    }

    /// A row's project label: open the task's project (or the Inbox), unfolded down to it, and show it there.
    func showInProject(_ task: Row) {
        page = task["project_id"].string.map(Page.project) ?? .inbox
        saveFolds(unfoldedDownTo(foldedTasks, task.id, tasks: snapshot.allTasks))
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            flash = task.id
            try? await Task.sleep(for: .milliseconds(700))
            if flash == task.id { flash = nil }
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

    func startProjectDrag(_ projectId: String) {
        /// The project, its parent and its siblings.
        func find(_ nodes: [Node], under parent: String?) -> (Node, String?, [Node])? {
            for node in nodes {
                if node.id == projectId { return (node, parent, nodes) }
                if let hit = find(node.children, under: node.id) { return hit }
            }
            return nil
        }
        func ids(_ nodes: [Node]) -> [String] { nodes.flatMap { [$0.id] + ids($0.children) } }
        guard let (node, parent, siblings) = find(snapshot.projects, under: nil),
              let index = siblings.firstIndex(where: { $0.id == projectId }) else {
            projectDrag = ProjectDrag(projectId: projectId, below: [])
            return
        }
        projectDrag = ProjectDrag(projectId: projectId, below: Set(ids(node.children)), parentId: parent,
                                  prev: index > 0 ? siblings[index - 1].id : nil,
                                  next: index + 1 < siblings.count ? siblings[index + 1].id : nil)
    }

    func endDrag() {
        dropMark = nil
        spring?.cancel()
        guard drag != nil || projectDrag != nil else { return }
        drag = nil
        projectDrag = nil
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
    /// A move by key or menu (named) has Edit ▸ Undo and no toast, as the sidebar's moves do.
    func drop(_ taskId: String, on target: DropTarget, named name: String? = nil) {
        spring?.cancel()
        guard let task = snapshot.allTasks[taskId] else { return }
        // Put under a folded task, it would vanish: unfold the way down to it.
        if case .place(let place) = target, let parent = place.parentId {
            saveFolds(unfoldedDownTo(foldedTasks, parent, tasks: snapshot.allTasks))
        }
        let names = dropNames(target, task)
        if case .label(let id) = target, task["labels"].array?.contains(.string(id)) == true {
            show(Toast(message: "Already has @\(names[id] ?? "")"))
            return
        }
        let message: (Done) -> String = { _ in describeDrop(target, task: task, names: names) { formatDay($0) } }
        let done = undoable(name ?? "Move", { try $0.drop(taskId, on: target) }, message: name == nil ? message : nil)
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
        case .day, .slot, .stretch: break
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

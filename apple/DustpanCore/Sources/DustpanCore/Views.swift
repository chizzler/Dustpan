import Foundation

// What Today, Upcoming and saved views list, and in what order.
// A port of views.py (web/src/lib/views.ts, v0.18.0). See spec/views.md.

public struct ViewGroup: Identifiable, Sendable {
    public let key: String
    public let heading: String
    public var tasks: [Row]
    public var id: String { key }
}

public struct ViewResult: Sendable {
    public var groups: [ViewGroup] = []
    /// Open matches.
    public var count = 0
    public var warnings: [String] = []
    public var error: String?
}

public enum ViewGroupBy: String, CaseIterable, Sendable { case project, due, priority, label, none }
public enum ViewSortBy: String, CaseIterable, Sendable { case due, priority, position, created, deadline, title }
public enum ViewSortDir: String, CaseIterable, Sendable { case asc, desc }

let defaultViewColor = "#64748b"
/// user_prefs.week_start; "system" reads as Monday.
let weekStartPrefs = ["sun": 0, "mon": 1, "sat": 6]

// MARK: - Today and Upcoming

func dueDate(_ task: Row, _ zone: TimeZone) -> String? { dueDay(task["due"], in: zone) }

private func dateText(_ value: JSON) -> String? { value.string.flatMap { $0.isEmpty ? nil : $0 } }

/// Due or deadline today or earlier, or a start date that has come. A hard date beats deferral.
func inToday(_ task: Row, today: String, zone: TimeZone) -> Bool {
    guard task["completed_at"].isNull else { return false }
    let due = dueDate(task, zone), deadline = dateText(task["deadline"]), start = dateText(task["start"])
    let hard = due.map { $0 <= today } ?? false || deadline.map { $0 <= today } ?? false
    return hard || start.map { $0 != "someday" && $0 <= today } ?? false
}

/// Today's Earlier group: due before today, or a passed deadline not planned for today.
func overdueInToday(_ task: Row, today: String, zone: TimeZone) -> Bool {
    let due = dueDate(task, zone)
    if let due, due < today { return true }
    return dateText(task["deadline"]).map { $0 < today && due != today } ?? false
}

/// Deferred, with no project and no do-on date: listed in Upcoming on its start date.
func deferredUnplaced(_ task: Row, today: String) -> Bool {
    task["completed_at"].isNull && task["project_id"].isNull && !task["due"].isTruthy && isDeferred(task, today: today)
}

func inUpcoming(_ task: Row, today: String, zone: TimeZone) -> Bool {
    if deferredUnplaced(task, today: today) { return true }
    guard task["completed_at"].isNull, isActive(task, today: today) else { return false }
    if task["due"].isTruthy { return dueDate(task, zone).map { $0 > today } ?? false }
    return dateText(task["deadline"]).map { $0 > today } ?? false
}

/// The day Upcoming lists a task under: its due date, else a deferred start, else its deadline.
func upcomingDate(_ task: Row, today: String, zone: TimeZone) -> String? {
    if task["due"].isTruthy { return dueDate(task, zone) }
    if deferredUnplaced(task, today: today) { return dateText(task["start"]) }
    return dateText(task["deadline"])
}

// MARK: - Sorting

public typealias TaskOrder = (Row, Row) -> Int

private func sign<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : a > b ? 1 : 0 }

/// Code-point order, as the other clients compare text.
private func textSign(_ a: String, _ b: String) -> Int { bytesLess(a, b) ? -1 : bytesLess(b, a) ? 1 : 0 }

private func number(_ value: JSON) -> Double { value.number ?? 0 }

/// Earlier first, all-day after timed on the same day, undated last.
func compareDue(_ a: JSON, _ b: JSON, zone: TimeZone) -> Int {
    if !a.isTruthy || !b.isTruthy { return (a.isTruthy ? 0 : 1) - (b.isTruthy ? 0 : 1) }
    func key(_ due: JSON) -> String {
        guard let w = localDue(due, in: zone) else { return "9999-99-99 99:99" }
        let time = w.hour.map { String(format: "%02d:%02d", $0, w.minute ?? 0) } ?? "99:99"
        return String(format: "%04d-%02d-%02d ", w.year, w.month, w.day) + time
    }
    return textSign(key(a), key(b))
}

/// One sort. Undated tasks stay last under due and deadline sorts. For priority, descending lists priority 1 first.
/// Ties fall back to due, priority, position and id.
func compareTasks(_ sortBy: ViewSortBy, _ dir: ViewSortDir, zone: TimeZone) -> TaskOrder {
    let flip = dir == .desc ? -1 : 1
    func fallback(_ a: Row, _ b: Row) -> Int {
        let due = compareDue(a["due"], b["due"], zone: zone)
        if due != 0 { return due }
        let priority = sign(number(a["priority"]), number(b["priority"]))
        if priority != 0 { return priority }
        let position = sign(number(a["position"]), number(b["position"]))
        return position != 0 ? position : textSign(a.id, b.id)
    }
    func by(_ a: Row, _ b: Row) -> Int {
        switch sortBy {
        case .due:
            let order = compareDue(a["due"], b["due"], zone: zone)
            return a["due"].isTruthy && b["due"].isTruthy ? flip * order : order
        case .deadline:
            let da = dateText(a["deadline"]), db = dateText(b["deadline"])
            guard let da, let db else { return (da == nil ? 1 : 0) - (db == nil ? 1 : 0) }
            return flip * textSign(da, db)
        case .priority: return flip * sign(number(b["priority"]), number(a["priority"]))
        case .title: return flip * textSign(text(a["title"]).lowercased(), text(b["title"]).lowercased())
        case .position: return flip * sign(number(a["position"]), number(b["position"]))
        case .created: return flip * sign(number(a["created_at"]), number(b["created_at"]))
        }
    }
    return { a, b in
        let order = by(a, b)
        return order != 0 ? order : fallback(a, b)
    }
}

private func text(_ value: JSON) -> String { value.string ?? "" }

/// A view's own order: placed tasks in the stored order, then the rest by position.
func manualOrder(_ order: JSON, _ dir: ViewSortDir, zone: TimeZone) -> TaskOrder {
    var rank: [String: Int] = [:]
    for id in order.array?.compactMap(\.string) ?? [] where rank[id] == nil { rank[id] = rank.count }
    func asc(_ a: Row, _ b: Row) -> Int {
        let ra = rank[a.id], rb = rank[b.id]
        if ra != nil || rb != nil {
            guard let ra, let rb else { return ra != nil ? -1 : 1 }
            return sign(ra, rb)
        }
        let position = sign(number(a["position"]), number(b["position"]))
        if position != 0 { return position }
        let due = compareDue(a["due"], b["due"], zone: zone)
        if due != 0 { return due }
        let priority = sign(number(a["priority"]), number(b["priority"]))
        return priority != 0 ? priority : textSign(a.id, b.id)
    }
    return dir == .desc ? { asc($1, $0) } : asc
}

func sorted(_ tasks: [Row], _ order: TaskOrder) -> [Row] { tasks.sorted { order($0, $1) < 0 } }

// MARK: - Grouping

/// "Today", "Tomorrow", a weekday this week, else the date, with the year when it isn't this year's.
public func dayHeading(_ day: Day, today: Day, locale: Locale = .current) -> String {
    let delta = day - today
    if delta == 0 { return "Today" }
    if delta == 1 { return "Tomorrow" }
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = .gmt
    f.dateFormat = 1 < delta && delta < 7 ? "EEEE" : day.parts.year != today.parts.year ? "EEE d MMM yyyy" : "EEE d MMM"
    return f.string(from: Date(timeIntervalSince1970: Double(day.number) * 86_400))
}

/// Sorted tasks split into headed groups, in a fixed order.
/// labels: live labels in sidebar order. projects: (id, path) in sidebar order.
func groupTasks(_ tasks: [Row], by groupBy: ViewGroupBy, today: Day, labels: [Row],
                projects: [(id: String, path: String)], zone: TimeZone) -> [ViewGroup] {
    var buckets: [String: [Row]] = [:]
    func emit(_ order: [(String, String)]) -> [ViewGroup] {
        order.compactMap { key, heading in buckets[key].map { ViewGroup(key: key, heading: heading, tasks: $0) } }
    }
    switch groupBy {
    case .none:
        return tasks.isEmpty ? [] : [ViewGroup(key: "all", heading: "", tasks: tasks)]
    case .priority:
        for task in tasks { buckets["p\(task["priority"].int.map(String.init) ?? "?")", default: []].append(task) }
        return emit((1...4).map { ("p\($0)", $0 < 4 ? "Priority \($0)" : "No priority") })
    case .due:
        let (now, next) = (today.description, (today + 1).description)
        var later = Set<String>()
        for task in tasks {
            let day = dueDate(task, zone)
            let key = switch day {
            case nil: "none"
            case let d? where d < now: "overdue"
            case now: "today"
            case next: "tomorrow"
            case let d?: d
            }
            if key == day { later.insert(key) }
            buckets[key, default: []].append(task)
        }
        let days = later.sorted().map { ($0, Day($0).map { dayHeading($0, today: today) } ?? $0) }
        return emit([("overdue", "Earlier"), ("today", "Today"), ("tomorrow", "Tomorrow")] + days + [("none", "No date")])
    case .label:
        // A task with several labels is listed under each.
        let known = Set(labels.map(\.id))
        for task in tasks {
            var own: [String] = []
            for id in task["labels"].array?.compactMap(\.string) ?? [] where known.contains(id) && !own.contains(id) {
                own.append(id)
            }
            for key in own.isEmpty ? ["none"] : own { buckets[key, default: []].append(task) }
        }
        return emit(labels.map { ($0.id, text($0["name"])) } + [("none", "No label")])
    case .project:
        let known = Set(projects.map(\.id))
        for task in tasks {
            let key = task["project_id"].string.map { known.contains($0) ? $0 : "other" } ?? "inbox"
            buckets[key, default: []].append(task)
        }
        return emit([("inbox", "Inbox")] + projects.map { ($0.id, $0.path) } + [("other", "Other")])
    }
}

/// Today: the Earlier group, then today's tasks by time.
public func todayGroups(_ tasks: [Row], today: Day, zone: TimeZone = .current) -> [ViewGroup] {
    let now = today.description
    let listed = sorted(tasks.filter { inToday($0, today: now, zone: zone) }, compareTasks(.due, .asc, zone: zone))
    let earlier = listed.filter { overdueInToday($0, today: now, zone: zone) }
    let rest = listed.filter { !overdueInToday($0, today: now, zone: zone) }
    return [ViewGroup(key: "earlier", heading: "Earlier", tasks: earlier), ViewGroup(key: "today", heading: "Today", tasks: rest)]
        .filter { !$0.tasks.isEmpty }
}

/// How many tasks Today lists.
public func todayCount(_ tasks: [Row], today: Day, zone: TimeZone = .current) -> Int {
    tasks.count { inToday($0, today: today.description, zone: zone) }
}

/// Upcoming: one group per day. On each day, tasks due then come before ones with only a deadline.
public func upcomingGroups(_ tasks: [Row], today: Day, zone: TimeZone = .current) -> [ViewGroup] {
    let now = today.description
    let byDue = compareTasks(.due, .asc, zone: zone)
    let order: TaskOrder = { a, b in
        let day = textSign(upcomingDate(a, today: now, zone: zone) ?? "", upcomingDate(b, today: now, zone: zone) ?? "")
        if day != 0 { return day }
        let dueFirst = (a["due"].isTruthy ? 0 : 1) - (b["due"].isTruthy ? 0 : 1)
        return dueFirst != 0 ? dueFirst : byDue(a, b)
    }
    var groups: [ViewGroup] = []
    for task in sorted(tasks.filter { inUpcoming($0, today: now, zone: zone) }, order) {
        let day = upcomingDate(task, today: now, zone: zone) ?? ""
        if groups.last?.key == day {
            groups[groups.count - 1].tasks.append(task)
        } else {
            groups.append(ViewGroup(key: day, heading: Day(day).map { dayHeading($0, today: today) } ?? day, tasks: [task]))
        }
    }
    return groups
}

// MARK: - Saved views

/// group_by, sort_by and sort_dir. A value this client doesn't know reads as the default.
public func viewOptions(_ view: Row) -> (ViewGroupBy, ViewSortBy, ViewSortDir) {
    (view["group_by"].string.flatMap(ViewGroupBy.init) ?? .project,
     view["sort_by"].string.flatMap(ViewSortBy.init) ?? .due,
     view["sort_dir"].string.flatMap(ViewSortDir.init) ?? .asc)
}

/// Live and not a dashboard. An unknown kind reads as a list.
func isListView(_ view: Row) -> Bool { view["deleted_at"].isNull && view["kind"].string != "dashboard" }

func viewOrderLess(_ a: Row, _ b: Row) -> Bool {
    let (pa, pb) = (number(a["position"]), number(b["position"]))
    if pa != pb { return pa < pb }
    let (ca, cb) = (number(a["created_at"]), number(b["created_at"]))
    return ca != cb ? ca < cb : bytesLess(a.id, b.id)
}

/// The tasks a query matches among candidates, how many are open, and its warnings.
public func runQuery(_ query: String, _ ctx: FilterContext, _ candidates: [Row], showCompleted: Bool = false)
    throws(FilterError) -> (matches: [Row], count: Int, warnings: [String]) {
    guard let ast = try parseFilter(query) else { throw FilterError("This view has no query", 0) }
    let (test, warnings) = compileFilter(showCompleted ? withCompleted(ast) : ast, ctx)
    let matches = candidates.filter(test)
    return (matches, matches.count { $0["completed_at"].isNull }, warnings)
}

/// A saved view's groups. A query this client can't parse gives its error and no results.
public func runView(_ view: Row, _ ctx: FilterContext, _ candidates: [Row], labels: [Row],
                    projects: [(id: String, path: String)]) -> ViewResult {
    let found: (matches: [Row], count: Int, warnings: [String])
    do {
        found = try runQuery(view["query"].string ?? "", ctx, candidates, showCompleted: view["show_completed"] == true)
    } catch {
        return ViewResult(error: error.message)
    }
    let (groupBy, sortBy, sortDir) = viewOptions(view)
    let order = sortBy == .position ? manualOrder(view["manual_order"], sortDir, zone: ctx.zone)
        : compareTasks(sortBy, sortDir, zone: ctx.zone)
    return ViewResult(groups: groupTasks(sorted(found.matches, order), by: groupBy, today: ctx.today, labels: labels,
                                         projects: projects, zone: ctx.zone),
                      count: found.count, warnings: found.warnings)
}

// MARK: - Label pages

/// A label's open tasks across projects, grouped by project unless the label's own options say otherwise.
public func labelGroups(_ label: Row, _ tasks: [Row], today: Day, labels: [Row],
                        projects: [(id: String, path: String)], zone: TimeZone = .current) -> [ViewGroup] {
    let iso = today.description
    let own = tasks.filter { $0["completed_at"].isNull && isActive($0, today: iso) && labelIds($0).contains(label.id) }
    let (groupBy, sortBy, sortDir) = viewOptions(label)
    let order = sortBy == .position ? manualOrder(label["manual_order"], sortDir, zone: zone)
        : compareTasks(sortBy, sortDir, zone: zone)
    return groupTasks(sorted(own, order), by: groupBy, today: today, labels: labels, projects: projects, zone: zone)
}

/// Open, active tasks per label id, as the sidebar counts them.
public func labelCounts(_ tasks: [Row], today: Day) -> [String: Int] {
    var counts: [String: Int] = [:]
    for task in tasks where task["completed_at"].isNull && isActive(task, today: today.description) {
        for id in Set(labelIds(task)) { counts[id, default: 0] += 1 }
    }
    return counts
}

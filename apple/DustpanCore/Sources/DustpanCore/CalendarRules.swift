import Foundation

// The calendar's rules: which tasks show on which day, in what order, and how full a day is.
// A port of the desktop's calendar_rules.py, itself from the web app's month.ts and calendar.ts. See spec/calendar.md.

/// Store meta, per device: whether the calendar window is open, completed tasks are shown, and the grid's settings.
public let calendarOpenKey = "calendar_open"
public let calendarShowCompletedKey = "calendar_show_completed"
public let calendarGridKey = "calendar_grid"
/// "day", "week" or "month".
public let calendarViewKey = "calendar_view"

/// The seven days of the week holding day, from weekStart (0 is Sunday).
public func weekDates(_ day: Day, weekStart: Int = 1) -> [Day] {
    let first = day - mod(day.weekday % 7 - weekStart, 7)
    return (0..<7).map { first + $0 }
}

/// Six weeks of seven days covering day's month.
public func monthGrid(_ day: Day, weekStart: Int = 1) -> [[Day]] {
    let (year, month, _) = day.parts
    let first = weekDates(Day(year: year, month: month, day: 1), weekStart: weekStart)[0]
    return (0..<6).map { row in (0..<7).map { first + 7 * row + $0 } }
}

/// Where a task is on the calendar: a day, and minutes from midnight when it has a time.
public struct CalendarSpot: Equatable, Sendable {
    public let day: Day
    public let minutes: Int?
}

/// A task's due on this device. A zoned due converts.
public func viewedDue(_ task: Row, zone: TimeZone = .current) -> CalendarSpot? {
    guard let wall = localDue(task["due"], in: zone) else { return nil }
    return CalendarSpot(day: Day(year: wall.year, month: wall.month, day: wall.day),
                        minutes: wall.hour.map { $0 * 60 + (wall.minute ?? 0) })
}

/// The local day a task was completed. completed_at is Unix ms.
func completedDay(_ task: Row, zone: TimeZone = .current) -> Day? {
    task["completed_at"].number.map { Day(Date(ms: Int64($0)), in: zone) }
}

/// Where the calendar shows a task: on its due. A completed task without one shows on the day it was completed.
public func shownSpot(_ task: Row, zone: TimeZone = .current) -> CalendarSpot? {
    viewedDue(task, zone: zone) ?? completedDay(task, zone: zone).map { CalendarSpot(day: $0, minutes: nil) }
}

/// Live tasks shown from first to last on this device, outside archived projects.
/// showCompleted adds completed tasks; a habit's skipped days are left out.
public func calendarTasks(_ tasks: some Sequence<Row>, archived: Set<String>, from first: Day, to last: Day,
                          showCompleted: Bool = false, zone: TimeZone = .current) -> [Row] {
    tasks.filter { task in
        let done = !task["completed_at"].isNull
        guard let spot = shownSpot(task, zone: zone), first <= spot.day, spot.day <= last else { return false }
        return task["deleted_at"].isNull && (showCompleted || !done) && !(done && task["skipped"].isTruthy)
            && !task["project_id"].string.map(archived.contains).isTrue
    }
}

/// Tasks by the day they show on, in a day's order: open before completed, then timed first by time,
/// then priority (1 first), then position.
public func byDay(_ tasks: [Row], zone: TimeZone = .current) -> [Day: [Row]] {
    var days: [Day: [(key: DayOrder, task: Row)]] = [:]
    for task in tasks {
        guard let spot = shownSpot(task, zone: zone) else { continue }
        days[spot.day, default: []].append((DayOrder(task, spot), task))
    }
    return days.mapValues { $0.sorted { $0.key < $1.key }.map(\.task) }
}

private struct DayOrder: Comparable {
    let done: Int
    let untimed: Int
    let minutes: Int
    let priority: Int64
    let position: Double

    init(_ task: Row, _ spot: CalendarSpot) {
        done = task["completed_at"].isNull ? 0 : 1
        untimed = spot.minutes == nil ? 1 : 0
        minutes = spot.minutes ?? 0
        priority = task["priority"].int ?? 4
        position = task["position"].number ?? 0
    }

    static func < (a: DayOrder, b: DayOrder) -> Bool {
        (a.done, a.untimed, a.minutes, a.priority, a.position) < (b.done, b.untimed, b.minutes, b.priority, b.position)
    }
}

/// Open tasks by their deadline day, leaving out a task due on its deadline day. By priority, then title.
public func deadlineMarkers(_ tasks: some Sequence<Row>, archived: Set<String>, from first: Day, to last: Day,
                            zone: TimeZone = .current) -> [Day: [Row]] {
    var out: [Day: [Row]] = [:]
    for task in tasks {
        guard let deadline = task["deadline"].string.flatMap(Day.init), first <= deadline, deadline <= last,
              task["deleted_at"].isNull, task["completed_at"].isNull,
              !task["project_id"].string.map(archived.contains).isTrue,
              viewedDue(task, zone: zone)?.day != deadline else { continue }
        out[deadline, default: []].append(task)
    }
    return out.mapValues { markers in
        markers.sorted {
            let (a, b) = ($0["priority"].int ?? 4, $1["priority"].int ?? 4)
            return a != b ? a < b : ($0["title"].string ?? "").lowercased() < ($1["title"].string ?? "").lowercased()
        }
    }
}

/// How full a day is: planned minutes, open tasks without an estimate, and whether it's over the day length.
public struct DayLoad: Equatable, Sendable {
    public let planned: Int
    public let unestimated: Int
    public let over: Bool
}

/// The web app's default day length, in minutes.
public let defaultDayLength = 480

public func dayLoad(_ tasks: [Row], dayLength: Int = defaultDayLength) -> DayLoad {
    var planned = 0, unestimated = 0
    for task in tasks where task["completed_at"].isNull && task["deleted_at"].isNull {
        if let minutes = task["estimate_minutes"].int, minutes != 0 {
            planned += Int(minutes)
        } else {
            unestimated += 1
        }
    }
    return DayLoad(planned: planned, unestimated: unestimated, over: planned > dayLength)
}

/// The rows a day shows, and how many are hidden: all when they fit, else most − 1 and a "+N more".
public func visibleRows<T>(_ cell: [T], most: Int) -> (shown: [T], hidden: Int) {
    if cell.count <= most { return (cell, 0) }
    let keep = max(0, most - 1)
    return (Array(cell.prefix(keep)), cell.count - keep)
}

// MARK: - Day and Week: blocks on a time grid (calendar.ts, layout.ts)

public let dayMinutes = 24 * 60
public let slotMinutes = 15
/// How long an unestimated block is drawn. It counts for nothing.
public let defaultBlockMinutes = 30
/// The shortest a block is drawn: room for its title.
public let minBlockMinutes = 25
/// The latest a block may start.
public let lastSlot = dayMinutes - slotMinutes
public let maxLanes = 4

/// Minutes from midnight as "HH:MM".
public func hhmm(_ minutes: Int) -> String {
    let (h, m) = (minutes / 60, minutes % 60)
    return (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
}

/// A task's block on its day, in minutes from midnight; nil without a time.
/// An unestimated block is drawn 30 minutes long. A block past midnight stops at the day's end.
public func blockFor(_ task: Row, zone: TimeZone = .current) -> (start: Int, end: Int, estimated: Bool)? {
    guard let start = viewedDue(task, zone: zone)?.minutes else { return nil }
    let estimate = task["estimate_minutes"].int.map(Int.init).flatMap { $0 > 0 ? $0 : nil }
    return (start, min(dayMinutes, start + (estimate ?? defaultBlockMinutes)), estimate != nil)
}

/// A block placed side by side with the blocks it overlaps: lane of lanes. Hidden ones are behind a "+N".
public struct PlacedBlock: Equatable, Sendable {
    public let id: String
    public let start: Int
    public let end: Int
    public let lane: Int
    public let lanes: Int
    public let overlap: Bool
    public let hidden: Bool
}

/// The "+N" in a cluster's last lane, from the earliest start to the latest end of the blocks it hides.
public struct BlockOverflow: Equatable, Sendable {
    public let lane: Int
    public let lanes: Int
    public let start: Int
    public let end: Int
    public let ids: [String]
}

/// Side by side layout of overlapping blocks. A port of layout.ts's layoutDay.
/// Placed come in time order. Blocks that overlap, as drawn at least minLength tall, form a cluster split into
/// equal lanes. A cluster needing more than maxLanes shows maxLanes − 1 lanes and a "+N" in the last.
/// spare: ids hidden first when a cluster overflows (completed tasks), so they never push others out.
public func layoutDay(_ blocks: [(id: String, start: Int, end: Int)], maxLanes: Int = maxLanes, minLength: Int = 0,
                      spare: Set<String> = []) -> (placed: [PlacedBlock], overflow: [BlockOverflow]) {
    typealias Block = (id: String, start: Int, end: Int)
    let cap = max(2, maxLanes)
    let ordered = blocks.map { b in (id: b.id, start: b.start, end: b.end > b.start ? b.end : b.start + 1) }
        .sorted { ($0.start, -$0.end, $0.id) < ($1.start, -$1.end, $1.id) }
    var placed: [PlacedBlock] = [], overflow: [BlockOverflow] = []
    var cluster: [(block: Block, lane: Int)] = [], laneEnds: [Int] = [], clusterEnd = Int.min

    func flush() {
        guard !cluster.isEmpty else { return }
        func overlaps(_ x: Block) -> Bool {
            cluster.contains { $0.block.id != x.id && $0.block.start < x.end && x.start < $0.block.end }
        }
        if laneEnds.count <= cap {
            placed += cluster.map { b, lane in
                PlacedBlock(id: b.id, start: b.start, end: b.end, lane: lane, lanes: laneEnds.count,
                            overlap: overlaps(b), hidden: false)
            }
            return
        }
        // Too many lanes: fill the first cap − 1, the other blocks before the spare ones, each in the first lane
        // it fits; what doesn't fit goes behind the "+N" in the last. Without spare blocks this is the web app's.
        let marker = cap - 1
        var lanes = Array(repeating: [(start: Int, end: Int)](), count: marker)
        var laneOf: [String: Int] = [:]
        let others = cluster.filter { !spare.contains($0.block.id) } + cluster.filter { spare.contains($0.block.id) }
        for (b, _) in others {
            let drawn = (start: b.start, end: max(b.end, b.start + minLength))
            if let free = lanes.firstIndex(where: { $0.allSatisfy { $0.end <= drawn.start || drawn.end <= $0.start } }) {
                lanes[free].append(drawn)
                laneOf[b.id] = free
            }
        }
        // Never empty: more than cap lanes means more than cap blocks overlap at one minute.
        let hidden = cluster.map(\.block).filter { laneOf[$0.id] == nil }
        placed += cluster.map { b, _ in
            PlacedBlock(id: b.id, start: b.start, end: b.end, lane: laneOf[b.id] ?? marker, lanes: cap,
                        overlap: overlaps(b), hidden: laneOf[b.id] == nil)
        }
        overflow.append(BlockOverflow(lane: marker, lanes: cap, start: hidden.map(\.start).min()!,
                                      end: hidden.map(\.end).max()!, ids: hidden.map(\.id)))
    }

    for b in ordered {
        if b.start >= clusterEnd {
            flush()
            (cluster, laneEnds, clusterEnd) = ([], [], Int.min)
        }
        let end = max(b.end, b.start + minLength)
        let lane = laneEnds.firstIndex { $0 <= b.start } ?? laneEnds.count
        if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
        cluster.append((b, lane))
        clusterEnd = max(clusterEnd, end)
    }
    flush()
    return (placed, overflow)
}

/// This device's grid settings (meta calendar_grid), each invalid or missing one at its default.
/// A port of normalizeGridPrefs: when the hours cross, the stored one is kept and the other repaired.
public struct GridPrefs: Equatable, Sendable {
    public var startHour = 6
    public var endHour = 22
    /// Minutes: what a day's load is measured against.
    public var dayLength = defaultDayLength

    public init() {}

    public init(_ raw: JSON) {
        func whole(_ name: String, _ range: ClosedRange<Int>) -> Int? {
            guard case .int(let value) = raw[name], range.contains(Int(value)) else { return nil }
            return Int(value)
        }
        let (start, end) = (whole("startHour", 0...23), whole("endHour", 1...24))
        startHour = start ?? startHour
        endHour = end ?? endHour
        if endHour <= startHour {
            switch (start, end) {
            case (.some, nil): endHour = min(24, startHour + 1)
            case (nil, .some): startHour = max(0, endHour - 1)
            default: (startHour, endHour) = (6, 22)
            }
        }
        dayLength = whole("dayLength", 15...1440) ?? defaultDayLength
    }
}

extension Bool? {
    var isTrue: Bool { self == true }
}

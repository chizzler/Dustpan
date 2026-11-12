import Foundation

/// What the calendar's Week and Day show: for each day, its header (load, deadlines, the Unscheduled lane)
/// and its timed tasks as blocks laid out side by side.
public struct TimeGridPage: Sendable {
    public struct Block: Identifiable, Sendable {
        public let task: Row
        public let start: Int
        public let end: Int
        public let lane: Int
        public let lanes: Int
        /// False: no estimate, drawn 30 minutes long with a dashed edge.
        public let estimated: Bool
        public var id: String { task.id }
        /// How tall it's drawn, in minutes.
        public var length: Int { max(minBlockMinutes, end - start) }
    }

    /// The "+N more" in a crowded cluster's last lane.
    public struct More: Identifiable, Sendable {
        public let start: Int
        public let lane: Int
        public let lanes: Int
        public let tasks: [Row]
        public var id: Int { start }
    }

    public struct Column: Identifiable, Sendable {
        public let day: Day
        /// Tasks due that day with no time, in the day's order.
        public let untimed: [Row]
        public let deadlines: [Row]
        public let load: DayLoad
        public let blocks: [Block]
        public let more: [More]
        public let isPast: Bool
        public let isToday: Bool
        public var id: Day { day }
    }

    public let columns: [Column]
    /// Project colours by id. The Inbox has none.
    public let colors: [String: String]

    public init(_ snapshot: Snapshot, days: [Day], today: Day, showCompleted: Bool, dayLength: Int,
                zone: TimeZone = .current) {
        let archived = Set(snapshot.archivedProjects.map(\.row.id))
        let (first, last) = (days[0], days[days.count - 1])
        let byDays = byDay(calendarTasks(snapshot.tasks, archived: archived, from: first, to: last,
                                         showCompleted: showCompleted, zone: zone), zone: zone)
        let deadlines = deadlineMarkers(snapshot.tasks, archived: archived, from: first, to: last, zone: zone)
        columns = days.map { day in
            let tasks = byDays[day] ?? []
            var timed: [String: (task: Row, estimated: Bool)] = [:]
            var spans: [(id: String, start: Int, end: Int)] = []
            var untimed: [Row] = []
            for task in tasks {
                if let block = blockFor(task, zone: zone) {
                    timed[task.id] = (task, block.estimated)
                    spans.append((task.id, block.start, block.end))
                } else {
                    untimed.append(task)
                }
            }
            let done = Set(tasks.filter { !$0["completed_at"].isNull }.map(\.id))
            let (placed, overflow) = layoutDay(spans, minLength: minBlockMinutes, spare: done)
            return Column(
                day: day, untimed: untimed, deadlines: deadlines[day] ?? [],
                load: dayLoad(tasks, dayLength: dayLength),
                blocks: placed.filter { !$0.hidden }.compactMap { b in
                    timed[b.id].map { Block(task: $0.task, start: b.start, end: b.end, lane: b.lane, lanes: b.lanes,
                                            estimated: $0.estimated) }
                },
                more: overflow.map { o in
                    More(start: o.start, lane: o.lane, lanes: o.lanes, tasks: o.ids.compactMap { timed[$0]?.task })
                },
                isPast: day < today, isToday: day == today)
        }
        colors = snapshot.projectColors
    }
}

extension Snapshot {
    /// Live projects' colours by id, for the dots and blocks on the calendar.
    public var projectColors: [String: String] {
        Dictionary(liveProjects.compactMap { p in p["color"].string.map { (p.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }
}

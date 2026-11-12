import Foundation

/// What the calendar's Month shows: six weeks, each day with its tasks, deadlines and load.
public struct MonthPage: Sendable {
    public struct Cell: Identifiable, Sendable {
        public let day: Day
        /// In the day's order: open before completed, timed first.
        public let tasks: [Row]
        public let deadlines: [Row]
        public let load: DayLoad
        public let inMonth: Bool
        public let isPast: Bool
        public let isToday: Bool
        public var id: Day { day }
    }

    public let weeks: [[Cell]]
    /// Project colours by id, for the dots on task lines. The Inbox has none.
    public let colors: [String: String]

    /// The month holding anchor. Tasks come from the snapshot, which leaves out archived and deleted projects.
    public init(_ snapshot: Snapshot, anchor: Day, today: Day, showCompleted: Bool, dayLength: Int,
                zone: TimeZone = .current) {
        let grid = monthGrid(anchor, weekStart: snapshot.filterContext(today: today).weekStart)
        let (first, last) = (grid[0][0], grid[5][6])
        let archived = Set(snapshot.archivedProjects.map(\.row.id))
        let days = byDay(calendarTasks(snapshot.tasks, archived: archived, from: first, to: last,
                                       showCompleted: showCompleted, zone: zone), zone: zone)
        let deadlines = deadlineMarkers(snapshot.tasks, archived: archived, from: first, to: last, zone: zone)
        let month = anchor.parts.month
        weeks = grid.map { week in
            week.map { day in
                let tasks = days[day] ?? []
                return Cell(day: day, tasks: tasks, deadlines: deadlines[day] ?? [],
                            load: dayLoad(tasks, dayLength: dayLength), inMonth: day.parts.month == month,
                            isPast: day < today, isToday: day == today)
            }
        }
        colors = snapshot.projectColors
    }
}

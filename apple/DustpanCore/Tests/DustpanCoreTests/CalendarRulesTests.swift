import Foundation
import Testing
@testable import DustpanCore

// The calendar's Month rules. A port of tests/test_calendar_rules.py's MonthTest, TasksTest and GridPrefsTest.

private let utc = TimeZone(identifier: "UTC")!

private func day(_ text: String) -> Day { Day(text)! }

private func task(_ id: String, _ date: String? = nil, _ time: String? = nil, _ fields: [String: JSON] = [:]) -> Row {
    var values: [String: JSON] = ["priority": 4, "position": 0, "completed_at": nil, "deleted_at": nil, "project_id": nil]
    if let date { values["due"] = time.map { ["date": .string(date), "time": .string($0)] } ?? ["date": .string(date)] }
    values.merge(fields) { _, new in new }
    return Row(id: id, values: values)
}

private func ids(_ rows: [Row]?) -> [String] { rows?.map(\.id) ?? [] }

@Suite struct CalendarMonthTests {
    // The first three cases are month.test.ts's.
    @Test func sixWeeksMondayOrSundayFirst() {
        let mon = monthGrid(day("2026-11-15"), weekStart: 1)
        #expect(mon.count == 6 && mon[0][0] == day("2026-10-26") && mon[5][6] == day("2026-12-06"))
        #expect(monthGrid(day("2026-11-15"), weekStart: 0)[0][0] == day("2026-11-01"))
    }

    @Test func aMonthThatNeedsSixRows() {
        let grid = monthGrid(day("2026-08-10"), weekStart: 1)
        #expect(grid[0][0] == day("2026-07-27") && grid[5][0] == day("2026-08-31"))
    }

    @Test func aCellKeepsALineForMore() {
        #expect(visibleRows([1, 2, 3], most: 3) == ([1, 2, 3], 0))
        #expect(visibleRows([1, 2, 3, 4, 5], most: 3) == ([1, 2], 3))
    }

    @Test func addMonthsClampsToTheLastDay() {
        #expect(addMonths(day("2026-01-31"), 1) == day("2026-02-28"))
        #expect(addMonths(day("2026-11-04"), 2) == day("2027-01-04"))
        #expect(addMonths(day("2026-01-15"), -1) == day("2025-12-15"))
    }

    @Test func weekDatesStartOnTheWeekStart() {
        #expect(weekDates(day("2026-11-04"), weekStart: 1)[0] == day("2026-11-02"))
        #expect(weekDates(day("2026-11-04"), weekStart: 0)[0] == day("2026-11-01"))
        #expect(weekDates(day("2026-11-01"), weekStart: 1)[0] == day("2026-10-26"))
    }
}

@Suite struct CalendarTasksTests {
    let first = day("2026-10-26"), last = day("2026-12-06")

    @Test func aDayOrdersTimedFirstThenPriorityThenPosition() {
        let tasks = [task("p4a", "2026-11-03", nil, ["position": 2]), task("p4b", "2026-11-03", nil, ["position": 1]),
                     task("p1", "2026-11-03", nil, ["priority": 1]), task("late", "2026-11-03", "18:00"),
                     task("early", "2026-11-03", "08:30"), task("other", "2026-11-04")]
        let days = byDay(tasks, zone: utc)
        #expect(ids(days[day("2026-11-03")]) == ["early", "late", "p1", "p4b", "p4a"])
        #expect(ids(days[day("2026-11-04")]) == ["other"])
    }

    @Test func whichTasksShow() {
        let tasks = [task("in", "2026-11-03"), task("before", "2026-10-01"), task("undated"),
                     task("done", "2026-11-03", nil, ["completed_at": 5]), task("gone", "2026-11-03", nil, ["deleted_at": 5]),
                     task("archived", "2026-11-03", nil, ["project_id": "old"])]
        #expect(ids(calendarTasks(tasks, archived: ["old"], from: first, to: last, zone: utc)) == ["in"])
        #expect(ids(calendarTasks(tasks, archived: ["old"], from: first, to: last, showCompleted: true, zone: utc))
            == ["in", "done"])
    }

    @Test func completedTasksShowOnTheirDueOrTheDayTheyWereDone() {
        let noon = JSON.int(Int64(gregorian(utc).date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!.ms))
        let tasks = [task("open", "2026-11-03"), task("done-due", "2026-11-03", nil, ["completed_at": noon]),
                     task("done-undated", nil, nil, ["completed_at": noon]),
                     task("skipped", "2026-11-03", nil, ["completed_at": noon, "skipped": true])]
        let shown = calendarTasks(tasks, archived: [], from: first, to: last, showCompleted: true, zone: utc)
        #expect(ids(shown) == ["open", "done-due", "done-undated"])
        let days = byDay(shown, zone: utc)
        #expect(days.mapValues(ids) == [day("2026-11-03"): ["open", "done-due"], day("2026-11-05"): ["done-undated"]])
    }

    @Test func completedTasksComeAfterOpenOnes() {
        let tasks = [task("done", "2026-11-03", "08:00", ["completed_at": 1]), task("open", "2026-11-03")]
        #expect(ids(byDay(tasks, zone: utc)[day("2026-11-03")]) == ["open", "done"])
    }

    @Test func deadlineMarkersSkipTasksDueThatDay() {
        let tasks = [task("a", nil, nil, ["deadline": "2026-11-10", "title": "b"]),
                     task("b", "2026-11-10", nil, ["deadline": "2026-11-10"]),
                     task("c", nil, nil, ["deadline": "2026-11-10", "priority": 1, "title": "z"]),
                     task("d", nil, nil, ["deadline": "2026-11-10", "completed_at": 1]),
                     task("e", nil, nil, ["deadline": "2027-01-01"])]
        let markers = deadlineMarkers(tasks, archived: [], from: first, to: last, zone: utc)
        #expect(markers.mapValues(ids) == [day("2026-11-10"): ["c", "a"]])
    }

    @Test func dayLoadCountsOpenEstimates() {
        let tasks = [task("a", nil, nil, ["estimate_minutes": 300]), task("b", nil, nil, ["estimate_minutes": 240]),
                     task("c"), task("d", nil, nil, ["estimate_minutes": 60, "completed_at": 1])]
        #expect(dayLoad(tasks) == DayLoad(planned: 540, unestimated: 1, over: true))
        #expect(dayLoad(Array(tasks.prefix(1))) == DayLoad(planned: 300, unestimated: 0, over: false))
    }

    @Test func aZonedDueShowsOnTheViewersDay() {
        let late = task("late", nil, nil, ["due": ["date": "2026-11-03", "time": "23:30", "tz": "UTC"]])
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        #expect(viewedDue(late, zone: sydney) == CalendarSpot(day: day("2026-11-04"), minutes: 10 * 60 + 30))
    }
}

@Suite struct GridPrefsTests {
    func prefs(_ start: Int, _ end: Int, _ length: Int) -> GridPrefs {
        var p = GridPrefs()
        (p.startHour, p.endHour, p.dayLength) = (start, end, length)
        return p
    }

    @Test func defaultsAndRepairs() {
        let standard = GridPrefs()
        #expect(GridPrefs(nil) == standard)
        #expect(GridPrefs("junk") == standard)
        #expect(GridPrefs(["startHour": 8, "endHour": 18, "dayLength": 360]) == prefs(8, 18, 360))
        #expect(GridPrefs(["startHour": 7.5, "endHour": 30, "dayLength": 0]) == standard)
        #expect(GridPrefs(["startHour": 23]) == prefs(23, 24, 480))
        #expect(GridPrefs(["endHour": 4]) == prefs(3, 4, 480))
        #expect(GridPrefs(["startHour": 18, "endHour": 9]) == standard)
        #expect(GridPrefs(["startHour": true]) == standard)
    }
}

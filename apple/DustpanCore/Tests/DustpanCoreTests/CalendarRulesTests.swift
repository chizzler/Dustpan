import Foundation
import Testing
@testable import DustpanCore

// The calendar's rules. A port of tests/test_calendar_rules.py's MonthTest, TasksTest, LayoutTest, BlockTest,
// StretchTest, GridPrefsTest and GridMovesTest.

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

/// Hours as minutes.
private func h(_ hours: Double) -> Int { Int(hours * 60) }

/// layout.test.ts's cases.
@Suite struct CalendarLayoutTests {
    func lay(_ blocks: [(id: String, start: Int, end: Int)], maxLanes: Int = maxLanes, minLength: Int = 0)
        -> (byId: [String: PlacedBlock], overflow: [BlockOverflow], placed: [PlacedBlock]) {
        let (placed, overflow) = layoutDay(blocks, maxLanes: maxLanes, minLength: minLength)
        return (Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) }), overflow, placed)
    }

    @Test func disjointAndTouchingBlocksTakeTheFullWidth() {
        let (m, overflow, _) = lay([("a", h(9), h(10)), ("b", h(10), h(11)), ("c", h(13), h(13.5))])
        #expect(overflow.isEmpty)
        #expect(m.values.allSatisfy { $0.lane == 0 && $0.lanes == 1 && !$0.overlap })
    }

    @Test func sameTimeSideBySideOrderedById() {
        let m = lay([("y", h(10), h(10.5)), ("x", h(10), h(10.5))]).byId
        #expect(m["x"]!.lane == 0 && m["y"]!.lane == 1 && m["x"]!.lanes == 2 && m["x"]!.overlap)
    }

    @Test func nestedAndChained() {
        var m = lay([("inner1", h(9.5), h(10)), ("outer", h(9), h(12)), ("inner2", h(10.5), h(11))]).byId
        #expect(["outer", "inner1", "inner2"].map { [m[$0]!.lane, m[$0]!.lanes] } == [[0, 2], [1, 2], [1, 2]])
        m = lay([("a", h(9), h(10)), ("b", h(9.5), h(10.5)), ("c", h(10), h(11))]).byId
        #expect(["a", "b", "c"].map { m[$0]!.lane } == [0, 1, 0])
    }

    @Test func clustersSizeIndependently() {
        let m = lay([("a", h(9), h(10)), ("b", h(9), h(10)), ("c", h(9), h(10)), ("d", h(14), h(15))]).byId
        #expect(["a", "b", "c"].map { m[$0]!.lanes } == [3, 3, 3] && m["d"]!.lanes == 1)
    }

    @Test func noTwoVisibleBlocksCollide() {
        let blocks = (0..<30).map { i in
            (id: "t\(i)", start: (i * 37) % 600 + 360, end: (i * 37) % 600 + 360 + 15 + (i * 13) % 90)
        }
        let placed = lay(blocks, maxLanes: 100).placed
        for x in placed {
            #expect(x.lane < x.lanes)
            for y in placed where x.id != y.id && x.lane == y.lane {
                #expect(!(x.start < y.end && y.start < x.end))
            }
        }
    }

    @Test func capsAtFourLanes() {
        var (_, overflow, placed) = lay("abcdef".map { (String($0), h(10), h(11)) })
        #expect(placed.filter { !$0.hidden }.map(\.id) == ["a", "b", "c"])
        #expect(overflow == [BlockOverflow(lane: 3, lanes: 4, start: h(10), end: h(11), ids: ["d", "e", "f"])])
        (_, overflow, placed) = lay("abcd".map { (String($0), h(10), h(11)) })
        #expect(overflow.isEmpty && placed.map(\.lane) == [0, 1, 2, 3])
    }

    @Test func spareBlocksGoBehindTheMarkerFirst() {
        let blocks = [("done1", 540, 600), ("done2", 545, 600), ("done3", 550, 600), ("open1", 555, 600),
                      ("open2", 560, 600)].map { (id: $0.0, start: $0.1, end: $0.2) }
        let (placed, overflow) = layoutDay(blocks, minLength: 25, spare: ["done1", "done2", "done3"])
        let m = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
        #expect(placed.map(\.id) == ["done1", "done2", "done3", "open1", "open2"])  // time order
        #expect(["open1", "open2", "done1"].map { [m[$0]!.lane, m[$0]!.hidden ? 1 : 0] } == [[0, 0], [1, 0], [2, 0]])
        #expect(overflow == [BlockOverflow(lane: 3, lanes: 4, start: 545, end: 600, ids: ["done2", "done3"])])
        // Without spare, the layout is the web app's: the latest starts are hidden.
        #expect(layoutDay(blocks, minLength: 25).overflow[0].ids == ["open1", "open2"])
    }

    @Test func spareBlocksFillGapsLeftByTheOthers() {
        // Five open blocks overlap at 9:00; a runs on to 10:30, so f and done join the cluster.
        let blocks = [(id: "a", start: h(9), end: h(10.5))] + "bcde".map { (id: String($0), start: h(9), end: h(10)) }
            + [(id: "done", start: h(10), end: h(11)), (id: "f", start: h(10.25), end: h(11))]
        let (placed, overflow) = layoutDay(blocks, spare: ["done"])
        let m = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
        #expect(overflow[0].ids == ["d", "e"])  // the others alone overflow, as without spare
        #expect(["f", "done"].map { [m[$0]!.lane, m[$0]!.hidden ? 1 : 0] } == [[1, 0], [2, 0]])
    }

    @Test func repairsEmptyBlocksAndIgnoresInputOrder() {
        #expect(lay([("z", 600, 600), ("w", 600, 590)]).placed.map(\.end) == [601, 601])
        let blocks = [("a", 540, 600), ("b", 570, 630), ("c", 600, 660), ("d", 540, 720), ("e", 800, 830)]
            .map { (id: $0.0, start: $0.1, end: $0.2) }
        let (forward, backward) = (layoutDay(blocks), layoutDay(blocks.reversed()))
        #expect(forward.placed == backward.placed && forward.overflow == backward.overflow)
    }

    @Test func shortBlocksSitSideBySideWithoutTheMarker() {
        var (m, _, placed) = lay([("hot", 810, 825), ("etsy", 825, 830), ("news", 830, 840), ("plan", 840, 850)],
                                 maxLanes: 4, minLength: 25)
        #expect(Set(placed.map(\.lane)).count > 1)
        #expect(!placed.contains { $0.overlap })
        (m, _, _) = lay([("a", 600, 660), ("b", 630, 690), ("c", 720, 780)], maxLanes: 4, minLength: 25)
        #expect(m["a"]!.overlap && m["b"]!.overlap)
        #expect(m["c"]!.lane == 0 && m["c"]!.lanes == 1)
    }

    @Test func blockFor() {
        let a = DustpanCore.blockFor(task("a", "2026-11-04", "09:30", ["estimate_minutes": 90]), zone: utc)
        #expect(a.map { [$0.start, $0.end] } == [570, 660] && a?.estimated == true)
        let b = DustpanCore.blockFor(task("b", "2026-11-04", "23:45"), zone: utc)
        #expect(b.map { [$0.start, $0.end] } == [1425, 1440] && b?.estimated == false)
        #expect(DustpanCore.blockFor(task("c", "2026-11-04"), zone: utc) == nil)
    }
}

/// calendar.test.ts's cases for the bottom edge and the keyboard steps.
@Suite struct CalendarStretchTests {
    let px = 48.0 / 60  // 48 points an hour, 12 a slot

    @Test func resizesInWholeSlots() {
        let start = 10 * 60
        let bottom = Double(start + 30) * px
        #expect(resizeEstimate(start: start, offset: bottom + 2 * 12, perMinute: px) == 60)
        #expect(resizeEstimate(start: start, offset: bottom + 2 * 12 + 5, perMinute: px) == 60)
        #expect(resizeEstimate(start: start, offset: bottom - 12, perMinute: px) == 15)
        #expect(resizeEstimate(start: start, offset: 0, perMinute: px) == 15)
        #expect(resizeEstimate(start: start, offset: 0, perMinute: 0) == 15)
    }

    @Test func stepsTheEstimate() {
        let cases: [(Int?, Int, Int)] = [(30, 15, 45), (30, -15, 15), (15, -15, 15), (nil, 15, 45), (nil, -15, 15),
                                         (20, 15, 30), (20, -15, 15), (10080, 15, 10080)]
        for (current, delta, want) in cases {
            #expect(stepEstimate(current, delta) == want, "\(String(describing: current)) \(delta)")
        }
    }

    @Test func stepsTheStartKeepingTheEnd() {
        let cases: [(Int, Int?, Int, [Int])] = [(600, 60, -15, [585, 75]), (600, 60, 15, [615, 45]),
                                                (600, 15, 15, [600, 15]), (600, nil, -15, [585, 45]),
                                                (605, 30, 15, [615, 20]), (0, 30, -15, [0, 30])]
        for (start, estimate, delta, want) in cases {
            let got = stepStart(start, estimate, delta)
            #expect([got.start, got.estimate] == want, "\(start) \(String(describing: estimate)) \(delta)")
        }
    }
}

@Suite struct CalendarGridMovesTests {
    func moves(_ date: String? = nil, _ time: String? = nil, _ fields: [String: JSON] = [:],
               onGrid: Bool = true) -> [GridMove: DropTarget?] {
        let list = gridMoves(task("t", date, time, fields), gridStart: 6 * 60, onGrid: onGrid, zone: utc)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.move, $0.target) })
    }

    func at(_ text: String, _ minutes: Int? = nil) -> DropTarget { .slot(day(text), minutes: minutes) }

    @Test func aTimedBlock() {
        let list = gridMoves(task("t", "2026-11-05", "09:00", ["estimate_minutes": 60]), gridStart: 360, zone: utc)
        #expect(list.map(\.move) == GridMove.allCases)
        let m = moves("2026-11-05", "09:00", ["estimate_minutes": 60])
        #expect(m[.earlier] == at("2026-11-05", 8 * 60 + 45))
        #expect(m[.later] == at("2026-11-05", 9 * 60 + 15))
        #expect(m[.dayBefore] == at("2026-11-04", 9 * 60))
        #expect(m[.dayAfter] == at("2026-11-06", 9 * 60))
        #expect(m[.shorter] == .stretch(45, start: nil))
        #expect(m[.longer] == .stretch(75, start: nil))
        #expect(m[.startEarlier] == .stretch(75, start: CalendarSpot(day: day("2026-11-05"), minutes: 8 * 60 + 45)))
        #expect(m[.startLater] == .stretch(45, start: CalendarSpot(day: day("2026-11-05"), minutes: 9 * 60 + 15)))
        #expect(m[.unschedule] == at("2026-11-05"))
    }

    @Test func theEndsOfTheDayAndTheShortestBlock() {
        let m = moves("2026-11-05", "00:00", ["estimate_minutes": 15])
        #expect(m[.earlier] == .some(nil) && m[.shorter] == .some(nil) && m[.startLater] == .some(nil))
        #expect(moves("2026-11-05", "23:45")[.later] == .some(nil))
    }

    @Test func withoutAnEstimateItStretchesFromThirtyMinutes() {
        let m = moves("2026-11-05", "09:00")
        #expect(m[.shorter] == .stretch(15, start: nil) && m[.longer] == .stretch(45, start: nil))
    }

    @Test func withoutATimeTheArrowsPutItOnTheGrid() {
        let m = moves("2026-11-05")
        #expect(m[.earlier] == at("2026-11-05", 6 * 60))
        #expect(m[.dayAfter] == at("2026-11-06"))
        #expect([GridMove.shorter, .longer, .startEarlier, .startLater, .unschedule].allSatisfy { m[$0] == .some(nil) })
    }

    @Test func monthMovesDaysOnlyAndKeepsTheTime() {
        #expect(moves("2026-11-30", "09:00", onGrid: false)
            == [.dayBefore: .day(day("2026-11-29")), .dayAfter: .day(day("2026-12-01"))])
        #expect(moves().isEmpty)
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

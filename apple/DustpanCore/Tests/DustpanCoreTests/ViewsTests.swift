import Foundation
import Testing
@testable import DustpanCore

private let today = Day("2026-10-16")!
private func ids(_ tasks: [Row]) -> [String] { tasks.map(\.id) }
private func ctx(_ tasks: [Row]) -> FilterContext { FilterContext(today: today, tasks: tasks, labels: [], projects: []) }

@Suite struct TodayUpcoming {
    @Test func todayTakesHardDatesAndStartedTasks() {
        let tasks = [task("due", ["due": ["date": "2026-10-16"]]), task("late", ["due": ["date": "2026-10-01"]]),
                     task("deadline", ["deadline": "2026-10-16", "due": ["date": "2026-10-30"]]),
                     task("started", ["start": "2026-10-10"]),
                     task("parked-but-due", ["start": "someday", "due": ["date": "2026-10-16"]]),
                     task("parked", ["start": "someday"]), task("done", ["due": ["date": "2026-10-16"], "completed_at": 1]),
                     task("tomorrow", ["due": ["date": "2026-10-17"]])]
        #expect(ids(tasks.filter { inToday($0, today: "2026-10-16", zone: .current) })
                == ["due", "late", "deadline", "started", "parked-but-due"])
        #expect(todayCount(tasks, today: today) == 5)
    }

    @Test func todayGroupsEarlierFirstAndSortsByTime() {
        let tasks = [task("all-day", ["due": ["date": "2026-10-16"]]), task("nine", ["due": ["date": "2026-10-16", "time": "09:00"]]),
                     task("passed", ["deadline": "2026-10-12"]),
                     task("passed-but-planned", ["deadline": "2026-10-12", "due": ["date": "2026-10-16"]]),
                     task("late", ["due": ["date": "2026-10-02"]])]
        #expect(todayGroups(tasks, today: today).map { [$0.heading] + ids($0.tasks) }
                == [["Earlier", "late", "passed"], ["Today", "nine", "all-day", "passed-but-planned"]])
    }

    @Test func upcomingListsByDayWithDeadlinesAfterDues() {
        let tasks = [task("deadline", ["deadline": "2026-10-18"]), task("due", ["due": ["date": "2026-10-18"]]),
                     task("soon", ["due": ["date": "2026-10-17", "time": "08:00"]]), task("now", ["due": ["date": "2026-10-16"]]),
                     task("deferred", ["start": "2026-10-20"]),
                     task("deferred-in-project", ["start": "2026-10-20", "project_id": "p"]),
                     task("parked", ["start": "someday", "due": ["date": "2026-10-19"]])]
        #expect(upcomingGroups(tasks, today: today).map { [$0.key] + ids($0.tasks) }
                == [["2026-10-17", "soon"], ["2026-10-18", "due", "deadline"], ["2026-10-20", "deferred"]])
        #expect(upcomingGroups(tasks, today: today).first?.heading == "Tomorrow")
    }
}

@Suite struct SortAndGroup {
    let tasks = [task("a", ["priority": 2, "due": ["date": "2026-10-20"], "position": 3, "labels": ["l2", "l1"]]),
                 task("b", ["priority": 1, "position": 1, "project_id": "p1"]),
                 task("c", ["priority": 4, "due": ["date": "2026-10-18", "time": "10:00"], "position": 2, "project_id": "gone"])]

    @Test func dueKeepsUndatedLastBothWays() {
        #expect(ids(sorted(tasks, compareTasks(.due, .asc, zone: .current))) == ["c", "a", "b"])
        #expect(ids(sorted(tasks, compareTasks(.due, .desc, zone: .current))) == ["a", "c", "b"])
    }

    @Test func priorityDescendingListsP1First() {
        #expect(ids(sorted(tasks, compareTasks(.priority, .desc, zone: .current))) == ["b", "a", "c"])
    }

    @Test func manualOrderThenPosition() {
        #expect(ids(sorted(tasks, manualOrder(["a", "x"], .asc, zone: .current))) == ["a", "b", "c"])
        #expect(ids(sorted(tasks, manualOrder(["a"], .desc, zone: .current))) == ["c", "b", "a"])
    }

    @Test func groups() {
        let labels = [Row(id: "l1", values: ["name": "one"]), Row(id: "l2", values: ["name": "two"])]
        func groups(_ by: ViewGroupBy) -> [[String]] {
            groupTasks(tasks, by: by, today: today, labels: labels, projects: [("p1", "Home")], zone: .current)
                .map { [$0.heading] + ids($0.tasks) }
        }
        #expect(groups(.label) == [["one", "a"], ["two", "a"], ["No label", "b", "c"]])
        #expect(groups(.project) == [["Inbox", "a"], ["Home", "b"], ["Other", "c"]])
        #expect(groups(.due).map { $0.dropFirst() } == [["c"], ["a"], ["b"]])
        #expect(groups(.due).last?.first == "No date")
        #expect(groups(.priority) == [["Priority 1", "b"], ["Priority 2", "a"], ["No priority", "c"]])
        #expect(groups(.none) == [["", "a", "b", "c"]])
    }

    @Test func runAView() {
        let view = Row(id: "v", values: ["query": "p1 | p2", "group_by": "someday-option", "sort_by": "priority",
                                         "sort_dir": "desc"])
        let result = runView(view, ctx(tasks), tasks, labels: [], projects: [("p1", "Home")])
        #expect(result.groups.map { [$0.key] + ids($0.tasks) } == [["inbox", "a"], ["p1", "b"]])
        #expect(result.count == 2)
        let broken = runView(Row(id: "v", values: ["query": "p1 &"]), ctx(tasks), tasks, labels: [], projects: [])
        #expect(broken.groups.isEmpty && broken.error == #"Expected a term after "&" at position 4"#)
    }

    @Test func showCompletedCountsOpenOnly() {
        let all = tasks + [task("d", ["priority": 1, "position": 5, "completed_at": 1])]
        let view = Row(id: "v", values: ["query": "p1", "show_completed": true, "group_by": "none"])
        let result = runView(view, ctx(all), all, labels: [], projects: [])
        #expect(ids(result.groups[0].tasks) == ["b", "d"] && result.count == 1)
    }

    @Test func dayHeadings() {
        #expect(dayHeading(today, today: today) == "Today")
        #expect(dayHeading(today + 1, today: today) == "Tomorrow")
        let english = Locale(identifier: "en_AU")
        #expect(dayHeading(today + 3, today: today, locale: english) == "Monday")
        #expect(dayHeading(today + 10, today: today, locale: english) == "Mon 26 Oct")
        #expect(dayHeading(Day("2027-01-04")!, today: today, locale: english) == "Mon 4 Jan 2027")
    }
}

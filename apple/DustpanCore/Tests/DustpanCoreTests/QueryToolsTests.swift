import Foundation
import Testing
@testable import DustpanCore

// Ports test_querytools.py: the query helper and the Anytime and Completed pages.

private let labels = ["errand", "deep work", "Café"]
private let projects = ["Home", "Work", "#hash"]

private func offered(_ query: String) -> [[String]] {
    suggest(query, labels: labels, projects: projects).map { [$0.shown, $0.completed] }
}

/// Unix ms of a local time, "2026-11-02T09:00".
private func ms(_ text: String) -> JSON {
    let day = Day(String(text.prefix(10)))!.parts
    let time = text.suffix(5).split(separator: ":").compactMap { Int($0) }
    return .int(zonedInstant(WallTime(year: day.year, month: day.month, day: day.day, hour: time[0], minute: time[1]),
                             in: .current))
}

@Suite struct Suggest {
    @Test func labelsAfterAt() {
        #expect(offered("p1 & @er") == [["@errand", "p1 & @errand "]])
        #expect(offered("@de") == [["@deep work", "@\"deep work\" "]])
        #expect(offered("@\"deep w") == [["@deep work", "@\"deep work\" "]])
        #expect(offered("@cafe") == [["@Café", "@Café "]])
    }

    @Test func projectsAfterHash() {
        #expect(offered("#w") == [["#Work", "#Work "]])
        #expect(offered("##h") == [["##Home", "##Home "]])
        #expect(offered("#") == [["#Home", "#Home "], ["#Work", "#Work "], ["##hash", "#\"#hash\" "]])
    }

    @Test func keywordsForABareWord() {
        #expect(offered("today & ov").map { $0[0] } == ["overdue"])
        #expect(offered("no").map { $0[0] }.contains("no date"))
        #expect(offered("overdue").isEmpty)  // typed in full
        #expect(offered("p1 & ").isEmpty)
    }

    @Test func everyKeywordParses() throws {
        for (word, _) in queryKeywords where !word.hasSuffix(":") && !["due", "deadline", "created"].contains(word) {
            _ = try parseFilter(word)  // the rest need what follows them
        }
    }

    @Test func quoting() {
        #expect([quoteName("errand"), quoteName("a b"), quoteName("say \"hi\"")]
                == ["errand", "\"a b\"", "\"say \\\"hi\\\"\""])
    }
}

@Suite struct Builder {
    @Test func everyConditionParses() throws {
        for group in queryConditions(labels: labels, projects: projects) {
            for (_, term) in group.items {
                _ = try parseFilter(term)
                _ = try parseFilter(addCondition("p1", term, negate: true))
            }
        }
    }

    @Test func addConditionKeepsMeaning() {
        #expect(addCondition("", "p1") == "p1")
        #expect(addCondition("today", "p1") == "today & p1")
        #expect(addCondition("today | overdue", "p1") == "(today | overdue) & p1")
        #expect(addCondition("today", "no date", negate: true) == "today & !(no date)")
        #expect(addCondition("today", "p1", negate: true) == "today & !p1")
        #expect(addCondition("today & (", "p1") == "today & ( & p1")  // unfinished: left for the user
    }
}

@Suite struct AnytimeCompleted {
    @Test func anytime() {
        let today = "2026-11-02"
        #expect(inAnytime(task("a"), today: today))
        for fields: [String: JSON] in [["due": ["date": .string(today)]], ["deadline": .string(today)],
                                       ["start": "someday"], ["start": "2026-12-01"], ["completed_at": 5]] {
            #expect(!inAnytime(task("b", fields), today: today))
        }
    }

    @Test func logbookByDayNewestFirstWithPaging() {
        let today = Day("2026-11-02")!
        let tasks = [task("a", ["completed_at": ms("2026-11-02T09:00")]), task("b", ["completed_at": ms("2026-11-02T18:00")]),
                     task("c", ["completed_at": ms("2026-11-01T12:00")]), task("d"),
                     task("e", ["completed_at": ms("2026-10-20T12:00"), "deleted_at": 1])]
        let all = logbook(tasks, limit: 100, today: today)
        #expect(all.total == 3)
        #expect(all.groups.map { [$0.heading] + $0.tasks.map(\.id) } == [["Today", "b", "a"], ["Yesterday", "c"]])
        let two = logbook(tasks, limit: 2, today: today)
        #expect(two.groups.flatMap { $0.tasks.map(\.id) } == ["b", "a"] && two.total == 3)
    }

    @Test func logbookFollowsTheDayStart() {
        let found = logbook([task("a", ["completed_at": ms("2026-11-02T01:30")])], limit: 100,
                            today: Day("2026-11-02")!, dayStart: 240)
        #expect(found.groups.first?.key == "2026-11-01")
    }

    @Test func logbookHeadings() {
        let today = Day("2026-11-02")!, english = Locale(identifier: "en_AU")
        #expect(logbookHeading(Day("2026-10-28")!, today: today, locale: english) == "Wednesday 28 October")
        #expect(logbookHeading(Day("2025-12-31")!, today: today, locale: english) == "Wednesday 31 December 2025")
    }
}

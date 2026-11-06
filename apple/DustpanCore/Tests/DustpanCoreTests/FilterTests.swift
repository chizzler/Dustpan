import Foundation
import Testing
@testable import DustpanCore

func error(_ query: String) -> String? {
    do {
        _ = try parseFilter(query)
        return nil
    } catch {
        return error.message
    }
}

/// The query fully parenthesised, to check how it grouped.
func show(_ query: String) throws -> String {
    func text(_ node: FilterNode) -> String {
        switch node {
        case .or(let nodes): "(" + nodes.map(text).joined(separator: " | ") + ")"
        case .and(let nodes): "(" + nodes.map(text).joined(separator: " & ") + ")"
        case .not(let inner): "!" + text(inner)
        case .label(let name): "@" + name
        case .project(let name, let descendants): (descendants ? "##" : "#") + name
        case .priority(let p): "p\(p)"
        case .keyword(let word): word
        default: "\(node)"
        }
    }
    return text(try #require(try parseFilter(query)))
}

/// The examples and messages OpenTodo's parsers are checked against.
@Suite(.enabled(if: Vectors.fileExists("docs/filters.md"))) struct SharedParser {
    @Test func docsExamplesParse() throws {
        let blocks = try Vectors.read("docs/filters.md").matches(of: /```filter\n((?s).*?)```/).map { String($0.1) }
        #expect(blocks.count >= 10)
        for query in blocks.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            #expect(error(query) == nil, "\(query)")
            #expect((try? parseFilter(query)) != nil, "\(query)")
        }
    }

    @Test func docsErrorTable() throws {
        let doc = try Vectors.read("docs/filters.md")
        let table = doc[doc.range(of: "## Errors")!.lowerBound..<doc.range(of: "## The New view page")!.lowerBound]
        let rows = table.matches(of: /(?m)^\| `(.+?)` \| `(.+?)` \|$/)
        #expect(rows.count >= 5)
        for row in rows {
            let query = String(row.1).replacing(#"\|"#, with: "|")
            #expect(error(query) == String(row.2).replacing(#"\|"#, with: "|"), "\(query)")
        }
    }

    @Test func formattedQueriesParse() throws {
        let lines = try Vectors.read("internal/filter/testdata/formatted.txt").split(separator: "\n")
            .map(String.init).filter { !$0.hasPrefix("# ") }
        #expect(lines.count >= 150)
        for query in lines {
            #expect(error(query) == nil, "\(query)")
            #expect((try? parseFilter(query)) != nil, "\(query)")
        }
    }

    @Test func limits() throws {
        let limits = try JSON(parsing: Data(try Vectors.read("internal/filter/testdata/limits.json").utf8))
        for v in limits["vectors"].array! {
            let query = v["prefix"].string! + String(repeating: v["repeat"].string!, count: Int(v["times"].int!))
                + v["suffix"].string! + String(repeating: v["close"].string!, count: Int(v["closeTimes"].int!))
            #expect(error(query) == v["error"].string, "\(query.prefix(40))")
        }
    }
}

@Suite struct Parser {
    @Test func precedence() throws {
        #expect(try show("@errand | @call & p1") == "(@errand | (@call & p1))")
        #expect(try show("!@a & @b") == "(!@a & @b)")
        #expect(try show("(@errand | @call) & !#Work") == "((@errand | @call) & !#Work)")
        #expect(try show("((p1))") == "p1")
        #expect(try show("p1 | p2 | p3") == "(p1 | p2 | p3)")
    }

    @Test func terms() throws {
        #expect(try parseFilter(#"#"Client A" & @"say \"hi\"""#)
                == .and([.project("Client A", descendants: false), .label(#"say "hi""#)]))
        #expect(try parseFilter("due<=tomorrow") == .date("due", .le, .relative(1)))
        #expect(try parseFilter("created > 7 days ago") == .date("created", .gt, .relative(-7)))
        #expect(try parseFilter("due after friday") == .date("due", .gt, .weekday(5)))
        #expect(try parseFilter("completed = 2 weeks ago") == .date("completed", .eq, .period(month: false, -2)))
        #expect(try parseFilter(#"SEARCH: "oat milk""#) == .search("oat milk"))
        #expect(try parseFilter("tracked >= 1h30") == .unsupported("Tracked time"))
        #expect(try parseFilter("no cost") == .unsupported("Custom fields"))
        #expect(try parseFilter("@C#-dev & #Café/Bar") == .and([.label("C#-dev"), .project("Café/Bar", descendants: false)]))
        #expect(try parseFilter("sector: this week") == .sector("this-week"))
        #expect(try parseFilter("   ") == nil)
        #expect(durationMinutes("1.5h") == 90 && durationMinutes("45") == 45 && durationMinutes("1h75") == nil)
    }

    @Test func messages() {
        let cases = [
            "@": #"Expected a label name after "@" at position 1"#,
            #"@"open"#: "Missing closing quote for the text starting at position 2",
            "p1 )": #"Unexpected ")" at position 4"#,
            "(p1 p2)": #"Expected "&", "|" or ")" before "p2" at position 5"#,
            "()": #"Expected a term after "(" at position 1"#,
            #""loose text""#: ##"Unexpected text "loose text" at position 1; quote names after "@" or "#", or use search:"##,
            "due < 2026-02-30": #"Invalid date "2026-02-30" at position 7"#,
            "completed today": #"Expected "&" or "|" before "today" at position 11"#,
            "tracked = 1h75": #"Expected a duration such as 30m or 1h30 after "=" at position 11"#,
            "p1 & energy:": "Energy must be deep, medium or low at position 6",
        ]
        for (query, message) in cases { #expect(error(query) == message, "\(query)") }
    }
}

/// The tables in docs/filters.md, "Dates" and "Periods".
@Suite struct DateRanges {
    func range(_ expr: String, _ today: String, weekStart: Int = 1) throws -> [String] {
        guard case .date(_, _, let date) = try parseFilter("due = \(expr)") else { return [] }
        let (a, b) = resolveRange(date, today: Day(today)!, weekStart: weekStart)
        return [a.description, b.description]
    }

    @Test func days() throws {
        for (expr, day) in [("today", "2026-10-10"), ("tomorrow", "2026-10-11"), ("yesterday", "2026-10-09"),
                            ("friday", "2026-10-16"), ("saturday", "2026-10-10"), ("3 days", "2026-10-13"),
                            ("7 days ago", "2026-10-03")] {
            #expect(try range(expr, "2026-10-10") == [day, day], "\(expr)")
        }
    }

    @Test func periods() throws {
        for (expr, want) in [("this week", ["2026-10-12", "2026-10-18"]), ("last week", ["2026-10-05", "2026-10-11"]),
                             ("next week", ["2026-10-19", "2026-10-25"]), ("2 weeks ago", ["2026-09-28", "2026-10-04"]),
                             ("this month", ["2026-10-01", "2026-10-31"]), ("last month", ["2026-09-01", "2026-09-30"]),
                             ("3 months ago", ["2026-07-01", "2026-07-31"])] {
            #expect(try range(expr, "2026-10-16") == want, "\(expr)")
        }
        #expect(try range("this week", "2026-10-16", weekStart: 0) == ["2026-10-11", "2026-10-17"])
        #expect(try range("next month", "2026-12-15") == ["2027-01-01", "2027-01-31"])
    }
}

func task(_ id: String, _ fields: [String: JSON] = [:]) -> Row {
    let base: [String: JSON] = ["title": .string(id), "description": "", "project_id": nil, "parent_id": nil,
                                "priority": 4, "due": nil, "labels": [], "completed_at": nil, "deleted_at": nil]
    return Row(id: id, values: base.merging(fields) { _, new in new })
}

/// Unix ms of a local time on day.
func at(_ day: String, hour: Int = 12) -> JSON {
    let (y, m, d) = Day(day)!.parts
    return .int(zonedInstant(WallTime(year: y, month: m, day: d, hour: hour, minute: 0), in: .current))
}

@Suite struct Evaluate {
    let labels = [Row(id: "l1", values: ["name": "Errand"]), Row(id: "l2", values: ["name": "errand"]),
                  Row(id: "l3", values: ["name": "call"])]
    let projects = [Row(id: "work", values: ["name": "Work"]),
                    Row(id: "client", values: ["name": "Client A", "parent_id": "work"]),
                    Row(id: "home", values: ["name": "Home"])]

    func match(_ query: String, _ tasks: [Row], today: String = "2026-10-16", dayStart: Int = 0)
        throws -> (ids: [String], warnings: [String]) {
        let ctx = FilterContext(today: Day(today)!, tasks: tasks, labels: labels, projects: projects, dayStart: dayStart)
        let (test, warnings) = compileFilter(try #require(try parseFilter(query)), ctx)
        return (tasks.filter(test).map(\.id).sorted(), warnings)
    }

    @Test func namesIgnoreCaseAndSharedNamesAllMatch() throws {
        let tasks = [task("a", ["labels": ["l1"]]), task("b", ["labels": ["l2"]]), task("c", ["labels": ["l3"]])]
        let found = try match("@ERRAND", tasks)
        #expect(found.ids == ["a", "b"] && found.warnings.isEmpty)
    }

    @Test func unknownNamesWarnAndMatchNothing() throws {
        let tasks = [task("a", ["labels": ["l3"]])]
        let one = try match("@gone | @call", tasks)
        #expect(one.ids == ["a"] && one.warnings == [#"No label named "gone""#])
        let two = try match("!#Nowhere", tasks)
        #expect(two.ids == ["a"] && two.warnings == [#"No project named "Nowhere""#])
    }

    @Test func projectsWithAndWithoutSubprojects() throws {
        let tasks = [task("a", ["project_id": "work"]), task("b", ["project_id": "client"]),
                     task("c", ["project_id": "home"]), task("d")]
        #expect(try match("#work", tasks).ids == ["a"])
        #expect(try match("##Work", tasks).ids == ["a", "b"])
        #expect(try match("no project", tasks).ids == ["d"])
    }

    @Test func dueTermsUseCalendarDays() throws {
        let tasks = [task("past", ["due": ["date": "2026-10-15"]]), task("now", ["due": ["date": "2026-10-16", "time": "23:00"]]),
                     task("next", ["due": ["date": "2026-10-19"]]), task("none")]
        #expect(try match("overdue", tasks).ids == ["past"])
        #expect(try match("due <= today", tasks).ids == ["now", "past"])
        #expect(try match("due = next week", tasks).ids == ["next"])
        #expect(try match("no date | no time", tasks).ids == ["next", "none", "past"])
    }

    @Test func onlyOpenTasksUnlessTheQueryNamesAState() throws {
        let tasks = [task("open", ["priority": 1]), task("done", ["priority": 1, "completed_at": at("2026-10-14")]),
                     task("skipped", ["priority": 1, "completed_at": at("2026-10-14"), "skipped": true]),
                     task("gone", ["priority": 1, "deleted_at": 1])]
        #expect(try match("p1", tasks).ids == ["open"])
        #expect(try match("p1 & completed", tasks).ids == ["done"])
        #expect(try match("completed = this week", tasks).ids == ["done"])
        let ctx = FilterContext(today: Day("2026-10-16")!, tasks: tasks, labels: [], projects: [])
        let (test, _) = compileFilter(withCompleted(try #require(try parseFilter("p1"))), ctx)
        #expect(tasks.filter(test).map(\.id).sorted() == ["done", "open"])
    }

    @Test func createdCountsTheDayStart() throws {
        let tasks = [task("late", ["created_at": at("2026-10-16", hour: 2)])]
        #expect(try match("created = today", tasks).ids == ["late"])
        #expect(try match("created = yesterday", tasks, dayStart: 3 * 60).ids == ["late"])
    }

    @Test func startDates() throws {
        let tasks = [task("parked", ["start": "someday"]), task("later", ["start": "2026-10-20"]),
                     task("started", ["start": "2026-10-01"])]
        #expect(try match("someday", tasks).ids == ["parked"])
        #expect(try match("deferred", tasks).ids == ["later"])
        #expect(try match("start <= today", tasks).ids == ["started"])
        #expect(try match("no start", tasks).ids == [])
    }

    @Test func taskFields() throws {
        let tasks = [task("a", ["origin": ["kind": "url", "provider": "GitHub"], "energy": "deep", "day_part": "morning"]),
                     task("b", ["origin": ["kind": "email"], "evening": true, "habit": true]), task("c", ["energy": "huge"])]
        #expect(try match("origin: github", tasks).ids == ["a"])
        #expect(try match("origin: EMAIL", tasks).ids == ["b"])
        #expect(try match("no origin", tasks).ids == ["c"])
        #expect(try match("energy: deep | no energy", tasks).ids == ["a", "b", "c"])
        #expect(try match("morning | evening", tasks).ids == ["a", "b"])
        #expect(try match("habit", tasks).ids == ["b"])
    }

    @Test func searchReadsTitleAndNotes() throws {
        let tasks = [task("Buy OAT milk"), task("b", ["description": "oat milk, 2L"]), task("c")]
        #expect(try match(#"search: "oat milk""#, tasks).ids == ["Buy OAT milk", "b"])
    }

    @Test func unsupportedTermsWarn() throws {
        for query in ["available", "tracked > 1h", "workspace: Home", "cost > 5", "no client"] {
            let found = try match(query, [task("a")])
            #expect(found.ids.isEmpty && found.warnings.count == 1, "\(query)")
        }
    }
}

@Suite(.enabled(if: Vectors.exists("filter/evaluate"))) struct EvaluateVectors {
    /// The defaults the upstream test gives every task (evaluate.vectors.test.ts).
    let defaults: [String: JSON] = [
        "title": "", "description": "", "labels": [], "priority": 4, "due": nil, "project_id": nil, "parent_id": nil,
        "start": nil, "deadline": nil, "completed_at": nil, "deleted_at": nil, "created_at": 1_792_454_400_000,
        "blocked_by": [],
    ]

    @Test func cases() throws {
        let data = try Vectors.load("filter/evaluate")
        func rows(_ items: JSON) -> [Row] { items.array!.map { Row(id: $0["id"].string!, values: $0.object!) } }
        let tasks = data["tasks"].array!.map {
            Row(id: $0["id"].string!, values: defaults.merging($0.object!) { _, new in new })
        }
        let ctx = FilterContext(today: Day(data["today"].string!)!, tasks: tasks, labels: rows(data["labels"]),
                                projects: rows(data["projects"]), weekStart: Int(data["week_start"].int!))
        for c in data["cases"].array! {
            let query = c["query"].string!
            // Tracked time and custom fields aren't evaluated: they warn and match nothing (spec/views.md).
            if query.contains("tracked") || query.contains("cost") { continue }
            let want = c["ids"].array!.map { $0.string! }.sorted()
            guard let ast = try parseFilter(query) else {
                #expect(want.isEmpty, "\(query)")
                continue
            }
            let (test, warnings) = compileFilter(ast, ctx)
            #expect(tasks.filter(test).map(\.id).sorted() == want, "\(query)")
            #expect(warnings.count == Int(c["warnings"].int ?? 0), "\(query)")
        }
    }
}

@Suite struct Blocked {
    func blocked(_ id: String, _ blockers: [String], ts: Int64 = 0, device: String = "d") -> Row {
        var row = task(id, ["blocked_by": .array(blockers.map(JSON.string))])
        row.clocks["blocked_by"] = FieldClock(ts: ts, device: device)
        return row
    }

    @Test func openBlockersOnly() {
        let tasks = [blocked("a", ["b", "gone"]), task("b"), blocked("c", ["d"]), task("d", ["completed_at": 1]),
                     blocked("e", ["f"]), task("f", ["deleted_at": 1])]
        #expect(blockedIds(tasks) == ["a"])
    }

    @Test func cycleBreaksAtTheNewestClock() {
        #expect(blockedIds([blocked("x", ["y"], ts: 10), blocked("y", ["x"], ts: 20)]) == ["x"])
        #expect(blockedIds([blocked("x", ["y"], ts: 5), blocked("y", ["z"], ts: 9), blocked("z", ["x"], ts: 7)]) == ["x", "z"])
    }

    @Test func tiesBreakOnDeviceThenId() {
        #expect(blockedIds([blocked("x", ["y"], ts: 5, device: "b"), blocked("y", ["x"], ts: 5, device: "a")]) == ["y"])
        #expect(blockedIds([blocked("x", ["y"], ts: 5), blocked("y", ["x"], ts: 5)]) == ["x"])
    }
}

@Suite(.enabled(if: Vectors.exists("sectors"))) struct SectorVectors {
    @Test func valid() throws {
        for c in try Vectors.load("sectors")["valid"].array! {
            #expect((Period(c["value"].string!) != nil) == c["valid"].bool!, "\(c["value"])")
        }
    }

    @Test func currentAndCarried() throws {
        for c in try Vectors.load("sectors")["cases"].array! {
            let today = Day(c["today"].string!)!, ws = Int(c["week_start"].int!)
            #expect(currentSectors(today, weekStart: ws).mapValues(JSON.string) == c["current"].object!, "\(c["today"])")
            for s in c["sectors"].array! {
                #expect(isCarried(s["sector"].string, today: today, weekStart: ws) == s["carried"].bool!, "\(s)")
            }
        }
    }
}

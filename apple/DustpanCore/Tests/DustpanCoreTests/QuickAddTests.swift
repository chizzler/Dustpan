import Foundation
import Testing
@testable import DustpanCore

/// Ports of test_quickadd.py: OpenTodo's quick-add vectors, and the vocabulary copy.
@Suite struct QuickAddTests {
    private func context(_ c: JSON) -> QuickAddContext {
        var ctx = QuickAddContext(today: Day(c["today"].string!)!, now: c["now"].string ?? "",
                                  languages: c["languages"].strings, projects: (c["projects"].array ?? []).map { p in
            QuickAddProject(id: p["id"].string!, name: p["name"].string ?? "", parentId: p["parent_id"].string,
                            archived: p["archived"].isTruthy, deleted: p["deleted"].isTruthy)
        })
        ctx.dayMonthOrder = c["dayMonthOrder"].string ?? ""
        ctx.weekStart = c["weekStart"].int.map(Int.init) ?? 1
        ctx.dayParts = c["dayParts"].bool ?? false
        ctx.energy = c["energy"].bool ?? false
        ctx.sectors = c["sectors"].bool ?? false
        return ctx
    }

    private func json(_ r: QuickAddResult) -> [String: JSON] {
        func int(_ n: Int?) -> JSON { n.map { .int(Int64($0)) } ?? nil }
        return [
            "title": .string(r.title), "due": r.due, "projectId": r.projectId.json,
            "labels": .array(r.labels.map(JSON.string)), "priority": int(r.priority),
            "estimateMinutes": int(r.estimateMinutes), "spentMinutes": int(r.spentMinutes),
            "recurrence": r.recurrence.json,
            "reminders": .array(r.reminders.map { reminder in
                switch reminder {
                case .offset(let minutes): ["kind": "offset", "minutes": .int(Int64(minutes))]
                case .moment(let date, let time): ["kind": "moment", "date": date.map { .string($0.description) } ?? nil,
                                                   "time": .string(time)]
                }
            }),
        ]
    }

    @Test(.enabled(if: Vectors.exists("nlp/quickadd")))
    func vectors() throws {
        let cases = try #require(try Vectors.load("nlp/quickadd")["cases"].array)
        #expect(cases.count >= 150)
        for c in cases {
            let got = parseQuickAdd(c["line"].string!, context(c["ctx"]))
            let want = c["expect"]
            let fields = json(got)
            for key in fields.keys.sorted() {
                #expect(fields[key] == want[key], "\(c["name"].string!): \(key)")
            }
            // Compared only when a case states them. A day part stated as null or "" means none.
            func none(_ s: String?) -> JSON { s.flatMap { $0.isEmpty ? nil : JSON.string($0) } ?? nil }
            if let part = want.object?["dayPart"] { #expect(none(got.dayPart) == none(part.string), "\(c["name"].string!)") }
            if let evening = want.object?["evening"] { #expect(got.evening == evening.bool, "\(c["name"].string!)") }
            if let energy = want.object?["energy"] { #expect(none(got.energy) == none(energy.string), "\(c["name"].string!)") }
            if let sector = want.object?["sector"] { #expect(none(got.sector) == none(sector.string), "\(c["name"].string!)") }
        }
    }

    @Test(.enabled(if: Vectors.fileExists("internal/quickadd/vocab.json")))
    func vocabularyIsThePinnedCopy() throws {
        let ours = try String(contentsOf: try #require(Bundle.module(for: QuickAddContext.self)), encoding: .utf8)
        #expect(ours == (try Vectors.read("internal/quickadd/vocab.json")))
        for code in ["en", "de", "fr", "it", "es", "pt"] {
            #expect(quickAddVocabs[code]?["weekdays"].array?.count == 7)
            #expect(quickAddVocabs[code]?["months"].array?.count == 12)
        }
    }

    @Test func languages() {
        #expect(quickAddLanguages(["de-CH", "ja", "fr"]) == ["de", "fr", "en"])
        #expect(quickAddLanguages(["en_AU"]) == ["en"])
    }

    @Test func quotedTextStays() {
        let got = parseQuickAdd(#"Read "tomorrow" #nowhere p2"#, QuickAddContext(today: Day("2026-10-31")!, now: "10:00"))
        #expect(got.title == "Read tomorrow #nowhere")
        #expect(got.due == nil && got.priority == 2)
    }

    /// Dustpan differs from upstream: "sun", "sat" and "wed" are everyday words too. Mirrors test_word_like_days.
    @Test func wordLikeDays() {
        let ctx = QuickAddContext(today: Day("2026-11-14")!, now: "15:00")  // a Saturday
        let cases: [(String, String, JSON)] = [
            ("Stack the turtles in the sun today", "Stack the turtles in the sun", ["date": "2026-11-14"]),
            ("Sit in the sun", "Sit in the sun", nil),
            ("Read on the sun deck tomorrow", "Read on the sun deck", ["date": "2026-11-15"]),
            ("Lunch with Sat friday", "Lunch with Sat", ["date": "2026-11-20"]),
            ("Sun cream", "Sun cream", nil),
            ("Call Mum sun", "Call Mum", ["date": "2026-11-15"]),
            ("Call Mum on sun", "Call Mum", ["date": "2026-11-15"]),
            ("Call Mum next sun", "Call Mum", ["date": "2026-11-22"]),
            ("Call Mum sun 4pm", "Call Mum", ["date": "2026-11-15", "time": "16:00"]),
            ("Call Mum sun p1", "Call Mum", ["date": "2026-11-15"]),
            ("Gym sat +1h", "Gym", ["date": "2026-11-21"]),
            ("Gym sat 1h", "Gym", ["date": "2026-11-21"]),
            ("Dinner sat #nowhere", "Dinner sat #nowhere", nil),
            ("Meet wed 10am @work", "Meet", ["date": "2026-11-18", "time": "10:00"]),
            ("Wed the fri", "Wed the", ["date": "2026-11-20"]),
        ]
        for (line, title, due) in cases {
            let got = parseQuickAdd(line, ctx)
            #expect(got.title == title, "\(line)")
            #expect(got.due == due, "\(line)")
        }
        #expect(parseQuickAdd("Bins every sun", ctx).recurrence == "every sunday")
        #expect(parseQuickAdd("Send report deadline sun for review", ctx).deadline == Day("2026-11-15"))
    }

    @Test func resolve() {
        let today = Day("2026-10-31")!
        let nine = TypedReminder.moment(date: nil, time: "09:00")
        #expect(resolveReminder(.offset(minutes: -30), due: nil, today: today, now: "10:00") == .relative(-30))
        #expect(resolveReminder(nine, due: ["date": "2026-11-03", "time": "15:00"], today: today, now: "10:00")
                == .relative(-360))
        #expect(resolveReminder(nine, due: ["date": "2026-11-03"], today: today, now: "10:00") == .relative(0))
        #expect(resolveReminder(nine, due: nil, today: today, now: "10:00") == .absolute(Day("2026-11-01")!, "09:00"))
        #expect(resolveReminder(nine, due: nil, today: today, now: "08:00") == .absolute(today, "09:00"))
    }

    @Test func contextFromPrefs() {
        let today = Day("2026-11-06")!
        let ctx = quickAddContext(prefs: ["language": "de", "week_start": "sun", "day_parts": "on"], projects: [],
                                  today: today, now: "10:00", system: "en-AU")
        #expect(ctx.languages == ["de", "en-AU"] && ctx.dayMonthOrder == "DM" && ctx.weekStart == 0 && ctx.dayParts)
        #expect(quickAddContext(prefs: [:], projects: [], today: today, now: "10:00", system: "en-US").dayMonthOrder == "MD")
        #expect(quickAddContext(prefs: [:], projects: [], today: today, now: "10:00", system: "en-AU").dayMonthOrder == "DM")
    }
}

/// Writer.quickAdd: ports of test_writes.py's quick add tests.
@Suite struct QuickAddWriteTests {
    let store: Store
    let writer: Writer

    init() throws {
        store = try memoryStore()
        writer = Writer(store: store, clock: HybridClock(store: store, now: { 1_000_000 }), now: { 1_000_000 },
                        today: { Day("2026-11-02")! })
        try store.setMeta("user_id", "me")
    }

    func seed(_ entity: String, _ id: String, _ fields: [String: JSON]) throws {
        for (name, value) in fields {
            try store.apply(Op(id: "\(id)-\(name)-1", entity: entity, entityId: id, field: name, value: value,
                               ts: 1, device: "other"))
        }
    }

    func task(_ id: String) throws -> Row { try #require(try store.rows("task")[id]) }

    @Test func quickAdd() throws {
        try seed("project", "p1", ["name": "Home"])
        try seed("project", "p2", ["name": "Work Stuff"])
        try seed("label", "l1", ["name": "Phone", "position": 1])
        let id = try writer.quickAdd("Call Sam tomorrow at 15:00 #workstuff @phone @new-one p1 +30m remind me 1 hour before",
                                     projectId: "p1")
        let t = try task(id)
        #expect(t["title"] == "Call Sam" && t["project_id"] == "p2" && t["priority"] == 1 && t["estimate_minutes"] == 30)
        #expect(t["due"] == ["date": "2026-11-03", "time": "15:00"])
        let labels = t["labels"].strings
        #expect(labels.first == "l1")
        #expect(try store.rows("label")[labels[1]]?["name"] == "new-one")
        let reminder = try #require(try store.rows("reminder").values.first { $0["task_id"].string == id })
        #expect(reminder["kind"] == "relative" && reminder["offset_minutes"] == -60)
        #expect(Set(try store.outboxBatch(limit: 1000).map(\.op.ts)).count == 1)
    }

    @Test func readsASectorOnlyWhenTurnedOn() throws {
        let today: JSON = ["date": "2026-11-02"]
        let off = try task(try writer.quickAdd("Plan it this week", due: today))
        #expect(off["title"] == "Plan it this week" && off["sector"] == nil && off["due"] == today)
        try seed("user_prefs", "me", ["time_sectors": "on"])
        let on = try task(try writer.quickAdd("Plan it this week", due: today))
        #expect(on["title"] == "Plan it" && on["sector"] == "2026-W45" && on["due"] == nil)
    }

    @Test func keepsThePagePlaceAndDateUnlessTheLineSetsThem() throws {
        try seed("project", "p1", ["name": "Home"])
        try seed("section", "s1", ["name": "Garden", "project_id": "p1"])
        let inSection = try task(try writer.quickAdd("Weed beds 25m/1h", projectId: "p1", sectionId: "s1"))
        #expect(inSection["project_id"] == "p1" && inSection["section_id"] == "s1" && inSection["due"] == nil)
        let entry = try #require(try store.rows("time_entry").values.first)
        #expect(entry["task_id"].string == inSection.id)
        #expect((entry["ended_at"].int ?? 0) - (entry["started_at"].int ?? 0) == 25 * 60_000)
        let today: JSON = ["date": "2026-11-02"]
        #expect(try task(try writer.quickAdd("Call mum", due: today))["due"] == today)
        let parked = try task(try writer.quickAdd("Learn piano someday", due: today))
        #expect(parked["title"] == "Learn piano" && parked["due"] == nil && parked["start"] == "someday")
        #expect(throws: CannotEdit.self) { try writer.quickAdd("tomorrow p1") }
    }

    @Test func subtaskTakesItsParentsProject() throws {
        try seed("project", "p1", ["name": "Home"])
        try seed("task", "a", ["title": "A", "project_id": "p1", "section_id": "s1"])
        let sub = try task(try writer.quickAdd("Buy paint p2", parentId: "a"))
        #expect(sub["parent_id"] == "a" && sub["project_id"] == "p1" && sub["priority"] == 2)
        #expect(sub.values["section_id"] == nil)
    }
}

private extension Bundle {
    /// The package's vocab.json, wherever its resource bundle is.
    static func module(for _: Any.Type) -> URL? { Bundle.module.url(forResource: "vocab", withExtension: "json") }
}

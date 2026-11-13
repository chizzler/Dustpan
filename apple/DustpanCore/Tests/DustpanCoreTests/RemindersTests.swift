import Foundation
import Testing
@testable import DustpanCore

@Suite(.enabled(if: Vectors.exists("defaultReminder"))) struct DefaultReminderVectors {
    let v: JSON

    init() throws { v = try Vectors.load("defaultReminder") }

    @Test func id() {
        #expect(defaultReminderId(userId: v["user_id"].string!, taskId: v["task_id"].string!) == v["default_id"].string)
    }

    @Test func parse() {
        for pair in v["parse"].array! {
            #expect(parseDefault(pair.array![0]) == pair.array![1].int, "\(pair)")
        }
    }

    @Test func cases() {
        let rid = { (s: String) in s == "$default" ? v["default_id"].string! : s }
        // The vectors are computed with the device in UTC.
        let fireAt = { (due: JSON, offset: JSON) in relativeFireAt(due, offset, localZone: .gmt) }
        for c in v["cases"].array! {
            let reminders = Dictionary(uniqueKeysWithValues: c["reminders"].array!.map { r in
                (rid(r["id"].string!), r.object!.filter { $0.key != "id" })
            })
            let batch = c["batch"].array!.map { Change("reminder", rid($0["id"].string!), $0["patch"].object!) }
            let got = planDefaultReminder(
                userId: v["user_id"].string!, taskId: v["task_id"].string!, before: c["before"].object,
                patch: c["patch"].object!, reminders: reminders, batch: batch,
                defaults: ReminderDefaults(prefs: c["prefs"].object ?? [:]), now: v["now"].int!, fireAt: fireAt)
            let want = c["expect"].array!.map { Change("reminder", rid($0["id"].string!), $0["patch"].object!) }
            #expect(got == want, "\(c["name"].string!)")
        }
    }
}

@Suite(.enabled(if: Vectors.exists("zoned"))) struct ZonedVectors {
    @Test func instants() throws {
        let format = ISO8601DateFormatter()
        for c in try Vectors.load("zoned")["instant"].array! {
            let instant = try #require(dueInstant(c))
            #expect(format.string(from: Date(timeIntervalSince1970: Double(instant) / 1000)) == c["utc"].string,
                    "\(c["note"].string!)")
        }
    }
}

@Suite struct NameIds {
    @Test func matchOpenTodo() {
        // Values from web/src/lib/ids.test.ts at v0.18.0.
        #expect(nameId("occurrence", "series-1:2026-10-12") == "7106e6f1-b1b0-89c3-a9dc-81493398a2bd")
        #expect(nameId("occurrence", "series-1:detach:2026-10-12") == "8f193c71-c00d-879f-a1fa-51a7b4ff2974")
        #expect(nameId("occurrence", "ünïcödé ✓:2026-10-12") == "17d11a8d-aec2-8ffd-b6fd-9c4027f03e68")
        #expect(nameId("", "") == "e7ac0786-668e-8ff0-b02b-62bd04f45ff6")
    }
}

@Suite struct DueDrafts {
    let sydney = TimeZone(identifier: "Australia/Sydney")!

    @Test func floatingDueRoundTrips() throws {
        for due: JSON in [["date": "2026-11-06"], ["date": "2026-11-06", "time": "15:30"]] {
            #expect(try #require(DueDraft(due, localZone: sydney)).json == due)
        }
    }

    @Test func aZonedDueKeepsItsZoneUntilTheTimeGoes() throws {
        var draft = try #require(DueDraft(["date": "2026-11-06", "time": "09:00", "tz": "Europe/Berlin"],
                                          localZone: sydney))
        #expect(draft.zoneName == "Europe/Berlin")
        draft.date += 3600
        #expect(draft.json == ["date": "2026-11-06", "time": "10:00", "tz": "Europe/Berlin"])
        draft.hasTime = false
        #expect(draft.json == ["date": "2026-11-06"])
    }

    @Test func noDueNoDraft() {
        #expect(DueDraft(.null) == nil)
        #expect(DueDraft(["date": "soon"]) == nil)
    }
}

@Suite struct ReminderFiring {
    let store: Store
    let now: Int64 = 100 * 86_400_000

    init() throws { store = try memoryStore() }

    func seed(_ entity: String, _ id: String, _ fields: [String: JSON], ts: Int64 = 1) throws {
        for (name, value) in fields {
            try store.apply(Op(id: "\(id)-\(name)-\(ts)", entity: entity, entityId: id, field: name, value: value,
                               ts: ts, device: "other"))
        }
    }

    @Test func labels() {
        #expect([0, -30, -60, 120, -1440, -2880].map(offsetLabel)
                == ["At due time", "30 minutes before", "1 hour before", "2 hours after", "1 day before",
                    "2 days before"])
    }

    @Test func oncePerFiringThenWithdrawn() throws {
        try seed("task", "t", ["title": "T"])
        try seed("reminder", "r", ["task_id": "t", "kind": "relative", "fire_at": .int(now - 60_000)])
        try seed("reminder", "later", ["task_id": "t", "kind": "relative", "fire_at": .int(now + 60_000)])
        let first = try checkReminders(store, now: now)
        #expect(first.show.map(\.reminder.id) == ["r"] && first.next == now + 60_000)
        #expect(try checkReminders(store, now: now).show.isEmpty)
        try seed("reminder", "r", ["dismissed_at": .int(now)], ts: 2)
        #expect(try checkReminders(store, now: now).withdraw == ["r"])
        // Snoozed past the dismissal: a new firing.
        try seed("reminder", "r", ["fire_at": .int(now + 1)], ts: 3)
        #expect(try checkReminders(store, now: now + 1).show.map(\.reminder.id) == ["r"])
    }

    @Test func firstRunSkipsStaleOnesAndTrashedProjectsAndDoneTasks() throws {
        try seed("project", "p", ["name": "P", "deleted_at": 1])
        try seed("task", "t", ["title": "T"])
        try seed("task", "gone", ["title": "G", "project_id": "p"])
        try seed("task", "done", ["title": "D", "completed_at": 1])
        try seed("reminder", "stale", ["task_id": "t", "fire_at": .int(now - staleReminderMs - 1)])
        try seed("reminder", "trashed", ["task_id": "gone", "fire_at": .int(now - 1)])
        try seed("reminder", "finished", ["task_id": "done", "fire_at": .int(now - 1)])
        #expect(try checkReminders(store, now: now).show.isEmpty)
        #expect(try store.meta("notified") == ["stale": .int(now - staleReminderMs - 1)])
    }
}

@Suite struct CustomDefaultOffsets {
    @Test func parsedAndFormatted() {
        #expect(formatDefault(-30) == "-30")
        let cases: [(String, Int64)] = [("15m", -15), ("2h", -120), ("3 days before", -4320), ("1w", -10080),
                                        ("30m after", 30), ("+45m", 45), ("0", 0), ("-45", -45)]
        for (text, minutes) in cases { #expect(parseCustomOffset(text) == minutes, "\(text)") }
        for bad in ["", "nope", "999d", "+10m before"] { #expect(parseCustomOffset(bad) == nil, "\(bad)") }
    }
}

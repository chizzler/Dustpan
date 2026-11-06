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

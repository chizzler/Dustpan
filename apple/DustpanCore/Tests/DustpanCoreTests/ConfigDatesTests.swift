import Foundation
import Testing
@testable import DustpanCore

@Suite struct SafeURL {
    func safe(_ text: String) -> Bool { URL(string: text).map(Config.isSafe) ?? false }

    @Test func httpsAnywhere() {
        #expect(safe("https://todo.example.com"))
        #expect(safe("https://203.0.113.5:8443/"))
    }

    @Test func plainHttpOnlyToThisMachine() {
        #expect(safe("http://localhost:8080"))
        #expect(safe("http://127.0.0.1:8080"))
        #expect(safe("http://[::1]:8080"))
        #expect(!safe("http://todo.example.com"))
        #expect(!safe("http://192.168.1.10:8080"))
        #expect(!safe("http://localhost.example.com"))
    }

    @Test func otherSchemesAndJunk() {
        #expect(!safe("ftp://localhost"))
        #expect(!safe("todo.example.com"))
        #expect(!safe("https://"))
    }
}

@Suite struct ConfigLoad {
    func load(_ text: String) throws -> Config {
        let path = FileManager.default.temporaryDirectory.appending(path: "dustpan-config-\(UUID().uuidString)")
        try text.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        return try Config.load(from: path)
    }

    @Test func readsURLAndToken() throws {
        let config = try load("# real server\nOPENTODO_URL=https://todo.example.com\nOPENTODO_TOKEN=ot_abc\n")
        #expect(config == Config(url: URL(string: "https://todo.example.com")!, token: "ot_abc"))
    }

    @Test func refusesPlainHttpToAnotherMachine() {
        #expect { try load("OPENTODO_URL=http://todo.example.com\nOPENTODO_TOKEN=ot_abc\n") } throws: {
            "\($0)".contains("https")
        }
    }

    @Test func needsBothKeys() {
        #expect(throws: ConfigError.self) { try load("OPENTODO_URL=https://todo.example.com\n") }
    }
}

@Suite struct FormatDue {
    static let sydney = TimeZone(identifier: "Australia/Sydney")!
    static let posix = Locale(identifier: "en_US_POSIX")
    /// 31 October 2026, 13:00 in Sydney.
    static let now = gregorian(sydney).date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 13))!

    func fmt(_ due: JSON, _ timeFormat: String = "24h", now: Date = now) -> String? {
        formatDue(due, now: now, timeFormat: timeFormat, zone: Self.sydney, locale: Self.posix).map {
            "\($0.text) \($0.state)"
        }
    }

    @Test func minutes() {
        #expect([15, 60, 90, 120].map(formatMinutes) == ["15 min", "1h", "1h 30m", "2h"])
    }

    @Test func relativeDays() {
        #expect(fmt(["date": "2026-10-31"]) == "Today today")
        #expect(fmt(["date": "2026-11-01"]) == "Tomorrow later")
        #expect(fmt(["date": "2026-10-30"]) == "Yesterday overdue")
        #expect(fmt(["date": "2026-11-04"]) == "Wed later")
        #expect(fmt(["date": "2026-11-15"]) == "15 Nov later")
        #expect(fmt(["date": "2027-01-02"]) == "2 Jan 2027 later")
    }

    @Test func timeFormats() {
        let due: JSON = ["date": "2026-11-01", "time": "16:30"]
        #expect(fmt(due) == "Tomorrow 16:30 later")
        #expect(fmt(due, "12h") == "Tomorrow 4:30pm later")
        #expect(fmt(["date": "2026-11-01", "time": "09:00"], "12h") == "Tomorrow 9am later")
    }

    @Test func timedDueEarlierTodayIsOverdue() {
        #expect(fmt(["date": "2026-10-31", "time": "09:00"]) == "Today 09:00 overdue")
        #expect(fmt(["date": "2026-10-31", "time": "17:00"]) == "Today 17:00 today")
    }

    @Test func noDue() {
        #expect(fmt(nil) == nil)
        #expect(fmt(["date": "not a date"]) == nil)
    }

    @Test func zonedDueConvertsToLocalTime() {
        #expect(fmt(["date": "2026-11-04", "time": "09:00", "tz": "Europe/Berlin"]) == "Wed 19:00 later")
    }

    @Test func floatingDueDoesNotConvert() {
        #expect(fmt(["date": "2026-11-04", "time": "09:00"]) == "Wed 09:00 later")
    }
}

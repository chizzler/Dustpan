import Foundation
import Testing
@testable import DustpanCore

@Suite(.enabled(if: Vectors.exists("recurrence"))) struct RecurrenceVectors {
    let v: JSON

    init() throws { v = try Vectors.load("recurrence") }

    func day(_ value: JSON) -> Day? { value.string.flatMap(Day.init) }
    func rule(_ value: JSON) throws -> Rule { try Rule(parsing: value.string!) }

    @Test func parse() {
        for c in v["parse"].array! {
            let input = c["input"].string!
            if c["error"] == true {
                #expect(throws: RuleError.self, "\(input)") { try Rule(parsing: input) }
            } else {
                #expect((try? Rule(parsing: input))?.canonical == c["canonical"].string, "\(input)")
            }
        }
    }

    @Test func next() throws {
        for c in v["next"].array! {
            let today = day(c["today"])!
            let got = try rule(c["rule"]).following(due: day(c["due"]), today: today,
                                                    completedOn: day(c["completedOn"]) ?? today,
                                                    done: Int(c["done"].int!))
            #expect(got.map(\.description) == c["expected"].string, "\(c["name"].string!)")
        }
    }

    @Test func first() throws {
        for c in v["first"].array! {
            #expect(try rule(c["rule"]).first(from: day(c["from"])!).description == c["expected"].string,
                    "\(c["rule"]) from \(c["from"])")
        }
    }

    @Test func preview() throws {
        for c in v["preview"].array! {
            let got = try rule(c["rule"]).preview(due: day(c["due"]), today: day(c["today"])!,
                                                  done: Int(c["done"].int!))
            #expect(got.map(\.description) == c["expected"].array!.map { $0.string! }, "\(c["name"].string!)")
        }
    }

    @Test func deadlineShift() {
        for c in v["deadline"].array! {
            #expect(shift(day(c["deadline"])!, from: day(c["from"])!, to: day(c["to"])!).description
                    == c["expected"].string, "\(c["name"].string!)")
        }
    }
}

@Suite struct Days {
    @Test func roundTripAndWeekday() {
        for text in ["0001-01-01", "1969-12-31", "1970-01-01", "2000-02-29", "2026-11-02", "9999-12-31"] {
            #expect(Day(text)?.description == text)
        }
        #expect(Day("1970-01-01")?.number == 0)
        #expect(Day("2026-11-02")?.weekday == 1)
        #expect(Day("2026-11-08")?.weekday == 7)
        for bad in ["2026-02-29", "2026-13-01", "0000-01-01", "2026-1-01", "2026-11-02x"] {
            #expect(Day(bad) == nil, "\(bad)")
        }
    }

    @Test func dayStart() {
        #expect(dayStartMinutes("04:30") == 270)
        #expect(dayStartMinutes("06:00") == 360)
        for bad: JSON in ["06:01", "4:30", "1:2:3", "", nil, 5] { #expect(dayStartMinutes(bad) == 0, "\(bad)") }
    }
}

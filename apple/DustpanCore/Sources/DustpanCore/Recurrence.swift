import Foundation

// Recurrence rules: parser, canonical form and next occurrence. See docs/recurrence.md.
// A port of web/src/lib/recurrence.ts, checked against recurrence.vectors.json.
// Dates are floating days and never pass through a time zone, so daylight saving has no effect.

/// A floating calendar day, as a count of days from 1970-01-01.
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let number: Int

    init(number: Int) { self.number = number }

    init(year: Int, month: Int, day: Int) {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        number = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    }

    /// YYYY-MM-DD, a day that exists from year 1.
    public init?(_ text: String) {
        guard let m = text.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/),
              let y = Int(m.1), let mo = Int(m.2), let d = Int(m.3),
              y >= 1, (1...12).contains(mo), (1...monthLength(y, mo)).contains(d) else { return nil }
        self.init(year: y, month: mo, day: d)
    }

    /// The day it is at now in zone.
    public init(_ now: Date, in zone: TimeZone = .current) {
        let c = gregorian(zone).dateComponents([.year, .month, .day], from: now)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public var parts: (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, doy - (153 * mp + 2) / 5 + 1)
    }

    /// ISO weekday: 1 is Monday, 7 is Sunday.
    public var weekday: Int { ((number % 7) + 10) % 7 + 1 }

    public var description: String {
        let (y, m, d) = parts
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public static func < (a: Day, b: Day) -> Bool { a.number < b.number }
    public static func + (day: Day, n: Int) -> Day { Day(number: day.number + n) }
    public static func - (day: Day, n: Int) -> Day { Day(number: day.number - n) }
    public static func - (a: Day, b: Day) -> Int { a.number - b.number }
}

func monthLength(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
}

/// Why a rule doesn't parse. The message is for the person typing it.
public struct RuleError: Error, Equatable, CustomStringConvertible {
    public let message: String
    init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct Rule: Equatable, Sendable {
    public enum Unit: String, Sendable { case day, week, month, year }

    public enum Pattern: Equatable, Sendable {
        case interval(Int, Unit, afterCompletion: Bool = false)
        /// Monday to Friday.
        case weekday
        /// ISO weekdays.
        case weekdays(Set<Int>)
        case monthDay(Int)
        case lastDay
        case lastWeekday
        /// The 1st to 4th weekday of a month, or the last (-1).
        case nthWeekday(Int, weekday: Int)
    }

    public var pattern: Pattern
    public var until: Day?
    /// "for N times", 0 when absent.
    public var count = 0

    init(_ pattern: Pattern, until: Day? = nil, count: Int = 0) {
        (self.pattern, self.until, self.count) = (pattern, until, count)
    }

    public var afterCompletion: Bool {
        if case .interval(_, _, true) = pattern { true } else { false }
    }
}

let maxRuleLength = 200
let maxInterval = 999
let maxCount = 10000

private let weekdayNames = ["", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
private let weekdayAliases = [
    "monday": 1, "mon": 1, "tuesday": 2, "tue": 2, "wednesday": 3, "wed": 3, "thursday": 4, "thu": 4,
    "friday": 5, "fri": 5, "saturday": 6, "sat": 6, "sunday": 7, "sun": 7,
]
private let wordOrdinals = ["first": 1, "second": 2, "third": 3, "fourth": 4, "last": -1]
private let mondayToFriday: Set = [1, 2, 3, 4, 5]

func ordinalSuffix(_ n: Int) -> String {
    if (11...13).contains(n % 100) { return "th" }
    return [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
}

private func numericOrdinal(_ token: String) -> Int? {
    guard let m = token.wholeMatch(of: /([1-9][0-9]?)(st|nd|rd|th)/), let n = Int(m.1) else { return nil }
    return n <= 31 && m.2 == ordinalSuffix(n) ? n : nil
}

private func positiveInt(_ token: String?, _ limit: Int) -> Int? {
    guard let token, token.wholeMatch(of: /[1-9][0-9]*/) != nil else { return nil }
    return Int(token).flatMap { $0 <= limit ? $0 : nil }
}

extension Rule {
    /// Read a rule like "every 2 weeks" or "every last friday until 2027-01-01".
    public init(parsing text: String) throws(RuleError) {
        if text.unicodeScalars.count > maxRuleLength { throw RuleError("longer than \(maxRuleLength) characters") }
        let toks = text.lowercased().replacing(",", with: " , ").split(whereSeparator: \.isWhitespace).map(String.init)
        guard toks.first == "every" else { throw RuleError(#"must start with "every""#) }
        var i = 1
        func peek(_ k: Int = 0) -> String? { i + k < toks.count ? toks[i + k] : nil }

        guard let tok = peek() else { throw RuleError(#"missing pattern after "every""#) }
        var rule: Rule
        if let unit = Unit(rawValue: tok) {
            rule = Rule(.interval(1, unit))
            i += 1
        } else if tok == "weekday" || tok == "weekdays" {
            rule = Rule(.weekday)
            i += 1
        } else if tok.wholeMatch(of: /[0-9]+/) != nil {
            guard let n = positiveInt(tok, maxInterval) else {
                throw RuleError("interval must be from 1 to \(maxInterval)")
            }
            let next = peek(1) ?? ""
            guard let unit = Unit(rawValue: next.hasSuffix("s") ? String(next.dropLast()) : next) else {
                throw RuleError("expected day(s), week(s), month(s) or year(s) after \(tok)")
            }
            rule = Rule(.interval(n, unit))
            i += 2
        } else if tok == "last", peek(1) == "day" || peek(1) == "weekday" {
            rule = Rule(peek(1) == "day" ? .lastDay : .lastWeekday)
            i += 2
        } else if weekdayAliases[tok] != nil {
            var days = Set<Int>()
            while true {
                guard let day = peek().flatMap({ weekdayAliases[$0] }) else {
                    throw RuleError(#"expected a weekday, got "\#(peek() ?? "")""#)
                }
                days.insert(day)
                i += 1
                var j = i
                if j < toks.count && toks[j] == "," { j += 1 }
                if j < toks.count && toks[j] == "and" { j += 1 }
                if j == i { break }
                if j >= toks.count { throw RuleError("expected a weekday after the list separator") }
                i = j
            }
            rule = Rule(.weekdays(days))
        } else {
            let word = wordOrdinals[tok], number = numericOrdinal(tok)
            guard let ordinal = number ?? word else { throw RuleError(#"unknown pattern "\#(tok)""#) }
            if let weekday = peek(1).flatMap({ weekdayAliases[$0] }) {
                if ordinal > 4 { throw RuleError("weekday ordinal must be 1st to 4th or last") }
                rule = Rule(.nthWeekday(ordinal, weekday: weekday))
                i += 2
            } else {
                guard let number else { throw RuleError(#"expected a weekday after "\#(tok)""#) }
                rule = Rule(.monthDay(number))
                i += 1
            }
        }
        if peek() == "after" {
            guard peek(1) == "completion" else { throw RuleError(#"expected "completion" after "after""#) }
            guard case .interval(let n, let unit, _) = rule.pattern else {
                throw RuleError(#""after completion" only applies to day, week, month and year intervals"#)
            }
            rule.pattern = .interval(n, unit, afterCompletion: true)
            i += 2
        }
        if peek() == "until" {
            guard let until = peek(1).flatMap(Day.init) else { throw RuleError("until needs a date YYYY-MM-DD") }
            rule.until = until
            i += 2
        } else if peek() == "for" {
            guard let n = positiveInt(peek(1), maxCount), peek(2) == "times" || peek(2) == "time" else {
                throw RuleError(#"expected "for N times" with N from 1 to \#(maxCount)"#)
            }
            rule.count = n
            i += 3
        }
        if let extra = peek() { throw RuleError(#"unexpected "\#(extra)""#) }
        self = rule
    }

    /// The stored form.
    public var canonical: String {
        var s = "every "
        switch pattern {
        case .interval(let n, let unit, _): s += n == 1 ? unit.rawValue : "\(n) \(unit.rawValue)s"
        case .weekday: s += "weekday"
        case .weekdays(let days): s += (1...7).filter(days.contains).map { weekdayNames[$0] }.joined(separator: ", ")
        case .monthDay(let d): s += "\(d)\(ordinalSuffix(d))"
        case .lastDay: s += "last day"
        case .lastWeekday: s += "last weekday"
        case .nthWeekday(let n, let weekday):
            s += "\(n < 0 ? "last" : "\(n)\(ordinalSuffix(n))") \(weekdayNames[weekday])"
        }
        if afterCompletion { s += " after completion" }
        if let until { s += " until \(until)" }
        if count > 0 { s += " for \(count) time\(count == 1 ? "" : "s")" }
        return s
    }
}

// MARK: - Calendar arithmetic

private func addMonths(_ day: Day, _ n: Int) -> Day {
    let (y, m, d) = day.parts
    let index = y * 12 + (m - 1) + n
    let (ny, nm) = (index / 12, index % 12 + 1)
    return Day(year: ny, month: nm, day: min(d, monthLength(ny, nm)))
}

private func step(_ n: Int, _ unit: Rule.Unit, from anchor: Day, times k: Int) -> Day {
    switch unit {
    case .day: anchor + n * k
    case .week: anchor + 7 * n * k
    case .month: addMonths(anchor, n * k)
    case .year: addMonths(anchor, 12 * n * k)
    }
}

private func lastDay(_ y: Int, _ m: Int) -> Day { Day(year: y, month: m, day: monthLength(y, m)) }

extension Rule {
    private func inMonth(_ y: Int, _ m: Int) -> Day {
        switch pattern {
        case .monthDay(let d): return Day(year: y, month: m, day: min(d, monthLength(y, m)))
        case .lastDay: return lastDay(y, m)
        case .lastWeekday:
            var z = lastDay(y, m)
            while z.weekday > 5 { z = z - 1 }
            return z
        case .nthWeekday(let n, let weekday):
            if n < 0 {
                let z = lastDay(y, m)
                return z - (z.weekday - weekday + 7) % 7
            }
            let first = Day(year: y, month: m, day: 1)
            return first + (weekday - first.weekday + 7) % 7 + 7 * (n - 1)
        default: preconditionFailure("not a month pattern")
        }
    }

    /// The first day matching the pattern strictly after day.
    private func firstAfter(_ day: Day) -> Day {
        let days: Set<Int>
        switch pattern {
        case .interval(let n, let unit, _): return step(n, unit, from: day, times: 1)
        case .weekday: days = mondayToFriday
        case .weekdays(let set): days = set
        default:
            let (y, m, _) = day.parts
            let c = inMonth(y, m)
            if c > day { return c }
            return m == 12 ? inMonth(y + 1, 1) : inMonth(y, m + 1)
        }
        return (1...7).lazy.map { day + $0 }.first { days.contains($0.weekday) } ?? day + 7
    }

    /// The first match strictly after due, or after today when that's already past (catch-up).
    func nextCalendar(due: Day?, today: Day) -> Day {
        let d = due ?? today
        let c = firstAfter(d)
        if c >= today { return c }
        guard case .interval(let n, let unit, _) = pattern else { return firstAfter(today) }
        if unit == .day || unit == .week {
            let size = unit == .week ? 7 * n : n
            return d + size * ((today - d) / size + 1)
        }
        var k = 2
        while true {
            let c = step(n, unit, from: d, times: k)
            if c > today { return c }
            k += 1
        }
    }

    /// The occurrence after a completion on completedOn, for an "after completion" rule; else the calendar one.
    func next(due: Day?, today: Day, completedOn: Day) -> Day {
        if case .interval(let n, let unit, true) = pattern { return step(n, unit, from: completedOn, times: 1) }
        return nextCalendar(due: due, today: today)
    }

    /// The next due date after completing the current occurrence, or nil at the end condition.
    /// done is the number of completed occurrence records already in the series.
    public func following(due: Day?, today: Day, completedOn: Day, done: Int = 0) -> Day? {
        let next = next(due: due, today: today, completedOn: completedOn)
        if count > 0 && done + 1 >= count { return nil }
        if let until, next > until { return nil }
        return next
    }

    /// The first occurrence on or after start: the due date for an undated task that gets a rule.
    public func first(from start: Day) -> Day {
        if case .interval = pattern { start } else { firstAfter(start - 1) }
    }

    /// Up to n occurrences after the current one, stopping at the end condition.
    public func preview(due: Day?, today: Day, done: Int = 0, count n: Int = 3) -> [Day] {
        var out: [Day] = []
        var current = due
        for i in stride(from: 1, through: n, by: 1) {
            let completedOn = afterCompletion && i > 1 ? current ?? today : today
            guard let next = following(due: current, today: today, completedOn: completedOn, done: done + i - 1)
            else { break }
            out.append(next)
            current = next
        }
        return out
    }
}

/// day moved by as many days as from start to end.
func shift(_ day: Day, from start: Day, to end: Day) -> Day { day + (end - start) }

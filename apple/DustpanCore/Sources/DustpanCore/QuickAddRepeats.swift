import Foundation

// Repeat-rule phrases ("every monday", "jeden zweiten Freitag", "every 3 days after completion") and reminder
// phrases ("remind me 30 min before"). Ports of quickadd/repeats.py and reminders.py
// (internal/quickadd/recurrence.go and reminders.go). Rules come out in the canonical English form.

struct RepeatMatch {
    let rule: String
    let start: Int
    let to: Int
    /// A phrase the grammar can't express ("every 2 Mondays"): it wins like any match but sets nothing,
    /// so it stays whole in the title.
    var literal = false
    /// The first date, when the rule can't hold the weekday ("every other friday").
    var first: Day?
}

private let weekdayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
private let ordinalNames = [1: "1st", 2: "2nd", 3: "3rd", 4: "4th", -1: "last"]

private func canonicalRule(_ rule: String) -> String? { (try? Rule(parsing: rule))?.canonical }

private func ruleUnitAt(_ tokens: [WordToken], _ i: Int, _ v: JSON) -> (Int, String) {
    unitAt(tokens, i, v, ["day", "week", "month", "year"])
}

/// Romance plurals without their s, hyphenated ones without each part's s, German ones without their e.
private func pluralStems(_ norm: String) -> [String] {
    var out: [String] = []
    let length = norm.unicodeScalars.count
    if length >= 4 && norm.hasSuffix("s") { out.append(String(norm.dropLast())) }
    if length >= 6 && norm.hasSuffix("e") { out.append(String(norm.dropLast())) }
    if norm.contains("-") {
        out.append(norm.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("s") ? String($0.dropLast()) : String($0) }.joined(separator: "-"))
    }
    return out
}

/// A weekday at i, or its plural ("mondays", "Montage", "segundas-feiras"). 0 is Monday, or -1.
private func weekdayPluralAt(_ tokens: [WordToken], _ i: Int, _ v: JSON) -> Int {
    let wd = weekdayAt(tokens, i, v)
    if wd >= 0 { return wd }
    guard let t = tok(tokens, i) else { return -1 }
    for stem in pluralStems(t.norm) {
        var stemmed = t
        stemmed.norm = stem
        let found = weekdayAt([stemmed], 0, v)
        if found >= 0 { return found }
    }
    return -1
}

/// (tokens covered, value): "3rd", "third", "last". Bare digits are a count, not an ordinal.
private func ordinalAt(_ tokens: [WordToken], _ i: Int, _ v: JSON) -> (Int, Int)? {
    guard let t = tok(tokens, i) else { return nil }
    let d = dayNumber(t)
    if !isDigits(t.norm) && d > 0 { return (1, d) }
    let (n, value) = lookupAt(tokens, i, v["ordinals"])
    return n > 0 ? value.int.map { (n, Int($0)) } : nil
}

/// What follows "every": (tokens covered, rule text, monthly), or nil.
private func patternAt(_ tokens: [WordToken], _ k: Int, _ v: JSON) -> (Int, String, Bool)? {
    let allDays = phraseAt(tokens, k, v["weekdayAll"].strings)
    if allDays > 0 { return (allDays, "weekday", false) }
    let count = tok(tokens, k).flatMap { $0.norm.wholeMatch(of: /[0-9]{1,3}/) != nil ? Int($0.norm) : nil } ?? 0
    let skip = count > 0 ? 1 : 0
    let (un, unit) = ruleUnitAt(tokens, k + skip, v)
    if un > 0 { return (skip + un, count > 1 ? "\(count) \(unit)s" : unit, false) }
    if count > 0 && (v["units"].object ?? [:]).values.contains(where: { phraseAt(tokens, k + 1, $0.strings) > 0 }) {
        return nil
    }
    // "2nd monday", "2e lundis", "segunda segunda-feira"
    if let (on, value) = weekdayOrdinalAt(tokens, k, v, { weekdayPluralAt(tokens, $0, v) >= 0 }),
       let name = ordinalNames[value] {
        return (on + 1, "\(name) \(weekdayNames[weekdayPluralAt(tokens, k + on, v)])", true)
    }
    if let (on, value) = ordinalAt(tokens, k, v) {
        let j = k + on
        let wd = weekdayPluralAt(tokens, j, v)
        if wd >= 0 && value <= 4, let name = ordinalNames[value] { return (on + 1, "\(name) \(weekdayNames[wd])", true) }
        if value == -1 {
            let d = phraseAt(tokens, j, v["units"]["day"].strings)
            if d > 0 { return (on + d, "last day", true) }
            let w = phraseAt(tokens, j, v["weekdayAll"].strings)
            if w > 0 { return (on + w, "last weekday", true) }
            return nil
        }
        if tokens[k].norm.first?.isASCII == true && tokens[k].norm.first?.isNumber == true && (1...31).contains(value) {
            return (on, "\(value)\(ordinalSuffix(value))", true)
        }
        return nil
    }
    var days: [String] = [], j = k
    while case let wd = weekdayPluralAt(tokens, j, v), wd >= 0 {
        days.append(weekdayNames[wd])
        j += 1
        let nAnd = phraseAt(tokens, j, v["andWords"].strings)
        if nAnd > 0 && weekdayPluralAt(tokens, j + nAnd, v) >= 0 {
            j += nAnd
        } else if !((tokens[j - 1].text.hasSuffix(",") || tokens[j - 1].text.hasSuffix(";"))
                    && weekdayPluralAt(tokens, j, v) >= 0) {
            break
        }
    }
    return days.isEmpty ? nil : (j - k, days.joined(separator: ", "), false)
}

/// "every 2 Mondays": a count before a weekday, which no rule holds. The token count, or 0.
private func countWeekdayAt(_ tokens: [WordToken], _ k: Int, _ v: JSON) -> Int {
    guard let t = tok(tokens, k), t.norm.wholeMatch(of: /[0-9]{1,3}/) != nil else { return 0 }
    return weekdayPluralAt(tokens, k + 1, v) >= 0 ? 2 : 0
}

/// "every other week" (every 2 weeks), "every other friday" (every 2 weeks from the next Friday),
/// and the French "un vendredi sur deux". (tokens covered, pattern, first date), or nil.
private func everyOtherAt(_ tokens: [WordToken], _ i: Int, _ v: JSON, _ today: Day) -> (Int, String, Day?)? {
    func noun(_ k: Int) -> (Int, String, Day?)? {
        let (n, unit) = ruleUnitAt(tokens, k, v)
        if n > 0 { return (n, "2 \(unit)s", nil) }
        let wd = weekdayPluralAt(tokens, k, v)
        if wd >= 0 { return (1, "2 weeks", (try? Rule(parsing: "every \(weekdayNames[wd])"))?.first(from: today)) }
        return nil
    }
    let ev = phraseAt(tokens, i, v["everyOther"].strings)
    if ev > 0 { return noun(i + ev).map { (ev + $0.0, $0.1, $0.2) } }
    let around = v["everyOtherAround"]
    let pre = phraseAt(tokens, i, around["before"].strings)
    guard pre > 0, let found = noun(i + pre) else { return nil }
    let post = phraseAt(tokens, i + pre + found.0, around["after"].strings)
    return post > 0 ? (pre + found.0 + post, found.1, found.2) : nil
}

/// The rule with any tails after it (after completion, until <date>, for N times), and where it ends.
private func tails(_ tokens: [WordToken], _ start: String, _ from: Int, _ ctx: DateContext) -> (String, Int) {
    var (rule, k) = (start, from)
    let n = anyLanguage(ctx, tokens, k, "afterCompletion")
    if n > 0 && canonicalRule(rule + " after completion") != nil {
        rule += " after completion"
        k += n
    }
    let until = anyLanguage(ctx, tokens, k, "untilWords")
    if until > 0 {
        if let dm = matchDateAt(tokens, k + until, ctx), canonicalRule("\(rule) until \(dm.date)") != nil {
            return ("\(rule) until \(dm.date)", dm.to)
        }
        return (rule, k)
    }
    for v in ctx.vocabs {
        let pre = phraseAt(tokens, k, v["timesWords"]["before"].strings)
        let (cn, count) = countAt(tokens, k + pre, v)
        guard cn > 0, isDigits(tokens[k + pre].norm) else { continue }
        let post = phraseAt(tokens, k + pre + cn, v["timesWords"]["after"].strings)
        if post > 0 && canonicalRule("\(rule) for \(count) times") != nil {
            return ("\(rule) for \(count) times", k + pre + cn + post)
        }
    }
    return (rule, k)
}

func matchRepeatAt(_ tokens: [WordToken], _ i: Int, _ ctx: DateContext) -> RepeatMatch? {
    guard tok(tokens, i) != nil else { return nil }
    var best: RepeatMatch?
    func consider(_ pattern: String, _ k: Int, _ first: Day?) {
        let (rule, end) = tails(tokens, "every " + pattern, k, ctx)
        if let c = canonicalRule(rule), best.map({ end > $0.to }) ?? true {
            best = RepeatMatch(rule: c, start: i, to: end, first: first)
        }
    }
    for v in ctx.vocabs {
        // "every other" first: on a tie it wins over the ordinal reading of "jeden zweiten Freitag".
        if let found = everyOtherAt(tokens, i, v, ctx.today) { consider(found.1, i + found.0, found.2) }
        let (n, pattern) = lookupAt(tokens, i, v["everyOne"])
        if n > 0 {
            consider(pattern.string ?? "", i + n, nil)
            continue
        }
        let ev = phraseAt(tokens, i, v["every"].strings)
        guard ev > 0 else { continue }
        guard let (covered, text, monthly) = patternAt(tokens, i + ev, v) else {
            let n = countWeekdayAt(tokens, i + ev, v)
            if n > 0 && (best.map { i + ev + n > $0.to } ?? true) {
                best = RepeatMatch(rule: "", start: i, to: i + ev + n, literal: true)
            }
            continue
        }
        var k = i + ev + covered
        if monthly { k += anyLanguage(ctx, tokens, k, "ofMonthWords") }
        consider(text, k, nil)
    }
    return best
}

// MARK: - Reminders

/// A reminder as typed: an offset from the due (negative is before), or a moment.
public enum TypedReminder: Equatable, Sendable {
    case offset(minutes: Int)
    case moment(date: Day?, time: String)
}

private let unitMinutes = [("minute", 1), ("hour", 60), ("day", 1440), ("week", 10080)]

/// (tokens covered, minutes) for "30 min before", "2h after", or nil.
private func offsetAt(_ tokens: [WordToken], _ k: Int, _ ctx: DateContext) -> (Int, Int)? {
    var best: (Int, Int)?
    for v in ctx.vocabs {
        var (n, amount) = (0, 0)
        let (cn, count) = countAt(tokens, k, v)
        if cn > 0 {
            for (unit, minutes) in unitMinutes {
                let un = phraseAt(tokens, k + cn, v["units"][unit].strings)
                if un > 0 {
                    (n, amount) = (cn + un, count * minutes)
                    break
                }
            }
        }
        if n == 0, let t = tok(tokens, k) {
            let m = matchDuration(t.text, bareHourIsTime: false)
            if m > 0 { (n, amount) = (1, m) }
        }
        guard n > 0, amount > 0 else { continue }
        let before = phraseAt(tokens, k + n, v["beforeWords"].strings)
        let after = before > 0 ? 0 : phraseAt(tokens, k + n, v["afterWords"].strings)
        guard before > 0 || after > 0 else { continue }
        if best.map({ n + before + after > $0.0 }) ?? true { best = (n + before + after, before > 0 ? -amount : amount) }
    }
    return best
}

/// (tokens covered, date or nil, time) for "tomorrow at 9", "at 9 on Friday", "at 9", or nil.
private func momentAt(_ tokens: [WordToken], _ k: Int, _ ctx: DateContext) -> (Int, Day?, String)? {
    if let dm = matchDateAt(tokens, k, ctx), let tm = matchTimeAt(tokens, dm.to, ctx) { return (tm.to - k, dm.date, tm.time) }
    guard let tm = matchTimeAt(tokens, k, ctx) else { return nil }
    if let dm = matchDateAt(tokens, tm.to, ctx) { return (dm.to - k, dm.date, tm.time) }
    return (tm.to - k, tm.date, tm.time)
}

/// (reminder, start, end) for a phrase starting with "remind me", or nil. An offset wins a tie.
func matchReminderAt(_ tokens: [WordToken], _ i: Int, _ ctx: DateContext) -> (TypedReminder, Int, Int)? {
    guard tok(tokens, i) != nil else { return nil }
    let word = ctx.vocabs.map { phraseAt(tokens, i, $0["remindWords"].strings) }.max() ?? 0
    guard word > 0 else { return nil }
    let k = i + word
    let (offset, moment) = (offsetAt(tokens, k, ctx), momentAt(tokens, k, ctx))
    if let offset, moment.map({ offset.0 >= $0.0 }) ?? true { return (.offset(minutes: offset.1), i, k + offset.0) }
    if let moment { return (.moment(date: moment.1, time: moment.2), i, k + moment.0) }
    return nil
}

/// How to store a typed reminder: relative to the due (offset minutes), or absolute (a day and time).
public enum StoredReminder: Equatable, Sendable {
    case relative(Int)
    case absolute(Day, String)
}

private func minutesOf(_ hhmm: String) -> Int { parseTime(hhmm).map { $0.0 * 60 + $0.1 } ?? 0 }

/// With a due, a moment becomes an offset from the due time (09:00 for a date-only due).
/// Without one, a time alone is today if it's still ahead, else tomorrow.
public func resolveReminder(_ reminder: TypedReminder, due: JSON, today: Day, now: String) -> StoredReminder {
    switch reminder {
    case .offset(let minutes):
        return .relative(minutes)
    case .moment(let date, let time):
        if let dueDay = due["date"].string.flatMap(Day.init) {
            let at = date ?? dueDay
            return .relative((at - dueDay) * 1440 + minutesOf(time) - minutesOf(due["time"].string ?? "09:00"))
        }
        if let date { return .absolute(date, time) }
        return .absolute(minutesOf(time) > minutesOf(now) ? today : today + 1, time)
    }
}

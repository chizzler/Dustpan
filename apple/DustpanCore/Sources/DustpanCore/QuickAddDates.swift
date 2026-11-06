import Foundation

// Quick add's date and time phrases. A port of quickadd/dates.py (internal/quickadd/dates.go).
// Matchers take the tokens and a start index, and return a match ending before token `to`, or nil.

struct DateContext {
    let today: Day
    /// HH:MM, or "" when unknown.
    let now: String
    let vocabs: [JSON]
    /// "DM" or "MD".
    let dayMonthOrder: String
    /// 0 is Sunday.
    let weekStart: Int
}

struct DateMatch {
    let date: Day
    let start: Int
    let to: Int
    /// A month name alone; a later complete date replaces it.
    var bare = false
}

struct TimeMatch {
    let time: String
    /// Set when the time moves the day ("in 20 hours").
    let date: Day?
    let start: Int
    let to: Int
}

// MARK: calendar

func isValidDate(_ y: Int, _ m: Int, _ d: Int) -> Bool {
    (1...12).contains(m) && (1...9999).contains(y) && d >= 1 && d <= monthLength(y, m)
}

/// 0 is Sunday.
private func jsDay(_ day: Day) -> Int { day.weekday % 7 }

/// The next such weekday after today (0 is Monday), never today.
private func nextWeekday(_ today: Day, _ wd: Int) -> Day {
    let n = mod(wd - (today.weekday - 1), 7)
    return today + (n == 0 ? 7 : n)
}

private func daysIntoWeek(_ day: Day, _ weekStart: Int) -> Int { mod(jsDay(day) - weekStart, 7) }

/// "next friday": that day in next week.
private func nextNextWeekday(_ today: Day, _ wd: Int, _ weekStart: Int) -> Day {
    let bare = nextWeekday(today, wd)
    return bare <= today + (6 - daysIntoWeek(today, weekStart)) ? bare + 7 : bare
}

private func nextOccurrence(_ today: Day, _ month: Int, _ day: Int) -> Day? {
    let year = today.parts.year
    for y in year..<(year + 9) where isValidDate(y, month, day) {
        let found = Day(year: y, month: month, day: day)
        if found >= today { return found }
    }
    return nil
}

private func resolveMonthDay(_ today: Day, _ year: Int, _ month: Int, _ day: Int) -> Day? {
    if year != 0 { return isValidDate(year, month, day) ? Day(year: year, month: month, day: day) : nil }
    return nextOccurrence(today, month, day)
}

/// (year, month) with an overflowing month carried.
private func monthIndex(_ y: Int, _ m: Int) -> (Int, Int) {
    let index = y * 12 + m - 1
    return (index / 12, index % 12 + 1)
}

func clockText(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }

/// The ordinal'th weekday (1 is Monday; -1 is the last) of a month.
private func nthWeekdayDate(_ y: Int, _ m: Int, _ ordinal: Int, _ weekday: Int) -> Day {
    Rule(.nthWeekday(ordinal, weekday: weekday)).inMonth(y, m)
}

// MARK: small matchers

private var dayPattern: Regex<(Substring, Substring)> { /([0-9]{1,2})(?:st|nd|rd|th|er|o|a|º|°|ª|\.)?/ }
private var ordinalPattern: Regex<(Substring, Substring)> { /([1-4])(?:st|nd|rd|th|er|re|eme|e|o|a|º|°|ª|\.)/ }

func isDigits(_ text: String) -> Bool { text.wholeMatch(of: /[0-9]+/) != nil }

private func isCount(_ text: String) -> Bool { text.wholeMatch(of: /[0-9]{1,3}/) != nil }

/// 0 is Monday, or -1.
func weekdayAt(_ tokens: [WordToken], _ i: Int, _ v: JSON) -> Int {
    (0..<7).first { phraseAt(tokens, i, v["weekdays"].array?[$0].strings ?? []) > 0 } ?? -1
}

/// 1 to 12, or 0.
private func monthAt(_ tokens: [WordToken], _ i: Int, _ v: JSON, abbr: Bool = true) -> Int {
    for (index, month) in (v["months"].array ?? []).enumerated() {
        if phraseAt(tokens, i, month["names"].strings) > 0 || (abbr && phraseAt(tokens, i, month["abbr"].strings) > 0) {
            return index + 1
        }
    }
    return 0
}

func dayNumber(_ t: WordToken?) -> Int {
    guard let t, let m = t.norm.wholeMatch(of: dayPattern), let n = Int(m.1), (1...31).contains(n) else { return 0 }
    return n
}

private func yearAt(_ t: WordToken?) -> Int {
    guard let t, t.norm.wholeMatch(of: /[0-9]{4}/) != nil else { return 0 }
    return Int(t.norm) ?? 0
}

/// (tokens covered, count): a number up to three digits, or "a", "one".
func countAt(_ tokens: [WordToken], _ i: Int, _ v: JSON) -> (Int, Int) {
    guard let t = tok(tokens, i) else { return (0, 0) }
    if isCount(t.norm) { return (1, Int(t.norm) ?? 0) }
    let n = phraseAt(tokens, i, v["oneWords"].strings)
    return n > 0 ? (n, 1) : (0, 0)
}

/// (tokens covered, unit name), or (0, "").
func unitAt(_ tokens: [WordToken], _ i: Int, _ v: JSON, _ names: [String] = ["hour", "day", "week", "month"]) -> (Int, String) {
    for name in names {
        let n = phraseAt(tokens, i, v["units"][name].strings)
        if n > 0 { return (n, name) }
    }
    return (0, "")
}

/// The longest phrase of v[key] at i, in any active language.
func anyLanguage(_ ctx: DateContext, _ tokens: [WordToken], _ i: Int, _ key: String) -> Int {
    ctx.vocabs.map { phraseAt(tokens, i, $0[key].strings) }.max() ?? 0
}

// MARK: dates

func matchDeadlineAt(_ tokens: [WordToken], _ i: Int, _ ctx: DateContext) -> DateMatch? {
    guard tok(tokens, i) != nil else { return nil }
    var best: DateMatch?
    for v in ctx.vocabs {
        let n = phraseAt(tokens, i, v["deadlineWords"].strings)
        if n > 0, let dm = matchDateAt(tokens, i + n, ctx), best.map({ dm.to > $0.to }) ?? true {
            best = DateMatch(date: dm.date, start: i, to: dm.to)
        }
    }
    return best
}

func matchDateAt(_ tokens: [WordToken], _ i: Int, _ ctx: DateContext) -> DateMatch? {
    guard tok(tokens, i) != nil else { return nil }
    var best: DateMatch?
    func consider(_ m: DateMatch) {
        if best.map({ m.to > $0.to }) ?? true { best = m }
    }
    for v in ctx.vocabs {
        let (n, d) = lookupAt(tokens, i, v["dayWords"])
        if n > 0, let d = d.int { consider(DateMatch(date: ctx.today + Int(d), start: i, to: i + n)) }
        let pre = phraseAt(tokens, i, v["before"].strings)
        for j in pre > 0 ? [i + pre, i] : [i] {
            for matcher in [weekdayPhraseAt, ordinalWeekdayAt, nextPeriodAt, inPeriodAt] {
                if let (day, covered) = matcher(tokens, j, v, ctx) {
                    consider(DateMatch(date: day, start: i, to: j + covered))
                }
            }
            // A month name alone is a weak date, and none right after "from", "since", "of", "for".
            if let (day, covered) = monthDayAt(tokens, j, v, ctx) {
                if covered > 1 {
                    consider(DateMatch(date: day, start: i, to: j + covered))
                } else if j != i || !monthTextBefore(tokens, i, ctx) {
                    consider(DateMatch(date: day, start: i, to: j + covered, bare: true))
                }
            }
            if let (day, covered) = numericDateAt(tokens, j, ctx) {
                consider(DateMatch(date: day, start: i, to: j + covered))
            }
        }
    }
    return best
}

/// "friday", "this friday", "next friday".
private func weekdayPhraseAt(_ tokens: [WordToken], _ j: Int, _ v: JSON, _ ctx: DateContext) -> (Day, Int)? {
    var (k, qualifier) = (j, "")
    let nb = phraseAt(tokens, k, v["nextBefore"].strings)
    if nb > 0 {
        (qualifier, k) = ("next", k + nb)
    } else {
        let tb = phraseAt(tokens, k, v["thisBefore"].strings)
        if tb > 0 { (qualifier, k) = ("this", k + tb) }
    }
    let wd = weekdayAt(tokens, k, v)
    guard wd >= 0 else { return nil }
    k += 1
    if qualifier.isEmpty {
        let na = phraseAt(tokens, k, v["nextAfter"].strings)
        if na > 0 { (qualifier, k) = ("next", k + na) }
    }
    if qualifier == "next" { return (nextNextWeekday(ctx.today, wd, ctx.weekStart), k - j) }
    return (nextWeekday(ctx.today, wd), k - j)
}

/// An ordinal directly before a weekday at i: (tokens covered, 1 to 4 or -1 for last), or nil.
/// Never when a list separator follows the ordinal.
func weekdayOrdinalAt(_ tokens: [WordToken], _ i: Int, _ v: JSON, _ isWeekday: (Int) -> Bool) -> (Int, Int)? {
    guard let t = tok(tokens, i) else { return nil }
    func direct(_ n: Int) -> Bool {
        let text = tokens[i + n - 1].text
        return !text.hasSuffix(",") && !text.hasSuffix(";") && isWeekday(i + n)
    }
    if let m = t.norm.wholeMatch(of: ordinalPattern) {
        return direct(1) ? (1, Int(m.1) ?? 0) : nil
    }
    for table in [v["ordinals"], v["ordinalsBeforeWeekday"]] {
        let (n, value) = lookupAt(tokens, i, table)
        if n > 0 && direct(n), let value = value.int { return (n, Int(value)) }
    }
    return nil
}

/// "5th Friday": no fifth weekday exists, so both tokens stay literal. The token count, or 0.
func ordinalOutOfRangeAt(_ tokens: [WordToken], _ i: Int, _ ctx: DateContext) -> Int {
    guard let t = tok(tokens, i), !isDigits(t.norm), dayNumber(t) > 4, !t.text.hasSuffix(","), !t.text.hasSuffix(";")
    else { return 0 }
    return ctx.vocabs.contains { weekdayAt(tokens, i + 1, $0) >= 0 } ? 2 : 0
}

/// [article] ordinal weekday [of MONTH [YEAR] | of the month]: this month's, or next month's once passed.
private func ordinalWeekdayAt(_ tokens: [WordToken], _ j: Int, _ v: JSON, _ ctx: DateContext) -> (Day, Int)? {
    var k = j + phraseAt(tokens, j, v["ordinalArticles"].strings)
    guard let (on, ordinal) = weekdayOrdinalAt(tokens, k, v, { weekdayAt(tokens, $0, v) >= 0 }) else { return nil }
    k += on
    let wd = weekdayAt(tokens, k, v) + 1
    k += 1
    let (ty, tm, _) = ctx.today.parts
    let of = phraseAt(tokens, k, v["ordinalOf"].strings)
    let month = of > 0 ? monthAt(tokens, k + of, v) : 0
    if month > 0 {
        k += of + 1
        let y = yearAt(tok(tokens, k))
        if y > 0 { return (nthWeekdayDate(y, month, ordinal, wd), k + 1 - j) }
        let day = nthWeekdayDate(ty, month, ordinal, wd)
        return (day >= ctx.today ? day : nthWeekdayDate(ty + 1, month, ordinal, wd), k - j)
    }
    k += anyLanguage(ctx, tokens, k, "ofMonthWords")
    var day = nthWeekdayDate(ty, tm, ordinal, wd)
    if day < ctx.today {
        let (ny, nm) = monthIndex(ty, tm + 1)
        day = nthWeekdayDate(ny, nm, ordinal, wd)
    }
    return (day, k - j)
}

/// "next week", "next month": the first day of it.
private func nextPeriodAt(_ tokens: [WordToken], _ j: Int, _ v: JSON, _ ctx: DateContext) -> (Day, Int)? {
    let nb = phraseAt(tokens, j, v["nextBefore"].strings)
    var k = j + nb
    let (un, unit) = unitAt(tokens, k, v)
    guard unit == "week" || unit == "month" else { return nil }
    k += un
    if nb == 0 {
        let na = phraseAt(tokens, k, v["nextAfter"].strings)
        guard na > 0 else { return nil }
        k += na
    }
    if unit == "week" { return (ctx.today + (7 - daysIntoWeek(ctx.today, ctx.weekStart)), k - j) }
    let (y, m, _) = ctx.today.parts
    let (ny, nm) = monthIndex(y, m + 1)
    return (Day(year: ny, month: nm, day: 1), k - j)
}

/// "in 3 days", "in a week", "in 2 months".
private func inPeriodAt(_ tokens: [WordToken], _ j: Int, _ v: JSON, _ ctx: DateContext) -> (Day, Int)? {
    let nIn = phraseAt(tokens, j, v["inWords"].strings)
    guard nIn > 0 else { return nil }
    let (cn, count) = countAt(tokens, j + nIn, v)
    guard cn > 0 else { return nil }
    let (un, unit) = unitAt(tokens, j + nIn + cn, v)
    guard un > 0, unit != "hour" else { return nil }
    let n = nIn + cn + un
    switch unit {
    case "day": return (ctx.today + count, n)
    case "week": return (ctx.today + 7 * count, n)
    default: return (addMonths(ctx.today, count), n)
    }
}

/// True when the word before i keeps a month name alone as text ("invoices from September").
private func monthTextBefore(_ tokens: [WordToken], _ i: Int, _ ctx: DateContext) -> Bool {
    guard i > 0, !tokens[i - 1].quoted else { return false }
    return ctx.vocabs.contains { phraseAt(tokens, i - 1, $0["monthTextBefore"].strings) == 1 }
}

/// "3 Nov", "3rd of November 2027", "Nov 3", or a month name alone (its first day).
private func monthDayAt(_ tokens: [WordToken], _ j: Int, _ v: JSON, _ ctx: DateContext) -> (Day, Int)? {
    let d1 = dayNumber(tok(tokens, j))
    if d1 > 0 {
        var k = j + 1
        k += phraseAt(tokens, k, v["ofWords"].strings)
        let m = monthAt(tokens, k, v)
        if m > 0 {
            k += 1
            let y = yearAt(tok(tokens, k))
            if y > 0 { k += 1 }
            return resolveMonthDay(ctx.today, y, m, d1).map { ($0, k - j) }
        }
    }
    let m = monthAt(tokens, j, v)
    guard m > 0 else { return nil }
    let d2 = dayNumber(tok(tokens, j + 1))
    if d2 > 0 {
        var k = j + 2
        let y = yearAt(tok(tokens, k))
        if y > 0 { k += 1 }
        return resolveMonthDay(ctx.today, y, m, d2).map { ($0, k - j) }
    }
    let full = monthAt(tokens, j, v, abbr: false)
    guard full > 0 else { return nil }
    return resolveMonthDay(ctx.today, 0, full, 1).map { ($0, 1) }
}

/// 2026-11-03, 3/11, 3.11.26 (day first only when the order is DM).
private func numericDateAt(_ tokens: [WordToken], _ j: Int, _ ctx: DateContext) -> (Day, Int)? {
    guard let t = tok(tokens, j) else { return nil }
    if let m = t.norm.wholeMatch(of: /([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})/) {
        let (y, mo, d) = (Int(m.1)!, Int(m.2)!, Int(m.3)!)
        return isValidDate(y, mo, d) ? (Day(year: y, month: mo, day: d), 1) : nil
    }
    guard let m = t.norm.wholeMatch(of: /([0-9]{1,2})([\/.-])([0-9]{1,2})(?:([\/.-])([0-9]{2}|[0-9]{4}))?(\.?)/),
          m.4 == nil || m.4 == m.2 else { return nil }
    let dotted = m.2 == "."
    if (t.norm.hasSuffix(".") && !dotted) || (dotted && ctx.dayMonthOrder != "DM") { return nil }
    let (a, b) = (Int(m.1)!, Int(m.3)!)
    var year = m.5.flatMap { Int($0) } ?? 0
    if m.5 != nil && year < 100 { year += 2000 }
    var (day, month) = ctx.dayMonthOrder == "DM" ? (a, b) : (b, a)
    let probe = year != 0 ? year : ctx.today.parts.year
    if !dotted && !isValidDate(probe, month, day) && isValidDate(probe, day, month) { (day, month) = (month, day) }
    return resolveMonthDay(ctx.today, year, month, day).map { ($0, 1) }
}

// MARK: times

func matchTimeAt(_ tokens: [WordToken], _ i: Int, _ ctx: DateContext) -> TimeMatch? {
    guard tok(tokens, i) != nil else { return nil }
    var best: TimeMatch?
    func consider(_ m: TimeMatch?) {
        if let m, best.map({ m.to > $0.to }) ?? true { best = m }
    }
    let hourSuffix = ctx.vocabs.contains { $0["hourSuffixH"].bool == true }
    for v in ctx.vocabs {
        consider(inHoursAt(tokens, i, v, ctx))
        let at = phraseAt(tokens, i, v["atWords"].strings)
        let j = i + at
        let (n, value) = lookupAt(tokens, j, v["timeWords"])
        if n > 0, let time = value.string { consider(TimeMatch(time: time, date: nil, start: i, to: j + n)) }
        if let (time, covered) = clockAt(tokens, j, v, afterAt: at > 0, hourSuffix: hourSuffix) {
            consider(TimeMatch(time: time, date: nil, start: i, to: j + covered))
        }
    }
    return best
}

/// "in 2 hours": now plus the hours, perhaps on a later day.
private func inHoursAt(_ tokens: [WordToken], _ i: Int, _ v: JSON, _ ctx: DateContext) -> TimeMatch? {
    let nIn = phraseAt(tokens, i, v["inWords"].strings)
    guard !ctx.now.isEmpty, nIn > 0, let (h, m) = parseTime(ctx.now) else { return nil }
    let (cn, count) = countAt(tokens, i + nIn, v)
    guard cn > 0 else { return nil }
    let (un, unit) = unitAt(tokens, i + nIn + cn, v)
    guard unit == "hour" else { return nil }
    let total = h + count
    return TimeMatch(time: clockText(total % 24, m), date: ctx.today + total / 24, start: i, to: i + nIn + cn + un)
}

/// (tokens covered, pm), or nil.
private func meridiem(_ tokens: [WordToken], _ k: Int, _ v: JSON) -> (Int, Bool)? {
    if phraseAt(tokens, k, v["pm"].strings) > 0 { return (1, true) }
    if phraseAt(tokens, k, v["am"].strings) > 0 { return (1, false) }
    return nil
}

private func to24(_ h: Int, _ pm: Bool) -> Int { h == 12 ? (pm ? 12 : 0) : (pm ? h + 12 : h) }

/// (HH:MM, tokens covered), or nil. A bare number is a time only after "at" or before "o'clock".
private func clockAt(_ tokens: [WordToken], _ j: Int, _ v: JSON, afterAt: Bool, hourSuffix: Bool) -> (String, Int)? {
    guard let t = tok(tokens, j) else { return nil }
    let s = t.norm
    func hourWord(_ k: Int) -> Int { phraseAt(tokens, k, v["hourWords"].strings) }

    if let m = s.wholeMatch(of: /([0-9]{1,2}):([0-9]{2})(am|pm|a\.m\.|p\.m\.)?/) {
        let (h, mins) = (Int(m.1)!, Int(m.2)!)
        guard mins <= 59 else { return nil }
        if let amPm = m.3.map({ (0, $0.hasPrefix("p")) }) ?? meridiem(tokens, j + 1, v) {
            return (1...12).contains(h) ? (clockText(to24(h, amPm.1), mins), 1 + amPm.0) : nil
        }
        return h <= 23 ? (clockText(h, mins), 1 + hourWord(j + 1)) : nil
    }
    if let m = s.wholeMatch(of: /([0-9]{1,2})\.([0-9]{2})/) {
        let (h, mins) = (Int(m.1)!, Int(m.2)!)
        let hw = hourWord(j + 1)
        if (!afterAt && hw == 0) || h > 23 || mins > 59 { return nil }
        return (clockText(h, mins), 1 + hw)
    }
    if let m = s.wholeMatch(of: /([0-9]{1,2})(am|pm|a\.m\.|p\.m\.)/) {
        let h = Int(m.1)!
        return (1...12).contains(h) ? (clockText(to24(h, m.2.hasPrefix("p")), 0), 1) : nil
    }
    if let m = s.wholeMatch(of: /([0-9]{1,2})h([0-9]{2})?/) {
        let (h, mins) = (Int(m.1)!, m.2.flatMap { Int($0) } ?? 0)
        if h > 23 || mins > 59 || (m.2 == nil && !afterAt && !hourSuffix) { return nil }
        return (clockText(h, mins), 1)
    }
    if let m = s.wholeMatch(of: /([0-9]{1,2})/) {
        let h = Int(m.1)!
        if let amPm = meridiem(tokens, j + 1, v) {
            return (1...12).contains(h) ? (clockText(to24(h, amPm.1), 0), 1 + amPm.0) : nil
        }
        let hw = hourWord(j + 1)
        if (!afterAt && hw == 0) || h > 23 { return nil }
        return (clockText(h, 0), 1 + hw)
    }
    return nil
}

/// (tokens covered, sector word) for the longest time sector phrase at i in any active language, or (0, nil).
func sectorPhraseAt(_ tokens: [WordToken], _ i: Int, _ ctx: DateContext) -> (Int, String?) {
    var (best, word): (Int, String?) = (0, nil)
    guard tok(tokens, i) != nil else { return (best, word) }
    for v in ctx.vocabs {
        for w in sectorWords {
            let n = phraseAt(tokens, i, v["sectorPhrases"][w].strings)
            if n > best { (best, word) = (n, w) }
        }
    }
    return (best, word)
}

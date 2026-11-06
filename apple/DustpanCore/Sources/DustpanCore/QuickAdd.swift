import Foundation

// Quick add: read "Call Sam tomorrow at 3pm #Work @phone p1 every week" into task fields.
// A port of the desktop's quickadd package (parse.py, settings.py), itself a port of OpenTodo's internal/quickadd,
// in six languages, checked against web/src/lib/nlp/quickadd.vectors.json. See spec/quickadd.md.

public struct QuickAddContext: Sendable {
    public var today: Day
    /// HH:MM.
    public var now: String
    public var languages = ["en"]
    public var projects: [QuickAddProject] = []
    /// "DM" or "MD"; the first language's when empty.
    public var dayMonthOrder = ""
    /// 0 is Sunday.
    public var weekStart = 1
    /// Read "this morning", "tomorrow afternoon".
    public var dayParts = false
    /// Read ~deep, ~low.
    public var energy = false
    /// Read "this week", "sometime next month".
    public var sectors = false

    public init(today: Day, now: String, languages: [String] = ["en"], projects: [QuickAddProject] = []) {
        (self.today, self.now, self.languages, self.projects) = (today, now, languages, projects)
    }
}

/// What a line sets.
public struct QuickAddResult: Equatable, Sendable {
    public var title = ""
    /// {"date"} or {"date", "time"}, or null.
    public var due: JSON = nil
    public var deadline: Day?
    public var someday = false
    /// "2026-W45": from a sector phrase on a line without a date.
    public var sector: String?
    public var evening = false
    /// "morning" or "afternoon".
    public var dayPart: String?
    public var projectId: String?
    /// Names, as typed.
    public var labels: [String] = []
    public var priority: Int?
    public var energy: String?
    public var estimateMinutes: Int?
    public var spentMinutes: Int?
    public var recurrence: String?
    /// As typed; see resolveReminder.
    public var reminders: [TypedReminder] = []
}

/// What a line sets. Pure: the result depends only on the line and the context.
public func parseQuickAdd(_ line: String, _ ctx: QuickAddContext) -> QuickAddResult {
    var parser = QuickAddParser(line, ctx)
    return parser.run()
}

private struct QuickAddParser {
    let line: [Unicode.Scalar]
    let ctx: QuickAddContext
    let dates: DateContext
    let bareHourIsTime: Bool
    let tokens: [WordToken]
    let quotes: [Span]
    // What was recognised, with its span.
    var date: (Day, Span)?, time: (String, Span)?, deadline: (Day, Span)?, project: (String, Span)?
    var repeatRule: (String, Span)?, dayPart: (String, Span)?, sector: (String, Span)?
    var priority: (Int, Span)?, estimate: (Int, Span)?
    /// A month name alone, which a later complete date replaces.
    var dateBare = false
    /// The first date of "every other friday".
    var repeatFirst: Day?
    /// The day a time like "in 20 hours" lands on.
    var timeDate: Day?
    var spent: Int?
    var evening: Span?, someday: Span?
    var labels: [(String, Span)] = [], energies: [(String, Span)] = [], reminders: [(TypedReminder, Span)] = []

    init(_ line: String, _ ctx: QuickAddContext) {
        self.line = Array(line.unicodeScalars)
        self.ctx = ctx
        let vocabs = quickAddLanguages(ctx.languages).compactMap { quickAddVocabs[$0] }
        dates = DateContext(today: ctx.today, now: ctx.now, vocabs: vocabs,
                            dayMonthOrder: ctx.dayMonthOrder.isEmpty ? vocabs.first?["dayMonthOrder"].string ?? "MD"
                                : ctx.dayMonthOrder,
                            weekStart: ctx.weekStart)
        bareHourIsTime = vocabs.contains { $0["hourSuffixH"].bool == true }
        (tokens, quotes) = tokenizeWords(self.line)
    }

    func span(_ start: Int, _ to: Int) -> Span { (tokens[start].start, tokens[to - 1].end) }

    mutating func run() -> QuickAddResult {
        var i = 0
        while i < tokens.count {
            if tokens[i].quoted {
                i += 1
            } else {
                let next = attribute(i)
                i = next > 0 ? next : phrase(i)
            }
        }
        return result()
    }

    func words(_ i: Int, _ key: String) -> Int { wordsAt(tokens, i, dates.vocabs) { $0[key] } }

    /// A part of the day without a date means today, and replaces a month name alone.
    mutating func setDateToday(_ span: Span) {
        if date == nil || dateBare { (date, dateBare) = ((ctx.today, span), false) }
    }

    // MARK: single tokens and fixed words

    /// The next token index after an attribute at i, or 0.
    mutating func attribute(_ i: Int) -> Int {
        let text = tokens[i].text
        let one = span(i, i + 1)
        if project == nil && text.count > 1 && text.hasPrefix("#"), let found = matchProject(text, ctx.projects) {
            project = (found.id, one)
            return i + 1
        }
        if let label = matchLabel(text) {
            labels.append((label, one))
            return i + 1
        }
        if ctx.energy {
            let found = matchEnergy(text)
            if !found.isEmpty {
                energies.append((found, one))
                return i + 1
            }
        }
        if priority == nil {
            let found = matchPriority(text)
            if found > 0 {
                priority = (found, one)
                return i + 1
            }
        }
        if estimate == nil {
            if let found = matchSpent(text) {
                (spent, estimate) = (found.spent, (found.estimate, one))
                return i + 1
            }
            let minutes = matchDuration(text, bareHourIsTime: bareHourIsTime)
            if minutes > 0 {
                estimate = (minutes, one)
                return i + 1
            }
        }
        if deadline == nil, let dl = matchDeadlineAt(tokens, i, dates) {
            deadline = (dl.date, span(dl.start, dl.to))
            // A time after the deadline is read past, and stays in the title.
            return matchTimeAt(tokens, dl.to, dates)?.to ?? dl.to
        }
        let next = thisPart(i)
        if next > 0 { return next }
        if evening == nil {
            let n = words(i, "eveningWords")
            if n > 0 {
                evening = span(i, i + n)
                setDateToday(span(i, i + n))
                return i + n
            }
        }
        return 0
    }

    /// A line sets one part of the day: the evening flag or a day part, never both.
    var partFree: Bool { evening == nil && dayPart == nil }

    /// "this morning", "this afternoon": today, with that part.
    mutating func thisPart(_ i: Int) -> Int {
        guard ctx.dayParts && partFree else { return 0 }
        for part in ["morning", "afternoon"] {
            let n = words(i, "\(part)Words")
            if n > 0 {
                dayPart = (part, span(i, i + n))
                setDateToday(span(i, i + n))
                return i + n
            }
        }
        return 0
    }

    /// A part word right after a date ("tomorrow morning"). Returns where reading goes on.
    mutating func partAfter(_ to: Int) -> Int {
        guard ctx.dayParts && partFree && to < tokens.count && !tokens[to].quoted else { return to }
        var (best, part) = (0, "")
        for name in ["morning", "afternoon", "evening"] {
            let n = wordsAt(tokens, to, dates.vocabs) { $0["partWords"][name] }
            if n > best { (best, part) = (n, name) }
        }
        guard best > 0 else { return to }
        if part == "evening" { evening = span(to, to + best) } else { dayPart = (part, span(to, to + best)) }
        return to + best
    }

    // MARK: phrases

    /// The longest of a date, a time, a repeat rule or a reminder at i, then the someday words.
    mutating func phrase(_ i: Int) -> Int {
        var dm: DateMatch?, tm: TimeMatch?
        if date == nil || dateBare {
            dm = matchDateAt(tokens, i, dates)
            if date != nil && dm?.bare == true { dm = nil }  // after a bare month, only a complete date
        }
        if time == nil { tm = matchTimeAt(tokens, i, dates) }
        // After the first rule only a literal match counts. "5th Friday" is one too.
        var rm = matchRepeatAt(tokens, i, dates)
        if let found = rm, repeatRule != nil && !found.literal { rm = nil }
        if rm == nil {
            let n = ordinalOutOfRangeAt(tokens, i, dates)
            if n > 0 { rm = RepeatMatch(rule: "", start: i, to: i + n, literal: true) }
        }
        let mm = matchReminderAt(tokens, i, dates)

        let phraseEnd = max(rm?.to ?? 0, mm?.2 ?? 0)
        if phraseEnd > max(dm?.to ?? 0, tm?.to ?? 0) {
            if let rm, rm.to == phraseEnd {
                if !rm.literal {
                    repeatRule = (rm.rule, span(rm.start, rm.to))
                    repeatFirst = rm.first
                }
                return rm.to
            }
            let (reminder, start, end) = mm!
            reminders.append((reminder, span(start, end)))
            return end
        }
        if let dm, tm.map({ dm.to >= $0.to }) ?? true {
            (date, dateBare) = ((dm.date, span(dm.start, dm.to)), dm.bare)
            return partAfter(dm.to)
        }
        if let tm {
            (time, timeDate) = ((tm.time, span(tm.start, tm.to)), tm.date)
            return tm.to
        }
        // A sector phrase, like the someday words, counts only on a line without a date.
        if ctx.sectors && sector == nil {
            let (n, word) = sectorPhraseAt(tokens, i, dates)
            if n > 0, let word, let resolved = resolveSector(word, today: ctx.today, weekStart: dates.weekStart) {
                sector = (resolved, span(i, i + n))
                return i + n
            }
        }
        if someday == nil {
            let n = words(i, "somedayWords")
            if n > 0 {
                someday = span(i, i + n)
                return i + n
            }
        }
        return i + 1
    }

    // MARK: result

    /// The date, else the rule's first date, the time's own date, or today.
    func due() -> JSON {
        guard date != nil || time != nil || repeatRule != nil else { return nil }
        let day: Day
        if let date {
            day = date.0
        } else if let repeatRule {
            day = repeatFirst ?? (try? Rule(parsing: repeatRule.0))?.first(from: ctx.today) ?? ctx.today
        } else {
            day = timeDate ?? ctx.today
        }
        if let time { return ["date": .string(day.description), "time": .string(time.0)] }
        return ["date": .string(day.description)]
    }

    func result() -> QuickAddResult {
        let sectored = sector != nil && date == nil && time == nil && repeatRule == nil
        let parked = someday != nil && !(sectored || date != nil || time != nil || deadline != nil || repeatRule != nil)
        var remove: [Span?] = [date?.1, time?.1, dayPart?.1, deadline?.1, project?.1, repeatRule?.1, priority?.1,
                               estimate?.1]
        remove += energies.map(\.1) + labels.map(\.1) + reminders.map(\.1)
        remove += [evening, parked ? someday : nil, sectored ? sector?.1 : nil]
        var out = QuickAddResult()
        out.title = stripSpans(line, remove: remove.compactMap { $0 }, drop: quotes)
        out.due = due()
        out.deadline = deadline?.0
        out.someday = parked
        out.sector = sectored ? sector?.0 : nil
        out.evening = evening != nil
        out.dayPart = dayPart?.0
        out.projectId = project?.0
        out.labels = labels.map(\.0)
        out.priority = priority?.0
        out.energy = energies.last?.0
        out.estimateMinutes = estimate?.0
        out.spentMinutes = spent
        out.recurrence = repeatRule?.0
        out.reminders = reminders.map(\.0)
        return out
    }
}

// MARK: - The context from the user's preferences (settings.py, web/src/lib/nlp/settings.ts)

/// The user's date format when it names an order, else the language's. English is month first only in the US.
func dayMonthOrder(_ prefs: [String: JSON], firstLanguage: String) -> String {
    switch prefs["date_format"]?.string {
    case "day-month": return "DM"
    case "month-day": return "MD"
    default: break
    }
    let parts = firstLanguage.lowercased().replacing("_", with: "-").split(separator: "-", maxSplits: 1)
    let (lang, region) = (parts.first.map(String.init) ?? "", parts.count > 1 ? String(parts[1]) : "")
    if lang == "en" { return region.isEmpty || region == "us" ? "MD" : "DM" }
    return quickAddVocabs[lang]?["dayMonthOrder"].string ?? "MD"
}

/// The parse context. prefs: the user_prefs values. projects: live projects, archived too.
/// system: this device's language tag, like "en-AU".
public func quickAddContext(prefs: [String: JSON], projects: [Row], today: Day, now: String,
                            system: String = Locale.preferredLanguages.first ?? "en") -> QuickAddContext {
    let language = prefs["language"]?.string
    let languages = language.map { !$0.isEmpty && $0 != "system" ? [$0, system] : [system] } ?? [system]
    let first = languages.first { quickAddVocabs[languageCode($0)] != nil } ?? "en"
    var ctx = QuickAddContext(today: today, now: now, languages: languages, projects: projects.map { p in
        QuickAddProject(id: p.id, name: p["name"].string ?? "", parentId: p["parent_id"].string,
                        archived: p["archived"].isTruthy)
    })
    ctx.dayMonthOrder = dayMonthOrder(prefs, firstLanguage: first)
    ctx.weekStart = prefs["week_start"]?.string.flatMap { weekStartPrefs[$0] } ?? 1
    ctx.dayParts = prefs["day_parts"]?.string == "on"
    ctx.energy = prefs["energy"]?.string == "on"
    ctx.sectors = prefs["time_sectors"]?.string == "on"
    return ctx
}

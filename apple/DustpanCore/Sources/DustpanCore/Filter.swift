import Foundation

// The filter query language: parse a query, then test tasks against it.
// A port of filters.py (web/src/lib/filter/parse.ts and evaluate.ts, v0.22.0). The grammar and messages are in
// OpenTodo's docs/filters.md. Positions count code points, like the Go parser. See spec/views.md.

/// A query that doesn't follow the grammar. offset is 0-based; the message counts from 1.
public struct FilterError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    init(_ message: String, _ offset: Int) { (self.message, self.offset) = (message, offset) }
    public var description: String { message }
}

public enum Comparison: String, Sendable { case lt = "<", le = "<=", eq = "=", ge = ">=", gt = ">" }

public enum DateExpr: Equatable, Sendable {
    case relative(Int)
    /// 0 is Sunday.
    case weekday(Int)
    case iso(Day)
    /// This (0), last (-1) or next (1) week or month, or n ago.
    case period(month: Bool, Int)
}

public indirect enum FilterNode: Equatable, Sendable {
    case or([FilterNode])
    case and([FilterNode])
    case not(FilterNode)
    case label(String)
    case project(String, descendants: Bool)
    case priority(Int)
    /// due, created, deadline, start or completed.
    case date(String, Comparison, DateExpr)
    case keyword(String)
    case search(String)
    case notes(String)
    case origin(String)
    case energy(String)
    case sector(String)
    /// A term that needs data this client doesn't keep: it parses, matches nothing and warns.
    case unsupported(String)
}

let maxQueryLength = 4096
let maxNesting = 64
let maxDuration = 144_000

private let weekdayWords = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
private let simpleKeywords: Set = [
    "overdue", "today", "tomorrow", "completed", "open", "subtask", "someday", "deferred", "evening", "morning",
    "afternoon", "blocked", "unblocked", "available", "habit", "origin", "energy", "notes", "sector", "carried",
]
private let noKeywords: Set = ["date", "project", "labels", "time", "deadline", "start", "origin", "energy", "notes", "sector"]
private let dateFields: Set = ["due", "created", "deadline", "start"]
private let dateStarts: Set = ["today", "tomorrow", "yesterday", "this", "last", "next"]
private let dateUnits: Set = ["days", "week", "weeks", "month", "months"]
private let energies: Set = ["deep", "medium", "low"]

private func isISODate(_ text: String) -> Bool { text.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil }
private func isInteger(_ text: String) -> Bool { text.wholeMatch(of: /[0-9]+/) != nil }

/// "30m", "1h30", "1.5h" or a bare number of minutes. Nil when it isn't one.
func durationMinutes(_ text: String) -> Int? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let m = text.wholeMatch(of: /([0-9]+(?:\.[0-9]+)?)h(?:([0-9]{1,2})(?:m|min)?)?/) {
        let minutes = m.2.flatMap { Int($0) } ?? 0
        guard minutes <= 59, let hours = Double(m.1), hours * 60 <= Double(maxDuration) else { return nil }
        let total = Int((hours * 60 + Double(minutes) + 0.5).rounded(.down))  // half up, like JS
        return total <= maxDuration ? total : nil
    }
    if let m = text.wholeMatch(of: /([0-9]+)(?:m|min|mins|minutes)?/) {
        return Int(m.1).flatMap { $0 <= maxDuration ? $0 : nil }
    }
    return nil
}

/// A sector: term's value: a relative word ("this-week") or a period in upper case ("2026-W44"), or nil.
func sectorTermValue(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let word = trimmed.lowercased().split { $0.isWhitespace || $0 == "_" || $0 == "-" }.joined(separator: "-")
    if sectorWords.contains(word) { return word }
    return Period(trimmed.uppercased()) != nil ? trimmed.uppercased() : nil
}

// MARK: - Tokens

private struct Token {
    enum Kind {
        case and, or, not, lparen, rparen, cmp, label, project, priority
        case search, notes, origin, energy, sector, workspace, word, string
    }
    var kind: Kind
    var pos: Int
    var raw: String
    var value = ""
    var descendants = false
}

private func tokenize(_ src: [Unicode.Scalar]) throws(FilterError) -> [Token] {
    var out: [Token] = []
    var i = 0
    let n = src.count
    func text(_ a: Int, _ b: Int) -> String { String(String.UnicodeScalarView(src[a..<b])) }
    func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
    func isBreak(_ c: Unicode.Scalar) -> Bool { isSpace(c) || "\"&|!()<>=".unicodeScalars.contains(c) }

    func readBare() -> String {
        let start = i
        while i < n && !isBreak(src[i]) { i += 1 }
        return text(start, i)
    }
    /// src[i] is the opening quote. A backslash escapes the next character.
    func readString() throws(FilterError) -> String {
        let start = i
        i += 1
        var s = String.UnicodeScalarView()
        while i < n && src[i] != "\"" {
            if src[i] == "\\" && i + 1 < n { i += 1 }
            s.append(src[i])
            i += 1
        }
        if i >= n { throw FilterError("Missing closing quote for the text starting at position \(start + 1)", start) }
        i += 1
        return String(s)
    }
    func readName(_ what: String, after: String, at: Int) throws(FilterError) -> String {
        if i < n && src[i] == "\"" { return try readString() }
        let name = readBare()
        if name.isEmpty { throw FilterError(#"Expected a \#(what) name after "\#(after)" at position \#(at + 1)"#, at) }
        return name
    }
    /// "search:text", "search: text" or 'search: "several words"'. rest is what followed the colon.
    func readPrefixed(_ rest: String) throws(FilterError) -> String {
        if !rest.isEmpty { return rest }
        while i < n && isSpace(src[i]) { i += 1 }
        return i < n && src[i] == "\"" ? try readString() : readBare()
    }

    let single: [Unicode.Scalar: Token.Kind] = ["&": .and, "|": .or, "!": .not, "(": .lparen, ")": .rparen]
    while i < n {
        let c = src[i]
        if isSpace(c) {
            i += 1
            continue
        }
        let pos = i
        if let kind = single[c] {
            i += 1
            out.append(Token(kind: kind, pos: pos, raw: String(c)))
        } else if c == "<" || c == ">" || c == "=" {
            let op = c != "=" && i + 1 < n && src[i + 1] == "=" ? "\(c)=" : "\(c)"
            i += op.unicodeScalars.count
            out.append(Token(kind: .cmp, pos: pos, raw: op, value: op))
        } else if c == "@" {
            i += 1
            let name = try readName("label", after: "@", at: pos)
            out.append(Token(kind: .label, pos: pos, raw: text(pos, i), value: name))
        } else if c == "#" {
            let descendants = i + 1 < n && src[i + 1] == "#"
            i += descendants ? 2 : 1
            let name = try readName("project", after: descendants ? "##" : "#", at: pos)
            out.append(Token(kind: .project, pos: pos, raw: text(pos, i), value: name, descendants: descendants))
        } else if c == "\"" {
            let value = try readString()
            out.append(Token(kind: .string, pos: pos, raw: text(pos, i), value: value))
        } else {
            let word = readBare()
            let scalars = word.unicodeScalars
            let colon = scalars.firstIndex(of: ":")
            let prefix = colon.map { String(scalars[...$0]).lowercased() } ?? ""
            let rest = colon.map { String(scalars[scalars.index(after: $0)...]) } ?? ""
            if prefix == "sector:" {
                var typed = try readPrefixed(rest)
                if ["this", "next"].contains(typed.lowercased()) {  // "sector: this week", written with a space
                    while i < n && isSpace(src[i]) { i += 1 }
                    typed = "\(typed) \(readBare())"
                }
                guard let value = sectorTermValue(typed) else {
                    throw FilterError(#"Unknown time sector "\#(typed)" at position \#(pos + 1); use this week, "#
                        + "next week, this month, next month, this quarter, next quarter or a period such as 2026-W44",
                        pos)
                }
                out.append(Token(kind: .sector, pos: pos, raw: text(pos, i), value: value))
            } else if let kind = ["search:": Token.Kind.search, "notes:": .notes, "workspace:": .workspace,
                                  "origin:": .origin, "energy:": .energy][prefix] {
                var value = try readPrefixed(rest)
                if kind == .energy {
                    value = value.lowercased()
                    guard energies.contains(value) else {
                        throw FilterError("Energy must be deep, medium or low at position \(pos + 1)", pos)
                    }
                } else if value.isEmpty {
                    let what = switch kind {
                    case .workspace: "a workspace name"
                    case .origin: "a provider or kind"
                    default: "text"
                    }
                    throw FilterError(#"Expected \#(what) after "\#(prefix)" at position \#(pos + 1)"#, pos)
                }
                out.append(Token(kind: kind, pos: pos, raw: text(pos, i), value: value))
            } else if let m = word.wholeMatch(of: /[pP]([1-4])/) {
                out.append(Token(kind: .priority, pos: pos, raw: word, value: String(m.1)))
            } else {
                out.append(Token(kind: .word, pos: pos, raw: word, value: word))
            }
        }
    }
    return out
}

// MARK: - Parser

/// The query's tree, or nil for an empty query.
public func parseFilter(_ src: String) throws(FilterError) -> FilterNode? {
    let scalars = Array(src.unicodeScalars)
    if scalars.count > maxQueryLength {
        throw FilterError("Query is too long: \(scalars.count) characters, at most \(maxQueryLength)", maxQueryLength)
    }
    let tokens = try tokenize(scalars)
    if tokens.isEmpty { return nil }
    var parser = Parser(tokens: tokens, end: scalars.count)
    return try parser.query()
}

private struct Parser {
    let tokens: [Token]
    let end: Int
    var i = 0
    var depth = 0

    init(tokens: [Token], end: Int) { (self.tokens, self.end) = (tokens, end) }

    func peek(_ ahead: Int = 0) -> Token? { i + ahead < tokens.count ? tokens[i + ahead] : nil }

    func lower(_ tok: Token?) -> String { tok?.kind == .word ? tok!.value.lowercased() : "" }

    @discardableResult
    mutating func take() -> Token {
        defer { i += 1 }
        return tokens[i]
    }

    mutating func query() throws(FilterError) -> FilterNode {
        let ast = try parseOr(nil)
        if let rest = peek() {
            if rest.kind == .rparen { throw FilterError(#"Unexpected ")" at position \#(rest.pos + 1)"#, rest.pos) }
            throw FilterError(#"Expected "&" or "|" before "\#(rest.raw)" at position \#(rest.pos + 1)"#, rest.pos)
        }
        return ast
    }

    /// prev is the operator or parenthesis just read, if any.
    func missingTerm(_ prev: Token?) -> FilterError {
        if let prev { return FilterError(#"Expected a term after "\#(prev.raw)" at position \#(prev.pos + 1)"#, prev.pos) }
        let at = peek()?.pos ?? end
        return FilterError("Expected a term at position \(at + 1)", at)
    }

    mutating func parseOr(_ prev: Token?) throws(FilterError) -> FilterNode {
        var items = [try parseAnd(prev)]
        while let tok = peek(), tok.kind == .or {
            take()
            items.append(try parseAnd(tok))
        }
        return items.count == 1 ? items[0] : .or(items)
    }

    mutating func parseAnd(_ prev: Token?) throws(FilterError) -> FilterNode {
        var items = [try parseNot(prev)]
        while let tok = peek(), tok.kind == .and {
            take()
            items.append(try parseNot(tok))
        }
        return items.count == 1 ? items[0] : .and(items)
    }

    mutating func enter(_ tok: Token) throws(FilterError) {
        depth += 1
        if depth > maxNesting {
            throw FilterError(#"Too deeply nested at position \#(tok.pos + 1); use at most \#(maxNesting) levels of "(" and "!""#,
                              tok.pos)
        }
    }

    mutating func parseNot(_ prev: Token?) throws(FilterError) -> FilterNode {
        guard let tok = peek() else { throw missingTerm(prev) }
        if tok.kind == .not {
            take()
            try enter(tok)
            let item = try parseNot(tok)
            depth -= 1
            return .not(item)
        }
        if tok.kind == .lparen {
            take()
            try enter(tok)
            let inner = try parseOr(tok)
            guard let close = peek() else { throw FilterError(#"Missing ")" at end of query"#, end) }
            if close.kind != .rparen {
                throw FilterError(#"Expected "&", "|" or ")" before "\#(close.raw)" at position \#(close.pos + 1)"#, close.pos)
            }
            take()
            depth -= 1
            return inner
        }
        return try parseTerm(prev)
    }

    mutating func parseTerm(_ prev: Token?) throws(FilterError) -> FilterNode {
        let tok = peek()!
        switch tok.kind {
        case .label: take(); return .label(tok.value)
        case .search: take(); return .search(tok.value)
        case .notes: take(); return .notes(tok.value)
        case .origin: take(); return .origin(tok.value)
        case .energy: take(); return .energy(tok.value)
        case .sector: take(); return .sector(tok.value)
        case .workspace: take(); return .unsupported("Workspaces")
        case .priority: take(); return .priority(Int(tok.value)!)
        case .project: take(); return .project(tok.value, descendants: tok.descendants)
        case .word: return try parseWordTerm(take())
        case .string:
            // A quoted name followed by a comparison is a custom field term.
            if peek(1)?.kind == .cmp {
                take()
                return try parseFieldTerm()
            }
            throw FilterError(##"Unexpected text \##(tok.raw) at position \##(tok.pos + 1); quote names after "@" or "#", or use search:"##,
                              tok.pos)
        default: throw missingTerm(prev)
        }
    }

    /// The comparison at the cursor, if there is one: <, <=, =, >=, >, before or after.
    func comparison() -> Comparison? {
        guard let tok = peek() else { return nil }
        if tok.kind == .cmp { return Comparison(rawValue: tok.value) }
        return ["before": .lt, "after": .gt][lower(tok)]
    }

    mutating func parseWordTerm(_ entry: Token) throws(FilterError) -> FilterNode {
        let w = entry.value.lowercased()
        // "completed" is the state keyword unless a comparison follows.
        if dateFields.contains(w) || (w == "completed" && comparison() != nil) {
            guard let op = comparison() else {
                throw FilterError(#"Expected a comparison (<, <=, =, >=, >, before or after) after "\#(entry.raw)" at position \#(entry.pos + 1)"#,
                                  entry.pos)
            }
            return .date(w, op, try parseDate(after: take()))
        }
        if w == "tracked" {
            guard let c = peek(), c.kind == .cmp else { return .keyword("tracked") }
            take()
            let v = peek()
            guard let v, v.kind == .word, durationMinutes(v.value) != nil else {
                let at = v?.kind == .word ? v!.pos : c.pos
                throw FilterError(#"Expected a duration such as 30m or 1h30 after "\#(c.raw)" at position \#(at + 1)"#, at)
            }
            take()
            return .unsupported("Tracked time")
        }
        if w == "no" {
            let next = peek()
            if noKeywords.contains(lower(next)) {
                take()
                return .keyword("no " + lower(next))
            }
            // Any other name is a custom field without a value.
            if let next, next.kind == .word || next.kind == .string {
                take()
                return .unsupported("Custom fields")
            }
            throw FilterError(#"Expected "date", "project", "labels", "time", "deadline", "start", "origin" or a field name after "no" at position \#(entry.pos + 1)"#,
                              entry.pos)
        }
        if simpleKeywords.contains(w) { return .keyword(w) }
        if w.wholeMatch(of: /p[0-9]+/) != nil {
            throw FilterError("Priority must be p1, p2, p3 or p4 at position \(entry.pos + 1)", entry.pos)
        }
        if peek()?.kind == .cmp { return try parseFieldTerm() }
        throw FilterError(#"Unknown term "\#(entry.raw)" at position \#(entry.pos + 1)"#, entry.pos)
    }

    /// A custom field compared with a value. Parsed for its errors; not evaluated yet.
    mutating func parseFieldTerm() throws(FilterError) -> FilterNode {
        let c = take()
        try parseFieldValue(after: c)
        return .unsupported("Custom fields")
    }

    /// A quoted text, true or false, a date, a number, or any other word as text.
    mutating func parseFieldValue(after: Token) throws(FilterError) {
        let tok = peek()
        if tok?.kind == .string {
            take()
            return
        }
        guard let tok, tok.kind == .word else {
            throw FilterError(#"Expected a value after "\#(after.raw)" at position \#(after.pos + 1)"#, after.pos)
        }
        let w = tok.value.lowercased()
        if w == "true" || w == "false" {
            take()
            return
        }
        let unit = isInteger(w) ? lower(peek(1)) : ""
        if dateStarts.contains(w) || weekdayWords.contains(w) || isISODate(w) || dateUnits.contains(unit) {
            _ = try parseDate(after: after)
            return
        }
        take()
    }

    mutating func parseDate(after: Token) throws(FilterError) -> DateExpr {
        guard let tok = peek(), tok.kind == .word else {
            throw FilterError(#"Expected a date after "\#(after.raw)" at position \#(after.pos + 1)"#, after.pos)
        }
        let w = tok.value.lowercased()
        take()
        if let days = ["today": 0, "tomorrow": 1, "yesterday": -1][w] { return .relative(days) }
        if let weekday = weekdayWords.firstIndex(of: w) { return .weekday(weekday) }
        if isISODate(w) {
            guard let day = Day(w) else { throw FilterError(#"Invalid date "\#(tok.raw)" at position \#(tok.pos + 1)"#, tok.pos) }
            return .iso(day)
        }
        if let offset = ["this": 0, "last": -1, "next": 1][w] {
            let unit = lower(peek())
            guard unit == "week" || unit == "month" else {
                throw FilterError(#"Expected "week" or "month" after "\#(tok.raw)" at position \#(tok.pos + 1)"#, tok.pos)
            }
            take()
            return .period(month: unit == "month", offset)
        }
        if isInteger(w) {
            // Far enough for any calendar; a longer number would overflow the arithmetic.
            let count = min(Int(w) ?? .max, 10_000_000)
            let unitTok = peek()
            let unit = lower(unitTok)
            if unit == "days" {
                take()
                if lower(peek()) == "ago" {
                    take()
                    return .relative(-count)
                }
                return .relative(count)
            }
            if ["week", "weeks", "month", "months"].contains(unit), let unitTok {
                take()
                guard lower(peek()) == "ago" else {
                    throw FilterError(#"Expected "ago" after "\#(unitTok.raw)" at position \#(unitTok.pos + 1)"#, unitTok.pos)
                }
                take()
                return .period(month: unit.hasPrefix("month"), -count)
            }
            throw FilterError(#"Expected "days", "weeks" or "months" after "\#(tok.raw)" at position \#(tok.pos + 1)"#, tok.pos)
        }
        throw FilterError(#"Invalid date "\#(tok.raw)" at position \#(tok.pos + 1)"#, tok.pos)
    }
}

// MARK: - Dates

private func monthStart(_ day: Day, _ months: Int) -> Day {
    let (y, m, _) = day.parts
    let index = y * 12 + m - 1 + months
    return Day(year: index / 12, month: mod(index, 12) + 1, day: 1)
}

/// The inclusive first and last days a date expression denotes. weekStart: 0 is Sunday.
func resolveRange(_ expr: DateExpr, today: Day, weekStart: Int = 1) -> (Day, Day) {
    switch expr {
    case .iso(let day): return (day, day)
    case .relative(let n): return (today + n, today + n)
    case .weekday(let wd):  // the next such day, today included
        let day = today + mod(wd - today.weekday % 7, 7)
        return (day, day)
    case .period(false, let offset):
        let start = today - mod(today.weekday % 7 - weekStart, 7) + 7 * offset
        return (start, start + 6)
    case .period(true, let offset):
        return (monthStart(today, offset), monthStart(today, offset + 1) - 1)
    }
}

/// A day against a range of days, as YYYY-MM-DD text. A one-day range is a plain comparison.
private func compareDays(_ day: String, _ op: Comparison, _ first: String, _ last: String) -> Bool {
    switch op {
    case .lt: day < first
    case .le: day <= last
    case .eq: first <= day && day <= last
    case .ge: day >= first
    case .gt: day > last
    }
}

/// The due's date in zone, as YYYY-MM-DD.
func dueDay(_ due: JSON, in zone: TimeZone) -> String? {
    guard due.isTruthy, let wall = localDue(due, in: zone) else { return nil }
    return String(format: "%04d-%02d-%02d", wall.year, wall.month, wall.day)
}

// MARK: - Blocked tasks

/// Strongly connected components of a graph, iteratively (Kosaraju).
private func components(_ ids: [String], _ edges: (String) -> [String]) -> [[String]] {
    var order: [String] = [], seen = Set<String>()
    for root in ids where !seen.contains(root) {
        seen.insert(root)
        var stack: [(node: String, rest: [String], next: Int)] = [(root, edges(root), 0)]
        while let top = stack.indices.last {
            var found: String?
            while stack[top].next < stack[top].rest.count {
                let w = stack[top].rest[stack[top].next]
                stack[top].next += 1
                if !seen.contains(w) {
                    found = w
                    break
                }
            }
            if let found {
                seen.insert(found)
                stack.append((found, edges(found), 0))
            } else {
                order.append(stack.removeLast().node)
            }
        }
    }
    var reverse: [String: [String]] = [:]
    for node in ids {
        for w in edges(node) { reverse[w, default: []].append(node) }
    }
    var result: [[String]] = [], assigned = Set<String>()
    for root in order.reversed() where !assigned.contains(root) {
        assigned.insert(root)
        var component: [String] = [], stack = [root]
        while let node = stack.popLast() {
            component.append(node)
            for w in reverse[node] ?? [] where !assigned.contains(w) {
                assigned.insert(w)
                stack.append(w)
            }
        }
        result.append(component)
    }
    return result
}

/// Open tasks waiting for a live, open task. In each cycle, the member whose blocked_by has the newest clock
/// stops blocking, the same on every device (web/src/lib/dependencies.ts).
func blockedIds(_ tasks: [Row]) -> Set<String> {
    struct Edge: Hashable { let from, to: String }
    var byId: [String: Row] = [:]
    for task in tasks { byId[task.id] = task }
    func blockers(_ task: Row) -> [String] { task["blocked_by"].array?.compactMap(\.string) ?? [] }
    func newer(_ a: Row, _ b: Row) -> Bool {
        let ca = a.clocks["blocked_by"] ?? FieldClock(ts: 0, device: "")
        let cb = b.clocks["blocked_by"] ?? FieldClock(ts: 0, device: "")
        if ca.ts != cb.ts { return ca.ts > cb.ts }
        if ca.device != cb.device { return bytesLess(cb.device, ca.device) }
        return bytesLess(b.id, a.id)
    }
    var broken = Set<Edge>()
    func edges(_ id: String) -> [String] {
        blockers(byId[id]!).filter { byId[$0] != nil && !broken.contains(Edge(from: id, to: $0)) }
    }
    let ids = byId.keys.sorted(by: bytesLess)
    while case let cycles = components(ids, edges).filter({ $0.count > 1 }), !cycles.isEmpty {
        for cycle in cycles {
            let members = Set(cycle)
            var loser = byId[cycle[0]]!
            for id in cycle.dropFirst() where newer(byId[id]!, loser) { loser = byId[id]! }
            for b in edges(loser.id) where members.contains(b) { broken.insert(Edge(from: loser.id, to: b)) }
        }
    }
    func isOpen(_ task: Row?) -> Bool { task.map { $0["deleted_at"].isNull && $0["completed_at"].isNull } ?? false }
    return Set(tasks.filter { t in
        isOpen(t) && blockers(t).contains { isOpen(byId[$0]) && !broken.contains(Edge(from: t.id, to: $0)) }
    }.map(\.id))
}

// MARK: - Evaluation

public struct FilterContext {
    /// The logical today.
    public var today: Day
    /// Every task, for "blocked".
    public var tasks: [Row]
    /// Live labels and projects.
    public var labels: [Row]
    public var projects: [Row]
    /// 0 is Sunday.
    public var weekStart = 1
    /// Minutes after midnight a day begins.
    public var dayStart = 0
    public var zone = TimeZone.current

    public init(today: Day, tasks: [Row], labels: [Row], projects: [Row], weekStart: Int = 1, dayStart: Int = 0,
                zone: TimeZone = .current) {
        (self.today, self.tasks, self.labels, self.projects) = (today, tasks, labels, projects)
        (self.weekStart, self.dayStart, self.zone) = (weekStart, dayStart, zone)
    }
}

public typealias TaskTest = (Row) -> Bool

/// True when the query says "completed" or "open", or compares the completion date.
func mentionsState(_ node: FilterNode) -> Bool {
    switch node {
    case .or(let nodes), .and(let nodes): nodes.contains(where: mentionsState)
    case .not(let inner): mentionsState(inner)
    case .keyword(let word): word == "completed" || word == "open"
    case .date(let field, _, _): field == "completed"
    default: false
    }
}

/// The query with completed matches shown too, unless it already names a state.
func withCompleted(_ ast: FilterNode) -> FilterNode {
    mentionsState(ast) ? ast : .and([ast, .or([.keyword("open"), .keyword("completed")])])
}

private func text(_ value: JSON) -> String { value.string ?? "" }
private func nameKey(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

private func origin(of task: Row) -> JSON? {
    let origin = task["origin"]
    // Not `nil`: JSON takes a nil literal itself.
    return origin["kind"].string != nil ? origin : .none
}

private func energy(of task: Row) -> String? { task["energy"].string.flatMap { energies.contains($0) ? $0 : nil } }

private func dayPart(of task: Row) -> String? {
    if task["evening"].isTruthy { return "evening" }
    return task["day_part"].string.flatMap { $0 == "morning" || $0 == "afternoon" ? $0 : nil }
}

/// A test over tasks, and warnings. Unknown names and unsupported terms match nothing and warn.
public func compileFilter(_ ast: FilterNode, _ ctx: FilterContext) -> (test: TaskTest, warnings: [String]) {
    var warnings: [String] = []
    func warn(_ message: String) { if !warnings.contains(message) { warnings.append(message) } }

    var byName: [String: Set<String>] = [:]
    for (kind, rows) in [("label", ctx.labels), ("project", ctx.projects)] {
        for row in rows { byName["\(kind):\(nameKey(text(row["name"])))", default: []].insert(row.id) }
    }
    var children: [String?: [String]] = [:]
    for project in ctx.projects { children[project["parent_id"].string, default: []].append(project.id) }
    let today = ctx.today.description, tomorrow = (ctx.today + 1).description
    let zone = ctx.zone
    var blocked: Set<String>?

    func subprojects(_ ids: Set<String>) -> Set<String> {
        var found = ids, stack = Array(ids)
        while let next = stack.popLast() {
            for child in children[next] ?? [] where found.insert(child).inserted { stack.append(child) }
        }
        return found
    }

    /// The first instant of a logical day, as Unix ms.
    func startOfDay(_ day: Day) -> Double {
        let (y, m, d) = day.parts
        let wall = WallTime(year: y, month: m, day: d, hour: ctx.dayStart / 60, minute: ctx.dayStart % 60)
        return Double(zonedInstant(wall, in: zone))
    }

    func instant(_ name: String, _ op: Comparison, _ first: Day, _ last: Day) -> TaskTest {
        let start = startOfDay(first), next = startOfDay(last + 1)
        return { t in
            guard let ms = t[name].number else { return false }
            return switch op {
            case .lt: ms < start
            case .le: ms < next
            case .eq: start <= ms && ms < next
            case .ge: ms >= start
            case .gt: ms >= next
            }
        }
    }

    func keyword(_ word: String) -> TaskTest {
        let due = { (t: Row) in dueDay(t["due"], in: zone) }
        let start = { (t: Row) in t["start"].string.flatMap { $0.isEmpty ? nil : $0 } }
        switch word {
        case "blocked", "unblocked":
            if blocked == nil { blocked = blockedIds(ctx.tasks) }
            let ids = blocked!
            return word == "blocked" ? { ids.contains($0.id) } : { !ids.contains($0.id) }
        case "available", "tracked":
            warn("“\(word)” isn't supported on this device yet")
            return { _ in false }
        case "overdue": return { t in due(t).map { $0 < today } ?? false }
        case "today": return { due($0) == today }
        case "tomorrow": return { due($0) == tomorrow }
        case "no date": return { !$0["due"].isTruthy }
        case "no time": return { $0["due"].isTruthy && !$0["due"]["time"].isTruthy }
        case "no project": return { $0["project_id"].isNull }
        case "no labels": return { !$0["labels"].isTruthy }
        case "no deadline": return { !$0["deadline"].isTruthy }
        case "no start": return { start($0) == nil }
        case "someday": return { start($0) == "someday" }
        case "deferred": return { t in start(t).map { $0 != "someday" && $0 > today } ?? false }
        case "evening": return { $0["evening"].isTruthy }
        case "morning": return { dayPart(of: $0) == "morning" }
        case "afternoon": return { dayPart(of: $0) == "afternoon" }
        // A habit's skipped day isn't a completion.
        case "completed": return { !$0["completed_at"].isNull && !$0["skipped"].isTruthy }
        case "open": return { $0["completed_at"].isNull }
        case "subtask": return { !$0["parent_id"].isNull }
        case "habit": return { $0["habit"] == true }
        case "origin": return { origin(of: $0) != nil }
        case "no origin": return { origin(of: $0) == nil }
        case "energy": return { energy(of: $0) != nil }
        case "no energy": return { energy(of: $0) == nil }
        case "sector": return { Period($0["sector"].string) != nil }
        case "no sector": return { Period($0["sector"].string) == nil }
        case "carried": return { isCarried($0["sector"].string, today: ctx.today, weekStart: ctx.weekStart) }
        // A note of only blank space is no note.
        case "notes": return { !text($0["description"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case "no notes": return { text($0["description"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        default: return { _ in false }
        }
    }

    func build(_ node: FilterNode) -> TaskTest {
        switch node {
        case .or(let nodes):
            let tests = nodes.map(build)
            return { t in tests.contains { $0(t) } }
        case .and(let nodes):
            let tests = nodes.map(build)
            return { t in tests.allSatisfy { $0(t) } }
        case .not(let inner):
            let test = build(inner)
            return { !test($0) }
        case .label(let name):
            // Several labels may share a name: any of them matches.
            guard let ids = byName["label:\(nameKey(name))"] else {
                warn(#"No label named "\#(name)""#)
                return { _ in false }
            }
            return { t in t["labels"].array?.contains { $0.string.map(ids.contains) ?? false } ?? false }
        case .project(let name, let descendants):
            guard let named = byName["project:\(nameKey(name))"] else {
                warn(#"No project named "\#(name)""#)
                return { _ in false }
            }
            let ids = descendants ? subprojects(named) : named
            return { t in t["project_id"].string.map(ids.contains) ?? false }
        case .priority(let p):
            return { $0["priority"].int == Int64(p) }
        case .date(let field, let op, let expr):
            let (first, last) = resolveRange(expr, today: ctx.today, weekStart: ctx.weekStart)
            if field == "created" || field == "completed" { return instant("\(field)_at", op, first, last) }
            let (a, b) = (first.description, last.description)
            switch field {
            case "due": return { t in dueDay(t["due"], in: zone).map { compareDays($0, op, a, b) } ?? false }
            case "start":
                return { t in t["start"].string.map { !$0.isEmpty && $0 != "someday" && compareDays($0, op, a, b) } ?? false }
            default:
                return { t in t["deadline"].string.map { !$0.isEmpty && compareDays($0, op, a, b) } ?? false }
            }
        case .search(let needle):
            let needle = needle.lowercased()
            return { t in text(t["title"]).lowercased().contains(needle) || text(t["description"]).lowercased().contains(needle) }
        case .notes(let needle):  // the note only, never the title
            let needle = needle.lowercased()
            return { text($0["description"]).lowercased().contains(needle) }
        case .sector(let value):  // a relative word is the viewer's period on this evaluation's day
            let want = resolveSector(value, today: ctx.today, weekStart: ctx.weekStart) ?? value
            return { $0["sector"].string == want }
        case .origin(let value):
            let want = value.lowercased()
            return { t in
                guard let origin = origin(of: t) else { return false }
                return text(origin["provider"].isNull ? origin["kind"] : origin["provider"]).lowercased() == want
            }
        case .energy(let value):
            return { energy(of: $0) == value }
        case .keyword(let word):
            return keyword(word)
        case .unsupported(let what):
            warn("\(what) isn't supported on this device yet")
            return { _ in false }
        }
    }

    let test = build(ast)
    if !mentionsState(ast) {
        return ({ $0["deleted_at"].isNull && $0["completed_at"].isNull && test($0) }, warnings)
    }
    // A habit's skipped day matches no query.
    return ({ $0["deleted_at"].isNull && !$0["skipped"].isTruthy && test($0) }, warnings)
}

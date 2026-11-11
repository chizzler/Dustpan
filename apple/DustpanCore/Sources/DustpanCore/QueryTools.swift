import Foundation

// Help writing a filter query: suggestions for the word being typed, and the builder's conditions.
// A port of querytools.py. The terms are written as OpenTodo's web builder writes them
// (web/src/lib/filter/builder.ts), so a view made here reads the same there. See spec/views.md, "The Filter page".

let maxSuggestions = 8

/// Words the parser knows, offered as a bare word is typed, with what they mean.
let queryKeywords: [(word: String, hint: String)] = [
    ("today", "due today or earlier"), ("tomorrow", "due tomorrow"), ("overdue", "past its due date"),
    ("open", "not completed"), ("completed", "completed"), ("subtask", "under another task"),
    ("someday", "parked for later"), ("deferred", "starts later"), ("blocked", "waiting for an open task"),
    ("unblocked", "not waiting for a task"), ("habit", "a repeating habit"),
    ("no date", "no due date"), ("no deadline", "no deadline"), ("no labels", "no label at all"),
    ("no project", "in the Inbox"), ("no time", "due on a day, at no set time"),
    ("due", "compare the due date: due <= 7 days"), ("deadline", "compare the deadline: deadline < friday"),
    ("created", "compare when it was added: created >= 7 days ago"),
    ("search:", "words in the title or notes"), ("notes:", "words in the notes"),
    ("notes", "has notes"), ("no notes", "no notes"),
    ("sector", "planned for a week, month or quarter"), ("no sector", "no time sector"),
    ("carried", "its sector's period has ended"), ("sector:", "this week, next month, 2026-W45"),
    ("p1", "priority 1"), ("p2", "priority 2"), ("p3", "priority 3"), ("p4", "no priority"),
]

/// A word to complete the query with: what's shown, what it means, and the query with it completed.
public struct QuerySuggestion: Hashable, Sendable {
    public let shown: String
    public let hint: String
    public let completed: String
}

/// A group of the builder's conditions, such as When or Label.
public struct QueryConditionGroup: Identifiable, Sendable {
    public let title: String
    public let items: [(label: String, term: String)]
    public var id: String { title }
}

/// A label or project name as the parser reads it: bare unless it holds a break character or starts with #.
public func quoteName(_ name: String) -> String {
    guard name.isEmpty || name.hasPrefix("#") || name.contains(/[\s"&|!()<>=]/) else { return name }
    return "\"" + name.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
}

public func labelTerm(_ name: String) -> String { "@" + quoteName(name) }

public func projectTerm(_ name: String, withSubprojects: Bool = false) -> String {
    (withSubprojects ? "##" : "#") + quoteName(name)
}

/// What to offer for the word at the end of query: after @ the labels, after # or ## the projects,
/// otherwise the keywords. A name typed in full isn't offered.
public func suggest(_ query: String, labels: [String], projects: [String]) -> [QuerySuggestion] {
    if let named = query.firstMatch(of: /(^|[\s(!&|])(@|##|#)("?)([^"&|()!<>=]*)$/) {
        let (_, _, sigil, quoted, typed) = named.output
        // A space ends a bare name: the word being typed is something else.
        if !quoted.isEmpty || !typed.contains(where: \.isWhitespace) {
            let isLabel = sigil == "@"
            let head = query[..<sigil.startIndex]
            let prefix = foldName(String(typed))
            // Typed in full is not offered; typed without its accents is, as the parser wants them.
            let found = (isLabel ? labels : projects).filter {
                foldName($0).hasPrefix(prefix) && $0.lowercased() != typed.lowercased()
            }
            return found.prefix(maxSuggestions).map {
                QuerySuggestion(shown: sigil + $0, hint: isLabel ? "label" : "project",
                                completed: String(head) + String(sigil) + quoteName($0) + " ")
            }
        }
        return []
    }
    guard let word = query.firstMatch(of: /(^|[\s(!&|])([A-Za-z:]+)$/) else { return [] }
    let typed = word.output.2.lowercased()
    let head = query[..<word.output.2.startIndex]
    return queryKeywords.filter { $0.word.hasPrefix(typed) && $0.word != typed }.prefix(maxSuggestions).map {
        QuerySuggestion(shown: $0.word, hint: $0.hint, completed: String(head) + $0.word + " ")
    }
}

/// query with term joined on by &. A query whose top level is an | keeps its meaning in brackets.
public func addCondition(_ query: String, _ term: String, negate: Bool = false) -> String {
    let term = !negate ? term : term.contains(" ") ? "!(\(term))" : "!" + term
    var query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty { return term }
    if case .or = try? parseFilter(query) { query = "(\(query))" }
    return "\(query) & \(term)"
}

/// The builder's menu. Every term parses.
public func queryConditions(labels: [String], projects: [String]) -> [QueryConditionGroup] {
    [
        QueryConditionGroup(title: "When", items: [
            ("Due today or earlier", "today"), ("Due tomorrow", "tomorrow"), ("Overdue", "overdue"),
            ("Due in the next 7 days", "due <= 7 days"), ("Due this week", "due <= this week"),
            ("No due date", "no date"), ("Deadline in the next 7 days", "deadline <= 7 days"),
            ("Added in the last 7 days", "created >= 7 days ago"),
            ("Completed in the last 7 days", "completed >= 7 days ago"),
        ]),
        QueryConditionGroup(title: "Priority", items: [
            ("Priority 1", "p1"), ("Priority 2", "p2"), ("Priority 3", "p3"), ("No priority", "p4"),
        ]),
        QueryConditionGroup(title: "State", items: [
            ("Open", "open"), ("Completed", "completed"), ("A subtask", "subtask"), ("Blocked", "blocked"),
            ("Someday", "someday"), ("Starts later", "deferred"), ("A habit", "habit"),
        ]),
        QueryConditionGroup(title: "Time sector", items: [
            ("This week", "sector: this week"), ("Next week", "sector: next week"),
            ("This month", "sector: this month"), ("Next month", "sector: next month"),
            ("Carried over", "carried"), ("Any sector", "sector"), ("No sector", "no sector"),
        ]),
        QueryConditionGroup(title: "Notes", items: [("Has notes", "notes"), ("No notes", "no notes")]),
        QueryConditionGroup(title: "Label", items: labels.map { ($0, labelTerm($0)) } + [("No labels", "no labels")]),
        QueryConditionGroup(title: "Project", items: projects.map { ($0, projectTerm($0)) }
            + projects.map { ($0 + " and its sub-projects", projectTerm($0, withSubprojects: true)) }
            + [("No project (Inbox)", "no project")]),
    ]
}

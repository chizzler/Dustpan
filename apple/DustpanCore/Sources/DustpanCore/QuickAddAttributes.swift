import Foundation

// Single-token attributes: #project, @label, p1, ~energy, +30m, 30m/2h.
// A port of quickadd/attributes.py (internal/quickadd/attributes.go).

/// A project as quick add sees it.
public struct QuickAddProject: Sendable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var archived = false
    public var deleted = false

    public init(id: String, name: String, parentId: String? = nil, archived: Bool = false, deleted: Bool = false) {
        (self.id, self.name, self.parentId, self.archived, self.deleted) = (id, name, parentId, archived, deleted)
    }
}

private func foldProjectName(_ name: String) -> String { normalizeWord(name).replacing(/[\s_-]+/, with: "") }

private func trimToken(_ token: String) -> String {
    var s = Substring(token)
    while let last = s.last, last == "," || last == ";" { s.removeLast() }
    return String(s)
}

/// The shallowest project, then the smallest id.
private func byDepth(_ found: [QuickAddProject], _ projects: [QuickAddProject]) -> QuickAddProject? {
    let byId = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func depth(_ p: QuickAddProject) -> Int {
        var (n, p, seen) = (0, p, Set([p.id]))
        while let parent = p.parentId.flatMap({ byId[$0] }), seen.insert(parent.id).inserted { (n, p) = (n + 1, parent) }
        return n
    }
    return found.min { a, b in depth(a) != depth(b) ? depth(a) < depth(b) : bytesLess(a.id, b.id) }
}

/// #Name: an exact folded name (the shallowest wins), else the only prefix. #Parent/Child: an exact path.
func matchProject(_ token: String, _ projects: [QuickAddProject]) -> QuickAddProject? {
    guard token.hasPrefix("#"), token.count >= 2 else { return nil }
    let live = projects.filter { !$0.archived && !$0.deleted }
    let body = token.dropFirst()
    if body.contains("/") {
        let parts = body.split(separator: "/", omittingEmptySubsequences: false).map { foldProjectName(String($0)) }
        guard !parts.contains(""), parts.count >= 2 else { return nil }
        let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func fits(_ project: QuickAddProject) -> Bool {
            var p: QuickAddProject? = project
            for i in parts.indices.reversed() {
                guard let here = p, foldProjectName(here.name) == parts[i] else { return false }
                p = i > 0 ? here.parentId.flatMap { byId[$0] } : here
            }
            return true
        }
        return byDepth(live.filter(fits), live)
    }
    let want = foldProjectName(String(body))
    guard !want.isEmpty else { return nil }
    let exact = live.filter { foldProjectName($0.name) == want }
    if !exact.isEmpty { return byDepth(exact, live) }
    let prefix = live.filter { foldProjectName($0.name).hasPrefix(want) }
    return prefix.count == 1 ? prefix[0] : nil
}

func matchLabel(_ token: String) -> String? {
    guard token.hasPrefix("@"), token.count >= 2 else { return nil }
    let name = trimToken(String(token.dropFirst()))
    return !name.isEmpty && !name.contains(where: { " \t\n".contains($0) }) ? name : nil
}

func matchPriority(_ token: String) -> Int {
    trimToken(token).wholeMatch(of: /[pP]([1-4])/).flatMap { Int($0.1) } ?? 0
}

/// ~deep, ~medium, ~low or any prefix of them, any case. "" otherwise, so ~6 stays text.
func matchEnergy(_ token: String) -> String {
    guard let m = trimToken(token).wholeMatch(of: /~([A-Za-z]+)/) else { return "" }
    let word = m.1.lowercased()
    return ["deep", "medium", "low"].first { $0.hasPrefix(word) } ?? ""
}

let maxQuickEstimate = 10080

private var hoursPattern: Regex<(Substring, Substring, Substring?)> { /([0-9]+(?:[.,][0-9]+)?)h(?:([0-9]{1,2})(?:m|min)?)?/ }
private var minutesPattern: Regex<(Substring, Substring, Substring)> { /([0-9]+)(m|min|mins|minutes)/ }

/// Minutes from an hours match, or nil when the minutes are over 59. Half up, like Go and JS.
private func hoursMinutes(_ hours: Substring, _ minutes: Substring?) -> Int? {
    let mins = minutes.flatMap { Int($0) } ?? 0
    guard mins <= 59, let h = Double(hours.replacing(",", with: ".", maxReplacements: 1)) else { return nil }
    return Int((h * 60 + Double(mins) + 0.5).rounded(.down))
}

/// An estimate: +30, +30m, +2h, +1h30, 45min, 2h. 0 when it isn't one.
func matchDuration(_ token: String, bareHourIsTime: Bool) -> Int {
    let text = trimToken(token).lowercased()
    let plus = text.hasPrefix("+")
    let body = plus ? String(text.dropFirst()) : text
    guard !body.isEmpty else { return 0 }
    var minutes = -1
    if let m = body.wholeMatch(of: hoursPattern) {
        if !plus && (bareHourIsTime || m.2 != nil) { return 0 }
        guard let found = hoursMinutes(m.1, m.2) else { return 0 }
        minutes = found
    } else if let m = body.wholeMatch(of: minutesPattern) {
        if !plus && m.2 == "m" { return 0 }
        minutes = Int(m.1) ?? -1
    } else if plus, body.wholeMatch(of: /[0-9]+/) != nil {
        minutes = Int(body) ?? -1
    }
    return (1...maxQuickEstimate).contains(minutes) ? minutes : 0
}

private func spentPart(_ text: Substring) -> Int {
    var value: Int?
    if let m = text.wholeMatch(of: hoursPattern) {
        value = hoursMinutes(m.1, m.2)
    } else if let m = text.wholeMatch(of: minutesPattern) {
        value = Int(m.1)
    }
    return value.flatMap { (1...maxQuickEstimate).contains($0) ? $0 : nil } ?? 0
}

/// 30m/2h: (30 minutes spent, a two-hour estimate), or nil. A date such as 30/12 never matches.
func matchSpent(_ token: String) -> (spent: Int, estimate: Int)? {
    let part = /([0-9]+(?:[.,][0-9]+)?h(?:[0-9]{1,2}(?:m|min)?)?|[0-9]+(?:m|min|mins|minutes))/
    let parts = trimToken(token).lowercased().split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: part) != nil }) else { return nil }
    let (spent, estimate) = (spentPart(parts[0]), spentPart(parts[1]))
    return spent > 0 && estimate > 0 ? (spent, estimate) : nil
}

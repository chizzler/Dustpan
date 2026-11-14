import Foundation

// Project icons: all of Lucide 1.48.0. A port of icons/__init__.py. See spec/icons.md.
//
// Resources/icons holds the desktop's files, copied unchanged: paths.json and lucide.json (built by the desktop's
// sync.py), OpenTodo's catalogue.json (the 411 icons its server and web app know) and Lucide's licence (ISC).
// A test checks they match the desktop's copies.

/// One icon the picker can show.
public struct IconEntry: Sendable, Hashable {
    /// The name written. OpenTodo's icons keep OpenTodo's name, which for eight is Lucide's old one (`trash-2`).
    public let name: String
    /// The picker's group (`IconGroup.id`).
    public let category: String
    /// OpenTodo's REST, MCP and web app know it.
    public let server: Bool
    /// OpenTodo's keywords, then Lucide's tags, lowercased.
    public let keywords: [String]
    /// What a query can match as the category: the group, its label, Lucide's categories.
    let categories: [String]
}

/// One of the picker's categories.
public struct IconGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    /// Lucide's categories it takes in.
    let lucide: Set<String>
    /// The icon beside its label.
    public let symbol: String
}

public enum Icons {
    /// Labels draw as a tag, so the picker doesn't offer it to projects. One stored by another client still draws.
    public static let labelMark = "tag"

    /// The picker's categories, in order. OpenTodo's 411 icons keep OpenTodo's categories (`fromOpenTodo`): they're
    /// chosen with care. Lucide files the rest in 42 categories, most icons in several, not always well. Each goes to
    /// the first group in `priority` it belongs to, the most specific first. Lucide keeps its people icons in its
    /// broad "account" category, so an account icon named for a user goes to People.
    public static let groups: [IconGroup] = [
        ("work", "Work", [], "briefcase"),
        ("home", "Home", ["home", "buildings"], "house"),
        ("people", "People", ["people", "emoji"], "user"),
        ("learning", "Learning", [], "graduation-cap"),
        ("food", "Food and drink", ["food-beverage"], "utensils"),
        ("travel", "Travel", ["travel"], "plane"),
        ("transport", "Transport", ["transportation"], "car"),
        ("nature", "Nature", ["nature", "sustainability"], "leaf"),
        ("animals", "Animals", ["animals"], "paw-print"),
        ("weather", "Weather", ["weather", "seasons"], "cloud-sun"),
        ("health", "Health", ["medical", "accessibility"], "heart-pulse"),
        ("leisure", "Leisure and sport", ["sports", "gaming"], "trophy"),
        ("money", "Money", ["finance"], "wallet"),
        ("shopping", "Shopping", ["shopping"], "shopping-cart"),
        ("tools", "Tools", ["tools"], "wrench"),
        ("science", "Science", ["science"], "flask-conical"),
        ("time", "Time", ["time"], "clock"),
        ("communication", "Communication", ["communication", "mail", "notifications", "social"], "message-circle"),
        ("media", "Media", ["multimedia", "photography"], "camera"),
        ("devices", "Devices", ["devices", "connectivity"], "laptop"),
        ("files", "Files", ["files"], "file"),
        ("security", "Security", ["security"], "lock"),
        ("charts", "Charts and maths", ["charts", "math"], "chart-column"),
        ("design", "Design", ["design"], "palette"),
        ("shapes", "Shapes and symbols", ["shapes"], "shapes"),
        ("text", "Text", ["text"], "type"),
        ("layout", "Layout", ["layout"], "layout-grid"),
        ("development", "Development", ["development"], "code"),
        ("account", "Accounts and settings", ["account"], "settings"),
        ("arrows", "Arrows and navigation", ["arrows", "navigation", "cursors"], "arrow-right"),
    ].map { IconGroup(id: $0.0, label: $0.1, lucide: Set($0.2), symbol: $0.3) }

    static let priority = ["animals", "food", "weather", "nature", "transport", "travel", "home", "shopping", "money",
                           "health", "leisure", "science", "time", "tools", "security", "people", "media",
                           "communication", "devices", "files", "charts", "shapes", "design", "text", "layout",
                           "development", "account", "arrows"]
    static let fromOpenTodo = ["work": "work", "home": "home", "people": "people", "travel": "travel",
                               "food": "food", "health": "health", "money": "money", "learning": "learning",
                               "nature": "nature", "animals": "animals", "tools": "tools", "tech": "devices",
                               "time": "time", "communication": "communication", "symbols": "shapes",
                               "leisure": "leisure"]

    private static func load(_ name: String) -> JSON { JSON(any: loadAny(name)) }

    private static func loadAny(_ name: String) -> Any {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "icons"),
              let data = try? Data(contentsOf: url), let any = try? JSONSerialization.jsonObject(with: data)
        else { fatalError("Missing icons/\(name).json in DustpanCore's resources") }
        return any
    }

    // Drawing needs only each icon's SVG body and Lucide's renames. The picker's tags and catalogue load when it
    // opens, and only the entries built from them stay.
    // Read straight from JSONSerialization: a JSON tree of the whole file would only be thrown away.
    private static let paths = loadAny("paths") as? [String: String] ?? [:]
    private static let aliases = (loadAny("lucide") as? [String: Any])?["aliases"] as? [String: String] ?? [:]

    /// Lucide's version, as sync.py wrote it.
    public static var version: String { load("lucide")["version"].string ?? "" }
    /// The names OpenTodo's REST, MCP and web app know.
    public static let server = Set((load("catalogue").array ?? []).compactMap { $0["name"].string })
    /// Every icon, in picker order: by group; in each, OpenTodo's first in its order, then the rest by name.
    public static let entries = makeEntries()
    /// What the picker shows: all but the labels' tag.
    public static let offered = entries.filter { $0.name != labelMark }
    /// Each group's offered icons, in order.
    public static let inGroup = Dictionary(grouping: offered, by: \.category).mapValues { $0.map(\.name) }
    /// Each icon's group, by name.
    public static let groupOf = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.category) })
    static let labels = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.label) })
    static let members = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.lucide) })

    /// The group for one of Lucide's icons outside OpenTodo's catalogue.
    static func group(of name: String, _ categories: Set<String>) -> String {
        let group = priority.first { id in !members[id, default: []].isDisjoint(with: categories) } ?? "arrows"
        return group == "account" && name.split(separator: "-").contains("user") ? "people" : group
    }

    private static func makeEntries() -> [IconEntry] {
        let catalogue = (load("catalogue").array ?? []).compactMap(\.object)
        let lucide = load("lucide")["icons"].object ?? [:]
        let old = Dictionary(uniqueKeysWithValues: server.compactMap { name in aliases[name].map { ($0, name) } })
        var words: [String: [String]] = [:], curated: [String: String] = [:], place: [String: Int] = [:]
        for (i, entry) in catalogue.enumerated() {
            guard let name = entry["name"]?.string else { continue }
            words[name] = (entry["keywords"]?.array ?? []).compactMap(\.string)
            curated[name] = entry["category"]?.string.flatMap { fromOpenTodo[$0] }
            place[name] = i
        }
        let order = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        let found = lucide.map { lucideName, info in
            let name = old[lucideName] ?? lucideName
            let lucideCategories = (info["categories"].array ?? []).compactMap(\.string)
            let group = curated[name] ?? self.group(of: lucideName, Set(lucideCategories))
            var seen = Set<String>()
            let keywords = ((words[name] ?? []) + (info["tags"].array ?? []).compactMap(\.string))
                .filter { seen.insert($0).inserted }.map { $0.lowercased() }
            return IconEntry(name: name, category: group, server: server.contains(name), keywords: keywords,
                             categories: [group, labels[group]!.lowercased()] + lucideCategories)
        }
        return found.sorted { a, b in
            let ka = (order[a.category]!, a.server ? 0 : 1, place[a.name] ?? 0)
            let kb = (order[b.category]!, b.server ? 0 : 1, place[b.name] ?? 0)
            return ka != kb ? ka < kb : a.name < b.name
        }
    }

    /// True for a name this client can draw. A newer client may have stored one it can't.
    public static func known(_ name: String?) -> Bool {
        guard let name else { return false }
        return paths[name] != nil || aliases[name] != nil
    }

    /// The icon's SVG body: its elements, without the `<svg>` around them.
    public static func body(_ name: String) -> String? {
        paths[aliases[name] ?? name]
    }

    /// An icon's readable name: "paw-print" is "paw print".
    public static func title(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: " ")
    }

    /// OpenTodo's match order: 0 exact name, 1 name prefix, 2 in the name, 3 keyword, 4 category; nil for none.
    public static func rank(_ entry: IconEntry, _ query: String) -> Int? {
        rank(entry, normalised: query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func rank(_ entry: IconEntry, normalised q: String) -> Int? {
        let name = entry.name
        if q.isEmpty || name == q { return 0 }
        if name.hasPrefix(q) { return 1 }
        if name.contains(q) { return 2 }
        if entry.keywords.contains(where: { $0.contains(q) }) { return 3 }
        if entry.categories.contains(where: { $0.contains(q) }) { return 4 }
        return nil
    }

    /// The offered icons matching query, best first; in a tie OpenTodo's first, then picker order.
    public static func search(_ query: String) -> [IconEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return offered.enumerated()
            .compactMap { i, entry in rank(entry, normalised: q).map { ($0, entry.server ? 0 : 1, i) } }
            .sorted { $0 < $1 }
            .map { offered[$0.2] }
    }

    /// For each offered icon: the words of its name, of its keywords, and its category texts.
    private static let wordSets = offered.map { entry in
        (Set(entry.name.split(separator: "-").map(String.init)), Set(entry.keywords.flatMap(asciiWords)),
         Set(entry.categories))
    }

    /// Runs of a-z and 0-9, as the desktop's `[a-z0-9]+` finds them.
    static func asciiWords(_ text: String) -> [String] {
        text.split { !("a"..."z").contains($0) && !("0"..."9").contains($0) }.map(String.init)
    }

    /// Icons for a project's name, best first. Whole words only, so "Car" doesn't offer the carrot.
    ///
    /// A word matches an icon's name (0), a word of its name (1), a keyword's word (2) or its category (3).
    /// A plural also tries its singular. In a tie, OpenTodo's icons come first: they're the everyday ones.
    public static func suggest(_ projectName: String, limit: Int = 8) -> [String] {
        var words = Set(asciiWords(projectName.lowercased()).filter { $0.count > 2 })
        words.formUnion(words.filter { $0.hasSuffix("s") && $0.count > 3 }.map { String($0.dropLast()) })
        guard !words.isEmpty else { return [] }
        let hits = zip(offered, wordSets).enumerated().compactMap { i, pair -> (Int, Int, Int)? in
            let (entry, (parts, keywords, category)) = pair
            let score = words.map { w in
                entry.name == w ? 0 : parts.contains(w) ? 1 : keywords.contains(w) ? 2 : category.contains(w) ? 3 : 4
            }.min()!
            return score < 4 ? (score, entry.server ? 0 : 1, i) : nil
        }
        return hits.sorted { $0 < $1 }.prefix(limit).map { offered[$0.2].name }
    }
}

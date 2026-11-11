import Foundation

// Labels without UI: finding them as you type, the picker's order, duplicates and the chips a row shows.
// A port of labels.py. See spec/labels.md. Writes are in Writes.swift.

/// Labels remembered as recently assigned on this device.
let maxRecentLabels = 8
/// A task row shows this many labels, then "+n".
public let rowChips = 2
/// Store meta: labels assigned lately on this device, newest first.
public let recentLabelsKey = "recent_labels"

/// The web app's label colours (web/src/ui/tokens/palette.ts). A new label takes the first one no label uses.
public let labelColours: [(hex: String, name: String)] = [
    ("#ef4444", "Red"), ("#f97316", "Orange"), ("#eab308", "Yellow"), ("#84cc16", "Lime"),
    ("#22c55e", "Green"), ("#14b8a6", "Teal"), ("#06b6d4", "Cyan"), ("#3b82f6", "Blue"),
    ("#6366f1", "Indigo"), ("#8b5cf6", "Violet"), ("#ec4899", "Pink"), ("#64748b", "Slate"),
]

/// The web app's eight project colours. A new project takes the first one no live project uses.
public let projectColours: [(hex: String, name: String)] = [
    ("#ef4444", "Red"), ("#f97316", "Orange"), ("#eab308", "Yellow"), ("#22c55e", "Green"),
    ("#14b8a6", "Teal"), ("#3b82f6", "Blue"), ("#8b5cf6", "Violet"), ("#ec4899", "Pink"),
]

/// For matching: no case, no accents.
func foldName(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Two labels with the same key have the same name, as far as the user can tell.
func labelKey(_ name: JSON) -> String {
    (name.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Ignoring case, then spaces, dashes and underscores too: how a typed name finds a label.
func labelKey(_ name: String, fold: Bool) -> String {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return fold ? key.filter { !$0.isWhitespace && $0 != "-" && $0 != "_" } : key
}

/// How well name matches a folded query: 0 best, nil for no match.
func matchRank(_ name: String, _ query: String) -> Int? {
    let name = foldName(name)
    if name.hasPrefix(query) { return 0 }
    let words = name.split { !($0.isLetter || $0.isNumber || $0 == "_") }
    if words.contains(where: { $0.hasPrefix(query) }) { return 1 }
    if name.contains(query) { return 2 }
    // The letters in order, with gaps.
    var letters = name.makeIterator()
    return query.allSatisfy { c in
        while let next = letters.next() { if next == c { return true } }
        return false
    } ? 3 : nil
}

/// The labels matching what's typed, best first. Ties keep the given order.
public func findLabels(_ labels: [Row], _ query: String) -> [Row] {
    let query = foldName(query)
    guard !query.isEmpty else { return labels }
    return labels.enumerated()
        .compactMap { i, label in matchRank(label["name"].string ?? "", query).map { ($0, i, label) } }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
}

/// Recently assigned on this device first, newest first, then the rest in sidebar order.
public func pickerOrder(_ labels: [Row], recent: [String]) -> [Row] {
    let byId = Dictionary(labels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen: Set<String> = []
    let first = recent.compactMap { id in seen.insert(id).inserted ? byId[id] : nil }
    let firstIds = Set(first.map(\.id))
    return first + labels.sorted(by: orderLess).filter { !firstIds.contains($0.id) }
}

/// The recent list after assigning labelIds.
public func rememberLabels(_ recent: [String], _ labelIds: [String]) -> [String] {
    var seen: Set<String> = []
    return Array((labelIds.reversed() + recent).filter { seen.insert($0).inserted }.prefix(maxRecentLabels))
}

/// The label named name, ignoring case, or nil. With duplicates, the first in sidebar order.
public func exactLabel(_ labels: [Row], _ name: String) -> Row? {
    let wanted = labelKey(.string(name))
    guard !wanted.isEmpty else { return nil }
    return labels.sorted(by: orderLess).first { labelKey($0["name"]) == wanted }
}

/// Ids of labels whose name another label shares.
public func duplicateLabels(_ labels: [Row]) -> Set<String> {
    let byKey = Dictionary(grouping: labels) { labelKey($0["name"]) }
    return Set(byKey.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
}

/// The labels a task shows, in its own order: known and live, once each. skip: the label page we're on.
public func shownLabels(_ ids: JSON, _ labelsById: [String: Row], skip: String? = nil) -> [Row] {
    var seen: Set<String> = []
    return (ids.array ?? []).compactMap(\.string).compactMap { id in
        guard id != skip, let label = labelsById[id], seen.insert(id).inserted else { return nil }
        return label
    }
}

/// Live tasks with the label: what deleting or merging it rewrites.
public func carrying(_ tasks: some Sequence<Row>, _ labelId: String) -> [Row] {
    tasks.filter { isLive($0) && labelIds($0).contains(labelId) }
}

/// A task's label ids, as stored.
func labelIds(_ task: Row) -> [String] { task["labels"].array?.compactMap(\.string) ?? [] }

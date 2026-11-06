import Foundation

// Manual order: the positions a move writes. A port of ordering.py (planMove in web/src/lib/ordering.ts).
// Lists sort by (position, id). A move usually writes one position, the midpoint between its new neighbours.
// When no distinct number fits there, the smallest window of neighbours around the gap is spread evenly
// with the moved item.

/// n increasing positions strictly between lower and upper (nil is open), or nil when they don't fit.
func spread(_ lower: Double?, _ upper: Double?, _ n: Int, anchor: Double) -> [Double]? {
    switch (lower, upper) {
    case (nil, nil): return (0..<n).map { anchor + Double($0) * positionGap }
    case (nil, let upper?): return (0..<n).map { upper - Double(n - $0) * positionGap }
    case (let lower?, nil): return (0..<n).map { lower + Double($0 + 1) * positionGap }
    case (let lower?, let upper?):
        guard upper > lower else { return nil }
        let step = (upper - lower) / Double(n + 1)
        // A window of several must leave room for about ten more bisections.
        if n > 1 && step < max(abs(lower), abs(upper), 1) * 0x1p-42 { return nil }
        var out: [Double] = [], previous = lower
        for i in 1...n {
            let p = lower + step * Double(i)
            guard previous < p, p < upper else { return nil }
            out.append(p)
            previous = p
        }
        return out
    }
}

/// The (id, position) writes that put movedId at index of its target list, the moved item first.
///
/// siblings: (id, position) pairs of the target list; the moved item may be among them.
/// index counts the list without the moved item. Empty when nothing moves.
func planOrder(_ siblings: [(id: String, position: Double)], moving movedId: String, to index: Int,
               fallback: Double) -> [(id: String, position: Double)] {
    let ordered = siblings.sorted { $0.position != $1.position ? $0.position < $1.position : bytesLess($0.id, $1.id) }
    let start = ordered.firstIndex { $0.id == movedId }
    let items = ordered.filter { $0.id != movedId }
    let k = max(0, min(items.count, index))
    if start == k { return [] }
    if items.isEmpty { return [(movedId, fallback)] }
    var (left, right) = (k, k - 1)  // items[left...right] is spread along with the moved item
    while true {
        let lower = left > 0 ? items[left - 1].position : nil
        let upper = right < items.count - 1 ? items[right + 1].position : nil
        if let points = spread(lower, upper, right - left + 2, anchor: items[0].position) {
            let window: [(id: String, position: Double?)] = items[left..<k].map { ($0.id, $0.position) }
                + [(movedId, nil)] + items[k..<(right + 1)].map { ($0.id, $0.position) }
            let changes = zip(window, points).filter { item, p in item.id == movedId || item.position != p }
                .map { item, p in (id: item.id, position: p) }
            return changes.filter { $0.id == movedId } + changes.filter { $0.id != movedId }
        }
        // Grow towards the side with fewer window items.
        if left > 0 && (right >= items.count - 1 || k - left <= right - k + 1) {
            left -= 1
        } else {
            right += 1
        }
    }
}

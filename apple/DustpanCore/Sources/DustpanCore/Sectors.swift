import Foundation

// Time sectors: a task planned for a week, month or quarter instead of a day.
// A part of web/src/lib/sectors.ts (v0.22.0): what the filter language needs. Checked against sectors.vectors.json.
// The stored value is absolute: "2026-W45", "2026-11" or "2026-Q4".

let sectorWords = ["this-week", "next-week", "this-month", "next-month", "this-quarter", "next-quarter"]

struct Period: Equatable, CustomStringConvertible {
    enum Kind: String { case week, month, quarter }
    var kind: Kind
    var year: Int
    /// The week (1–53), month (1–12) or quarter (1–4).
    var n: Int

    /// A stored sector, or nil when empty or invalid (years 2000–2999).
    init?(_ value: String?) {
        guard let value, let m = value.wholeMatch(of: /([0-9]{4})-(?:W([0-9]{2})|([0-9]{2})|Q([0-9]))/),
              let year = Int(m.1), (2000...2999).contains(year) else { return nil }
        let (kind, n, last): (Kind, Int?, Int) =
            if let w = m.2 { (.week, Int(w), isoWeeks(year)) }
            else if let mo = m.3 { (.month, Int(mo), 12) }
            else { (.quarter, m.4.flatMap { Int($0) }, 4) }
        guard let n, (1...last).contains(n) else { return nil }
        self.init(kind, year, n)
    }

    init(_ kind: Kind, _ year: Int, _ n: Int) { (self.kind, self.year, self.n) = (kind, year, n) }

    var description: String {
        switch kind {
        case .week: String(format: "%d-W%02d", year, n)
        case .month: String(format: "%d-%02d", year, n)
        case .quarter: "\(year)-Q\(n)"
        }
    }

    /// The period after this one, of the same kind.
    var next: Period {
        let last = switch kind { case .week: isoWeeks(year); case .month: 12; case .quarter: 4 }
        return n < last ? Period(kind, year, n + 1) : Period(kind, year + 1, 1)
    }
}

/// The ISO week-numbering year and week of a day.
func isoWeek(_ day: Day) -> (year: Int, week: Int) {
    let thursday = day + (4 - day.weekday)
    let year = thursday.parts.year
    return (year, (thursday - Day(year: year, month: 1, day: 1)) / 7 + 1)
}

/// 52 or 53: 28 December is always in a year's last ISO week.
func isoWeeks(_ year: Int) -> Int { isoWeek(Day(year: year, month: 12, day: 28)).week }

func mod(_ a: Int, _ n: Int) -> Int { (a % n + n) % n }

/// The viewer's periods by relative word. weekStart is 0 (Sunday) to 6.
///
/// This week is the ISO week holding the Monday inside the viewer's week.
func currentSectors(_ today: Day, weekStart: Int) -> [String: String] {
    let ws = mod(weekStart, 7)
    let start = today - mod(today.weekday % 7 - ws, 7)
    let monday = start + mod(1 - ws, 7)
    let iso = isoWeek(monday)
    let (y, m, _) = today.parts
    let week = Period(.week, iso.year, iso.week)
    let month = Period(.month, y, m)
    let quarter = Period(.quarter, y, (m - 1) / 3 + 1)
    return [
        "this-week": "\(week)", "next-week": "\(week.next)",
        "this-month": "\(month)", "next-month": "\(month.next)",
        "this-quarter": "\(quarter)", "next-quarter": "\(quarter.next)",
    ]
}

/// The sector a relative word ("this week", "next-month") means today, or nil.
func resolveSector(_ word: String, today: Day, weekStart: Int) -> String? {
    let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacing(/[\s_]+/, with: "-")
    return sectorWords.contains(key) ? currentSectors(today, weekStart: weekStart)[key] : nil
}

/// The period ended before the viewer's current period of its kind.
func isCarried(_ sector: String?, today: Day, weekStart: Int) -> Bool {
    guard let p = Period(sector),
          let now = Period(currentSectors(today, weekStart: weekStart)["this-\(p.kind.rawValue)"]) else { return false }
    return (p.year, p.n) < (now.year, now.n)
}

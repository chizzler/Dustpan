import DustpanCore

/// What the calendar shows: one day or a week on a time grid, or a month. Stored in meta calendar_view.
enum CalendarMode: String, CaseIterable, Identifiable {
    case day, week, month

    var id: Self { self }

    var title: String { rawValue.capitalized }

    /// Its key, as on the desktop: d, w or m.
    var key: Character { rawValue.first! }

    /// The day the view step lands on from anchor, by steps of its own length.
    func step(_ anchor: Day, by steps: Int) -> Day {
        switch self {
        case .day: anchor + steps
        case .week: anchor + 7 * steps
        case .month: addMonths(anchor, steps)
        }
    }
}

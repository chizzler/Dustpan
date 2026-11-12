/// The calendar's sizes, in points.
nonisolated enum CalendarMetrics {
    /// A task line in a Month day.
    static let lineHeight = 17.0
    /// A Month day's date and load, above its lines, with the cell's padding.
    static let headerHeight = 24.0
    /// An hour on Week and Day's grid, as the web app's 48 px.
    static let hourHeight = 48.0
    static let perMinute = hourHeight / 60
    /// The hour labels left of the grid.
    static let gutterWidth = 52.0
}

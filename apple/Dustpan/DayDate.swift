import DustpanCore
import Foundation

extension Day {
    /// The start of this day in the current calendar, for formatting.
    var date: Date {
        let (year, month, day) = parts
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }
}

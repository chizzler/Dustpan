import DustpanCore
import Foundation

extension Day {
    /// Noon on this day, here: a Date that names it in every nearby zone.
    var noon: Date {
        let (year, month, day) = parts
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }
}

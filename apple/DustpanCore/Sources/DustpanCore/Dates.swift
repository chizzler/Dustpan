import Foundation

/// A due date as a row shows it. See docs/sync.md, "Zoned due values".
public struct Due: Equatable, Sendable {
    public enum State: Sendable { case overdue, today, later }
    public let text: String
    public let state: State
}

/// Wall-clock date and time, without a zone.
struct WallTime: Equatable {
    var year, month, day: Int
    var hour, minute: Int?

    var dateComponents: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0)
    }
}

func parseDate(_ text: String) -> (Int, Int, Int)? {
    let parts = text.split(separator: "-")
    guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
          (1...12).contains(m), (1...31).contains(d) else { return nil }
    return (y, m, d)
}

/// "HH:MM" or "HH:MM:SS".
func parseTime(_ text: String) -> (Int, Int)? {
    let parts = text.split(separator: ":")
    guard (2...3).contains(parts.count), let h = Int(parts[0]), let m = Int(parts[1]),
          (0..<24).contains(h), (0..<60).contains(m) else { return nil }
    return (h, m)
}

func gregorian(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}

/// The due's date and time in zone. A zoned due converts; a floating one doesn't.
func localDue(_ due: JSON, in zone: TimeZone) -> WallTime? {
    guard let (y, m, d) = due["date"].string.flatMap(parseDate) else { return nil }
    guard let (h, min) = due["time"].string.flatMap(parseTime) else { return WallTime(year: y, month: m, day: d) }
    let wall = WallTime(year: y, month: m, day: d, hour: h, minute: min)
    guard let tzName = due["tz"].string, let dueZone = TimeZone(identifier: tzName),
          let moment = gregorian(dueZone).date(from: wall.dateComponents) else { return wall }
    let c = gregorian(zone).dateComponents([.year, .month, .day, .hour, .minute], from: moment)
    return WallTime(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!)
}

/// The user_prefs.time_format value: "12h", "24h", or "system" (the locale decides).
func uses12h(_ timeFormat: String, locale: Locale) -> Bool {
    if timeFormat == "12h" || timeFormat == "24h" { return timeFormat == "12h" }
    return DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false
}

func formatTime(hour: Int, minute: Int, twelveHour: Bool) -> String {
    guard twelveHour else { return String(format: "%02d:%02d", hour, minute) }
    let h = hour % 12 == 0 ? 12 : hour % 12
    let suffix = hour < 12 ? "am" : "pm"
    return minute == 0 ? "\(h)\(suffix)" : String(format: "%d:%02d%@", h, minute, suffix)
}

/// An estimate: "15 min", "2h", "1h 30m".
public func formatMinutes(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) min" }
    let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
}

/// "Today", "Tomorrow 16:30", "Wed", "15 Nov", "2 Jan 2027". Nil without a due.
public func formatDue(_ due: JSON, now: Date = Date(), timeFormat: String = "system",
                      zone: TimeZone = .current, locale: Locale = .current) -> Due? {
    guard let wall = localDue(due, in: zone) else { return nil }
    let calendar = gregorian(zone)
    let today = calendar.startOfDay(for: now)
    guard let day = calendar.date(from: DateComponents(year: wall.year, month: wall.month, day: wall.day)) else {
        return nil
    }
    let delta = calendar.dateComponents([.day], from: today, to: day).day!

    func format(_ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: day)
    }
    var text = switch delta {
    case 0: "Today"
    case 1: "Tomorrow"
    case -1: "Yesterday"
    case 2..<7: format("EEE")
    default: format("d MMM") + (wall.year != calendar.component(.year, from: now) ? " \(wall.year)" : "")
    }
    let overdue: Bool
    if let hour = wall.hour, let minute = wall.minute {
        text += " " + formatTime(hour: hour, minute: minute, twelveHour: uses12h(timeFormat, locale: locale))
        overdue = calendar.date(from: wall.dateComponents).map { $0 < now } ?? false
    } else {
        overdue = delta < 0
    }
    return Due(text: text, state: overdue ? .overdue : delta == 0 ? .today : .later)
}

/// Today's date as YYYY-MM-DD in zone.
public func isoToday(now: Date = Date(), zone: TimeZone = .current) -> String {
    let c = gregorian(zone).dateComponents([.year, .month, .day], from: now)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

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

/// Minutes from midnight on the user's clock (user_prefs.time_format): "08:30" or "8:30am".
public func clockText(_ minutes: Int, timeFormat: String = "system", locale: Locale = .current) -> String {
    formatTime(hour: minutes / 60, minute: minutes % 60, twelveHour: uses12h(timeFormat, locale: locale))
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

// MARK: - Instants

/// The time a date-only due counts as, for reminders.
let defaultReminderHour = 9

/// Unix ms of a wall time in zone. A gap moves forward to the transition; an overlap takes the first.
func zonedInstant(_ wall: WallTime, in zone: TimeZone) -> Int64 {
    let asUTC = Int64(gregorian(.gmt).date(from: wall.dateComponents)!.timeIntervalSince1970)
    func offset(at seconds: Int64) -> Int64 {
        Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds))))
    }
    let before = offset(at: asUTC - 86_400), after = offset(at: asUTC + 86_400)
    let fits = [asUTC - before, asUTC - after].filter { asUTC - offset(at: $0) == $0 }
    if let first = fits.min() { return first * 1000 }
    // In a gap: the transition lies between the two readings. Find it to the minute.
    var low = asUTC - before, high = asUTC - after
    if low > high { swap(&low, &high) }
    while high - low > 60 {
        let mid = (low + (high - low) / 2) / 60 * 60
        if offset(at: mid) == offset(at: low) { low = mid } else { high = mid }
    }
    return high * 1000
}

/// Unix ms a due denotes. Zoned: its wall time in its zone. Floating: local time, 09:00 without a time.
public func dueInstant(_ due: JSON, localZone: TimeZone = .current) -> Int64? {
    guard let (y, m, d) = due["date"].string.flatMap(parseDate) else { return nil }
    let time = due["time"].string.flatMap(parseTime)
    let wall = WallTime(year: y, month: m, day: d, hour: time?.0 ?? defaultReminderHour, minute: time?.1 ?? 0)
    let zone = time != nil ? due["tz"].string.flatMap(TimeZone.init(identifier:)) ?? localZone : localZone
    return zonedInstant(wall, in: zone)
}

// MARK: - Editing

/// A due as the editor holds it: a moment, shown in the due's own zone.
///
/// A zoned due keeps its zone while its date or time changes. Clearing the time drops the zone.
public struct DueDraft: Equatable, Sendable {
    /// The day, and the time when hasTime, read in zone.
    public var date: Date
    public var hasTime: Bool
    /// The due's zone, or this device's for a floating due.
    public let zone: TimeZone
    let tz: String?

    /// A new due on date's day in this device's zone.
    public init(date: Date, hasTime: Bool = false, zone: TimeZone = .current) {
        (self.date, self.hasTime, self.zone, tz) = (date, hasTime, zone, nil)
    }

    /// The draft of a stored due. Nil when there's none.
    public init?(_ due: JSON, localZone: TimeZone = .current) {
        guard let (y, m, d) = due["date"].string.flatMap(parseDate) else { return nil }
        let time = due["time"].string.flatMap(parseTime)
        tz = time != nil ? due["tz"].string.flatMap { TimeZone(identifier: $0) == nil ? nil : $0 } : nil
        zone = tz.flatMap(TimeZone.init(identifier:)) ?? localZone
        hasTime = time != nil
        let wall = WallTime(year: y, month: m, day: d, hour: time?.0 ?? defaultReminderHour, minute: time?.1 ?? 0)
        guard let date = gregorian(zone).date(from: wall.dateComponents) else { return nil }
        self.date = date
    }

    /// The zone's name, when the due has one of its own.
    public var zoneName: String? { hasTime ? tz : nil }

    public var json: JSON {
        let c = gregorian(zone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var due: [String: JSON] = ["date": .string(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))]
        if hasTime {
            due["time"] = .string(String(format: "%02d:%02d", c.hour!, c.minute!))
            if let tz { due["tz"] = .string(tz) }
        }
        return .object(due)
    }
}

// MARK: - Days

/// user_prefs.day_start: "HH:MM" from 00:00 to 06:00. Anything else reads as midnight.
public func dayStartMinutes(_ value: JSON) -> Int {
    guard let text = value.string, text.count == 5, text.dropFirst(2).first == ":",
          let (h, m) = parseTime(text), h * 60 + m <= 6 * 60 else { return 0 }
    return h * 60 + m
}

/// Today, where a day begins dayStart minutes after midnight.
func logicalToday(dayStart: Int, now: Date, zone: TimeZone = .current) -> Day {
    Day(now.addingTimeInterval(-Double(dayStart) * 60), in: zone)
}

/// "Mon 9 Nov".
public func formatDay(_ day: Day, locale: Locale = .current) -> String {
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = .gmt
    f.dateFormat = "EEE d MMM"
    return f.string(from: Date(timeIntervalSince1970: Double(day.number) * 86_400))
}

/// An estimate as typed: "30m", "1h30", "2h", "1.5h" or a number of minutes. Empty means none.
public func parseEstimate(_ text: String) throws(CannotEdit) -> Int64? {
    let text = text.lowercased().filter { !$0.isWhitespace }
    guard !text.isEmpty else { return nil }
    var minutes: Int64?
    if let m = text.wholeMatch(of: /(\d+(?:[.,]\d+)?)h(?:(\d{1,2})(?:m|min)?)?/),
       let hours = Double(m.1.replacingOccurrences(of: ",", with: ".")) {
        let extra = m.2.flatMap { Int64($0) } ?? 0
        // Half up, like Go and JS.
        if extra <= 59 { minutes = Int64((hours * 60 + Double(extra) + 0.5).rounded(.down)) }
    } else if let m = text.wholeMatch(of: /(\d+)(?:m|min|mins|minutes)?/) {
        minutes = Int64(m.1)
    }
    guard let minutes, (1...maxEstimate).contains(minutes) else {
        throw CannotEdit("Write the estimate like 30m or 1h30, up to a week")
    }
    return minutes
}

/// An estimate as the editor shows it: "30m", "1h30", "2h".
public func estimateText(_ minutes: Int64?) -> String {
    guard let minutes, minutes > 0 else { return "" }
    let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
    return hours == 0 ? "\(rest)m" : rest == 0 ? "\(hours)h" : "\(hours)h" + String(format: "%02d", rest)
}

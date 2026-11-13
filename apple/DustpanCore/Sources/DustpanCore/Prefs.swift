import Foundation

// Preferences on user_prefs "me", as Settings sets them. They work standalone and sync once connected.
// A port of Writer.set_prefs in the desktop's writes.py.

public enum PrefChoices {
    public static let dateFormats = ["system", "day-month", "month-day", "iso"]
    public static let timeFormats = ["system", "24h", "12h"]
    public static let weekStarts = ["system", "mon", "sun", "sat"]
    public static let languages = ["system", "en", "de", "fr", "es", "it", "pt"]
    public static let dayStarts = ["00:00", "01:00", "02:00", "03:00", "04:00", "05:00", "06:00"]
    /// The quick-add switches, stored as "on" or "off".
    public static let switches = ["time_sectors", "day_parts", "energy"]
    static let enums = ["date_format": dateFormats, "time_format": timeFormats, "week_start": weekStarts,
                        "language": languages]
    static let reminders = ["reminder_default_timed", "reminder_default_dated"]
    /// What each choice is called in Settings.
    public static let labels = [
        "system": "System", "24h": "24-Hour", "12h": "12-Hour", "day-month": "Day–Month", "month-day": "Month–Day",
        "iso": "ISO (YYYY-MM-DD)", "mon": "Monday", "sun": "Sunday", "sat": "Saturday", "en": "English",
        "de": "Deutsch", "fr": "Français", "es": "Español", "it": "Italiano", "pt": "Português",
    ]
}

/// Settings ▸ Default reminders, as OpenTodo's DefaultRemindersSettings.tsx offers them.
public let defaultTimedPresets = relativePresets
/// Counted from 09:00 on the due date.
public let defaultDatedPresets: [Int64] = [0, -1440, -2880, -4320, -10080]

extension Writer {
    /// Write the changed fields of user_prefs "me". Choosing what's already in effect writes nothing, so a later
    /// sync doesn't send fields nobody touched.
    ///
    /// Values: a choice's string; "HH:MM" or "" for day_start; minutes, a stored string or null for a default
    /// reminder; a Bool or "on"/"off" for a switch.
    public func setPrefs(_ changes: [String: JSON]) throws {
        let known = Set(PrefChoices.enums.keys).union(PrefChoices.reminders).union(PrefChoices.switches)
            .union(["day_start"])
        if let unknown = changes.keys.first(where: { !known.contains($0) }) { throw CannotEdit("Not editable: \(unknown)") }
        let wanted = Dictionary(uniqueKeysWithValues: try changes.map { ($0.key, try normalizePref($0.key, $0.value)) })
        try commit {
            let current = try store.rows("user_prefs")["me"]?.values ?? [:]
            var patch: [String: JSON] = [:]
            for (name, want) in wanted where prefDiffers(name, want, current) { patch[name] = want }
            return patch.isEmpty ? [] : [Change("user_prefs", "me", patch)]
        }
    }
}

private func normalizePref(_ name: String, _ value: JSON) throws -> JSON {
    if let choices = PrefChoices.enums[name] {
        guard let text = value.string, choices.contains(text) else { throw CannotEdit("Unsupported \(name): \(value.text)") }
        return value
    }
    if name == "day_start" {
        guard let text = value.string else { throw CannotEdit("Write the day start as HH:MM from 00:00 to 06:00") }
        if text.isEmpty { return "" }
        guard text.wholeMatch(of: /\d{2}:[0-5]\d/) != nil else {
            throw CannotEdit("Write the day start as HH:MM from 00:00 to 06:00")
        }
        guard Int(text.prefix(2))! * 60 + Int(text.suffix(2))! <= 6 * 60 else {
            throw CannotEdit("Day start can be at most 06:00")
        }
        return value
    }
    if PrefChoices.reminders.contains(name) {
        if value.isNull || value.string == "" { return "" }
        let minutes = value.int.flatMap { abs($0) <= maxReminderOffset ? $0 : nil } ?? parseDefault(value)
        guard let minutes else { throw CannotEdit("A reminder can be at most a year from the due time") }
        return .string(formatDefault(minutes))
    }
    if let on = value.bool { return on ? "on" : "off" }
    guard let text = value.string, ["on", "off", ""].contains(text) else { throw CannotEdit("Unsupported \(name): \(value.text)") }
    return value
}

private func prefDiffers(_ name: String, _ want: JSON, _ current: [String: JSON]) -> Bool {
    let cur = current[name] ?? .null
    if PrefChoices.enums[name] != nil { return want.string != prefChoice(current, name) }
    if name == "day_start" {
        let wantMinutes = dayStartMinutes(want), curMinutes = dayStartMinutes(cur)
        return wantMinutes != curMinutes || (wantMinutes == 0 && !(cur.isNull || cur.string == "" || cur.string == "00:00"))
    }
    if PrefChoices.reminders.contains(name) {
        return parseDefault(want) != parseDefault(cur) || (want.string == "" && !(cur.isNull || cur.string == ""))
    }
    return (want.string == "on") != prefIsOn(current, name)
}

/// "On the day at 09:00", "2 days before", "1 week before": a default for tasks with no time.
public func datedDefaultLabel(_ minutes: Int64) -> String {
    if minutes == 0 { return "On the day at 09:00" }
    if minutes % 10080 == 0 {
        let weeks = abs(minutes) / 10080
        return "\(weeks) week\(weeks == 1 ? "" : "s") \(minutes < 0 ? "before" : "after")"
    }
    return offsetLabel(minutes)
}

/// user_prefs.day_start as "HH:MM", midnight when unset or out of range.
public func dayStartText(_ prefs: [String: JSON]) -> String { hhmm(dayStartMinutes(prefs["day_start"] ?? .null)) }

/// A choice preference as it takes effect: "system" when unset or unknown.
public func prefChoice(_ prefs: [String: JSON], _ name: String) -> String {
    prefs[name]?.string.flatMap { PrefChoices.enums[name]?.contains($0) == true ? $0 : nil } ?? "system"
}

/// A quick-add switch: on only when stored as "on".
public func prefIsOn(_ prefs: [String: JSON], _ name: String) -> Bool { prefs[name]?.string == "on" }

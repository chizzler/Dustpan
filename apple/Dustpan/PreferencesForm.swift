import DustpanCore
import SwiftUI

/// Settings ▸ General: default reminders, dates and times, and what quick add understands.
/// Stored on user_prefs, as on the desktop, so they sync once connected.
struct PreferencesForm: View {
    @Environment(AppModel.self) private var model
    @State private var timed: Int64?
    @State private var dated: Int64?
    @State private var timeFormat: String
    @State private var dateFormat: String
    @State private var weekStart: String
    @State private var dayStart: String
    @State private var language: String
    @State private var sectors: Bool
    @State private var dayParts: Bool
    @State private var energy: Bool
    @State private var problem: String?
    @State private var showsProblem = false

    private static let timeFormats = [("system", "System"), ("24h", "24-Hour"), ("12h", "12-Hour")]
    private static let dateFormats = [("system", "System"), ("day-month", "Day–Month"), ("month-day", "Month–Day"),
                                      ("iso", "ISO (YYYY-MM-DD)")]
    private static let weekStarts = [("system", "System"), ("mon", "Monday"), ("sun", "Sunday"), ("sat", "Saturday")]
    private static let languages = [("system", "System"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"),
                                    ("es", "Español"), ("it", "Italiano"), ("pt", "Português")]

    init(prefs: [String: JSON]) {
        let defaults = defaultReminderOffsets(prefs)
        func choice(_ name: String, _ choices: [String]) -> String {
            prefs[name]?.string.flatMap { choices.contains($0) ? $0 : nil } ?? "system"
        }
        _timed = State(initialValue: defaults.timed)
        _dated = State(initialValue: defaults.dated)
        _timeFormat = State(initialValue: choice("time_format", PrefChoices.timeFormats))
        _dateFormat = State(initialValue: choice("date_format", PrefChoices.dateFormats))
        _weekStart = State(initialValue: choice("week_start", PrefChoices.weekStarts))
        _dayStart = State(initialValue: dayStartText(prefs))
        _language = State(initialValue: choice("language", PrefChoices.languages))
        _sectors = State(initialValue: prefs["time_sectors"]?.string == "on")
        _dayParts = State(initialValue: prefs["day_parts"]?.string == "on")
        _energy = State(initialValue: prefs["energy"]?.string == "on")
    }

    var body: some View {
        Form {
            Section {
                DefaultReminderPicker("Tasks with a time", presets: defaultTimedPresets, label: offsetLabel,
                                      minutes: $timed)
                DefaultReminderPicker("Tasks with no time", subtitle: "Counted from 09:00 on the due date",
                                      presets: defaultDatedPresets, label: datedDefaultLabel, minutes: $dated)
            } header: {
                Text("Default Reminders")
            } footer: {
                Text("Added automatically when a task first gets a due date.")
            }
            Section("Date and Time") {
                choicePicker("Time format", Self.timeFormats, $timeFormat)
                choicePicker("Date order", subtitle: "For dates like 06/11 in quick add", Self.dateFormats, $dateFormat)
                choicePicker("Week starts on", Self.weekStarts, $weekStart)
                Picker(selection: $dayStart) {
                    ForEach(dayStarts, id: \.self) { Text(dayStartLabel($0)).tag($0) }
                } label: {
                    Text("Day starts at")
                    Text("Work before this hour still counts as the day before")
                }
            }
            Section("Quick Add") {
                choicePicker("Language", Self.languages, $language)
                switchRow("Time sectors", "Understand phrases like “this week” or “next month”", $sectors)
                switchRow("Parts of the day", "Understand “morning” and “afternoon”", $dayParts)
                switchRow("Energy levels", "Understand “deep”, “medium” and “low energy”", $energy)
            }
        }
        .formStyle(.grouped)
        .onChange(of: timed) { save("reminder_default_timed", timed.map(JSON.int) ?? .null) }
        .onChange(of: dated) { save("reminder_default_dated", dated.map(JSON.int) ?? .null) }
        .onChange(of: timeFormat) { save("time_format", .string(timeFormat)) }
        .onChange(of: dateFormat) { save("date_format", .string(dateFormat)) }
        .onChange(of: weekStart) { save("week_start", .string(weekStart)) }
        .onChange(of: dayStart) { save("day_start", .string(dayStart)) }
        .onChange(of: language) { save("language", .string(language)) }
        .onChange(of: sectors) { save("time_sectors", .bool(sectors)) }
        .onChange(of: dayParts) { save("day_parts", .bool(dayParts)) }
        .onChange(of: energy) { save("energy", .bool(energy)) }
        .alert("Couldn't change that setting", isPresented: $showsProblem, presenting: problem) { _ in
        } message: { Text($0) }
    }

    /// Midnight to 06:00, and the stored start when it's between the hours.
    private var dayStarts: [String] {
        PrefChoices.dayStarts.contains(dayStart) ? PrefChoices.dayStarts : (PrefChoices.dayStarts + [dayStart]).sorted()
    }

    private func dayStartLabel(_ value: String) -> String {
        guard value != "00:00" else { return "Midnight" }
        return clockText(Int(value.prefix(2))! * 60 + Int(value.suffix(2))!, timeFormat: timeFormat)
    }

    private func choicePicker(_ title: String, subtitle: String? = nil, _ choices: [(String, String)],
                              _ selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            ForEach(choices, id: \.0) { Text($0.1).tag($0.0) }
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }

    private func switchRow(_ title: String, _ subtitle: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(subtitle)
        }
    }

    private func save(_ name: String, _ value: JSON) {
        do {
            try model.setPrefs([name: value])
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
            showsProblem = true
        }
    }
}

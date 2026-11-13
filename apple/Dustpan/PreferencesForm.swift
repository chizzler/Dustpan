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

    init(prefs: [String: JSON]) {
        let defaults = ReminderDefaults(prefs: prefs)
        _timed = State(initialValue: defaults.timed)
        _dated = State(initialValue: defaults.dated)
        _timeFormat = State(initialValue: prefChoice(prefs, "time_format"))
        _dateFormat = State(initialValue: prefChoice(prefs, "date_format"))
        _weekStart = State(initialValue: prefChoice(prefs, "week_start"))
        _dayStart = State(initialValue: dayStartText(prefs))
        _language = State(initialValue: prefChoice(prefs, "language"))
        _sectors = State(initialValue: prefIsOn(prefs, "time_sectors"))
        _dayParts = State(initialValue: prefIsOn(prefs, "day_parts"))
        _energy = State(initialValue: prefIsOn(prefs, "energy"))
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
                choicePicker("Time format", PrefChoices.timeFormats, $timeFormat)
                choicePicker("Date order", subtitle: "For dates like 06/11 in quick add", PrefChoices.dateFormats, $dateFormat)
                choicePicker("Week starts on", PrefChoices.weekStarts, $weekStart)
                Picker(selection: $dayStart) {
                    ForEach(dayStarts, id: \.self) { Text(dayStartLabel($0)).tag($0) }
                } label: {
                    Text("Day starts at")
                    Text("Work before this hour still counts as the day before")
                }
            }
            Section("Quick Add") {
                choicePicker("Language", PrefChoices.languages, $language)
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
        return clockText(dayStartMinutes(.string(value)), timeFormat: timeFormat)
    }

    private func choicePicker(_ title: String, subtitle: String? = nil, _ choices: [String],
                              _ selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            ForEach(choices, id: \.self) { Text(PrefChoices.labels[$0] ?? $0).tag($0) }
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

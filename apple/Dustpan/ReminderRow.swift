import DustpanCore
import SwiftUI

/// One reminder in the editor: its offset or time, changed in place, and Delete.
struct ReminderRow: View {
    @Environment(AppModel.self) private var model
    let reminder: Row
    /// Runs a change, showing why when it can't be made.
    let act: (() throws -> Void) -> Void
    @State private var offset: Int64
    @State private var time: Date

    init(reminder: Row, act: @escaping (() throws -> Void) -> Void) {
        self.reminder = reminder
        self.act = act
        _offset = State(initialValue: reminder["offset_minutes"].int ?? 0)
        _time = State(initialValue: reminder["fire_at"].int.map(Date.init(ms:)) ?? .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                switch reminder["kind"].string {
                case "relative":
                    Picker("Remind", selection: $offset) {
                        ForEach(Set(relativePresets + [offset]).sorted(by: >), id: \.self) {
                            Text(offsetLabel($0)).tag($0)
                        }
                    }
                    .onChange(of: offset) { act { try model.setOffset(reminder.id, minutes: offset) } }
                case "deadline":
                    Picker("Remind", selection: $offset) {
                        ForEach(Set(deadlinePresets + [offset]).sorted(by: >), id: \.self) {
                            Text(deadlineOffsetLabel($0)).tag($0)
                        }
                    }
                    .onChange(of: offset) { act { try model.setOffset(reminder.id, minutes: offset) } }
                case "absolute":
                    LabeledContent("Remind at") {
                        HStack(spacing: 4) {
                            DayPicker(date: $time)
                            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                    .onChange(of: time) { act { try model.retime(reminder.id, at: time) } }
                default:
                    Text(describe(reminder: reminder))
                    Spacer()
                }
                Button("Delete Reminder", systemImage: "trash") { act { try model.deleteReminder(reminder.id) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete reminder")
            }
            if reminder["fire_at"].isNull {
                Text("No \(reminder["kind"] == "deadline" ? "deadline" : "due date"), so it won't fire")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

import DustpanCore
import SwiftUI

/// None, the presets, or an offset typed in: 15m, 2h, 3d, 30m after.
struct DefaultReminderPicker: View {
    let title: String
    var subtitle: String?
    let presets: [Int64]
    let label: (Int64) -> String
    @Binding var minutes: Int64?

    @State private var choice: ReminderChoice
    @State private var asksCustom = false
    @State private var customText = ""
    @State private var invalid = false

    init(_ title: String, subtitle: String? = nil, presets: [Int64], label: @escaping (Int64) -> String,
         minutes: Binding<Int64?>) {
        (self.title, self.subtitle, self.presets, self.label) = (title, subtitle, presets, label)
        _minutes = minutes
        _choice = State(initialValue: ReminderChoice(minutes.wrappedValue))
    }

    var body: some View {
        Picker(selection: $choice) {
            Text("None").tag(ReminderChoice.none)
            ForEach(options, id: \.self) { minutes in
                Text(label(minutes)).tag(ReminderChoice.minutes(minutes))
            }
            Divider()
            Text("Custom…").tag(ReminderChoice.custom)
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
        .onChange(of: choice) { _, new in choose(new) }
        .alert("Custom Default Reminder", isPresented: $asksCustom) {
            TextField("15m", text: $customText)
            Button("Set", action: setCustom)
            Button("Cancel", role: .cancel) { choice = ReminderChoice(minutes) }
        } message: {
            Text("An offset like 15m, 2h, 3d, or 30m after.")
        }
        .alert("Write an offset up to a year, like 15m, 2h or 3d.", isPresented: $invalid) {}
    }

    /// The presets, and the stored offset when it's one of its own.
    private var options: [Int64] {
        guard let minutes, !presets.contains(minutes) else { return presets }
        return presets + [minutes]
    }

    private func choose(_ choice: ReminderChoice) {
        switch choice {
        case .none: minutes = nil
        case .minutes(let value): minutes = value
        case .custom:
            customText = ""
            asksCustom = true
        }
    }

    private func setCustom() {
        guard let value = parseCustomOffset(customText) else {
            choice = ReminderChoice(minutes)
            invalid = true
            return
        }
        minutes = value
        choice = .minutes(value)
    }
}

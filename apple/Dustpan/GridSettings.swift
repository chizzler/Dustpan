import DustpanCore
import SwiftUI

/// When the grid starts and ends, and the day length planned time is measured against. This Mac only
/// (meta calendar_grid), as the web app's.
struct GridSettings: View {
    @Environment(AppModel.self) private var model
    @State private var grid = GridPrefs()

    var body: some View {
        Form {
            Section {
                Picker("Grid starts", selection: $grid.startHour) {
                    ForEach(0..<24, id: \.self) { hour in Text(hourText(hour)).tag(hour) }
                }
                Picker("Grid ends", selection: $grid.endHour) {
                    ForEach((grid.startHour + 1)...24, id: \.self) { hour in Text(hourText(hour)).tag(hour) }
                }
                Picker("Day length", selection: $grid.dayLength) {
                    ForEach(Array(Set(dayLengths + [grid.dayLength])).sorted(), id: \.self) { minutes in
                        Text(formatMinutes(minutes)).tag(minutes)
                    }
                }
            } footer: {
                Text("Day and Week open at the start; later hours are shaded. These settings are for this Mac only.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .onAppear(perform: load)
        .onChange(of: grid.startHour) { grid.endHour = max(grid.endHour, grid.startHour + 1) }
        .onChange(of: grid) { model.setCalendarGrid(grid) }
    }

    private func load() { grid = model.calendarGrid }

    private func hourText(_ hour: Int) -> String {
        hour == 24 ? "Midnight" : clockText(hour * 60, timeFormat: model.snapshot.prefs["time_format"]?.string ?? "system")
    }
}

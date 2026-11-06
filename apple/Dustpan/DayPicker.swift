import SwiftUI

/// A day: the date field, and a button that opens the month calendar.
struct DayPicker: View {
    @Binding var date: Date
    @State private var showsCalendar = false

    var body: some View {
        HStack(spacing: 4) {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .labelsHidden()
            Button("Show Calendar", systemImage: "calendar") { showsCalendar.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show calendar")
                .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding()
                }
        }
    }
}

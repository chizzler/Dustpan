import SwiftUI

/// Opens or closes the calendar window: in the main window's toolbar and the View menu.
struct CalendarButton: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button(model.calendarOpen ? "Hide Calendar" : "Show Calendar", systemImage: "calendar", action: toggle)
            .help(model.calendarOpen ? "Hide the calendar" : "Show the calendar beside this window")
            .disabled(model.setupProblem != nil)
    }

    private func toggle() {
        if model.calendarOpen {
            dismissWindow(id: CalendarWindow.id)
        } else {
            openWindow(id: CalendarWindow.id)
        }
    }
}

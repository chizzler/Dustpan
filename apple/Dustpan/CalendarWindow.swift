import DustpanCore
import SwiftUI

/// The calendar, in a window of its own beside the main one, so tasks can be dragged from a list onto a day.
/// Month for now. See spec/calendar.md.
struct CalendarWindow: View {
    static let id = "calendar"

    @Environment(AppModel.self) private var model
    /// A day in the month shown; nil follows today.
    @State private var anchor: Day?
    @State private var selection: String?
    @State private var showsCompleted = false

    var body: some View {
        @Bindable var model = model
        let shown = anchor ?? model.today
        MonthGrid(page: MonthPage(model.snapshot, anchor: shown, today: model.today, showCompleted: showsCompleted,
                                  dayLength: model.calendarGrid.dayLength),
                  selection: $selection)
            .navigationTitle(monthTitle(shown))
            .toolbar { CalendarToolbar(anchor: $anchor, showsCompleted: $showsCompleted) }
            .overlay(alignment: .bottom) { ToastView() }
            .sheet(item: $model.calendarEditing, content: TaskEditor.init)
            .activeUndo()
            .onAppear(perform: appeared)
            .onDisappear(perform: disappeared)
            .onChange(of: showsCompleted) { model.setCalendarShowsCompleted(showsCompleted) }
            .frame(minWidth: 520, minHeight: 400)
    }

    private func appeared() {
        showsCompleted = model.calendarShowsCompleted
        model.setCalendarOpen(true)
    }

    /// Closed, not quit with the app: it stays closed next time.
    private func disappeared() {
        if !AppDelegate.quitting { model.setCalendarOpen(false) }
    }

    /// "November 2026"
    private func monthTitle(_ day: Day) -> String {
        let (year, month, _) = day.parts
        return Calendar.current.date(from: DateComponents(year: year, month: month))?
            .formatted(.dateTime.month(.wide).year()) ?? ""
    }
}

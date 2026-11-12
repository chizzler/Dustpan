import DustpanCore
import SwiftUI

/// The calendar, in a window of its own beside the main one, so tasks can be dragged from a list onto a day.
/// Day, Week or Month. See spec/calendar.md.
struct CalendarWindow: View {
    static let id = "calendar"

    @Environment(AppModel.self) private var model
    /// A day in the stretch shown; nil follows today.
    @State private var anchor: Day?
    @State private var mode = CalendarMode.month
    @State private var selection: String?
    @State private var showsCompleted = false
    /// Week and Day's scroll position, kept as the view switches between them.
    @State private var scrolled = ScrollMemory()

    var body: some View {
        @Bindable var model = model
        let shown = anchor ?? model.today
        let snapshot = model.snapshot
        Group {
            if mode == .month {
                MonthGrid(page: MonthPage(snapshot, anchor: shown, today: model.today, showCompleted: showsCompleted,
                                          dayLength: model.calendarGrid.dayLength),
                          selection: $selection)
            } else {
                TimeGrid(page: TimeGridPage(snapshot, days: days(shown), today: model.today,
                                            showCompleted: showsCompleted, dayLength: model.calendarGrid.dayLength),
                         startHour: model.calendarGrid.startHour, selection: $selection, scrolled: scrolled)
            }
        }
        .navigationTitle(title(shown))
        .navigationSubtitle(subtitle(shown))
        .toolbar { CalendarToolbar(anchor: $anchor, mode: $mode, showsCompleted: $showsCompleted) }
        .background { CalendarModeKeys(mode: $mode) }
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(item: $model.calendarEditing, content: TaskEditor.init)
        .activeUndo()
        .onAppear(perform: appeared)
        .onDisappear(perform: disappeared)
        .onChange(of: showsCompleted) { model.setCalendarShowsCompleted(showsCompleted) }
        .onChange(of: mode) { model.setCalendarMode(mode) }
        .frame(minWidth: 520, minHeight: 400)
    }

    private func appeared() {
        showsCompleted = model.calendarShowsCompleted
        mode = model.calendarMode
        model.setCalendarOpen(true)
    }

    /// Closed, not quit with the app: it stays closed next time.
    private func disappeared() {
        if !AppDelegate.quitting { model.setCalendarOpen(false) }
    }

    private func days(_ day: Day) -> [Day] {
        mode == .day ? [day] : weekDates(day, weekStart: model.snapshot.filterContext(today: model.today).weekStart)
    }

    /// "November 2026", "9–15 Nov" or "Thu 12 November".
    private func title(_ day: Day) -> String {
        switch mode {
        case .month: return date(day).formatted(.dateTime.month(.wide).year())
        case .day: return date(day).formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
        case .week:
            let week = days(day)
            let (first, last) = (date(week[0]), date(week[6]))
            return (first..<last).formatted(.interval.day().month(.abbreviated))
        }
    }

    /// "Week 46, 2026" or "2026"; Month has none.
    private func subtitle(_ day: Day) -> String {
        switch mode {
        case .month: return ""
        case .day: return day.parts.year.formatted(.number.grouping(.never))
        case .week:
            let first = date(days(day)[0])
            let number = Calendar(identifier: .iso8601).component(.weekOfYear, from: first)
            return "Week \(number), \(days(day)[6].parts.year.formatted(.number.grouping(.never)))"
        }
    }

    private func date(_ day: Day) -> Date {
        let (year, month, dayOfMonth) = day.parts
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) ?? .now
    }
}

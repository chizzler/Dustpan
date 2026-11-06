import SwiftUI

/// A month of days across the full width, for picking a day inline. Picking keeps the time of day.
struct MonthCalendar: View {
    @Binding var date: Date
    let zone: TimeZone
    /// The first day of the month shown.
    @State private var month: Date

    init(date: Binding<Date>, zone: TimeZone = .current) {
        _date = date
        self.zone = zone
        _month = State(initialValue: Self.calendar(zone).dateInterval(of: .month, for: date.wrappedValue)!.start)
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = zone
        return calendar
    }

    private var calendar: Calendar { Self.calendar(zone) }

    var body: some View {
        VStack(spacing: 6) {
            header
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(weekdaySymbols.indices, id: \.self) { i in
                    Text(weekdaySymbols[i])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                ForEach(days, id: \.self) { day($0) }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: date) { month = calendar.dateInterval(of: .month, for: date)!.start }
    }

    private var header: some View {
        HStack {
            Text(month.formatted(style(.dateTime.month(.wide).year())))
                .font(.headline)
            Spacer()
            Group {
                Button("Previous Month", systemImage: "chevron.left") { show(-1) }
                    .labelStyle(.iconOnly)
                Button("Today") { pick(.now) }
                Button("Next Month", systemImage: "chevron.right") { show(1) }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
    }

    private func day(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: date)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let today = calendar.isDateInToday(day)
        return Button { pick(day) } label: {
            Text(day.formatted(style(.dateTime.day())))
                .fontWeight(today ? .bold : .regular)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : today ? AnyShapeStyle(.tint)
                                 : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 28, height: 28)
                .background { if selected { Circle().fill(.tint) } }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(style(.dateTime.weekday(.wide).day().month(.wide).year())))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Six weeks from the start of the week holding the 1st, so the height never jumps.
    private var days: [Date] {
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: month)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
    }

    private func style(_ format: Date.FormatStyle) -> Date.FormatStyle {
        var format = format
        format.timeZone = zone
        return format
    }

    private func show(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month)!
    }

    /// The picked day, at date's time of day.
    private func pick(_ day: Date) {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute], from: date)
        (parts.hour, parts.minute) = (time.hour, time.minute)
        if let picked = calendar.date(from: parts) { date = picked }
        month = calendar.dateInterval(of: .month, for: day)!.start
    }
}

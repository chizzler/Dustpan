import DustpanCore
import SwiftUI

/// Week and Day: each day's header and Unscheduled lane, pinned above a scrolling time grid, 48 points an hour.
/// The headers scroll with the grid's width, so they stay over their columns whatever the scroll bar takes.
/// It opens at the grid's first hour and keeps its place across refreshes and views.
struct TimeGrid: View {
    @Environment(AppModel.self) private var model
    let page: TimeGridPage
    @Binding var selection: String?
    /// Where the grid is scrolled to, kept by the window so switching views holds it.
    let scrolled: ScrollMemory
    @State private var position: ScrollPosition

    init(page: TimeGridPage, startHour: Int, selection: Binding<String?>, scrolled: ScrollMemory) {
        self.page = page
        _selection = selection
        self.scrolled = scrolled
        _position = State(initialValue: ScrollPosition(y: scrolled.y ?? Double(startHour) * CalendarMetrics.hourHeight))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    HStack(alignment: .top, spacing: 0) {
                        HourGutter(timeFormat: model.snapshot.prefs["time_format"]?.string ?? "system")
                        ForEach(page.columns) { column in
                            TimeColumn(column: column, colors: page.colors, selection: $selection)
                        }
                    }
                } header: {
                    TimeGridHeads(page: page, selection: $selection)
                }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in scrolled.y = y }
    }
}

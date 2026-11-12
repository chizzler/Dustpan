import DustpanCore
import SwiftUI

/// The days across the top of Week and Day, over their columns, with a rule beneath.
struct TimeGridHeads: View {
    let page: TimeGridPage
    @Binding var selection: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: CalendarMetrics.gutterWidth, height: 1)
            ForEach(page.columns) { column in
                DayHead(column: column, colors: page.colors, single: page.columns.count == 1, selection: $selection)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }
}

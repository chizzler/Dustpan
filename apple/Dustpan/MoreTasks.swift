import DustpanCore
import SwiftUI

/// A Month day's tasks that didn't fit, in the popover behind "+N more".
struct MoreTasks: View {
    let tasks: [Row]
    let colors: [String: String]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(tasks) { task in
                CalendarTaskLine(task: task, colors: colors, selection: $selection)
            }
        }
        .padding()
        .frame(minWidth: 220, alignment: .leading)
    }
}

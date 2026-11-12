import DustpanCore
import SwiftUI

/// "+N more" on the calendar, with the tasks that didn't fit in a popover.
struct MoreButton: View {
    let tasks: [Row]
    let colors: [String: String]
    @Binding var selection: String?
    @State private var showsMore = false

    var body: some View {
        Button("+\(tasks.count) more", action: showMore)
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.leading, 3)
            .popover(isPresented: $showsMore) {
                MoreTasks(tasks: tasks, colors: colors, selection: $selection)
            }
    }

    private func showMore() { showsMore = true }
}

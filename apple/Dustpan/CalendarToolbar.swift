import DustpanCore
import SwiftUI

/// Back, Today and forward a month, and the completed tasks toggle. Single keys, as on the desktop: [ t ] and h.
struct CalendarToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Binding var anchor: Day?
    @Binding var showsCompleted: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous Month", systemImage: "chevron.left", action: back)
                .keyboardShortcut("[", modifiers: [])
                .help("Previous month ([)")
            Button("Today", action: today)
                .keyboardShortcut("t", modifiers: [])
                .help("Today (t)")
            Button("Next Month", systemImage: "chevron.right", action: forward)
                .keyboardShortcut("]", modifiers: [])
                .help("Next month (])")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle("Show Completed", systemImage: "checkmark.circle", isOn: $showsCompleted)
                .keyboardShortcut("h", modifiers: [])
                .help("Show completed tasks (h)")
        }
    }

    private func back() { anchor = addMonths(anchor ?? model.today, -1) }
    private func forward() { anchor = addMonths(anchor ?? model.today, 1) }
    private func today() { anchor = nil }
}

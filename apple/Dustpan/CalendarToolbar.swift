import DustpanCore
import SwiftUI

/// Back, Today and forward by the view's length, Day, Week or Month, and the completed tasks toggle.
/// Single keys, as on the desktop: [ t ] and h; d, w and m are on CalendarModeKeys.
struct CalendarToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Binding var anchor: Day?
    @Binding var mode: CalendarMode
    @Binding var showsCompleted: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Previous \(mode.title)", systemImage: "chevron.left", action: back)
                .keyboardShortcut("[", modifiers: [])
                .help("Previous \(mode.rawValue) ([)")
            Button("Today", action: today)
                .keyboardShortcut("t", modifiers: [])
                .help("Today (t)")
            Button("Next \(mode.title)", systemImage: "chevron.right", action: forward)
                .keyboardShortcut("]", modifiers: [])
                .help("Next \(mode.rawValue) (])")
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $mode) {
                ForEach(CalendarMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Day (d), Week (w) or Month (m)")
        }
        ToolbarItem(placement: .primaryAction) {
            GridSettingsButton()
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle("Show Completed", systemImage: "checkmark.circle", isOn: $showsCompleted)
                .keyboardShortcut("h", modifiers: [])
                .help("Show completed tasks (h)")
        }
    }

    private func back() { anchor = mode.step(anchor ?? model.today, by: -1) }
    private func forward() { anchor = mode.step(anchor ?? model.today, by: 1) }
    private func today() { anchor = nil }
}

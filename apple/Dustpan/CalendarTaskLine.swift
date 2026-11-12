import DustpanCore
import SwiftUI

/// A task on the calendar: its project's dot, its time, its title. A click selects it, a double-click opens it,
/// and an open one drags. A completed one is faded and struck through, with a tick for its dot.
struct CalendarTaskLine: View {
    @Environment(AppModel.self) private var model
    let task: Row
    /// Project colours by id.
    let colors: [String: String]
    @Binding var selection: String?

    var body: some View {
        let done = !task["completed_at"].isNull
        let title = task["title"].string ?? ""
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark" : "circle.fill")
                .imageScale(.small)
                .font(.caption)
                .foregroundStyle(done ? Color.secondary : Color(hex: task["project_id"].string.flatMap { colors[$0] }) ?? .gray)
                .accessibilityHidden(true)
            if let minutes = shownSpot(task)?.minutes {
                Text(clockText(minutes, timeFormat: model.snapshot.prefs["time_format"]?.string ?? "system"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .strikethrough(done)
                .lineLimit(1)
        }
        .font(.callout)
        .opacity(done ? 0.55 : 1)
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(selection == task.id ? 0.2 : 0), in: .rect(cornerRadius: 4))
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(done ? "Completed" : "")
        .accessibilityAction(named: "Open", open)
        .help(done ? "\(title)\nCompleted" : title)
        .taskDrag(task, compact: true)
        .flashes(task.id)
    }

    private func select() { selection = task.id }

    private func open() {
        selection = task.id
        model.openFromCalendar(task.id)
    }
}

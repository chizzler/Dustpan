import DustpanCore
import SwiftUI

/// A timed task on Week and Day's grid, as tall as its estimate, in its project's colour (grey for the Inbox).
/// Without an estimate it's drawn 30 minutes long with a dashed edge. A click selects it, a double-click opens it,
/// an open one drags, and its bottom edge stretches it. A completed one is faded and struck through.
struct CalendarBlock: View {
    @Environment(AppModel.self) private var model
    let block: TimeGridPage.Block
    let colors: [String: String]
    @Binding var selection: String?
    @Binding var stretching: Stretching?

    var body: some View {
        let task = block.task
        let done = !task["completed_at"].isNull
        let title = task["title"].string ?? ""
        let color = Color(hex: task["project_id"].string.flatMap { colors[$0] }) ?? .gray
        let fade = done ? 0.45 : 1
        let tall = block.end - block.start >= 45
        Group {
            if tall {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).strikethrough(done).lineLimit(3)
                    Text(when).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Text(clock(block.start)).foregroundStyle(.secondary)
                    Text(title).strikethrough(done).lineLimit(1)
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
        .opacity(done ? 0.55 : 1)
        .padding(EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 4))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 5)
            shape.fill(color.opacity((block.estimated ? 0.24 : 0.12) * fade))
            if block.estimated {
                Rectangle().fill(color.opacity(fade))
                    .frame(width: 3)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                shape.strokeBorder(color.opacity(0.8 * fade), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(selection == task.id ? 0.8 : 0)
        }
        .clipShape(.rect(cornerRadius: 5))
        .overlay(alignment: .bottom) {
            if !done { StretchHandle(block: block, stretching: $stretching) }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection == block.task.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityValue(done ? "Completed" : "")
        .accessibilityAction(named: "Open", open)
        .help("\(title)\n\(when)" + (done ? "\nCompleted" : ""))
        .contextMenu { CalendarTaskMenu(task: task) }
        .taskDrag(task, compact: true)
        .flashes(task.id)
    }

    /// "09:30–11:00", or only the start without an estimate.
    private var when: String {
        clock(block.start) + (block.estimated ? "–" + clock(block.end % dayMinutes) : "")
    }

    private func clock(_ minutes: Int) -> String {
        clockText(minutes, timeFormat: prefChoice(model.snapshot.prefs, "time_format"))
    }

    private func select() { selection = block.task.id }

    private func open() {
        selection = block.task.id
        model.openFromCalendar(block.task.id)
    }
}

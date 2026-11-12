import DustpanCore
import SwiftUI

/// A task's check circle in its priority colour. An open parent's circle holds a pie of its done subtasks:
/// a faint ring when none are done, a full disc when all are. The count is in the tooltip and read by VoiceOver.
struct TaskCheck: View {
    let done: Bool
    let priority: Int64?
    let progress: SubtaskProgress?
    let toggle: () -> Void

    var body: some View {
        let color = priorityColor(priority)
        Button(done ? "Reopen" : "Complete", systemImage: done ? "checkmark.circle.fill" : "circle", action: toggle)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(color)
            .bold(priority.map { $0 < 4 } ?? false)
            .overlay {
                if let progress, !done, progress.total > 0 {
                    Group {
                        if progress.done == 0 {
                            Circle().strokeBorder(color.opacity(0.45), lineWidth: 1)
                        } else {
                            ProgressPie(fraction: Double(progress.done) / Double(progress.total)).fill(color)
                        }
                    }
                    .padding(3.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .contentShape(.circle)
            .help(help)
            .accessibilityValue(done ? "" : progress?.text ?? "")
    }

    private var help: String {
        let action = done ? "Reopen" : "Complete"
        guard !done, let progress else { return action }
        return action + "\n" + progress.text
    }
}

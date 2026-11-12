import DustpanCore
import SwiftUI

/// A block's bottom 6 points: dragging it changes the estimate in whole 15-minute slots, the start staying put.
/// An unestimated block stretches from its drawn 30 minutes. Only the estimate is written, with Undo.
struct StretchHandle: View {
    @Environment(AppModel.self) private var model
    let block: TimeGridPage.Block
    @Binding var stretching: Stretching?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 6)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .bottom))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged(changed).onEnded(ended))
            .accessibilityHidden(true)
    }

    private var estimate: Int? {
        block.task["estimate_minutes"].int.map(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    private func changed(_ drag: DragGesture.Value) {
        let bottom = Double(block.start + (estimate ?? defaultBlockMinutes)) * CalendarMetrics.perMinute
        let wanted = resizeEstimate(start: block.start, offset: bottom + drag.translation.height,
                                    perMinute: CalendarMetrics.perMinute)
        if stretching?.estimate != wanted { stretching = Stretching(taskId: block.id, estimate: wanted) }
    }

    private func ended(_: DragGesture.Value) {
        defer { stretching = nil }
        guard let wanted = stretching?.estimate, wanted != estimate else { return }
        model.drop(block.id, on: .stretch(wanted, start: nil))
    }
}

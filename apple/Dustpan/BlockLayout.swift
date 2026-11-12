import SwiftUI

/// Where a view sits in a day's time column: from top for length, in minutes, in lane of lanes side by side.
nonisolated struct BlockSpot {
    var top = 0
    var length = 0
    var lane = 0
    var lanes = 1
}

nonisolated private struct BlockSpotKey: LayoutValueKey {
    static let defaultValue = BlockSpot()
}

extension View {
    func blockSpot(top: Int, length: Int, lane: Int = 0, lanes: Int = 1) -> some View {
        layoutValue(key: BlockSpotKey.self, value: BlockSpot(top: top, length: length, lane: lane, lanes: lanes))
    }
}

/// A day's time column: its views placed by their BlockSpot, a whole day tall.
nonisolated struct BlockLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 100, height: CalendarMetrics.hourHeight * 24)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let perMinute = CalendarMetrics.perMinute
        for view in subviews {
            let spot = view[BlockSpotKey.self]
            let width = bounds.width / Double(max(1, spot.lanes))
            let size = CGSize(width: max(0, width - 2), height: max(0, Double(spot.length) * perMinute - 1))
            view.place(at: CGPoint(x: bounds.minX + width * Double(spot.lane) + 1,
                                   y: bounds.minY + Double(spot.top) * perMinute),
                       proposal: ProposedViewSize(size))
        }
    }
}

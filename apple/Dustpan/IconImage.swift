import DustpanCore
import SwiftUI

/// A Lucide icon, size points square, drawn in the foreground style. Its lines are 1.5 units of Lucide's 24:
/// lighter than Lucide's 2 (spec/icons.md).
struct IconImage: View {
    let name: String
    var size: Double = 16

    var body: some View {
        IconShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: 1.5 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

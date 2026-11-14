import DustpanCore
import SwiftUI

/// A Lucide icon's outline, scaled from its 24-unit grid to fit the frame. Stroke it: Lucide draws lines.
nonisolated struct IconShape: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        guard let outline = Icons.path(name) else { return Path() }
        let scale = min(rect.width, rect.height) / 24
        return Path(outline).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }
}

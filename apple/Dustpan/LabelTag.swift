import SwiftUI

/// A label's mark: a solid tag in its colour, grey without one. Solid, so it never looks like a project's line icon
/// or dot (spec/icons.md).
struct LabelTag: View {
    let color: String?
    var size: Double = 10

    var body: some View {
        Image(systemName: "tag.fill")
            .font(.system(size: size))
            .foregroundStyle(Color(hex: color) ?? .secondary)
            .accessibilityHidden(true)
    }
}

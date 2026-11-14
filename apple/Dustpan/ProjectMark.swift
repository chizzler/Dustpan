import DustpanCore
import SwiftUI

/// A project's icon in its colour, or its dot when it has no icon this Mac can draw. Both fill the same square,
/// so names line up. A Theme project (no colour) draws in the text colour (spec/icons.md).
struct ProjectMark: View {
    let color: String?
    let icon: String?
    var size: Double = 16

    var body: some View {
        Group {
            if let icon, Icons.known(icon) {
                IconImage(name: icon, size: size)
            } else {
                Circle()
                    .frame(width: size * 0.55, height: size * 0.55)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Color(hex: color) ?? .primary)
    }
}

/// Before a section's name: its icon, in its colour or the text colour; a dot of its colour; or, with neither,
/// nothing, so it looks as it always has (spec/projects.md).
struct SectionMark: View {
    let color: String?
    let icon: String?

    var body: some View {
        if color != nil || icon.map(Icons.known) == true {
            ProjectMark(color: color, icon: icon, size: 14)
        }
    }
}

extension ProjectMark {
    init(_ project: Row, size: Double = 16) {
        self.init(color: project["color"].string, icon: project["icon"].string, size: size)
    }
}

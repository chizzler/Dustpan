import SwiftUI

/// The mark before a page's title: a project's icon or dot, a label's tag, or the page's symbol in the accent colour.
struct PageMark: View {
    let mark: PageHead.Mark?

    var body: some View {
        switch mark {
        case .project(let project): ProjectMark(project, size: 26)
        case .label(let color): LabelTag(color: color, size: 22)
        case .symbol(let name): Image(systemName: name).font(.title).foregroundStyle(.tint).accessibilityHidden(true)
        case nil: EmptyView()
        }
    }
}

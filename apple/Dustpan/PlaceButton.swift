import DustpanCore
import SwiftUI

/// A sub-project under a page's heading, with its mark. A click opens it.
struct PlaceButton: View {
    @Environment(AppModel.self) private var model
    let project: Row

    var body: some View {
        let name = project["name"].string ?? ""
        Button(action: open) {
            Label {
                Text(name).lineLimit(1)
            } icon: {
                ProjectMark(project, size: 14)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Open \(name)")
    }

    private func open() { model.page = .project(project.id) }
}

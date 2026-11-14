import DustpanCore
import SwiftUI

/// The top of a page, so a project reads as a place you are in: an eyebrow saying where or when, a large title with
/// its mark, a dim count, and the sub-projects to walk into (spec/pagehead.md).
struct PageHeading: View {
    @Environment(AppModel.self) private var model
    let head: PageHead

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow = head.eyebrow {
                let text = Text(eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                if let parent = head.parent {
                    Button(action: goUp) { text }
                        .buttonStyle(.plain)
                        .help("Open \(parent["name"].string ?? "")")
                } else {
                    text
                }
            }
            HStack(spacing: 12) {
                PageMark(mark: head.mark)
                Text(head.title)
                    .font(.largeTitle.weight(.heavy))
                    .tracking(-0.5)
                    .accessibilityAddTraits(.isHeader)
            }
            if let meta = head.meta {
                Text(meta).foregroundStyle(.secondary).padding(.top, 4)
            }
            if !head.places.isEmpty {
                FlowLayout {
                    ForEach(head.places) { PlaceButton(project: $0) }
                }
                .padding(.top, 8)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectionDisabled()
        .listRowSeparator(.hidden)
    }

    private func goUp() { model.page = head.parent.map { .project($0.id) } }
}

import DustpanCore
import SwiftUI

/// One icon to pick, named in its tooltip.
struct IconCell: View {
    let name: String
    let chosen: Bool
    let color: Color
    let pick: (String) -> Void

    var body: some View {
        Button(action: choose) {
            IconImage(name: name, size: 22)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(chosen ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Icons.title(name))
        .accessibilityLabel(Icons.title(name))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func choose() { pick(name) }
}

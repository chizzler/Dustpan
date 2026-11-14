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
                .background(.tint.opacity(chosen ? 0.25 : 0), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Icons.title(name))
        .accessibilityLabel(Icons.title(name))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func choose() { pick(name) }
}

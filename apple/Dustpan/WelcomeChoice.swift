import SwiftUI

/// A setup choice ends with the button that selects it.
struct WelcomeChoice<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let accent: Color
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(accent).accessibilityHidden(true)
                Text(title)
            }
            .font(.title3.bold())
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action
                .buttonStyle(.bordered)
                .controlSize(.extraLarge)
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

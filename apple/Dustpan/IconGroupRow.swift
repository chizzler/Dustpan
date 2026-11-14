import SwiftUI

/// A category in the icon picker's sidebar: its icon, name and how many it holds.
struct IconGroupRow: View {
    let label: String
    /// A Lucide icon's name.
    let symbol: String
    let count: Int

    var body: some View {
        Label {
            Text(label)
        } icon: {
            IconImage(name: symbol)
        }
        .badge(count)
    }
}

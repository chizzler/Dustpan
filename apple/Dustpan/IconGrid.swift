import DustpanCore
import SwiftUI

/// Icons eight to a line, in the project's colour. The chosen one is highlighted and scrolled to.
struct IconGrid: View {
    let names: [String]
    let chosen: String?
    let color: Color
    let pick: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 6), count: 8), spacing: 6) {
                    ForEach(names, id: \.self) { name in
                        IconCell(name: name, chosen: name == chosen, color: color, pick: pick)
                    }
                }
                .padding(12)
            }
            .onAppear { if let chosen, names.contains(chosen) { proxy.scrollTo(chosen, anchor: .center) } }
        }
    }
}

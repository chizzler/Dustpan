import DustpanCore
import SwiftUI

/// Picks a project's icon: a search across all of them, and a sidebar of categories beside the chosen one's icons.
/// Opens on the current icon's category, else on Suggested when the name gives any, else on Work (spec/icons.md).
struct IconPicker: View {
    @Binding var icon: String?
    /// Shows the picker. A popover's own dismiss would close the editor's sheet around it.
    @Binding var isPresented: Bool
    /// The project's colour, to draw the icons in. Nil is Theme.
    let color: String?
    @State private var query = ""
    @State private var group: String?
    @FocusState private var searching: Bool
    private let suggested: [String]

    /// A short query matches most icons: this many show, best first.
    private static let searchLimit = 240
    private static let suggestedId = "suggested"

    init(icon: Binding<String?>, isPresented: Binding<Bool>, color: String?, projectName: String) {
        _icon = icon
        _isPresented = isPresented
        self.color = color
        suggested = Icons.suggest(projectName)
        let current = icon.wrappedValue.flatMap { Icons.groupOf[$0] }
        _group = State(initialValue: current ?? (suggested.isEmpty ? "work" : Self.suggestedId))
    }

    var body: some View {
        let found = query.isEmpty ? nil : Icons.search(query)
        VStack(spacing: 0) {
            TextField("Search icons", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit(takeBest)
                .padding(10)
            Divider()
            HStack(spacing: 0) {
                List(selection: $group) {
                    if !suggested.isEmpty {
                        IconGroupRow(label: "Suggested", symbol: "sparkles", count: suggested.count)
                            .tag(Self.suggestedId)
                    }
                    ForEach(Icons.groups) { group in
                        IconGroupRow(label: group.label, symbol: group.symbol, count: Icons.inGroup[group.id]?.count ?? 0)
                            .tag(group.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 210)
                .onChange(of: group) { query = "" }
                Divider()
                IconGrid(names: names(found), chosen: icon, color: Color(hex: color) ?? .primary, pick: pick)
                    .id(found == nil ? group : "search")
            }
            Divider()
            HStack {
                Button("No Icon", action: clear)
                    .disabled(icon == nil)
                Spacer()
                if let found, found.count > Self.searchLimit {
                    Text("The first \(Self.searchLimit) of \(found.count). Type more to narrow it down.")
                        .foregroundStyle(.secondary)
                } else if let found, found.isEmpty {
                    Text("No icon matches “\(query)”.").foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .frame(width: 620, height: 460)
        .onAppear { searching = true }
    }

    private func names(_ found: [IconEntry]?) -> [String] {
        if let found { return found.prefix(Self.searchLimit).map(\.name) }
        return group == Self.suggestedId ? suggested : Icons.inGroup[group ?? ""] ?? []
    }

    /// Return takes the best match.
    private func takeBest() {
        if let best = Icons.search(query).first, !query.isEmpty { pick(best.name) }
    }

    private func pick(_ name: String) {
        icon = name
        isPresented = false
    }

    private func clear() {
        icon = nil
        isPresented = false
    }
}

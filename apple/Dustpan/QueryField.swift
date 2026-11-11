import DustpanCore
import SwiftUI

/// A filter query with help: suggestions for the word being typed, and a menu of conditions to add.
/// The Filter page and the view editor share it. The rules are in QueryTools.swift.
struct QueryField: View {
    @Environment(AppModel.self) private var model
    @Binding var query: String
    /// A new value puts the focus in the field.
    var focusRequest: Int?
    @State private var selection: TextSelection?
    @State private var negate = false
    @FocusState private var focused: Bool

    var body: some View {
        let names = model.queryNames
        HStack {
            TextField("Query", text: $query, selection: $selection, prompt: Text("Like @errand & due <= 7 days"))
                .font(.body.monospaced())
                .focused($focused)
                .textInputSuggestions {
                    ForEach(suggestions(names), id: \.self) { suggestion in
                        Text("\(suggestion.shown)  \(Text(suggestion.hint).foregroundStyle(.secondary))")
                            .textInputCompletion(suggestion.completed)
                    }
                }
            Toggle("Not", isOn: $negate)
                .toggleStyle(.button)
                .help("Add the opposite of the next condition")
            Menu("Condition", systemImage: "plus") {
                ForEach(queryConditions(labels: names.labels, projects: names.projects)) { group in
                    Menu(group.title) {
                        ForEach(group.items.enumerated(), id: \.offset) { _, item in
                            Button(item.label) { add(item.term) }
                        }
                    }
                }
            }
            .fixedSize()
            .help("Add a condition")
        }
        .onChange(of: focusRequest, initial: true) { if focusRequest != nil { focused = true } }
    }

    /// Offered only with the cursor at the end, where the word being completed is.
    private func suggestions(_ names: (labels: [String], projects: [String])) -> [QuerySuggestion] {
        if let selection, case .selection(let range) = selection.indices,
           !(range.isEmpty && range.upperBound == query.endIndex) {
            return []
        }
        return suggest(query, labels: names.labels, projects: names.projects)
    }

    /// Joined on with &. With Not on, its opposite is, and Not turns off again.
    private func add(_ term: String) {
        query = addCondition(query, term, negate: negate)
        selection = TextSelection(insertionPoint: query.endIndex)
        negate = false
        focused = true
    }
}

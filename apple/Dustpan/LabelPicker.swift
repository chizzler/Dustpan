import DustpanCore
import SwiftUI

/// Find labels as you type and add or remove them. ↑ ↓ move, Return toggles and clears the search, Esc closes.
/// refs are label ids, or names of labels to create.
struct LabelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var refs: [String]
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searching: Bool

    private enum Choice: Hashable {
        case label(Row)
        case new(String)
        case create(String)
    }

    var body: some View {
        let choices = self.choices
        VStack(alignment: .leading, spacing: 0) {
            TextField("Find or create a label", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .padding(10)
                .onChange(of: query) { highlighted = 0 }
                .onSubmit { pick(choices) }
                .onKeyPress(.downArrow) { step(1, choices.count) }
                .onKeyPress(.upArrow) { step(-1, choices.count) }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(choices.enumerated(), id: \.offset) { index, choice in
                            row(choice, highlighted: index == highlighted)
                                .id(index)
                                .onTapGesture {
                                    highlighted = index
                                    pick(choices)
                                }
                        }
                        if choices.isEmpty {
                            Text("No labels yet. Type a name to create one.")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { searching = true }
    }

    /// Labels to create first, then the labels that match, then "Create label …" when no label has the typed name.
    private var choices: [Choice] {
        let labels = model.labelsForPicker
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = refs.filter { model.snapshot.labels[$0] == nil }
        var out = new.filter { query.isEmpty || $0.localizedStandardContains(typed) }.map(Choice.new)
            + findLabels(labels, query).map(Choice.label)
        if !typed.isEmpty && exactLabel(labels, typed) == nil
            && !new.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
            out.append(.create(typed))
        }
        return out
    }

    private func row(_ choice: Choice, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            switch choice {
            case .label(let label):
                Image(systemName: "checkmark").opacity(refs.contains(label.id) ? 1 : 0).frame(width: 14)
                LabelTag(color: label["color"].string)
                Text(label["name"].string ?? "")
            case .new(let name):
                Image(systemName: "checkmark").frame(width: 14)
                LabelTag(color: nil)
                Text(name)
                Text("new").foregroundStyle(.secondary)
            case .create(let name):
                Image(systemName: "plus").frame(width: 14)
                Text("Create label “\(name)”")
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(highlighted ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 4))
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func step(_ by: Int, _ count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        highlighted = (highlighted + by + count) % count
        return .handled
    }

    /// Add or remove the highlighted choice, and clear the search for the next one.
    private func pick(_ choices: [Choice]) {
        guard choices.indices.contains(highlighted) else { return }
        switch choices[highlighted] {
        case .label(let label):
            if let at = refs.firstIndex(of: label.id) { refs.remove(at: at) } else { refs.append(label.id) }
        case .new(let name):
            refs.removeAll { $0 == name }
        case .create(let name):
            refs.append(name)
        }
        query = ""
        highlighted = 0
        searching = true
    }
}

/// The picker on a task row. Changes are written as one batch when it closes, with Undo.
struct RowLabelPicker: View {
    @Environment(AppModel.self) private var model
    let task: Row
    @State private var refs: [String]
    private let before: [String]

    init(task: Row) {
        self.task = task
        before = task["labels"].array?.compactMap(\.string) ?? []
        _refs = State(initialValue: before)
    }

    var body: some View {
        LabelPicker(refs: $refs)
            .onDisappear {
                model.changeLabels(of: task, add: refs.filter { !before.contains($0) },
                                   remove: Set(before.filter { !refs.contains($0) }))
            }
    }
}

extension View {
    /// The label picker in a popover on this task's row, while the model says so.
    func labelPicker(for task: Row) -> some View { modifier(LabelPickerAnchor(task: task)) }
}

private struct LabelPickerAnchor: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: Row

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding {
            model.labelling == task.id
        } set: { shown in
            if !shown && model.labelling == task.id { model.labelling = nil }
        }, arrowEdge: .bottom) {
            RowLabelPicker(task: task)
        }
    }
}

/// A label as a chip: its tag and name, and × to remove it when there's a remove action.
struct LabelChip: View {
    let name: String
    let color: String?
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            LabelTag(color: color)
            Text(name)
            if let remove {
                Button("Remove \(name)", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.small)
                    .help("Remove \(name)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background((Color(hex: color) ?? .secondary).opacity(0.15), in: .capsule)
    }
}

/// Children in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.indices.last, rows[last].width + spacing + size.width <= width {
                rows[last].items.append(index)
                rows[last].width += spacing + size.width
                rows[last].height = max(rows[last].height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

/// Name and colour of a new or existing label. Delete is here too, as in the sidebar's menu.
struct LabelEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: LabelDraft
    @State private var name: String
    @State private var color: String
    @State private var problem: String?
    @State private var confirmsDelete = false

    init(draft: LabelDraft) {
        self.draft = draft
        _name = State(initialValue: draft.label?["name"].string ?? "")
        _color = State(initialValue: draft.label?["color"].string ?? "")
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            LabeledContent("Colour") {
                HStack(spacing: 6) {
                    ForEach(labelColours, id: \.hex) { swatch in
                        Button(swatch.name) { color = swatch.hex }
                            .buttonStyle(Swatch(hex: swatch.hex, name: swatch.name, chosen: color.lowercased() == swatch.hex))
                            .help(swatch.name)
                    }
                }
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
            if let label = draft.label {
                Section {
                    Button("Delete Label…", role: .destructive) {
                        if model.uses(of: label) > 0 { confirmsDelete = true } else { delete(label) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
        .onAppear {
            // A new label starts with the first colour no label uses.
            if color.isEmpty {
                let used = Set(model.snapshot.labels.values.compactMap { $0["color"].string })
                color = labelColours.first { !used.contains($0.hex) }?.hex ?? labelColours[0].hex
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.label == nil ? "Create" : "Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .labelDeleteConfirmation(draft.label, isPresented: $confirmsDelete) { delete($0) }
    }

    private func save() {
        do {
            try model.saveLabel(draft.label, name: name, color: color)
            dismiss()
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
        }
    }

    private func delete(_ label: Row) {
        dismiss()
        model.deleteLabel(label)
    }
}

/// A colour to pick. Nil is Theme: the text colour, light on a dark theme and dark on a light one.
struct Swatch: ButtonStyle {
    let hex: String?
    let name: String
    let chosen: Bool
    /// A nil hex is no colour at all, a dashed ring, rather than the text colour.
    var none = false

    func makeBody(configuration: Configuration) -> some View {
        Circle()
            .fill(hex.map { Color(hex: $0) ?? .gray } ?? (none ? .clear : .primary))
            .overlay {
                if none { Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
            }
            .frame(width: 18, height: 18)
            .overlay {
                if chosen {
                    Image(systemName: "checkmark").font(.caption2.bold())
                        .foregroundStyle(none ? AnyShapeStyle(.primary)
                                         : hex == nil ? AnyShapeStyle(.background) : AnyShapeStyle(.white))
                }
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
            .accessibilityLabel(name)
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

extension View {
    /// Asks before deleting a label that tasks carry, saying how many.
    func labelDeleteConfirmation(_ label: Row?, isPresented: Binding<Bool>,
                                 delete: @escaping (Row) -> Void) -> some View {
        modifier(LabelDeleteConfirmation(label: label, isPresented: isPresented, delete: delete))
    }
}

private struct LabelDeleteConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    let label: Row?
    @Binding var isPresented: Bool
    let delete: (Row) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete label “\(label?["name"].string ?? "")”?", isPresented: $isPresented,
                                   presenting: label) { label in
            Button("Delete Label", role: .destructive) { delete(label) }
        } message: { label in
            let uses = model.uses(of: label)
            Text("It comes off \(uses) task\(uses == 1 ? "" : "s"), on every device. The tasks stay.")
        }
    }
}

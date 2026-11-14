import DustpanCore
import SwiftUI

/// A new section's name, colour and icon, or an existing one's (spec/projects.md).
struct SectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: SectionDraft
    @State private var name: String
    /// Nil is none: the icon draws in the text colour, and without one there's no dot.
    @State private var color: String?
    /// A name this Mac can't draw (a newer client's) stays as it is unless another is picked.
    @State private var icon: String?
    @State private var picksIcon = false
    @State private var problem: String?

    init(draft: SectionDraft) {
        self.draft = draft
        _name = State(initialValue: draft.section?["name"].string ?? "")
        _color = State(initialValue: draft.section?["color"].string)
        _icon = State(initialValue: draft.section?["icon"].string)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .onSubmit(save)
            LabeledContent("Colour") {
                HStack(spacing: 6) {
                    Button("None") { color = nil }
                        .buttonStyle(Swatch(hex: nil, name: "None", chosen: color == nil, none: true))
                        .help("None")
                    ForEach(projectColours, id: \.hex) { swatch in
                        Button(swatch.name) { color = swatch.hex }
                            .buttonStyle(Swatch(hex: swatch.hex, name: swatch.name,
                                                chosen: color?.lowercased() == swatch.hex))
                            .help(swatch.name)
                    }
                }
            }
            LabeledContent("Icon") {
                Button(action: showPicker) {
                    Label {
                        Text(icon.map(Icons.title) ?? "None")
                    } icon: {
                        SectionMark(color: color, icon: icon)
                    }
                }
                .popover(isPresented: $picksIcon, arrowEdge: .trailing) {
                    IconPicker(icon: $icon, isPresented: $picksIcon, color: color, name: name)
                }
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .navigationTitle(draft.section == nil ? "New Section" : "Edit Section")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.section == nil ? "Add" : "Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func showPicker() { picksIcon = true }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try model.saveSection(draft, name: name, color: color, icon: icon)
            dismiss()
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
        }
    }
}

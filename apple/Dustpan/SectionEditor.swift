import DustpanCore
import SwiftUI

/// Name a new section, or rename one.
struct SectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: SectionDraft
    @State private var name: String
    @State private var problem: String?

    init(draft: SectionDraft) {
        self.draft = draft
        _name = State(initialValue: draft.section?["name"].string ?? "")
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .onSubmit(save)
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360)
        .navigationTitle(draft.section == nil ? "New Section" : "Rename Section")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.section == nil ? "Add" : "Rename", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try model.saveSection(draft, name: name)
            dismiss()
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
        }
    }
}

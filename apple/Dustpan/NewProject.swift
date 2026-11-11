import DustpanCore
import SwiftUI

/// Create a project: a name, and where it goes. Its colour is the first one no project uses.
struct NewProject: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parentId: String?
    @State private var problem: String?

    init(draft: ProjectDraft) {
        _parentId = State(initialValue: draft.parentId)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .onSubmit(create)
            Picker("Inside", selection: $parentId) {
                Text("No parent").tag(String?.none)
                Divider()
                ForEach(model.snapshot.projectPaths, id: \.id) { Text($0.path).tag(Optional($0.id)) }
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400)
        .navigationTitle("New Project")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: create)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try model.addProject(name, under: parentId)
            dismiss()
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
        }
    }
}

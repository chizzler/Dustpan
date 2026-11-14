import DustpanCore
import SwiftUI

/// Name, colour, icon and parent of a new or existing project. An existing one can be archived or deleted here too.
struct ProjectEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: ProjectDraft
    @State private var name: String
    /// Nil is Theme: no colour of its own.
    @State private var color: String?
    /// A name this Mac can't draw (a newer client's) stays as it is unless another is picked.
    @State private var icon: String?
    @State private var picksIcon = false
    @State private var parentId: String?
    /// The parent as first shown. A parent not offered (archived, say) shows as none, and is only written if
    /// another is picked.
    @State private var shownParent: String?
    @State private var problem: String?

    init(draft: ProjectDraft) {
        self.draft = draft
        _name = State(initialValue: draft.project?["name"].string ?? "")
        _color = State(initialValue: draft.project?["color"].string)
        _icon = State(initialValue: draft.project?["icon"].string)
        _parentId = State(initialValue: draft.project.map { $0["parent_id"].string } ?? draft.parentId)
    }

    var body: some View {
        let parents = parents
        Form {
            TextField("Name", text: $name)
                .onSubmit(save)
            LabeledContent("Colour") {
                HStack(spacing: 6) {
                    Button("Theme") { color = nil }
                        .buttonStyle(Swatch(hex: nil, name: "Theme", chosen: color == nil))
                        .help("Theme: the text colour")
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
                        ProjectMark(color: color, icon: icon)
                    }
                }
                .popover(isPresented: $picksIcon, arrowEdge: .trailing) {
                    IconPicker(icon: $icon, isPresented: $picksIcon, color: color, name: name)
                }
            }
            Picker("Inside", selection: $parentId) {
                Text("No parent").tag(String?.none)
                Divider()
                ForEach(parents, id: \.id) { Text($0.path).tag(Optional($0.id)) }
            }
            if let problem {
                Text(problem).foregroundStyle(.red)
            }
            if let project = draft.project {
                Section {
                    Button("Archive Project") { then { model.archiveProject(project.id) } }
                    Button("Delete Project…", role: .destructive) { then { model.askToDelete(project) } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .navigationTitle(draft.project == nil ? "New Project" : "Edit Project")
        .onAppear(perform: start)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.project == nil ? "Create" : "Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Any visible project but this one and those below it.
    private var parents: [(id: String, path: String)] {
        guard let id = draft.project?.id else { return model.snapshot.projectPaths }
        func ids(_ nodes: [Node]) -> [String] { nodes.flatMap { [$0.id] + ids($0.children) } }
        let skip = Set([id] + ids(model.projectsById[id]?.children ?? []))
        return model.snapshot.projectPaths.filter { !skip.contains($0.id) }
    }

    private func start() {
        if let id = parentId, !parents.contains(where: { $0.id == id }) { parentId = nil }
        shownParent = parentId
        // A new project starts with the first colour no project uses.
        if draft.project == nil {
            color = unusedProjectColour(model.snapshot.liveProjects)
        }
    }

    private func showPicker() { picksIcon = true }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try model.saveProject(draft.project, name: name, color: color, icon: icon,
                                  parentId: draft.project == nil || parentId != shownParent ? .some(parentId) : nil)
            dismiss()
        } catch {
            problem = (error as? CannotEdit)?.message ?? "\(error)"
        }
    }

    private func then(_ action: () -> Void) {
        dismiss()
        action()
    }
}

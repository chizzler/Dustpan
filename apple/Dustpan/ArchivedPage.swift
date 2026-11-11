import DustpanCore
import SwiftUI

/// An archived project's page: its tasks are hidden until it's unarchived.
struct ArchivedPage: View {
    @Environment(AppModel.self) private var model
    let projectId: String

    var body: some View {
        let project = model.snapshot.archivedProjects.first { $0.row.id == projectId }
        ContentUnavailableView {
            Label(project?.row["name"].string ?? "Archived", systemImage: "archivebox")
        } description: {
            Text("This project is archived. Its tasks are hidden until it's unarchived.")
        } actions: {
            if let project {
                Button("Unarchive") { model.unarchiveProject(projectId) }
                    .buttonStyle(.borderedProminent)
                Button("Delete Project…", role: .destructive) { model.askToDelete(project.row) }
            }
        }
        .navigationTitle(project?.path ?? "Archived")
    }
}

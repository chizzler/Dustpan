import DustpanCore
import SwiftUI

/// An archived project's page: its tasks are hidden until it's unarchived.
struct ArchivedPage: View {
    @Environment(AppModel.self) private var model
    let projectId: String

    var body: some View {
        let project = model.snapshot.archivedProjects.first { $0.row.id == projectId }
        ContentUnavailableView {
            Label("Archived", systemImage: "archivebox")
        } description: {
            Text("This project is archived. Its tasks are hidden until it's unarchived.")
        } actions: {
            if let project {
                Button("Unarchive", action: unarchive)
                    .buttonStyle(.borderedProminent)
                Button("Delete Project…", role: .destructive) { model.askToDelete(project.row) }
            }
        }
        .safeAreaInset(edge: .top) {
            PageHeading(head: model.pageHead(.archived(projectId)))
                .padding(.horizontal, 20)
        }
        .navigationTitle("")
    }

    private func unarchive() { model.unarchiveProject(projectId) }
}

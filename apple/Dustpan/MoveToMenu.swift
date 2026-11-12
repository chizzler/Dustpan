import DustpanCore
import SwiftUI

/// Move To in a task's menu: the Inbox and every project, as a drag to the sidebar would place the task.
/// A project with sections lists them.
struct MoveToMenu: View {
    @Environment(AppModel.self) private var model
    let taskId: String

    var body: some View {
        Menu("Move To") {
            Button("Inbox") { model.drop(taskId, on: .place(Placement(nil, nil))) }
            ForEach(model.snapshot.projectPaths, id: \.id) { project in
                let sections = model.snapshot.sectionsByProject[project.id] ?? []
                if sections.isEmpty {
                    Button(project.path) { model.drop(taskId, on: .place(Placement(project.id, nil))) }
                } else {
                    Menu(project.path) {
                        Button("No Section") { model.drop(taskId, on: .place(Placement(project.id, nil))) }
                        ForEach(sections) { section in
                            Button(section["name"].string ?? "") {
                                model.drop(taskId, on: .place(Placement(project.id, section.id)))
                            }
                        }
                    }
                }
            }
        }
    }
}

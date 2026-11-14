import DustpanCore
import Foundation

extension AppModel {
    /// The large heading at the top of a page: a project's icon, name and where it sits, or a page's symbol.
    func pageHead(_ page: Page) -> PageHead {
        let snap = snapshot
        switch page {
        case .today:
            let count = todayCount(snap.tasks, today: today)
            return PageHead(eyebrow: today.noon.formatted(.dateTime.weekday(.wide).day().month(.wide)), title: page.name,
                            mark: .symbol(page.symbol), meta: count == 0 ? "Nothing to do" : "\(count) to do")
        case .inbox:
            // Everything open on the page, planned or not. The sidebar counts only the unplanned.
            return PageHead(title: page.name, mark: .symbol(page.symbol),
                            meta: PageHead.open(countListed(snap, nil, today: today.description)))
        case .project(let id):
            guard let node = projectsById[id] else { return PageHead(title: "Project") }
            let parentId = node.row["parent_id"].string
            return PageHead(eyebrow: parentId.map(projectPath) ?? "Project",
                            title: node.row["name"].string ?? "", mark: .project(node.row),
                            meta: PageHead.open(countOpen(snap, id, today: today.description)),
                            places: node.children.map(\.row),
                            parent: parentId.flatMap { projectsById[$0]?.row })
        case .archived(let id):
            guard let project = snap.archivedProjects.first(where: { $0.row.id == id })?.row else {
                return PageHead(title: "Archived")
            }
            return PageHead(eyebrow: "Archived project", title: project["name"].string ?? "", mark: .project(project))
        case .label(let id):
            guard let label = snap.labels[id] else { return PageHead(title: "Label") }
            return PageHead(eyebrow: "Label", title: label["name"].string ?? "",
                            mark: .label(color: label["color"].string),
                            meta: PageHead.open(labelCounts(snap.tasks, today: today)[id] ?? 0))
        case .view(let id):
            let view = snap.views.first { $0.id == id }
            return PageHead(eyebrow: "Saved view", title: view?["name"].string ?? "View", mark: .symbol(page.symbol))
        case .upcoming, .anytime, .completed, .filter, .trash:
            return PageHead(title: page.name, mark: .symbol(page.symbol))
        }
    }
}

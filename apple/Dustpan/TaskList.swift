import DustpanCore
import SwiftUI

struct TaskList: View {
    @Environment(AppModel.self) private var model
    let page: Page

    var body: some View {
        let snap = model.snapshot
        let (title, projectId) = heading
        let sections = projectSections(snap, projectId)
        Group {
            if sections.allSatisfy(\.tasks.isEmpty) && sections.count == 1 {
                ContentUnavailableView("Nothing here", systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        if section.name.isEmpty {
                            rows(section.tasks)
                        } else {
                            Section(section.name) { rows(section.tasks) }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    /// The page's title and project. A project that's gone shows the Inbox.
    private var heading: (String, String?) {
        if case .project(let id) = page, let node = model.projectsById[id] {
            return (node.row["name"].string ?? "", id)
        }
        return ("Inbox", nil)
    }

    private func rows(_ nodes: [Node]) -> some View {
        ForEach(flatten(nodes, depth: 0), id: \.node.id) { item in
            TaskRow(task: item.node.row, labels: model.snapshot.labels)
                .padding(.leading, CGFloat(item.depth) * 24)
        }
    }

    private func flatten(_ nodes: [Node], depth: Int) -> [(node: Node, depth: Int)] {
        nodes.flatMap { [($0, depth)] + flatten($0.children, depth: depth + 1) }
    }
}

struct TaskRow: View {
    let task: Row
    let labels: [String: Row]

    var body: some View {
        let done = !task["completed_at"].isNull
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(priorityColor)
                .fontWeight(task["priority"].int.map { $0 < 4 } == true ? .bold : .regular)
            VStack(alignment: .leading, spacing: 3) {
                Text(task["title"].string ?? "")
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                details.font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var details: some View {
        let due = formatDue(task["due"])
        let estimate = task["estimate_minutes"].int
        let chips = (task["labels"].array ?? []).compactMap { $0.string.flatMap { labels[$0] } }
        if due != nil || estimate != nil || !chips.isEmpty {
            HStack(spacing: 10) {
                if let due {
                    Label(due.text, systemImage: "calendar")
                        .foregroundStyle(due.state == .overdue ? .red : due.state == .today ? .green : .secondary)
                }
                if let estimate {
                    Label(formatMinutes(Int(estimate)), systemImage: "timer").foregroundStyle(.secondary)
                }
                ForEach(chips, id: \.id) { label in
                    let color = Color(hex: label["color"].string) ?? .secondary
                    Text(label["name"].string ?? "")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(color)
                        .background(color.opacity(0.15), in: Capsule())
                }
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private var priorityColor: Color {
        switch task["priority"].int {
        case 1: .red
        case 2: .orange
        case 3: .blue
        default: .secondary
        }
    }
}

extension Color {
    /// "#rrggbb" or "#rgb", as the server stores colours. Nil for anything else.
    init?(hex: String?) {
        guard var hex = hex, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

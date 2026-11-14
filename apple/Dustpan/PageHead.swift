import DustpanCore

/// What a page's heading says (spec/pagehead.md). `AppModel.pageHead` gathers it.
struct PageHead {
    enum Mark {
        /// A project's icon, or its dot.
        case project(Row)
        case label(color: String?)
        /// An SF Symbol, in the accent colour.
        case symbol(String)
    }

    var eyebrow: String?
    var title: String
    var mark: Mark?
    /// A dim count under the title.
    var meta: String?
    /// Sub-projects to open.
    var places: [Row] = []
    /// Makes the eyebrow a link: the parent project.
    var up: Page?

    /// "3 open tasks", or "Nothing open".
    static func open(_ count: Int) -> String {
        count == 0 ? "Nothing open" : "\(count) open task\(count == 1 ? "" : "s")"
    }
}

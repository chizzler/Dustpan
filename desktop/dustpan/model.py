"""What the UI shows, derived from the store. See spec/sync.md, "Display rules".

Nothing here writes: odd states (missing parents, cycles, stale sections)
are resolved for display only, the same way on every device.
"""

from dataclasses import dataclass, field

from .store import Clock, wins
from .views import is_inbox_task, is_list_view, open_count, view_order


@dataclass
class Node:
    row: object
    children: list = field(default_factory=list)

    @property
    def id(self):
        return self.row.id


@dataclass
class Section:
    id: str | None
    name: str
    tasks: list  # Nodes
    is_list: bool = True  # a real list: tasks are added, ordered and dropped here


@dataclass
class Snapshot:
    projects: list  # Nodes, top level
    labels: dict  # id -> Row
    tasks_by_project: dict  # open tasks: project id or None (no project) -> [Row]
    sections_by_project: dict  # project id -> [Row]
    tasks: list  # live tasks outside archived and deleted projects, completed too
    all_tasks: dict  # id -> Row, every task
    live_projects: list  # Rows, archived too
    views: list  # live list views, in sidebar order


def order_key(row):
    position = row.get("position")
    return (position if isinstance(position, (int, float)) else 0, row.id)


def parent_clock_key(row):
    clock = row.clocks.get("parent_id") or Clock(0, "")
    return (clock.ts, clock.device, row.id)


def newer_parent_clock(a, b):
    ka, kb = parent_clock_key(a), parent_clock_key(b)
    return wins(ka[0], ka[1], kb[0], kb[1]) or (ka[:2] == kb[:2] and ka[2] > kb[2])


def build_tree(rows, parent_of):
    """Nest rows by parent_of(row) -> parent id or None.

    A row whose parent isn't in rows is a root. In a cycle, the member whose
    parent_id has the newest clock becomes a root and the rest hang below it.
    """
    by_id = {row.id: row for row in rows}
    parent = {}
    for row in rows:
        pid = parent_of(row)
        parent[row.id] = pid if pid in by_id and pid != row.id else None

    for start in by_id:
        seen = []
        node = start
        while node is not None and node not in seen:
            seen.append(node)
            node = parent[node]
        if node is not None:
            cycle = seen[seen.index(node):]
            root = cycle[0]
            for member in cycle[1:]:
                if newer_parent_clock(by_id[member], by_id[root]):
                    root = member
            parent[root] = None

    nodes = {row_id: Node(row) for row_id, row in by_id.items()}
    roots = []
    for row_id, node in nodes.items():
        pid = parent[row_id]
        (nodes[pid].children if pid else roots).append(node)

    def sort(level):
        level.sort(key=lambda n: order_key(n.row))
        for n in level:
            sort(n.children)

    sort(roots)
    return roots


def live(row):
    return row.get("deleted_at") is None


def snapshot(store):
    """Read everything the UI needs in one pass over the store."""
    projects = store.rows("project")
    tasks = store.rows("task")
    sections = store.rows("section")
    labels = {i: r for i, r in store.rows("label").items() if live(r)}

    visible_projects = [p for p in projects.values() if live(p) and not p.get("archived")]
    visible_ids = {p.id for p in visible_projects}

    listed = [t for t in tasks.values() if live(t) and (t.get("project_id") is None or t.get("project_id") in visible_ids)]
    tasks_by_project = {}
    for task in listed:
        if task.get("completed_at") is None:
            tasks_by_project.setdefault(task.get("project_id"), []).append(task)

    sections_by_project = {}
    for sec in sections.values():
        if live(sec):
            sections_by_project.setdefault(sec.get("project_id"), []).append(sec)
    for secs in sections_by_project.values():
        secs.sort(key=order_key)

    return Snapshot(
        projects=build_tree(visible_projects, lambda p: p.get("parent_id")),
        labels=labels,
        tasks_by_project=tasks_by_project,
        sections_by_project=sections_by_project,
        tasks=listed,
        all_tasks=tasks,
        live_projects=[p for p in projects.values() if live(p)],
        views=sorted((v for v in store.rows("view").values() if is_list_view(v)), key=view_order),
    )


def project_sections(snap, project_id):
    """Sections of a project, each with its task trees. "No section" first.

    For the Inbox (None): its tasks, then the planned tasks without a project.
    """
    rows = snap.tasks_by_project.get(project_id, [])
    roots = build_tree(rows, lambda t: t.get("parent_id"))
    if project_id is None:
        inbox = [n for n in roots if is_inbox_task(n.row, snap.all_tasks.get)]
        planned = [n for n in roots if not is_inbox_task(n.row, snap.all_tasks.get)]
        return [Section(None, "", inbox)] + ([Section(None, "Planned, no project", planned, False)] if planned else [])
    secs = snap.sections_by_project.get(project_id, [])
    known = {s.id for s in secs}

    grouped = {}
    for node in roots:
        sid = node.row.get("section_id")
        grouped.setdefault(sid if sid in known else None, []).append(node)

    result = [Section(None, "", grouped.get(None, []))]
    result += [Section(s.id, s.get("name", ""), grouped.get(s.id, [])) for s in secs]
    return result


def project_path(project_id, projects):
    """ "Parent › Child": the project's name after its live ancestors'. projects: id -> Row."""
    names, seen = [], set()
    while project_id and project_id not in seen:
        seen.add(project_id)
        row = projects.get(project_id)
        if row is None or not live(row):
            break
        names.append(row.get("name", ""))
        project_id = row.get("parent_id")
    return " › ".join(reversed(names))


def count_open(snap, project_id, today):
    """The sidebar count: open, neither parked nor deferred. For the Inbox, its own tasks."""
    rows = snap.tasks_by_project.get(project_id, [])
    if project_id is None:
        return sum(is_inbox_task(t, snap.all_tasks.get) for t in rows)
    return sum(open_count(t, today) for t in rows)

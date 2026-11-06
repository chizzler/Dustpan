"""What the UI shows, derived from the store. See spec/sync.md, "Display rules".

Nothing here writes: odd states (missing parents, cycles, stale sections)
are resolved for display only, the same way on every device.
"""

from dataclasses import dataclass, field

from .store import Clock, wins
from .views import is_inbox_task, is_list_view, open_count, view_order

CLEARED_SUBTASKS = "cleared_completed_subtasks"  # per-device display choice
FOLDED_TASKS = "folded_tasks"  # per-device display choice: ids of tasks whose subtasks are folded away


def folded_after(folded, task_id, fold, tasks):
    """The folded ids once task_id is folded (fold) or unfolded, without ids of tasks that are gone.

    tasks: every task by id. Kept in the order they were folded, so the stored list changes little.
    """
    kept = [i for i in folded if i in tasks and i != task_id]
    return kept + [task_id] if fold and task_id in tasks else kept


def unfolded_down_to(folded, parent_id, tasks):
    """The folded ids with parent_id and every task above it unfolded: a task put under parent_id stays in sight."""
    above = set()
    while parent_id and parent_id not in above:  # a cycle in the data ends the walk
        above.add(parent_id)
        parent_id = (tasks.get(parent_id) or {}).get("parent_id")
    return [i for i in folded if i not in above]


def completed_subtask_visible(task, cleared):
    return (task.get("completed_at") is not None and task.get("parent_id") and
            cleared.get(task.id) != [task.get("completed_at"), task.get("parent_id")])


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


@dataclass(frozen=True)
class Progress:
    done: int = 0
    total: int = 0
    swept: int = 0  # done ones the broom hid on this device; still counted

    def text(self):
        swept = f" ({self.swept} swept)" if self.swept else ""
        return f"{self.done} of {self.total} subtask{'s' if self.total > 1 else ''} completed{swept}"


def progress_map(tasks, cleared=None):
    """Each parent's progress over its direct, live subtasks: the web app's progressMap. See spec/progress.md.

    tasks: every task. Parents without live subtasks are absent.
    """
    cleared = cleared or {}
    counts = {}
    for task in tasks:
        parent = task.get("parent_id")
        if not parent or not live(task):
            continue
        done, total, swept = counts.get(parent, (0, 0, 0))
        if task.get("completed_at") is not None:
            done += 1
            swept += not completed_subtask_visible(task, cleared)
        counts[parent] = (done, total + 1, swept)
    return {parent: Progress(*c) for parent, c in counts.items()}


def is_ready(parent, tasks):
    """An open, live parent whose live subtasks are all done: ready to be offered for completion.

    tasks: every task by id. Nothing completes it by itself (upstream design D5).
    """
    if parent is None or not live(parent) or parent.get("completed_at") is not None:
        return False
    children = [t for t in tasks.values() if t.get("parent_id") == parent.id and live(t)]
    return bool(children) and all(t.get("completed_at") is not None for t in children)


def ready_parent(task_id, tasks):
    """After task_id was completed: its parent if that is now ready, else None."""
    parent = tasks.get((tasks.get(task_id) or {}).get("parent_id"))
    return parent if is_ready(parent, tasks) else None


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


def sink_completed(nodes, settling=None):
    """Each task's completed subtasks after its open ones, both in their own order. Display only: positions don't change.

    settling: {task id: whether it sorts as done}, for tasks just ticked or reopened. They keep the place they had
    until the window lets them settle.
    """
    settling = settling or {}

    def done(node):
        return settling.get(node.id, node.row.get("completed_at") is not None)

    for node in nodes:
        node.children.sort(key=done)  # stable: the order within open and within done is kept
        sink_completed(node.children, settling)
    return nodes


def project_sections(snap, project_id, cleared=None, settling=None):
    """Sections of a project, each with its task trees. "No section" first.

    For the Inbox (None): its tasks, then the planned tasks without a project.
    Completed subtasks come after open ones (sink_completed).
    """
    # Completed subtasks stay beneath an open ancestor until the user sweeps
    # them away. Completed top-level tasks still belong only in Completed.
    cleared = cleared or {}
    rows = [t for t in snap.tasks if t.get("project_id") == project_id and
            (t.get("completed_at") is None or completed_subtask_visible(t, cleared))]
    by_id = {t.id: t for t in rows}
    def visible_parent(task):
        parent = by_id.get(task.get("parent_id"))
        if parent is None or (task.get("completed_at") is None and parent.get("completed_at") is not None):
            return None
        return parent.id

    roots = sink_completed([n for n in build_tree(rows, visible_parent) if n.row.get("completed_at") is None], settling)
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

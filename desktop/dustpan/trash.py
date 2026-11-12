"""The Trash: deleted tasks and projects, with local or server-synced permanent deletion.

Restoring is an ordinary write (writes.py). In standalone mode, permanent deletion
removes the entity, its cascaded children and any queued ops locally at once.
When connected to OpenTodo, permanent deletion is queued here and sent after a sync
has pushed the outbox, then every device drops the entities when sync names them in `purged`.
"""

from dataclasses import dataclass

from .api import ApiError
from .model import build_tree

DAY_MS = 86_400_000
DEFAULT_RETENTION_DAYS = 30
RETENTION = "trash_retention_days"  # store meta: days an item stays in the Trash, as the server last said; 0 = never
PENDING = "pending_purges"  # store meta: [[entity, id]] to delete permanently once the server can be reached
PROJECT_CHILDREN = ("section", "field", "note", "rule")
TASK_CHILDREN = ("reminder", "comment", "attachment", "time_entry")


@dataclass
class Item:
    entity: str  # "task" or "project"
    id: str
    title: str
    deleted_at: int
    project_name: str | None = None  # for tasks: their project, None for the Inbox
    color: str | None = None  # for projects
    subtasks: int = 0  # deleted with this task, and restored with it


def deleted_with(task, tasks):
    """The deleted tasks below task that went with it: same deletion time, all the way down. Safe against cycles."""
    children = {}
    for t in tasks.values():
        if t.get("parent_id") and t.get("deleted_at") == task.get("deleted_at"):
            children.setdefault(t.get("parent_id"), []).append(t)
    found, stack, seen = [], [task.id], {task.id}
    while stack:
        for child in children.get(stack.pop(), []):
            if child.id not in seen:
                seen.add(child.id)
                found.append(child)
                stack.append(child.id)
    return found


def items(tasks, projects):
    """Deleted projects and tasks, newest deletion first.

    A subtask deleted with its parent is folded into the parent's item. The web app lists it on its own too.
    Tasks of a deleted project aren't deleted themselves: they come back with the project, so only it is listed.
    """
    out = []
    for p in projects.values():
        if p.get("deleted_at") is not None:
            out.append(Item("project", p.id, p.get("name") or "Untitled project", p.get("deleted_at"),
                            color=p.get("color")))
    deleted = [t for t in tasks.values() if t.get("deleted_at") is not None]

    def parent_of(task):
        parent = tasks.get(task.get("parent_id"))
        return parent.id if parent is not None and parent.get("deleted_at") == task.get("deleted_at") else None

    for node in build_tree(deleted, parent_of):
        t = node.row
        project = projects.get(t.get("project_id"))
        out.append(Item("task", t.id, t.get("title") or "Untitled", t.get("deleted_at"),
                        project_name=project.get("name", "") if project is not None else None,
                        subtasks=len(deleted_with(t, tasks))))
    out.sort(key=lambda i: (-i.deleted_at, i.id))
    return out


def remaining_days(deleted_at, retention, now):
    """Whole days until the server deletes an item for good, or None when it never does."""
    if not retention or retention <= 0:
        return None
    return max(0, -(-(deleted_at + retention * DAY_MS - now) // DAY_MS))


def pending(store):
    return {(entity, entity_id) for entity, entity_id in store.get_meta(PENDING) or []}


def queue(store, targets):
    """Ask for a permanent delete of each (entity, id). Sent by the next sync."""
    with store.transaction():
        have = store.get_meta(PENDING) or []
        known = {tuple(p) for p in have}
        for target in targets:
            if tuple(target) not in known:
                have.append(list(target))
                known.add(tuple(target))
        store.set_meta(PENDING, have)


def send(store, api):
    """Send the queued permanent deletes. Returns how many the server took.

    Call it after a sync has pushed the outbox, so the server already has the delete.
    A request for something restored since, or already gone, is dropped. Temporary
    failures keep the request and raise, so the caller can show the sync error.
    Acknowledgements remove only that request, never ones queued during a call.
    """
    sent = 0
    queued = store.get_meta(PENDING) or []
    for entity, entity_id in queued:
        refused = None
        row = store.rows(entity).get(entity_id)
        if row is not None and row.get("deleted_at") is not None:
            # A server limit, or an edit made during sync, may leave its delete unsent.
            waiting = [op for _, op in store.outbox_batch(store.outbox_count())]
            waiting += store.get_meta("held_ops", [])
            if any(op["entity"] == entity and op["entityId"] == entity_id for op in waiting):
                continue
            try:
                api.purge(entity, entity_id)
                sent += 1
            except ApiError as err:
                if err.status not in (403, 404) and err.code != "not_deleted":
                    raise
                if err.status == 403:
                    refused = err
            # Offline propagates too, leaving this and all later requests queued.
        with store.transaction():
            have = store.get_meta(PENDING) or []
            store.set_meta(PENDING, [p for p in have if p != [entity, entity_id]])
        if refused is not None:
            raise refused
    return sent


def expand_purge(store, targets):
    """Expand trashed (entity, id) targets with the cascades of OpenTodo's expandPurge.

    Missing or live (restored) targets are skipped. Purging a project removes all of
    its tasks, sections and project-scoped rows; purging a task removes its deleted
    descendants (even ones deleted separately) and its reminders, comments, attachments
    and time entries.
    """
    rows_cache = {}

    def rows_of(entity):
        if entity not in rows_cache:
            rows_cache[entity] = store.rows(entity)
        return rows_cache[entity]

    seen = set()
    out = []
    purged_tasks = []

    def add(entity, entity_id):
        key = (entity, entity_id)
        if key in seen:
            return False
        seen.add(key)
        out.append(key)
        return True

    for entity, entity_id in targets:
        if entity not in ("task", "project", "note"):
            continue
        row = rows_of(entity).get(entity_id)
        if row is None or row.get("deleted_at") is None:
            continue
        if not add(entity, entity_id):
            continue
        if entity == "task":
            purged_tasks.append(entity_id)
        elif entity == "project":
            for tid, task in rows_of("task").items():
                if task.get("project_id") == entity_id and add("task", tid):
                    purged_tasks.append(tid)
            for child in PROJECT_CHILDREN:
                for cid, crow in rows_of(child).items():
                    if crow.get("project_id") == entity_id:
                        add(child, cid)
            if entity_id in rows_of("project_prefs"):
                add("project_prefs", entity_id)

    deleted_children = {}
    for tid, task in rows_of("task").items():
        if task.get("parent_id") and task.get("deleted_at") is not None:
            deleted_children.setdefault(task.get("parent_id"), []).append(tid)
    i = 0
    while i < len(purged_tasks):
        for cid in deleted_children.get(purged_tasks[i], ()):
            if add("task", cid):
                purged_tasks.append(cid)
        i += 1

    task_set = set(purged_tasks)
    if task_set:
        for child in TASK_CHILDREN:
            for cid, crow in rows_of(child).items():
                if crow.get("task_id") in task_set:
                    add(child, cid)
    return out


def purge_local(store, targets):
    """Permanently delete trashed targets and their cascaded data locally in one transaction."""
    target_set = {(entity, entity_id) for entity, entity_id in targets}
    with store.transaction():
        expanded = expand_purge(store, targets)
        gone = set(expanded)
        for entity, entity_id in expanded:
            store.purge(entity, entity_id)
        if held := store.get_meta("held_ops"):
            store.set_meta("held_ops", [op for op in held if (op["entity"], op["entityId"]) not in gone])
        if have := store.get_meta(PENDING):
            drop = target_set | gone
            store.set_meta(PENDING, [p for p in have if tuple(p) not in drop])
        return len(expanded)

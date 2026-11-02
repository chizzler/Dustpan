"""Drag and drop rules: where a drop lands, the keyboard moves that do the same, and what they mean. No GTK here.

See spec/dragdrop.md. A list hands in its rows as Slots and the pointer as a hit, a zone and a level;
resolve() returns the Drop to show and write. nudge() gives the same targets for a key. Writer.drop() turns a
target into one batch.
"""

from dataclasses import dataclass

BEFORE, INSIDE, AFTER = "before", "inside", "after"
HEAD, END = "head", "end"  # a hit on a list's heading, or past its last row


# ---- targets: what a drop writes ----


@dataclass(frozen=True)
class Place:
    """A place in a project's (or the Inbox's) list: under parent_id, or at the top level of section_id.

    before or after names a sibling; neither means the end of the list.
    """

    project_id: str | None
    section_id: str | None
    parent_id: str | None = None
    before: str | None = None
    after: str | None = None


@dataclass(frozen=True)
class ToProject:
    """The end of a project's list, out of any section and parent. None is the Inbox."""

    project_id: str | None


@dataclass(frozen=True)
class ToDay:
    """Due on day (ISO), keeping any time and zone."""

    day: str


@dataclass(frozen=True)
class ToLabel:
    """The label added to the task's own. Its place, project and dates stay."""

    label_id: str


# ---- a list as the pointer sees it ----


@dataclass(frozen=True)
class Slot:
    """A task row in display order: its depth in the tree and its parent."""

    id: str
    depth: int
    parent_id: str | None = None


@dataclass(frozen=True)
class Drop:
    """A resolved drop: the target, and how to show it.

    ring: the row to ring for a drop inside it. Otherwise a line at depth, below the row prev
    (or above the row next, or under the heading when the list is empty).
    """

    target: object
    ring: str | None = None
    prev: str | None = None
    next: str | None = None
    depth: int = 0


def zone(y, height, inside=True):
    """The zone of a row for a pointer y pixels below its top. OpenTodo's listDrop.dropZone.

    With nesting, the top and bottom quarters place before and after and the middle half nests inside.
    Without it, the halves.
    """
    f = y / height if height > 0 else 0
    if not inside:
        return BEFORE if f < 0.5 else AFTER
    return BEFORE if f < 0.25 else AFTER if f > 0.75 else INSIDE


def level(x, indent):
    """The tree level a dragged row's left edge, x pixels from the list's left, points at."""
    return round(x / indent)


def without_subtree(rows, task_id):
    """rows minus task_id and everything under it, and the index where it was (None when absent)."""
    kept, at, skip = [], None, None
    for slot in rows:
        if skip is not None and slot.depth > skip:
            continue
        skip = None
        if slot.id == task_id:
            at, skip = len(kept), slot.depth
            continue
        kept.append(slot)
    return kept, at


def resolve(rows, project_id, section_id, hit, where, depth, moving):
    """The drop for a pointer over one list.

    rows: the list's Slots in display order. hit: an index into rows, HEAD or END.
    where: the zone for a row hit. depth: the level the pointer picks. moving: the dragged task's id.
    A hit on the dragged task or its subtree means the gap it left, so dragging sideways in place
    changes its level. Returns None when there's nothing to drop on.
    """
    kept, at = without_subtree(rows, moving)
    if hit == HEAD:
        gap = 0
    elif hit == END:
        gap = len(kept)
    else:
        slot = rows[hit]
        if slot in kept:
            if where == INSIDE:
                return Drop(Place(project_id, section_id, slot.id), ring=slot.id)
            gap = kept.index(slot) + (where == AFTER)
        else:
            gap = at
    return at_gap(kept, project_id, section_id, gap, depth)


def at_gap(rows, project_id, section_id, gap, depth):
    """The drop into the gap before rows[gap], at the level depth picks.

    The level is held between the row below's depth (it can't be orphaned) and the row above's depth.
    Below an open parent that range is just its children's level: the top of its subtasks.
    """
    prev = rows[gap - 1] if gap > 0 else None
    nxt = rows[gap] if gap < len(rows) else None
    low = nxt.depth if nxt else 0
    depth = max(low, min(depth, max(prev.depth if prev else 0, low)))
    if nxt and depth == nxt.depth:
        target = Place(project_id, section_id, nxt.parent_id, before=nxt.id)
    elif prev is None:
        target = Place(project_id, section_id)
    else:
        # After the ancestor of prev (or prev itself) that sits at this level.
        by_id = {slot.id: slot for slot in rows}
        anchor = prev
        while anchor.depth > depth:
            anchor = by_id[anchor.parent_id]
        target = Place(project_id, section_id, anchor.parent_id, after=anchor.id)
    return Drop(target, prev=prev and prev.id, next=nxt and nxt.id, depth=depth)


# ---- sidebar rows: projects, labels and views ----


@dataclass(frozen=True)
class ItemPlace:
    """Where a dragged sidebar item lands among its own kind: under parent_id (projects only),
    right before or after a sibling, or last when neither is named."""

    parent_id: str | None = None
    before: str | None = None
    after: str | None = None


def place_item(row_id, row_parent, row_children, where, moving, below=()):
    """The ItemPlace for a drop on a sidebar row, or None.

    row_children: the row's shown children, in order (projects). where: BEFORE, AFTER, or INSIDE to nest.
    below: the ids under the dragged item. It can't land on itself or inside its own subtree.
    After a row whose children are shown means above its first child, where the line is drawn.
    """
    if row_id == moving or row_id in below:
        return None
    if where == INSIDE:
        return ItemPlace(parent_id=row_id)
    if where == AFTER and row_children:
        first = next((c for c in row_children if c != moving), None)
        return ItemPlace(parent_id=row_id, before=first)
    side = "before" if where == BEFORE else "after"
    return ItemPlace(parent_id=row_parent, **{side: row_id})


# ---- the same moves by keyboard ----

UP, DOWN, TOP, BOTTOM, INDENT, OUTDENT = "up", "down", "top", "bottom", "indent", "outdent"
MOVES = (UP, DOWN, TOP, BOTTOM, INDENT, OUTDENT)


def nudge(rows, project_id, section_id, task_id, move):
    """The Place a keyboard move gives a task in one list, or None when it can't go that way.

    Up, down, top and bottom stay among its siblings, as the web app's Alt+arrows do. Indent makes it the last
    subtask of the sibling above (Tab). Outdent puts it right after its old parent, where dragging it left would.
    """
    by_id = {slot.id: slot for slot in rows}
    slot = by_id.get(task_id)
    if slot is None:
        return None
    siblings = [s for s in rows if s.parent_id == slot.parent_id and s.depth == slot.depth]
    i = siblings.index(slot)
    last = len(siblings) - 1

    def place(parent_id=slot.parent_id, **anchor):
        return Place(project_id, section_id, parent_id, **anchor)

    if move == UP and i > 0:
        return place(before=siblings[i - 1].id)
    if move == DOWN and i < last:
        return place(after=siblings[i + 1].id)
    if move == TOP and i > 0:
        return place(before=siblings[0].id)
    if move == BOTTOM and i < last:
        return place(after=siblings[last].id)
    if move == INDENT and i > 0:
        return place(siblings[i - 1].id)
    if move == OUTDENT and slot.parent_id in by_id:
        parent = by_id[slot.parent_id]
        return place(parent.parent_id, after=parent.id)
    return None


# ---- what to say afterwards ----


def describe(target, task, names, day_text):
    """The toast after a drop. names maps task, section and project ids to titles and names."""
    if isinstance(target, ToDay):
        return "Due " + day_text(target.day)
    if isinstance(target, ToProject):
        return "Moved to " + names.get(target.project_id, "Inbox")
    if isinstance(target, ToLabel):
        return "Added " + names.get(target.label_id, "the label")
    if target.parent_id and target.parent_id != task.get("parent_id"):
        return f"Moved under “{names.get(target.parent_id, 'a task')}”"
    if target.project_id != task.get("project_id"):
        return "Moved to " + names.get(target.project_id, "Inbox")
    if not target.parent_id and task.get("parent_id"):
        return "Moved out of “{}”".format(names.get(task.get("parent_id"), "its parent"))
    if not target.parent_id and target.section_id != task.get("section_id"):
        return "Moved to " + names.get(target.section_id, "No section")
    return "Order changed"

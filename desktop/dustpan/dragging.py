"""Drag and drop in GTK: task sources, page and sidebar targets, the drop line, autoscroll. See spec/dragdrop.md.

The rules are in dragdrop.py. The handlers here only measure widgets and hand numbers over, so
hover() and drop() can be driven by a script as well as by a real pointer.
"""

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, GObject, Gtk, Pango  # noqa: E402

from .dragdrop import END, HEAD, Drop, level, resolve, zone  # noqa: E402
from .widgets import INDENT_PX  # noqa: E402

EDGE_PX = 50  # autoscroll starts this close to an edge (Nautilus found 20 px too small to discover)
MAX_SCROLL_PX_S = 1200
SPRING_MS = 700  # hovering a sidebar row this long opens its page


def bounds(widget, ancestor):
    """widget's (x, y, width, height) in ancestor's coordinates."""
    ok, rect = widget.compute_bounds(ancestor)
    return (rect.get_x(), rect.get_y(), rect.get_width(), rect.get_height()) if ok else None


class Drag:
    """The task drag in progress. One per window: every source and target shares it.

    on_end runs when a drag finishes, dropped or not.
    """

    def __init__(self, on_end):
        self.task_id = None
        self.grab_x = 0  # where the pointer held the row, from the row's left edge
        self.on_end = on_end

    @property
    def active(self):
        return self.task_id is not None

    def source(self, widget, task_id, title, subtasks=lambda: 0):
        """Let widget be dragged as task_id. subtasks() counts what travels with it, for the drag preview."""
        source = Gtk.DragSource(actions=Gdk.DragAction.MOVE)
        held = {}

        def prepare(_source, x, _y):
            held["x"] = x
            return Gdk.ContentProvider.new_for_value(task_id)

        def begin(_source, drag):
            self.task_id, self.grab_x = task_id, held.get("x", 0)
            Gtk.DragIcon.get_for_drag(drag).set_child(preview(title, subtasks()))
            drag.set_hotspot(-16, -8)
            widget.add_css_class("dragging")

        def end(*_args):
            widget.remove_css_class("dragging")
            self.task_id = None
            self.on_end()

        source.connect("prepare", prepare)
        source.connect("drag-begin", begin)
        source.connect("drag-end", end)
        widget.add_controller(source)

    def accepts(self, value):
        """Only our own drags: text dragged in from another app is no task id."""
        return self.active and value in (None, self.task_id)


def preview(title, subtasks):
    """The drag image: a small pill with the title, and "+N" for the subtasks that come along."""
    pill = Gtk.Box(spacing=8, css_classes=["drag-pill"])
    pill.append(Gtk.Label(label=title, max_width_chars=32, ellipsize=Pango.EllipsizeMode.END))
    if subtasks:
        pill.append(Gtk.Label(label=f"+{subtasks}", css_classes=["dim-label"]))
    return pill


class _List:
    """One list on a page: a project's section, or the Inbox."""

    def __init__(self, project_id, section_id, heading, rows, end):
        self.project_id, self.section_id, self.heading, self.end = project_id, section_id, heading, end
        self.slots = [slot for slot, _ in rows]
        self.widgets = {slot.id: widget for slot, widget in rows}


class PageDrop:
    """One drop target over a whole page, so the line never drops out in the gaps between rows.

    Lists place, nest and outdent. Groups are a single target each, such as a day in Upcoming.
    on_drop(task_id, target) gets a dragdrop target.
    """

    def __init__(self, column, drag, on_drop):
        self.column, self.drag, self.on_drop = column, drag, on_drop
        self.widget = Gtk.Overlay(child=column)
        self.line = Gtk.Box(halign=Gtk.Align.START, valign=Gtk.Align.START, can_target=False, visible=False,
                            css_classes=["drop-line"])
        self.line.append(Gtk.Box(valign=Gtk.Align.CENTER, css_classes=["drop-dot"]))
        self.line.append(Gtk.Box(valign=Gtk.Align.CENTER, hexpand=True, css_classes=["drop-stroke"]))
        self.widget.add_overlay(self.line)
        self.hits = []  # (widget, owner, hit): hit is a row index, HEAD or END; a group's owner is its target
        self.lists = {}  # task id -> the list it's in
        self.marked = None
        self.pointer = None

        target = Gtk.DropTarget.new(GObject.TYPE_STRING, Gdk.DragAction.MOVE)
        target.connect("motion", lambda _t, x, y: Gdk.DragAction.MOVE if self.hover(x, y) else 0)
        target.connect("leave", lambda _t: self.clear())
        target.connect("drop", lambda _t, value, x, y: self.drop(x, y, value))
        self.widget.add_controller(target)

    def add_list(self, project_id, section_id, heading, rows, end):
        """rows: (Slot, widget) in display order. heading and end (the add-task row) may be None."""
        owner = _List(project_id, section_id, heading, rows, end)
        self.lists.update((slot.id, owner) for slot in owner.slots)
        self.hits += [(widget, owner, i) for i, (_, widget) in enumerate(rows)]
        self.hits += [(w, owner, hit) for w, hit in ((heading, HEAD), (end, END)) if w is not None]

    def list_of(self, task_id):
        """The list a task's row is in: its project_id, section_id and slots. None on flat pages."""
        return self.lists.get(task_id)

    def add_group(self, target, heading, widgets):
        """A heading and its rows, all dropping on one target."""
        self.hits += [(w, (target, heading), None) for w in widgets]

    # ---- the pointer ----

    def hover(self, x, y):
        """Show where a drop at (x, y) would land. Returns the Drop, or None."""
        self.pointer = (x, y)
        found = self.resolve(x, y)
        self.show(found)
        return found

    def drop(self, x, y, value=None):
        found = self.resolve(x, y) if self.drag.accepts(value) else None
        task_id = self.drag.task_id
        self.clear()
        if found is None:
            return False
        self.on_drop(task_id, found[0].target)
        return True

    def scrolled(self, dy):
        """The page scrolled under a still pointer during autoscroll."""
        if self.pointer:
            self.hover(self.pointer[0], self.pointer[1] + dy)

    def resolve(self, x, y):
        """(Drop, owner) for a pointer at (x, y) over the page, or None."""
        if not self.drag.active:
            return None
        hit = self.nearest(y)
        if hit is None:
            return None
        widget, owner, index = hit
        if not isinstance(owner, _List):
            return Drop(owner[0]), owner
        left = bounds(self.column, self.widget)[0]
        depth = level(x - self.drag.grab_x - left, INDENT_PX)
        where = None
        if index not in (HEAD, END):
            _, top, _, height = bounds(widget, self.widget)
            where = zone(y - top, height)
        drop = resolve(owner.slots, owner.project_id, owner.section_id, index, where, depth, self.drag.task_id)
        return (drop, owner) if drop else None

    def nearest(self, y):
        """The hit under y, or the closest one above or below."""
        best, distance = None, None
        for hit in self.hits:
            box = bounds(hit[0], self.widget)
            if box is None or not hit[0].get_mapped():
                continue
            top, bottom = box[1], box[1] + box[3]
            d = 0 if top <= y <= bottom else min(abs(y - top), abs(y - bottom))
            if distance is None or d < distance:
                best, distance = hit, d
        return best

    # ---- feedback ----

    def show(self, found):
        self.clear(keep_pointer=True)
        if found is None:
            return
        drop, owner = found
        if not isinstance(owner, _List):
            self.mark(owner[1], "drop-onto")
        elif drop.ring:
            self.mark(owner.widgets[drop.ring], "drop-inside")
        else:
            self.place_line(drop, owner)

    def place_line(self, drop, owner):
        """A line with a dot, at the gap and indented to the level the task will land on."""
        if drop.prev:
            _, top, _, height = bounds(owner.widgets[drop.prev], self.widget)
            y = top + height
        elif drop.next:
            y = bounds(owner.widgets[drop.next], self.widget)[1]
        elif owner.heading is not None:
            _, top, _, height = bounds(owner.heading, self.widget)
            y = top + height
        else:
            y = bounds(owner.end, self.widget)[1] if owner.end is not None else 0
        left, _, width, _ = bounds(self.column, self.widget)
        x = left + drop.depth * INDENT_PX
        self.line.set_margin_start(max(0, round(x) - 4))
        self.line.set_margin_top(max(0, round(y) - 4))
        self.line.set_size_request(max(8, round(width - drop.depth * INDENT_PX) + 4), 8)
        self.line.set_visible(True)

    def mark(self, widget, css):
        widget.add_css_class(css)
        self.marked = (widget, css)

    def clear(self, keep_pointer=False):
        if self.marked:
            self.marked[0].remove_css_class(self.marked[1])
            self.marked = None
        self.line.set_visible(False)
        if not keep_pointer:
            self.pointer = None


class SidebarDrop:
    """Drops on sidebar rows. Holding a drag over a row opens its page, so a task can be placed exactly.

    target_of(row) gives a dragdrop target or None. open_row(row) shows that row's page.
    """

    def __init__(self, listbox, drag, target_of, on_drop, open_row):
        self.listbox, self.drag, self.target_of, self.on_drop, self.open_row = listbox, drag, target_of, on_drop, open_row
        self.row = None
        self.timer = 0
        target = Gtk.DropTarget.new(GObject.TYPE_STRING, Gdk.DragAction.MOVE)
        target.connect("motion", lambda _t, _x, y: Gdk.DragAction.MOVE if self.hover(y) else 0)
        target.connect("leave", lambda _t: self.hover(None))
        target.connect("drop", lambda _t, value, _x, y: self.drop(y, value))
        listbox.add_controller(target)

    def hover(self, y):
        """The target under y (None leaves). Starts the spring for a new row."""
        row = self.listbox.get_row_at_y(round(y)) if y is not None and self.drag.active else None
        if row is not self.row:
            if self.row is not None:
                self.row.remove_css_class("drop-onto")
            if self.timer:
                GLib.source_remove(self.timer)
                self.timer = 0
            self.row = row
            if row is not None and row.get_selectable() and not row.is_selected():
                self.timer = GLib.timeout_add(SPRING_MS, self.spring, row)
        target = self.target_of(row) if row is not None else None
        if row is not None:
            (row.add_css_class if target else row.remove_css_class)("drop-onto")
        return target

    def spring(self, row):
        self.timer = 0
        if row is self.row and self.drag.active:
            self.open_row(row)
        return GLib.SOURCE_REMOVE

    def drop(self, y, value=None):
        target = self.hover(y) if self.drag.accepts(value) else None
        task_id = self.drag.task_id
        self.hover(None)
        if target is None:
            return False
        self.on_drop(task_id, target)
        return True


class Autoscroll:
    """Scroll a ScrolledWindow while a drag nears its top or bottom edge. GTK doesn't.

    The speed grows towards the edge. on_scroll(dy) runs after each step.
    """

    def __init__(self, scrolled, on_scroll=lambda dy: None):
        self.scrolled, self.on_scroll = scrolled, on_scroll
        self.speed = 0.0
        self.tick = 0
        self.last = None
        motion = Gtk.DropControllerMotion()
        motion.connect("motion", lambda _m, _x, y: self.aim(y))
        motion.connect("leave", lambda _m: self.aim(None))
        scrolled.add_controller(motion)

    def aim(self, y):
        height = self.scrolled.get_height()
        if y is None or height < 3 * EDGE_PX:
            depth = 0.0
        elif y < EDGE_PX:
            depth = -(1 - y / EDGE_PX)
        elif y > height - EDGE_PX:
            depth = 1 - (height - y) / EDGE_PX
        else:
            depth = 0.0
        self.speed = MAX_SCROLL_PX_S * depth * abs(depth)
        if self.speed and not self.tick:
            self.last = None
            self.tick = self.scrolled.add_tick_callback(self.step)

    def step(self, _widget, clock):
        now = clock.get_frame_time()
        seconds = (now - self.last) / 1e6 if self.last is not None else 0
        self.last = now
        if not self.speed:
            self.tick = 0
            return GLib.SOURCE_REMOVE
        adj = self.scrolled.get_vadjustment()
        old = adj.get_value()
        adj.set_value(min(max(old + self.speed * seconds, adj.get_lower()), adj.get_upper() - adj.get_page_size()))
        if adj.get_value() != old:
            self.on_scroll(adj.get_value() - old)
        return GLib.SOURCE_CONTINUE

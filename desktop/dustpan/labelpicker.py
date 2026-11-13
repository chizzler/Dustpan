"""The label picker: type to find a label, Enter to add or remove it, or to create a new one. See spec/labels.md.

One widget for the task editor, the L key on a task, and choosing where to merge a label.
"""

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, Gtk, Pango  # noqa: E402

from .labels import exact, find, key  # noqa: E402
from .widgets import NO_COLOUR, focus_soon, label_mark, scroll_into_view  # noqa: E402

NEW_LABEL_COLOUR = NO_COLOUR  # a created label's tag until the writer gives it its colour
MAX_HEIGHT = 320


class LabelPicker(Gtk.Popover):
    """labels: live label Rows, in the order to offer them. selected: ids that are on. created: names that are on.

    Several (choose=None): the rows have ticks. Activating one toggles it and the picker stays open.
    on_toggle(ref, on) reports each change; ref is a label id, or a name for a label to create.
    One (choose given): activating a label calls choose(label_id) and closes. Nothing is created.
    """

    def __init__(self, labels, selected=(), created=(), on_toggle=None, choose=None, exclude=None, placeholder=None):
        super().__init__(css_classes=["label-picker"])
        self.labels = [label for label in labels if label.id != exclude]
        self.created = list(created)  # names to create, chosen here or earlier: not labels yet
        self.selected = [*selected, *self.created]
        self.on_toggle, self.choose = on_toggle, choose

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, width_request=280)
        # No search delay: Enter must act on what was typed, however fast.
        self.entry = Gtk.SearchEntry(search_delay=0, placeholder_text=placeholder or (
            "Find a label" if choose else "Find or create a label"))
        self.entry.connect("search-changed", lambda _e: self.fill())
        self.entry.connect("activate", lambda _e: self.activate_selected(from_entry=True))
        self.entry.connect("stop-search", lambda _e: self.popdown())
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_entry_key)
        self.entry.add_controller(keys)
        box.append(self.entry)

        self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE, css_classes=["navigation-sidebar"])
        self.list.connect("row-activated", lambda _l, row: self.activate(row))
        self.list.set_placeholder(Gtk.Label(label="No labels yet. Type a name to create one." if not choose else
                                            "No other labels", wrap=True, margin_top=12, margin_bottom=12,
                                            css_classes=["dim-label"]))
        self.scroll = Gtk.ScrolledWindow(child=self.list, hscrollbar_policy=Gtk.PolicyType.NEVER,
                                         propagate_natural_height=True, max_content_height=MAX_HEIGHT)
        box.append(self.scroll)
        if not choose:
            box.append(Gtk.Label(label="Enter adds or removes · Esc closes", css_classes=["dim-label", "caption"]))
        self.set_child(box)
        self.connect("show", lambda _p: focus_soon(self.entry))
        self.fill()

    # ---- the list ----

    def fill(self):
        query = self.filled = self.entry.get_text().strip()
        self.list.remove_all()
        for label in find(self.labels, query):
            self.add_row(label.id, label.get("name", ""), label.get("color"))
        for name in self.created:
            if not query or key(query) in key(name):
                self.add_row(name, name, NEW_LABEL_COLOUR)
        if query and not self.choose and exact(self.labels, query) is None and \
                key(query) not in (key(n) for n in self.created):
            self.add_row(None, query, None)
        self.list.select_row(self.list.get_row_at_index(0))

    def add_row(self, ref, name, color):
        """ref None is the "Create" row."""
        box = Gtk.Box(spacing=10, margin_top=4, margin_bottom=4)
        if ref is None:
            box.append(Gtk.Image(icon_name="list-add-symbolic"))
            text = Gtk.Label(xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END)
            text.set_markup(f"Create label <b>{GLib.markup_escape_text(name)}</b>")
            box.append(text)
            spoken = f"Create label {name}"
        else:
            box.append(label_mark(color))
            box.append(Gtk.Label(label=name, xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END))
            on = ref in self.selected
            if not self.choose:
                tick = Gtk.Image(icon_name="object-select-symbolic", opacity=1 if on else 0)
                box.append(tick)
            spoken = f"{name}, {'on' if on else 'off'}" if not self.choose else name
        row = Gtk.ListBoxRow(child=box)
        row.ref, row.name = ref, name
        row.update_property([Gtk.AccessibleProperty.LABEL], [spoken])
        self.list.append(row)

    def on_entry_key(self, _controller, keyval, _code, _state):
        """Up and Down move through the list while the typing stays in the entry."""
        if keyval not in (Gdk.KEY_Up, Gdk.KEY_Down):
            return False
        row = self.list.get_selected_row()
        index = (row.get_index() if row else -1) + (1 if keyval == Gdk.KEY_Down else -1)
        target = self.list.get_row_at_index(max(index, 0))
        if target is not None:
            self.list.select_row(target)
            scroll_into_view(self.scroll, target)
        return True

    def activate_selected(self, from_entry=False):
        if self.entry.get_text().strip() != self.filled:
            self.fill()
        row = self.list.get_selected_row()
        if row is not None:
            self.activate(row)
            if from_entry and not self.choose:
                self.entry.set_text("")  # ready for the next label

    def activate(self, row):
        if self.choose:
            self.popdown()
            self.choose(row.ref)
            return
        ref = row.ref
        if ref is None:  # create
            ref = row.name
            self.created.append(ref)
        on = ref not in self.selected
        if on:
            self.selected.append(ref)
        else:
            self.selected.remove(ref)
            if ref in self.created:
                self.created.remove(ref)
        if self.on_toggle:
            self.on_toggle(ref, on)
        index = row.get_index()
        self.fill()
        self.list.select_row(self.list.get_row_at_index(index) or self.list.get_row_at_index(0))

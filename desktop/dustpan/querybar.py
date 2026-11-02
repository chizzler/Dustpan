"""The query box: suggestions as you type, and a menu of conditions to add. See spec/views.md, "The Filter page".

Used by the Filter page and the view editor. The rules are in querytools.py.
"""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

from .querytools import add_condition, conditions, suggest  # noqa: E402


class QueryBar(Gtk.Box):
    """names() gives (label names, project names) in sidebar order. on_change(query) runs as the query changes.

    While suggestions show, ↑ ↓ pick one and Enter or Tab takes it; Esc hides them. Otherwise Enter calls on_enter.
    """

    def __init__(self, names, on_change, on_enter=None, text=""):
        super().__init__(spacing=6)
        self.names, self.on_change, self.on_enter = names, on_change, on_enter
        self.entry = Gtk.Entry(text=text, hexpand=True, css_classes=["monospace"],
                               placeholder_text="Like  @errand & due <= 7 days")
        self.entry.update_property([Gtk.AccessibleProperty.LABEL], ["Query"])
        self.entry.connect("changed", lambda _e: self.changed())
        self.entry.connect("activate", lambda _e: self.enter())
        keys = Gtk.EventControllerKey(propagation_phase=Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self.on_key)
        self.entry.add_controller(keys)
        self.append(self.entry)

        self.negate = Gtk.ToggleButton(label="Not", css_classes=["flat"],
                                       tooltip_text="Add the opposite of the next condition")
        self.append(self.negate)
        add = Gtk.MenuButton(child=Adw.ButtonContent(icon_name="list-add-symbolic", label="Condition"),
                             tooltip_text="Add a condition", css_classes=["flat"])
        add.set_create_popup_func(self.condition_menu)
        self.append(add)

        # Suggestions: a popover that leaves the typing in the entry.
        self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE, can_focus=False, css_classes=["navigation-sidebar"])
        self.list.connect("row-activated", lambda _l, row: self.take(row))
        self.popover = Gtk.Popover(child=self.list, autohide=False, has_arrow=False, position=Gtk.PositionType.BOTTOM,
                                   can_focus=False)
        self.popover.set_parent(self.entry)
        self.connect("unrealize", lambda _w: self.popover.unparent() if self.popover.get_parent() else None)

    def text(self):
        return self.entry.get_text()

    def focus(self):
        self.entry.grab_focus_without_selecting()
        self.entry.set_position(-1)

    # ---- suggestions ----

    def changed(self):
        self.on_change(self.text())
        if self.entry.get_focus_child() is not None:  # typed here, not set by code
            # Once the cursor has moved past what was typed: "changed" comes first.
            GLib.idle_add(lambda: self.show_suggestions() and False)

    def show_suggestions(self):
        """Offered only with the cursor at the end, where the word being completed is."""
        query = self.text()
        found = suggest(query, *self.names()) if self.entry.get_position() in (-1, len(query)) else []
        self.list.remove_all()
        for shown, hint, completed in found:
            box = Gtk.Box(spacing=12)
            box.append(Gtk.Label(label=shown, xalign=0, css_classes=["monospace"],
                                 ellipsize=Pango.EllipsizeMode.END, max_width_chars=28))
            box.append(Gtk.Label(label=hint, xalign=1, hexpand=True, css_classes=["dim-label", "caption"],
                                 ellipsize=Pango.EllipsizeMode.END, max_width_chars=30))
            row = Gtk.ListBoxRow(child=box, can_focus=False)
            row.completed = completed
            self.list.append(row)
        if found:
            self.list.select_row(self.list.get_row_at_index(0))
            self.popover.popup()
        else:
            self.popover.popdown()

    def take(self, row):
        self.popover.popdown()
        self.entry.set_text(row.completed)
        self.focus()

    def on_key(self, _controller, keyval, _code, _state):
        if not self.popover.get_visible():
            return False
        row = self.list.get_selected_row()
        if keyval in (Gdk.KEY_Down, Gdk.KEY_Up):
            index = (row.get_index() if row else -1) + (1 if keyval == Gdk.KEY_Down else -1)
            target = self.list.get_row_at_index(max(index, 0))
            if target is not None:
                self.list.select_row(target)
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_Tab) and row is not None:
            self.take(row)
            return True
        if keyval == Gdk.KEY_Escape:
            self.popover.popdown()
            return True
        return False

    def enter(self):
        if self.on_enter:
            self.on_enter(self.text())

    # ---- conditions ----

    def condition_menu(self, button):
        """Each condition is added with &. With Not on, its opposite is, and Not turns off again."""
        group = Gio.SimpleActionGroup()
        model = Gio.Menu()
        index = 0
        for title, items in conditions(*self.names()):
            sub = Gio.Menu()
            for label, term in items:
                action = Gio.SimpleAction.new(f"add-{index}", None)
                action.connect("activate", lambda *_a, t=term: self.add(t))
                group.add_action(action)
                sub.append(label, f"query.add-{index}")
                index += 1
            model.append_submenu(title, sub)
        button.insert_action_group("query", group)
        button.set_menu_model(model)

    def add(self, term):
        self.entry.set_text(add_condition(self.text(), term, self.negate.get_active()))
        self.negate.set_active(False)
        self.popover.popdown()
        GLib.idle_add(lambda: self.focus() or False)

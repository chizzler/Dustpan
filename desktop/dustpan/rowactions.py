"""Keys and a menu on each task row: every move a drag can make, without a pointer. See spec/dragdrop.md.

The keys follow the web app's list shortcuts. The menu holds the same actions, with their keys shown,
so they can be found and used with a single pointer click (WCAG 2.5.7).
"""

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402

from .dragdrop import BOTTOM, DOWN, INDENT, OUTDENT, TOP, UP  # noqa: E402

MODS = Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.CONTROL_MASK
SHIFT, ALT = Gdk.ModifierType.SHIFT_MASK, Gdk.ModifierType.ALT_MASK
NONE = Gdk.ModifierType(0)

# (key, modifiers) -> (action, argument)
KEYS = {
    (Gdk.KEY_Up, ALT): ("move", UP),
    (Gdk.KEY_Down, ALT): ("move", DOWN),
    (Gdk.KEY_Up, ALT | SHIFT): ("move", TOP),
    (Gdk.KEY_Down, ALT | SHIFT): ("move", BOTTOM),
    (Gdk.KEY_Tab, NONE): ("move", INDENT),
    (Gdk.KEY_ISO_Left_Tab, SHIFT): ("move", OUTDENT),
    (Gdk.KEY_Tab, SHIFT): ("move", OUTDENT),
    (Gdk.KEY_Up, NONE): ("step", -1),
    (Gdk.KEY_k, NONE): ("step", -1),
    (Gdk.KEY_Down, NONE): ("step", 1),
    (Gdk.KEY_j, NONE): ("step", 1),
    (Gdk.KEY_Return, NONE): ("open", None),
    (Gdk.KEY_KP_Enter, NONE): ("open", None),
    (Gdk.KEY_c, NONE): ("complete", None),
    (Gdk.KEY_l, NONE): ("labels", None),
    (Gdk.KEY_L, SHIFT): ("labels", None),
    (Gdk.KEY_Delete, NONE): ("delete", None),
    (Gdk.KEY_BackSpace, NONE): ("delete", None),
    (Gdk.KEY_Menu, NONE): ("menu", None),
    (Gdk.KEY_F10, SHIFT): ("menu", None),
    (Gdk.KEY_period, NONE): ("menu", None),
    (Gdk.KEY_Escape, NONE): ("unselect", None),
}

# The moves in the menu, with the keys it shows for them.
MENU_MOVES = ((UP, "Move up", "<Alt>Up"), (DOWN, "Move down", "<Alt>Down"), (TOP, "Move to top", "<Alt><Shift>Up"),
         (BOTTOM, "Move to bottom", "<Alt><Shift>Down"), (INDENT, "Indent", "Tab"), (OUTDENT, "Outdent", "<Shift>Tab"))


class TaskRow(Gtk.Box):
    """A task's row. A plain Box is never a Tab or arrow stop, even when focusable: GTK only looks at its children."""

    def do_focus(self, _direction):
        if self.has_focus():
            return False  # focus moves on to the next row
        return self.grab_focus()


class RowActions:
    """Gives task rows focus, keys and a menu. The window does the work, through these methods:

    moves(task_id): {move: target or None} for a task in a list, or None on flat pages
    move(task_id, move), apply_drop(task_id, target): apply a move or a target; the task keeps the focus
    step(task_id, n): focus the row n rows away
    leaving(task_id): focus the next row once this one is gone
    edit(task_id), complete(task_id), reopen(task_id), delete_task(task_id), pick_labels(task_id)
    places(): [(label, target, [(label, target)])] for Move to; days(): [(label, target)] for the date items
    """

    def __init__(self, window):
        self.window = window
        self.popover = None  # the open menu

    def attach(self, row, task_id, done):
        """Make row selectable: a click selects it (it takes the focus), a double-click opens it,
        a right-click opens its menu, and the keys act on it."""
        row.set_focusable(True)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", lambda _c, keyval, _code, state: self.key(row, task_id, done, keyval, state))
        row.add_controller(keys)
        click = Gtk.GestureClick(button=0)
        click.connect("pressed", lambda gesture, n, x, y: self.pressed(gesture, row, task_id, done, n, x, y))
        row.add_controller(click)

    def pressed(self, gesture, row, task_id, done, presses, x, y):
        row.grab_focus()
        if gesture.get_current_button() == Gdk.BUTTON_SECONDARY:
            gesture.set_state(Gtk.EventSequenceState.CLAIMED)
            self.menu(row, task_id, done, x, y)
        elif presses == 2:
            self.run("open", task_id)

    def key(self, row, task_id, done, keyval, state):
        action, arg = KEYS.get((keyval, state & MODS), (None, None))
        if action is None or (done and action == "move"):
            return False
        if done and action == "complete":
            action = "reopen"  # c completes or reopens, as in the web app
        if action == "step":
            self.window.step(task_id, arg)
        elif action == "unselect":
            row.get_root().set_focus(None)
        elif action == "menu":
            self.menu(row, task_id, done, 12, row.get_height() / 2)
        elif action == "move":
            # Tab indents in a list, as in the web app. On a flat page it keeps moving focus.
            if self.window.moves(task_id) is None:
                return keyval not in (Gdk.KEY_Tab, Gdk.KEY_ISO_Left_Tab)
            self.later(self.window.move, task_id, arg)
        else:
            self.run(action, task_id)
        return True

    def run(self, action, task_id):
        if action in ("complete", "delete"):
            self.window.leaving(task_id)
        method = {"open": self.window.edit, "complete": self.window.complete, "reopen": self.window.reopen,
                  "delete": self.window.delete_task, "labels": self.window.pick_labels}[action]
        self.later(method, task_id)

    def later(self, method, *args):
        """After the key or menu signal: the action rebuilds the page that sent it."""
        GLib.idle_add(lambda: method(*args) and False)

    # ---- the menu ----

    def menu(self, row, task_id, done, x, y):
        group = Gio.SimpleActionGroup()
        model = Gio.Menu()
        targets = []

        def item(section, label, name, handler, enabled=True, accel=None):
            action = Gio.SimpleAction.new(name, None)
            action.set_enabled(enabled)
            action.connect("activate", lambda *_a: handler())
            group.add_action(action)
            entry = Gio.MenuItem.new(label, "row." + name)
            if accel:
                entry.set_attribute_value("accel", GLib.Variant.new_string(accel))
            section.append_item(entry)

        def target_item(section, label, target):
            name = f"to-{len(targets)}"
            targets.append(target)
            item(section, label, name, lambda: self.later(self.window.apply_drop, task_id, target))

        first = Gio.Menu()
        item(first, "Open", "open", lambda: self.run("open", task_id), accel="Return")
        if done:
            item(first, "Reopen", "reopen", lambda: self.run("reopen", task_id))
        else:
            item(first, "Complete", "complete", lambda: self.run("complete", task_id), accel="c")
        item(first, "Labels…", "labels", lambda: self.run("labels", task_id), accel="l")
        model.append_section(None, first)

        moves = None if done else self.window.moves(task_id)
        if moves is not None:
            section = Gio.Menu()
            for move, label, accel in MENU_MOVES:
                item(section, label, move, lambda m=move: self.later(self.window.move, task_id, m),
                     enabled=moves.get(move) is not None, accel=accel)
            model.append_section(None, section)

        if not done:
            section = Gio.Menu()
            for label, target in self.window.days():
                target_item(section, label, target)
            places = Gio.Menu()
            for label, target, children in self.window.places():
                if children:
                    sub = Gio.Menu()
                    for child_label, child_target in children:
                        target_item(sub, child_label, child_target)
                    places.append_submenu(label, sub)
                else:
                    target_item(places, label, target)
            section.append_submenu("Move to", places)
            model.append_section(None, section)

        last = Gio.Menu()
        item(last, "Delete", "delete", lambda: self.run("delete", task_id), accel="Delete")
        model.append_section(None, last)

        row.insert_action_group("row", group)
        popover = self.popover = Gtk.PopoverMenu.new_from_model(model)
        popover.set_parent(row)
        popover.set_has_arrow(False)
        spot = Gdk.Rectangle()
        spot.x, spot.y, spot.width, spot.height = int(x), int(y), 1, 1
        popover.set_pointing_to(spot)
        popover.connect("closed", lambda p: GLib.idle_add(lambda: p.unparent() or False))
        popover.popup()

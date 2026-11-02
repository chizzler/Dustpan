"""Small widgets and helpers shared by the window and its dialogs."""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Graphene", "1.0")
gi.require_version("Gsk", "4.0")
gi.require_version("Pango", "1.0")
from gi.repository import Adw, Gdk, Gio, GLib, Graphene, Gsk, Gtk, Pango  # noqa: E402

from . import theme  # noqa: E402

INDENT_PX = 24  # one level of subtasks
FLASH_MS = 700  # how long a moved row is highlighted
THEME_SETTLE_MS = 200  # Omarchy swaps the theme in several steps; reload once they stop

CSS = """
:root {
  --dustpan-p1: #d1453b; --dustpan-p2: #eb8909; --dustpan-p3: #246fe0;
  --dustpan-overdue: #d1453b; --dustpan-today: #058527;
}
button.task-check {
  min-width: 18px; min-height: 18px; padding: 0;
  border-radius: 999px;
  border: 1.5px solid alpha(currentColor, 0.45);
  background: none; box-shadow: none;
}
button.task-check image { -gtk-icon-size: 12px; opacity: 0; }
button.task-check:hover image, button.task-check:focus-visible image { opacity: 0.7; }
button.task-check.p1 { border-color: var(--dustpan-p1); background: alpha(var(--dustpan-p1), 0.12); }
button.task-check.p2 { border-color: var(--dustpan-p2); background: alpha(var(--dustpan-p2), 0.12); }
button.task-check.p3 { border-color: var(--dustpan-p3); background: alpha(var(--dustpan-p3), 0.12); }
button.task-check.done { border-color: alpha(currentColor, 0.3); background: alpha(currentColor, 0.15); }
button.task-check.done image { opacity: 0.7; }
.task-text { min-height: 20px; }
.add-task { margin-top: 4px; }
.task-row { padding: 8px 4px; border-bottom: 1px solid alpha(currentColor, 0.08); }
.task-row:focus { background: alpha(var(--accent-bg-color), 0.15); border-radius: 6px; }
.task-row:focus-visible { outline: 2px solid alpha(var(--accent-color), 0.7); outline-offset: -2px; }
.dragging { opacity: 0.4; }
.drag-pill { padding: 6px 12px; border-radius: 8px; background: var(--popover-bg-color); color: var(--popover-fg-color);
  box-shadow: 0 2px 8px alpha(black, 0.25); margin: 8px; }
.drop-dot { min-width: 8px; min-height: 8px; border-radius: 4px; background: var(--accent-bg-color); }
.drop-stroke { min-height: 2px; background: var(--accent-bg-color); }
.drop-inside { box-shadow: inset 0 0 0 2px var(--accent-bg-color); border-radius: 6px; }
.drop-onto { background: alpha(var(--accent-bg-color), 0.2); border-radius: 6px; }
.drop-before { box-shadow: inset 0 2px 0 var(--accent-bg-color); }
.drop-after { box-shadow: inset 0 -2px 0 var(--accent-bg-color); }
@keyframes flash { from { background-color: alpha(var(--accent-bg-color), 0.3); } to { background-color: transparent; } }
.flash { animation: flash 700ms ease-out; }
.task-meta { font-size: 0.85em; }
.danger-button { min-height: 44px; padding: 0 36px; margin-top: 12px; font-weight: bold;
                 background: var(--destructive-bg-color); color: var(--destructive-fg-color); }
.danger-button:hover { background: color-mix(in srgb, var(--destructive-bg-color) 85%, white); }
.danger-button:active { background: color-mix(in srgb, var(--destructive-bg-color) 80%, black); }
.due-overdue { color: var(--dustpan-overdue); }
.due-today { color: var(--dustpan-today); }
.section-heading { margin-top: 24px; padding-bottom: 6px; border-bottom: 1px solid alpha(currentColor, 0.15); }
.section-heading button { min-height: 24px; min-width: 24px; padding: 0; }
.colour-choice { min-width: 28px; min-height: 28px; padding: 0; border-radius: 999px; }
.colour-choice:checked { box-shadow: inset 0 0 0 2px var(--accent-color); }
.note-editor { min-height: 96px; }
.note-preview { padding: 10px 12px; }
.note-quote { border-left: 3px solid alpha(currentColor, 0.25); padding-left: 10px; }
.note-code { background: alpha(currentColor, 0.06); border-radius: 6px; padding: 8px 10px; }
.task-note { font-size: 0.9em; }
.label-chip { padding: 1px 8px 1px 6px; border-radius: 999px; background: alpha(currentColor, 0.08); }
.label-chip button { min-width: 18px; min-height: 18px; padding: 0; margin: -2px -4px -2px 0; }
.label-chip.more { padding: 1px 8px; }
.label-picker list row { padding: 2px 6px; }
"""


class Dot(Gtk.Widget):
    """A small coloured circle. Colours are hex strings in OpenTodo."""

    def __init__(self, color, size=10):
        super().__init__(valign=Gtk.Align.CENTER)
        self.set_size_request(size, size)
        self.rgba = Gdk.RGBA()
        if not (isinstance(color, str) and self.rgba.parse(color)):
            self.rgba.parse("#94a3b8")

    def do_snapshot(self, snap):
        width, height = self.get_width(), self.get_height()
        size = min(width, height)
        rect = Graphene.Rect().init((width - size) / 2, (height - size) / 2, size, size)
        clip = Gsk.RoundedRect()
        clip.init_from_rect(rect, size / 2)
        snap.push_rounded_clip(clip)
        snap.append_color(self.rgba, rect)
        snap.pop()


def label_chip(name, color, on_remove=None):
    """A label as a small pill: its colour as a dot, then its name. on_remove adds an × that calls it."""
    chip = Gtk.Box(spacing=5, valign=Gtk.Align.CENTER, css_classes=["label-chip"])
    chip.append(Dot(color, 8))
    chip.append(Gtk.Label(label=name, ellipsize=Pango.EllipsizeMode.END, max_width_chars=24))
    if on_remove is not None:
        remove = Gtk.Button(icon_name="window-close-symbolic", tooltip_text=f"Remove {name}",
                            css_classes=["flat", "circular"])
        remove.connect("clicked", lambda _b: on_remove())
        chip.append(remove)
    return chip


def flash(widget):
    """Highlight a row for a moment, so the eye finds where it landed."""
    widget.add_css_class("flash")
    GLib.timeout_add(FLASH_MS, lambda: widget.remove_css_class("flash") or GLib.SOURCE_REMOVE)


def scroll_into_view(scrolled, widget):
    """Scroll just enough to show widget, a descendant of scrolled's child."""
    ok, rect = widget.compute_bounds(scrolled.get_child())
    if not ok:
        return
    adj = scrolled.get_vadjustment()
    top, bottom = rect.get_y(), rect.get_y() + rect.get_height()
    if top < adj.get_value():
        adj.set_value(top)
    elif bottom > adj.get_value() + adj.get_page_size():
        adj.set_value(bottom - adj.get_page_size())


def escape(text):
    return GLib.markup_escape_text(text)


def popup_menu(widget, sections, x=None, y=None):
    """A menu at (x, y) in widget, or below it. sections: [[(label, handler, enabled)]].

    Handlers run after the menu's signal, since most rebuild the page the menu belongs to.
    """
    group = Gio.SimpleActionGroup()
    model = Gio.Menu()
    for i, items in enumerate(sections):
        section = Gio.Menu()
        for j, (label, handler, enabled) in enumerate(items):
            action = Gio.SimpleAction.new(f"item-{i}-{j}", None)
            action.set_enabled(enabled)
            action.connect("activate", lambda *_a, h=handler: GLib.idle_add(lambda: h() and False))
            group.add_action(action)
            section.append(label, f"menu.item-{i}-{j}")
        model.append_section(None, section)
    widget.insert_action_group("menu", group)
    popover = Gtk.PopoverMenu.new_from_model(model)
    popover.set_parent(widget)
    if x is not None:
        popover.set_has_arrow(False)
        spot = Gdk.Rectangle()
        spot.x, spot.y, spot.width, spot.height = int(x), int(y), 1, 1
        popover.set_pointing_to(spot)
    popover.connect("closed", lambda p: GLib.idle_add(lambda: p.unparent() or False))
    popover.popup()


def on_right_click(widget, handler):
    """handler(x, y) on a secondary click in widget."""
    click = Gtk.GestureClick(button=Gdk.BUTTON_SECONDARY)

    def pressed(gesture, _n, x, y):
        gesture.set_state(Gtk.EventSequenceState.CLAIMED)
        handler(x, y)

    click.connect("pressed", pressed)
    widget.add_controller(click)


def save_screenshot(widget, path):
    """Render a widget to PNG. Used by DUSTPAN_SCREENSHOT during development."""
    width, height = widget.get_width(), widget.get_height()
    snap = Gtk.Snapshot()
    Gtk.WidgetPaintable.new(widget).snapshot(snap, width, height)
    node = snap.to_node()
    rect = Graphene.Rect().init(0, 0, width, height)
    widget.get_native().get_renderer().render_texture(node, rect).save_to_png(path)


class ThemeFollower:
    """Keeps the app in the current Omarchy theme's colours, and follows theme changes.

    Omarchy replaces the whole theme folder on a switch, so this watches the folder above it."""

    def __init__(self, display):
        self.provider = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(display, self.provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        self.css = None
        self.pending = 0
        self.apply()
        try:
            folder = Gio.File.new_for_path(str(theme.colors_path().parent.parent))
            self.monitor = folder.monitor_directory(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect("changed", self.on_changed)
        except GLib.Error:
            self.monitor = None

    def on_changed(self, *_args):
        if self.pending:
            GLib.source_remove(self.pending)
        self.pending = GLib.timeout_add(THEME_SETTLE_MS, self.reload)

    def reload(self):
        self.pending = 0
        self.apply()
        return GLib.SOURCE_REMOVE

    def apply(self):
        palette = theme.load(theme.colors_path())
        css = theme.stylesheet(palette) if palette else ""
        if css == self.css:
            return
        self.css = css
        self.provider.load_from_string(css)
        # Adwaita's own shades and text colours depend on the mode, so match the theme's.
        schemes = {"light": Adw.ColorScheme.FORCE_LIGHT, "dark": Adw.ColorScheme.FORCE_DARK}
        Adw.StyleManager.get_default().set_color_scheme(
            schemes[palette.mode] if palette else Adw.ColorScheme.DEFAULT)

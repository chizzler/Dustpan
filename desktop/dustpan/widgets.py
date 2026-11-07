"""Small widgets and helpers shared by the window and its dialogs."""

import math

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Graphene", "1.0")
gi.require_version("Gsk", "4.0")
gi.require_version("Pango", "1.0")
from gi.repository import Adw, Gdk, Gio, GLib, Graphene, Gsk, Gtk, Pango  # noqa: E402

from . import theme  # noqa: E402

INDENT_PX = 24  # one level of subtasks
FOLD_PX = 16  # the leading slot on every task row, where a parent shows its fold chevron
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
button.task-check .task-pie { color: alpha(currentColor, 0.45); transition: opacity 150ms; }
button.task-check.p1 .task-pie { color: var(--dustpan-p1); }
button.task-check.p2 .task-pie { color: var(--dustpan-p2); }
button.task-check.p3 .task-pie { color: var(--dustpan-p3); }
button.task-check:hover .task-pie, button.task-check:focus-visible .task-pie { opacity: 0.3; }
button.subtask-broom { min-width: 24px; min-height: 24px; padding: 0;
  border: 1px solid alpha(currentColor, 0.12); background: alpha(currentColor, 0.02);
  margin: -4px 0; }  /* as tall as a line of text, so a row doesn't grow when its broom appears */
button.subtask-broom:hover { border-color: alpha(currentColor, 0.22); background: alpha(currentColor, 0.06); }
button.fold-chevron { min-width: 16px; min-height: 18px; padding: 0; border-radius: 4px; opacity: 0.55; }
button.fold-chevron:hover { opacity: 1; }
button.fold-chevron image { -gtk-icon-size: 12px; }
.brand-pill { padding: 3px 12px; border-radius: 999px;
              background: var(--window-fg-color); color: var(--window-bg-color); }
.brand-title { font-family: "Author", sans-serif; font-size: 22px; font-weight: 700;
               color: var(--window-bg-color); }
.brand-dust { color: var(--window-bg-color); }
.sidebar-heading { padding-bottom: 5px; border-bottom: 2px solid alpha(currentColor, 0.22); }
.sidebar-heading-mark { background: var(--accent-bg-color); border-radius: 1px; }
.sidebar-heading-label { font-size: 0.78em; font-weight: 700; color: alpha(currentColor, 0.72); }
.task-text { min-height: 20px; }
.add-task { margin-top: 4px; }
.task-row { padding: 8px 4px; border-bottom: 1px solid alpha(currentColor, 0.08); }
.task-row:focus { background: alpha(var(--accent-bg-color), 0.08); border-radius: 3px;
                   box-shadow: inset 3px 0 0 var(--accent-bg-color); }
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
button.task-place { min-height: 0; padding: 0 4px; margin: 0 -4px; font-weight: normal; }
button.task-place:hover label { text-decoration: underline; }
.danger-button { min-height: 44px; padding: 0 36px; margin-top: 12px; font-weight: bold;
                 background: var(--destructive-bg-color); color: var(--destructive-fg-color); }
.danger-button:hover { background: color-mix(in srgb, var(--destructive-bg-color) 85%, white); }
.danger-button:active { background: color-mix(in srgb, var(--destructive-bg-color) 80%, black); }
.due-overdue { color: var(--dustpan-overdue); }
.due-today { color: var(--dustpan-today); }
.section-heading { margin-top: 24px; padding-bottom: 6px; border-bottom: 2px solid alpha(currentColor, 0.24); }
.section-heading button { min-height: 24px; min-width: 24px; padding: 0; }
.colour-choice { min-width: 28px; min-height: 28px; padding: 0; border-radius: 999px; }
.colour-choice:checked { box-shadow: inset 0 0 0 2px var(--accent-color); }
.note-editor { min-height: 96px; }
.note-preview { padding: 10px 12px; }
.note-quote { border-left: 3px solid alpha(currentColor, 0.25); padding-left: 10px; }
.note-code { background: alpha(currentColor, 0.06); border-radius: 6px; padding: 8px 10px; }
.task-note { font-size: 0.9em; }
.label-chip { padding: 1px 8px 1px 6px; border-radius: 3px; background: alpha(currentColor, 0.05);
              box-shadow: inset 0 0 0 1px alpha(currentColor, 0.24); }
.label-chip button { min-width: 18px; min-height: 18px; padding: 0; margin: -2px -4px -2px 0; }
.label-chip.more { padding: 1px 8px; }
.label-picker list row { padding: 2px 6px; }
"""


def animations_enabled():
    settings = Gtk.Settings.get_default()
    return settings is None or settings.get_property("gtk-enable-animations")


class BrandMark(Gtk.Fixed):
    """The logo, with a short wiggle inside a fixed-size hover target."""

    STEPS = ((-1, 0), (0, 0), (1, 0), (0, 0))

    def __init__(self, logo):
        super().__init__(width_request=25, height_request=25, valign=Gtk.Align.CENTER)
        self.logo = logo
        self.put(logo, 4, 4)
        self.frame = 0
        self.timer = 0
        self.connect("unmap", self.on_unmap)

    def wiggle(self):
        if self.timer or not animations_enabled():
            return
        self.frame = 0
        self.timer = GLib.timeout_add(60, self.step)
        self.step()

    def step(self):
        dx, dy = self.STEPS[self.frame]
        self.move(self.logo, 4 + dx, 4 + dy)
        self.frame += 1
        if self.frame < len(self.STEPS):
            return GLib.SOURCE_CONTINUE
        self.timer = 0
        return GLib.SOURCE_REMOVE

    def on_unmap(self, _widget):
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0
        self.move(self.logo, 4, 4)


class BrandDust(Gtk.DrawingArea):
    """A brief dust puff at the pointer while it is near the logo."""

    DURATION = 0.72
    PUFFS = ((-2, -2, -4, -8, 3.2), (2, -3, 3, -10, 3.4),
             (4, 1, 6, -5, 2.8), (-4, 2, -7, -5, 2.6))

    def __init__(self):
        super().__init__(can_target=False, hexpand=True, vexpand=True, css_classes=["brand-dust"])
        self.set_draw_func(self.draw)
        self.bursts = []  # (start time, pointer x, pointer y)
        self.timer = 0
        self.last = None  # last pointer position that emitted dust
        self.last_time = 0
        self.connect("unmap", self.on_unmap)

    def puff_at(self, x, y, entered=False):
        if not animations_enabled():
            return
        now = GLib.get_monotonic_time() / 1_000_000
        if not entered and self.last is not None:
            dx, dy = x - self.last[0], y - self.last[1]
            if dx * dx + dy * dy < 12 * 12 or now - self.last_time < 0.075:
                return
        self.last, self.last_time = (x, y), now
        self.bursts.append((now, x, y))
        self.queue_draw()
        if not self.timer:
            self.timer = GLib.timeout_add(16, self.tick)

    def pointer_left(self):
        self.last = None

    def tick(self):
        now = GLib.get_monotonic_time() / 1_000_000
        self.bursts = [burst for burst in self.bursts if now - burst[0] < self.DURATION]
        self.queue_draw()
        if self.bursts:
            return GLib.SOURCE_CONTINUE
        self.timer = 0
        return GLib.SOURCE_REMOVE

    def on_unmap(self, _widget):
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0
        self.bursts.clear()
        self.last = None

    def draw(self, _area, cr, _width, _height):
        now = GLib.get_monotonic_time() / 1_000_000
        color = self.get_color()
        for start, x, y in self.bursts:
            t = min((now - start) / self.DURATION, 1)
            fade = (1 - t) ** 2
            for sx, sy, dx, dy, size in self.PUFFS:
                px, py = x + sx + dx * t, y + sy + dy * t
                radius = size + 2.5 * t
                for scale, opacity in ((1.65, 0.035), (1.2, 0.065), (0.75, 0.09)):
                    cr.set_source_rgba(color.red, color.green, color.blue,
                                       color.alpha * opacity * fade)
                    cr.arc(px, py, radius * scale, 0, 2 * math.pi)
                    cr.fill()


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


class Pie(Gtk.Widget):
    """A parent's progress inside its check circle (spec/progress.md), in the CSS colour of .task-pie.

    A wedge from 12 o'clock, clockwise, for done/total. None done: a faint inner ring.
    """

    GAP = 2  # between the pie and the circle's border

    def __init__(self, done, total):
        super().__init__(css_classes=["task-pie"], can_target=False)
        self.fraction = done / total if total else 0

    def do_snapshot(self, snap):
        width, height = self.get_width(), self.get_height()
        cx, cy = width / 2, height / 2
        r = min(width, height) / 2 - self.GAP
        if r <= 0:
            return
        color = self.get_color()
        path = Gsk.PathBuilder.new()
        if self.fraction <= 0:
            path.add_circle(Graphene.Point().init(cx, cy), r - 0.5)
            faint = color.copy()
            faint.alpha *= 0.6
            snap.append_stroke(path.to_path(), Gsk.Stroke.new(1), faint)
            return
        if self.fraction >= 1:
            path.add_circle(Graphene.Point().init(cx, cy), r)
        else:
            angle = 2 * math.pi * self.fraction
            path.move_to(cx, cy)
            path.line_to(cx, cy - r)
            path.svg_arc_to(r, r, 0, self.fraction > 0.5, True, cx + r * math.sin(angle), cy - r * math.cos(angle))
            path.close()
        snap.append_fill(path.to_path(), Gsk.FillRule.WINDING, color)


def broom_button():
    """Small, theme-coloured broom in a quiet circular button."""
    size = 14
    icon = Gtk.DrawingArea(content_width=size, content_height=size, can_target=False)

    def draw(area, cr, width, height):
        color = area.get_style_context().get_color()
        cr.set_source_rgba(color.red, color.green, color.blue, color.alpha * 0.65)
        cr.translate((width - size) / 2, (height - size) / 2)
        cr.scale(size / 16, size / 16)
        cr.set_line_cap(1)  # round
        cr.set_line_join(1)
        cr.set_line_width(1.5)
        cr.move_to(8.7, 8.0)
        cr.line_to(13.2, 2.5)
        cr.stroke()
        cr.move_to(6.7, 7.8)
        cr.line_to(9.7, 10.2)
        cr.stroke()
        cr.move_to(6.2, 8.4)
        cr.line_to(9.2, 10.8)
        cr.line_to(6.8, 14.1)
        cr.line_to(2.3, 11.0)
        cr.close_path()
        cr.fill()

    icon.set_draw_func(draw)
    return Gtk.Button(child=icon, tooltip_text="Clear completed subtasks from this list",
                      valign=Gtk.Align.CENTER, css_classes=["flat", "circular", "subtask-broom"])


def label_chip(name, color, on_remove=None):
    """A label as a small tag: its colour as a dot, then its name. on_remove adds an × that calls it."""
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

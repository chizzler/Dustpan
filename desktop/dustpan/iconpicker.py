"""The icon picker: categories down the side, their icons beside them, and a search over all. See spec/icons.md."""

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango  # noqa: E402

from . import icons  # noqa: E402
from .widgets import IconMark, focus_soon  # noqa: E402

HEIGHT = 380
PER_LINE = 8
MOST_FOUND = 240  # a short query matches most icons; this many are shown, and typing more narrows them
SUGGESTED = "suggested"


class IconPicker(Gtk.Popover):
    """context() gives (project name, colour, current icon) each time the picker opens.

    Choosing an icon, or No icon, calls choose(name or None) and closes.
    """

    def __init__(self, context, choose):
        super().__init__(css_classes=["icon-picker"])
        self.context, self.choose = context, choose
        self.name = self.color = self.current = None
        self.suggested, self.first, self.shown, self.row_for = [], None, None, {}

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.entry = Gtk.SearchEntry(search_delay=0, placeholder_text=f"Find among {len(icons.OFFERED):,} icons")
        self.entry.connect("search-changed", lambda _e: self.fill())
        self.entry.connect("activate", lambda _e: self.pick_first())
        self.entry.connect("stop-search", lambda _e: self.popdown())
        box.append(self.entry)

        panes = Gtk.Box(spacing=6)
        self.sidebar = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE, css_classes=["navigation-sidebar"])
        self.sidebar.connect("row-selected", self.on_category)
        panes.append(Gtk.ScrolledWindow(child=self.sidebar, hscrollbar_policy=Gtk.PolicyType.NEVER,
                                        width_request=200, height_request=HEIGHT))
        self.content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.scroll = Gtk.ScrolledWindow(child=self.content, hscrollbar_policy=Gtk.PolicyType.NEVER,
                                         width_request=PER_LINE * 40 + 16, height_request=HEIGHT)
        panes.append(self.scroll)
        box.append(panes)

        self.clear = Gtk.Button(label="No icon", css_classes=["flat"], halign=Gtk.Align.START)
        self.clear.connect("clicked", lambda _b: self.pick(None))
        box.append(self.clear)
        self.set_child(box)
        self.connect("show", self.on_show)

    # ---- opening ----

    def on_show(self, _popover):
        self.name, self.color, self.current = self.context()
        self.suggested = icons.suggest(self.name or "")
        self.clear.set_visible(self.current is not None)
        self.fill_sidebar()
        self.shown = self.opening()
        self.entry.set_text("")
        self.fill()
        focus_soon(self.entry)

    def fill_sidebar(self):
        """Suggested first when the name gives any, then each category with its count."""
        self.sidebar.remove_all()
        self.row_for = {}
        rows = [(SUGGESTED, "Suggested", "sparkles", len(self.suggested))] if self.suggested else []
        rows += [(group, label, symbol, len(icons.IN_GROUP[group])) for group, label, _c, symbol in icons.GROUPS]
        for key, label, symbol, count in rows:
            line = Gtk.Box(spacing=10, margin_top=2, margin_bottom=2)
            line.append(IconMark(symbol, None, 16))
            line.append(Gtk.Label(label=label, xalign=0, hexpand=True, ellipsize=Pango.EllipsizeMode.END))
            line.append(Gtk.Label(label=str(count), css_classes=["dim-label", "caption"]))
            row = Gtk.ListBoxRow(child=line)
            row.key = key
            self.row_for[key] = row
            row.update_property([Gtk.AccessibleProperty.LABEL], [f"{label}, {count} icons"])
            self.sidebar.append(row)

    def opening(self):
        """Where the picker opens: the current icon's category, else the suggestions, else the first category."""
        if self.current in icons.GROUP_OF:
            return icons.GROUP_OF[self.current]
        return SUGGESTED if self.suggested else icons.GROUPS[0][0]

    # ---- what the grid shows ----

    def fill(self):
        """With a query, its matches best first, across every category. Without, the chosen category."""
        query = self.entry.get_text().strip()
        if query:
            self.sidebar.unselect_all()
            found = [e["name"] for e in icons.search(query)]
            if not found:
                self.show_grid(None, [], empty="No icons match")
            else:
                note = f"{MOST_FOUND} of {len(found):,} shown. Type more to narrow them." \
                    if len(found) > MOST_FOUND else None
                self.show_grid(f"{len(found):,} found" if len(found) > 1 else "1 found", found[:MOST_FOUND], note)
            return
        row = self.row_for.get(self.shown)
        if row is None:  # not opened yet
            return
        if self.sidebar.get_selected_row() is row:
            self.show_category(row.key)
        else:
            self.sidebar.select_row(row)  # on_category shows it

    def on_category(self, _list, row):
        if row is None:
            return
        self.shown = row.key
        if self.entry.get_text().strip():
            self.entry.set_text("")  # search-changed fills the chosen category
        else:
            self.show_category(row.key)

    def show_category(self, key):
        if key == SUGGESTED:
            self.show_grid(f"Suggested for “{self.name}”", self.suggested)
        else:
            self.show_grid(icons.LABELS[key], icons.IN_GROUP[key])

    def show_grid(self, heading, names, note=None, empty=None):
        while child := self.content.get_first_child():
            self.content.remove(child)
        if heading:
            self.content.append(Gtk.Label(label=heading, xalign=0, margin_top=4, margin_start=4,
                                          css_classes=["heading"]))
        if empty:
            self.content.append(Gtk.Label(label=empty, margin_top=12, css_classes=["dim-label"]))
        grid = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, homogeneous=True, valign=Gtk.Align.START,
                           min_children_per_line=PER_LINE, max_children_per_line=PER_LINE)
        for name in names:
            button = Gtk.Button(child=IconMark(name, self.color, 20), tooltip_text=icons.title(name),
                                css_classes=["flat", "icon-choice"] + (["current"] if name == self.current else []))
            button.update_property([Gtk.AccessibleProperty.LABEL], [icons.title(name)])
            button.connect("clicked", lambda _b, n=name: self.pick(n))
            grid.append(button)
        self.content.append(grid)
        if note:
            self.content.append(Gtk.Label(label=note, wrap=True, xalign=0, margin_top=6, margin_start=4,
                                          css_classes=["dim-label", "caption"]))
        self.first = names[0] if names else None
        self.scroll.get_vadjustment().set_value(0)

    # ---- choosing ----

    def pick_first(self):
        """Enter takes the best match."""
        if self.entry.get_text().strip() and self.first:
            self.pick(self.first)

    def pick(self, name):
        self.popdown()
        self.choose(name)

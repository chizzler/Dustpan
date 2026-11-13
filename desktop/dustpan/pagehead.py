"""The page heading: a large title at the top of each page, so a project reads as a place. See spec/pagehead.md."""

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango  # noqa: E402

CSS = """
.page-head { margin: 10px 0 14px 0; }
.page-eyebrow { font-size: 0.78em; font-weight: 700; letter-spacing: 0.08em; color: alpha(currentColor, 0.6); }
.page-title { font-size: 30px; font-weight: 800; letter-spacing: -0.02em; }
.page-meta { color: alpha(currentColor, 0.6); }
.page-symbol { color: var(--accent-color); }
button.page-up { min-height: 0; padding: 0; margin: 0; background: none; box-shadow: none; }
button.page-up:hover .page-eyebrow { color: currentColor; }
button.page-place { min-height: 26px; padding: 0 10px 0 8px; border-radius: 999px; font-weight: normal;
                    background: alpha(currentColor, 0.05); box-shadow: inset 0 0 0 1px alpha(currentColor, 0.14); }
button.page-place:hover { background: alpha(currentColor, 0.1); }
"""

MARK_PX = 26  # a project's icon or a page's symbol, beside the 30 px title
HEADER_AFTER_PX = 72  # scrolled this far, the heading is out of sight and the header bar shows the page's name


def page_head(title, mark=None, eyebrow=None, meta=None, places=(), up=None):
    """The heading widget.

    mark: a widget before the title (a project's icon, a page's symbol). eyebrow: a short line above it, such as
    the parent project or the date. meta: a dim line below.
    places: (mark, name, on_click) for sub-projects, shown as buttons to walk into.
    up: makes the eyebrow a link, to the parent project.
    """
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, css_classes=["page-head"])
    if eyebrow:
        text = Gtk.Label(label=eyebrow.upper(), xalign=0, ellipsize=Pango.EllipsizeMode.END,
                         css_classes=["page-eyebrow"])
        if up is None:
            box.append(text)
        else:
            text.set_ellipsize(Pango.EllipsizeMode.NONE)  # a button would shrink it to its ellipsis
            text.set_wrap(True)
            link = Gtk.Button(child=text, halign=Gtk.Align.START, css_classes=["flat", "page-up"],
                              tooltip_text=f"Open {eyebrow.rsplit(' › ', 1)[-1]}")
            link.connect("clicked", lambda _b: up())
            box.append(link)
    line = Gtk.Box(spacing=12)
    if mark is not None:
        line.append(mark)
    line.append(Gtk.Label(label=title, xalign=0, hexpand=True, wrap=True, css_classes=["page-title"],
                          accessible_role=Gtk.AccessibleRole.HEADING))
    box.append(line)
    if meta:
        box.append(Gtk.Label(label=meta, xalign=0, margin_top=4, css_classes=["page-meta"]))
    if places:
        flow = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=6, row_spacing=6, margin_top=8,
                           max_children_per_line=12, halign=Gtk.Align.START)
        for place_mark, name, on_click in places:
            content = Gtk.Box(spacing=6)
            content.append(place_mark)
            content.append(Gtk.Label(label=name, ellipsize=Pango.EllipsizeMode.END, max_width_chars=24))
            button = Gtk.Button(child=content, css_classes=["page-place"], tooltip_text=f"Open {name}")
            button.connect("clicked", lambda _b, go=on_click: go())
            flow.append(button)
        box.append(flow)
    return box

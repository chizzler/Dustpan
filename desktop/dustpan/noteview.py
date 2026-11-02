"""A task's notes in the window: Markdown written as text, shown formatted. See spec/notes.md."""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk, Pango  # noqa: E402

from .markdown import pango, parse  # noqa: E402

HEADING_CLASSES = {1: "title-2", 2: "title-3", 3: "title-4"}  # deeper headings are "heading"


def text_label(markup, css=()):
    """markup comes from markdown.pango(), which escapes all text. <a> is GTK's, so Pango alone would refuse it."""
    return Gtk.Label(label=markup, use_markup=True, xalign=0, wrap=True, wrap_mode=Pango.WrapMode.WORD_CHAR,
                     selectable=True, css_classes=list(css))


def note_view(src):
    """The note, formatted. Links open in the browser; nothing else is loaded."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    add_blocks(box, parse(src))
    return box


def add_blocks(box, blocks):
    for block in blocks:
        box.append(block_widget(block))


def block_widget(block):
    kind = block["t"]
    if kind == "p":
        return text_label(pango(block["c"]))
    if kind == "h":
        return text_label(pango(block["c"]), [HEADING_CLASSES.get(block["level"], "heading")])
    if kind == "pre":
        label = Gtk.Label(label=block["v"], xalign=0, selectable=True, css_classes=["monospace"])
        return Gtk.ScrolledWindow(child=label, vscrollbar_policy=Gtk.PolicyType.NEVER,
                                  propagate_natural_height=True, css_classes=["note-code"])
    if kind == "quote":
        quote = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, css_classes=["note-quote"])
        add_blocks(quote, block["c"])
        return quote
    if kind == "list":
        return list_widget(block)
    if kind == "table":
        return table_widget(block)
    # An attachment image: Dustpan doesn't fetch attachments yet.
    return text_label(GLib.markup_escape_text(f"Image: {block['alt'] or 'attachment'}"), ["dim-label"])


def list_widget(block):
    items = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
    checks = block.get("checks") or [None] * len(block["items"])
    for n, (item, check) in enumerate(zip(block["items"], checks)):
        if check is not None:
            marker = "☑" if check else "☐"
        else:
            marker = f"{block['start'] + n}." if block["ordered"] else "•"
        row = Gtk.Box(spacing=8)
        row.append(Gtk.Label(label=marker, valign=Gtk.Align.START, css_classes=["dim-label"]))
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, hexpand=True)
        add_blocks(content, item)
        row.append(content)
        items.append(row)
    return items


def table_widget(block):
    grid = Gtk.Grid(column_spacing=16, row_spacing=4)
    align = {"center": 0.5, "right": 1}
    for r, row in enumerate([block["head"], *block["rows"]]):
        for c, cell in enumerate(row):
            markup = pango(cell)
            label = text_label(f"<b>{markup}</b>" if r == 0 else markup)
            label.set_xalign(align.get(block["align"][c], 0))
            grid.attach(label, c, r, 1, 1)
    return Gtk.ScrolledWindow(child=grid, vscrollbar_policy=Gtk.PolicyType.NEVER, propagate_natural_height=True)


class NotesEditor(Adw.PreferencesGroup):
    """Notes in the task editor: Write is plain Markdown, Preview shows it formatted. Ctrl+Enter saves."""

    def __init__(self, text, on_save):
        super().__init__(title="Notes")
        self.buffer = Gtk.TextBuffer(text=text)
        # The "monospace" class, as css_classes would undo monospace=True.
        editor = Gtk.TextView(buffer=self.buffer, wrap_mode=Gtk.WrapMode.WORD_CHAR, accepts_tab=False,
                              top_margin=10, bottom_margin=10, left_margin=12, right_margin=12,
                              css_classes=["card", "note-editor", "monospace"])
        editor.update_property([Gtk.AccessibleProperty.LABEL], ["Notes, in Markdown"])
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", lambda _c, keyval, _code, state: self.on_key(keyval, state, on_save))
        editor.add_controller(keys)
        self.editor = editor

        self.preview = Adw.Bin(css_classes=["card", "note-preview"])
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vhomogeneous=False)
        self.stack.add_named(editor, "write")
        self.stack.add_named(self.preview, "preview")
        self.add(self.stack)

        self.mode = Adw.ToggleGroup(css_classes=["flat", "round"], valign=Gtk.Align.CENTER)
        self.mode.add(Adw.Toggle(name="write", label="Write"))
        self.mode.add(Adw.Toggle(name="preview", label="Preview"))
        self.mode.connect("notify::active-name", lambda *_a: self.show(self.mode.get_active_name()))
        self.set_header_suffix(self.mode)
        # A note opens formatted. An empty one opens ready to write.
        self.mode.set_active_name("preview" if text.strip() else "write")
        self.show(self.mode.get_active_name())

    def text(self):
        start, end = self.buffer.get_bounds()
        return self.buffer.get_text(start, end, False)

    def show(self, mode):
        if mode == "preview":
            text = self.text()
            if text.strip():
                self.preview.set_child(note_view(text))
            else:
                self.preview.set_child(Gtk.Label(label="No notes", xalign=0, css_classes=["dim-label"]))
        self.stack.set_visible_child_name(mode)

    def on_key(self, keyval, state, on_save):
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter) and state & Gdk.ModifierType.CONTROL_MASK:
            on_save()
            return True
        return False

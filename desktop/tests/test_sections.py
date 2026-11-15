"""Section colours and icons in the editor and project-list headings."""

import unittest
from unittest.mock import patch

from .test_icons import WindowCase, iter_children, texts
from .test_standalone import HAS_DISPLAY

from gi.repository import Gtk  # noqa: E402 (test_standalone selects the GTK version)


@unittest.skipUnless(HAS_DISPLAY, "needs a display")
class SectionWindowTest(WindowCase):
    def setUp(self):
        super().setUp()
        self.project_id = self.window.writer.add_project("Work", color="#ef4444")
        self.window.show_project(self.project_id)

    def dialog(self, section_id=None):
        from dustpan.dialogs import SectionDialog

        section = self.window.store.rows("section").get(section_id)
        dialog = SectionDialog(self.window, self.project_id, section)
        dialog.present(self.window)
        self.addCleanup(dialog.force_close)
        return dialog

    def test_section_marks_and_plain_headings(self):
        from dustpan.widgets import Dot, IconMark, section_mark

        for row in ({}, {"icon": "from-the-future"}):
            self.assertIsNone(section_mark(row))
        icon = section_mark({"icon": "hourglass"})
        self.assertIsInstance(icon, IconMark)
        self.assertEqual((icon.size, icon.color), (14, None))  # text colour, not the project's red
        coloured = section_mark({"icon": "hourglass", "color": "#f59e0b"})
        self.assertEqual(coloured.color, "rgb(245,158,11)")
        for row in ({"color": "#22c55e"}, {"color": "#22c55e", "icon": "from-the-future"}):
            self.assertIsInstance(section_mark(row), Dot)

        writer = self.window.writer
        writer.add_section(self.project_id, "Waiting", color="#f59e0b", icon="hourglass")
        writer.add_section(self.project_id, "Doing", color="#22c55e")
        writer.add_section(self.project_id, "Next")
        with patch.object(self.window, "heading", wraps=self.window.heading) as heading:
            self.window.after_edit()
        marks = {call.args[1]: call.args[3] for call in heading.call_args_list if len(call.args) == 4}
        self.assertIsInstance(marks["Waiting"], IconMark)
        self.assertIsInstance(marks["Doing"], Dot)
        self.assertIsNone(marks["Next"])
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        plain = self.window.heading(column, "Next", lambda: [])
        self.assertIsInstance(plain.get_first_child(), Gtk.Label)  # no empty icon slot

    def test_new_section_picker_saves_colour_and_icon(self):
        dialog = self.dialog()
        self.assertFalse(dialog.save_button.get_sensitive())
        dialog.name_row.set_text("Dog walking")
        self.assertTrue(dialog.save_button.get_sensitive())
        picker = dialog.icon_button.get_popover()
        picker.on_show(picker)
        self.assertEqual(picker.first, "dog")  # suggestions use the section name
        dialog.pick_color("#22c55e")
        picker.on_show(picker)
        self.assertEqual(picker.color, "#22c55e")
        picker.entry.set_text("hourglass")
        picker.fill()
        picker.pick_first()  # Return's handler
        self.assertEqual(dialog.icon, "hourglass")
        self.assertIn("hourglass", texts(dialog.icon_button))
        dialog.save()
        section = next(iter(self.window.store.rows("section").values()))
        self.assertEqual((section.get("name"), section.get("color"), section.get("icon")),
                         ("Dog walking", "#22c55e", "hourglass"))

    def test_edit_clear_and_undo_then_noop(self):
        sid = self.window.writer.add_section(self.project_id, "Waiting", color="#f59e0b", icon="hourglass")
        dialog = self.dialog(sid)
        self.assertEqual((dialog.color, dialog.icon), ("#f59e0b", "hourglass"))
        dialog.name_row.set_text("Next")
        dialog.pick_color(None)
        dialog.icon_button.get_popover().pick(None)  # No icon
        dialog.save()
        row = self.window.store.rows("section")[sid]
        self.assertEqual((row.get("name"), row.get("color"), row.get("icon")), ("Next", None, None))
        self.assertTrue(self.window.undo_last())
        row = self.window.store.rows("section")[sid]
        self.assertEqual((row.get("name"), row.get("color"), row.get("icon")),
                         ("Waiting", "#f59e0b", "hourglass"))
        count = self.window.store.outbox_count()
        dialog = self.dialog(sid)
        with patch.object(self.window, "after_edit") as refresh:
            dialog.save()
            refresh.assert_not_called()
        self.assertEqual(self.window.store.outbox_count(), count)

    def test_cancel_and_untouched_unknown_icon(self):
        sid = self.window.writer.add_section(self.project_id, "Old")
        # Seed a value a newer client could have written, with a winning clock.
        self.window.writer.commit(lambda: [("section", sid, {"icon": "from-the-future", "color": "#ABCDEF"})])
        count = self.window.store.outbox_count()
        dialog = self.dialog(sid)
        self.assertEqual(dialog.icon, "from-the-future")
        dialog.pick_icon("dog")
        dialog.pick_color("#22c55e")
        dialog.force_close()
        self.assertEqual(self.window.store.outbox_count(), count)
        dialog = self.dialog(sid)
        dialog.name_row.set_text("New")
        dialog.save()
        row = self.window.store.rows("section")[sid]
        self.assertEqual((row.get("name"), row.get("color"), row.get("icon")),
                         ("New", "#ABCDEF", "from-the-future"))

    def test_none_swatch_and_invalid_save_keep_the_dialog(self):
        from dustpan.widgets import NoColour

        dialog = self.dialog()
        self.assertIn("None", texts(dialog.icon_button))
        # Traverse the dialog to check the colour row offers None rather than Theme.
        def descendants(widget):
            for child in iter_children(widget):
                yield child
                yield from descendants(child)

        choices = [w for w in descendants(dialog) if isinstance(w, Gtk.ToggleButton)]
        none = next(w for w in choices if w.get_tooltip_text() == "None")
        self.assertIsInstance(none.get_child(), NoColour)
        self.assertTrue(none.get_active())
        dialog.name_row.set_text("Waiting")
        dialog.icon = "no-such-icon"
        with patch.object(dialog, "close") as close:
            dialog.save()
            close.assert_not_called()
        self.assertEqual(self.window.store.rows("section"), {})

    def test_rename_preserves_style_synced_while_editor_is_open_and_undo_only_renames(self):
        writer = self.window.writer
        sid = writer.add_section(self.project_id, "Waiting", color="#f59e0b", icon="hourglass")
        dialog = self.dialog(sid)
        writer.edit_section(sid, {"color": "#3b82f6", "icon": "dog"})  # a winning remote update
        self.window.after_edit()
        count = self.window.store.outbox_count()
        dialog.name_row.set_text("Renamed")
        dialog.save()
        row = self.window.store.rows("section")[sid]
        self.assertEqual((row.get("name"), row.get("color"), row.get("icon")), ("Renamed", "#3b82f6", "dog"))
        self.assertEqual(self.window.store.outbox_count(), count + 1)
        self.assertTrue(self.window.undo_last())
        row = self.window.store.rows("section")[sid]
        self.assertEqual((row.get("name"), row.get("color"), row.get("icon")), ("Waiting", "#3b82f6", "dog"))

    def test_clearing_icon_preserves_remote_name_and_colour_and_undo_restores_latest_icon(self):
        writer = self.window.writer
        sid = writer.add_section(self.project_id, "Waiting", color="#f59e0b", icon="hourglass")
        dialog = self.dialog(sid)
        writer.edit_section(sid, {"name": "Remote name", "color": "#3b82f6", "icon": "dog"})
        self.window.after_edit()
        count = self.window.store.outbox_count()
        dialog.pick_icon(None)  # explicitly changing this field wins over the remote value
        dialog.save()
        row = self.window.store.rows("section")[sid]
        self.assertEqual((row.get("name"), row.get("color"), row.get("icon")), ("Remote name", "#3b82f6", None))
        self.assertEqual(self.window.store.outbox_count(), count + 1)
        self.assertTrue(self.window.undo_last())
        self.assertEqual(self.window.store.rows("section")[sid].get("icon"), "dog")

    def test_untouched_or_reverted_editor_does_not_write_over_remote_changes(self):
        writer = self.window.writer
        sid = writer.add_section(self.project_id, "Waiting", color="#f59e0b", icon="hourglass")
        for reverted in (False, True):
            with self.subTest(reverted=reverted):
                dialog = self.dialog(sid)
                original = self.window.store.rows("section")[sid]
                if reverted:
                    dialog.pick_color("#22c55e")
                    dialog.pick_color(original.get("color"))
                    dialog.pick_icon("sprout")
                    dialog.pick_icon(original.get("icon"))
                writer.edit_section(sid, {"name": f"Remote {reverted}", "color": "#3b82f6", "icon": "dog"})
                self.window.after_edit()
                count = self.window.store.outbox_count()
                dialog.name_row.set_text(f"  {original.get('name')}  ")  # whitespace is not a rename
                with patch.object(self.window, "after_edit") as refresh:
                    dialog.save()
                    refresh.assert_not_called()
                self.assertEqual(self.window.store.outbox_count(), count)
                row = self.window.store.rows("section")[sid]
                self.assertEqual((row.get("name"), row.get("color"), row.get("icon")),
                                 (f"Remote {reverted}", "#3b82f6", "dog"))

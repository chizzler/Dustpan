"""Project icons: the pinned catalogue, search, suggestions, writes and the window. See spec/icons.md."""

import json
import os
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

from dustpan import icons
from dustpan.icons import sync

from .test_writes import WriterCase
from .vectors import read

FOLDER = sync.FOLDER


class CatalogueTest(unittest.TestCase):
    def test_catalogue_is_the_pinned_copy(self):
        ours = (pathlib.Path(icons.__file__).parent / "catalogue.json").read_text()
        self.assertEqual(ours, read(f"{FOLDER}/catalogue.json"))

    def test_opentodo_icons_draw_as_in_the_pinned_clone(self):
        """All of Lucide is vendored; the 411 OpenTodo knows have the same path data as OpenTodo's."""
        theirs = sync.bodies(read(f"{FOLDER}/lucide.ts")) | sync.bodies(read(f"{FOLDER}/catalogue.paths.ts"))
        for entry in json.loads(read(f"{FOLDER}/catalogue.json")):
            self.assertEqual(icons.path(entry["name"]), theirs[entry["name"]], entry["name"])

    def test_all_of_lucide(self):
        self.assertEqual(icons.LUCIDE["version"], sync.VERSION)
        self.assertEqual(len(icons.ENTRIES), len(icons.PATHS))
        self.assertGreaterEqual(len(icons.ENTRIES), 1800)
        self.assertEqual(sum(e["server"] for e in icons.ENTRIES), len(icons.CATALOGUE))
        names = {e["name"] for e in icons.ENTRIES}
        self.assertEqual(len(names), len(icons.ENTRIES))
        self.assertLessEqual(icons.SERVER, names)  # OpenTodo's old names, like trash-2, stay the names written
        self.assertNotIn("trash", names)

    def test_every_icon_draws_as_well_formed_svg(self):
        for name in icons.PATHS:
            root = ET.fromstring(icons.svg(name, "#16a34a", 16))
            self.assertEqual((root.get("stroke"), root.get("width"), root.get("stroke-width")), ("#16a34a", "16", "1.5"))
        self.assertEqual(ET.fromstring(icons.svg("trash-2", "#000000", 20)).get("width"), "20")

    def test_categories(self):
        groups = {e["category"] for e in icons.ENTRIES}
        self.assertEqual(groups, set(icons.LABELS))
        self.assertTrue(all(icons.known(icon) for icon in (symbol for *_rest, symbol in icons.GROUPS)))
        where = {e["name"]: e["category"] for e in icons.ENTRIES}
        # OpenTodo's own: Lucide files the briefcase under transport.
        self.assertEqual((where["briefcase"], where["house"], where["dog"]), ("work", "home", "animals"))
        self.assertEqual((where["user-cog"], where["cat"]), ("people", "animals"))  # Lucide's account, a user
        for group in icons.LABELS:
            self.assertGreaterEqual(sum(1 for e in icons.ENTRIES if e["category"] == group), 10, group)
        first = [e["server"] for e in icons.ENTRIES if e["category"] == "home"]
        self.assertEqual(first, sorted(first, reverse=True))  # OpenTodo's first in each category

    def test_known_names(self):
        for name in ("sprout", "paw-print", "briefcase", "zodiac-leo", "home"):  # home: Lucide's old name
            self.assertTrue(icons.known(name))
        for name in (None, "", "Sprout", "not-an-icon", 7):
            self.assertFalse(icons.known(name))
        self.assertEqual(icons.title("paw-print"), "paw print")


class SearchTest(unittest.TestCase):
    """The web app's search tests (catalogue.test.tsx), on our port."""

    def names(self, query):
        return [e["name"] for e in icons.search(query)]

    def test_order_matches_the_web_app(self):
        dog = self.names("dog")
        self.assertEqual(dog[0], "dog")
        self.assertIn("paw-print", dog)
        self.assertTrue({"sprout", "flower"} <= set(self.names("plant")))
        self.assertIn("pizza", self.names("food"))
        self.assertEqual(len(self.names("")), len(icons.OFFERED))
        self.assertEqual(self.names("zzzz-no-such-icon"), [])

    def test_ranks(self):
        dog = next(e for e in icons.ENTRIES if e["name"] == "dog")
        self.assertEqual([icons.rank(dog, q) for q in ("dog", "do", "og", "pet", "animals", "car")], [0, 1, 2, 3, 4, -1])
        devices = [e for e in icons.ENTRIES if e["category"] == "devices"]
        self.assertTrue(devices and all(icons.rank(e, "devices") >= 0 for e in devices))  # the category's label
        self.assertEqual(icons.rank(next(e for e in icons.ENTRIES if e["name"] == "dice-5"), "gaming"), 4)

    def test_opentodo_icons_win_ties(self):
        found = icons.search("car")
        self.assertEqual(found[0]["name"], "car")
        server = [e["server"] for e in found if icons.rank(e, "car") == 1]
        self.assertEqual(server, sorted(server, reverse=True))


class SuggestTest(unittest.TestCase):
    def test_whole_words_from_the_name(self):
        self.assertEqual(icons.suggest("Car")[:2], ["car", "car-front"])
        self.assertNotIn("carrot", icons.suggest("Car"))
        self.assertEqual(icons.suggest("Dog walking")[0], "dog")
        self.assertIn("book", icons.suggest("Books"))  # a plural tries its singular
        self.assertIn("briefcase", icons.suggest("Work"))

    def test_nothing_to_go_on(self):
        for name in ("", "  ", "a b", "Dustpan"):
            self.assertEqual(icons.suggest(name), [])
        self.assertLessEqual(len(icons.suggest("Work stuff")), 8)


class IconWritesTest(WriterCase):
    def project(self, project_id):
        return self.store.rows("project")[project_id]

    def test_add_project_with_and_without_an_icon(self):
        with_icon = self.writer.add_project("Garden", icon="sprout")
        self.assertEqual(self.project(with_icon).get("icon"), "sprout")
        without = self.writer.add_project("Work")
        self.assertNotIn("icon", {o["field"] for o in self.outbox() if o["entityId"] == without})
        with self.assertRaises(ValueError):
            self.writer.add_project("Bad", icon="not-an-icon")

    def test_edit_sets_clears_and_undoes(self):
        self.seed("project", "p1", name="Home", color="#ef4444")
        done = self.writer.edit_project("p1", {"icon": "house"})
        self.assertEqual([(o["field"], o["value"]) for o in self.outbox()], [("icon", "house")])
        self.writer.revert(done.undo)
        self.assertIsNone(self.project("p1").get("icon"))
        self.writer.edit_project("p1", {"icon": "house"})
        self.writer.edit_project("p1", {"icon": None})
        self.assertIsNone(self.project("p1").get("icon"))
        with self.assertRaises(ValueError):
            self.writer.edit_project("p1", {"icon": "unicorn-rainbow"})

    def test_an_unknown_stored_icon_is_kept_when_unchanged(self):
        """A newer client's icon survives an edit of something else here."""
        self.seed("project", "p1", name="Home", color="#ef4444", icon="from-the-future")
        before = self.store.outbox_count()
        self.writer.edit_project("p1", {"name": "House", "color": "#ef4444", "icon": "from-the-future"})
        self.assertEqual([o["field"] for o in self.outbox()][before:], ["name"])
        self.assertEqual(self.project("p1").get("icon"), "from-the-future")


class ThemeColourTest(WriterCase):
    """No colour (None) is the "Theme" choice. The writer still picks a colour when none is asked for."""

    def test_add_with_theme_or_auto_colour(self):
        from dustpan.writes import PROJECT_PALETTE

        themed = self.writer.add_project("Plain", color=None)
        self.assertIsNone(self.store.rows("project")[themed].get("color"))
        self.assertIn(("color", None), [(o["field"], o["value"]) for o in self.outbox() if o["entityId"] == themed])
        auto = self.writer.add_project("Work")
        self.assertIn(self.store.rows("project")[auto].get("color"), PROJECT_PALETTE)
        for bad in ("red", "#12345", 7):
            with self.assertRaises(ValueError):
                self.writer.add_project("Bad", color=bad)

    def test_edit_to_theme_and_back_with_undo(self):
        self.seed("project", "p1", name="Home", color="#ef4444")
        done = self.writer.edit_project("p1", {"color": None})
        self.assertIsNone(self.store.rows("project")["p1"].get("color"))
        self.writer.revert(done.undo)
        self.assertEqual(self.store.rows("project")["p1"].get("color"), "#ef4444")
        with self.assertRaises(ValueError):
            self.writer.edit_project("p1", {"color": "red"})


from .test_standalone import HAS_DISPLAY  # noqa: E402  (it sets the GTK version)

from gi.repository import Gtk  # noqa: E402


class WindowCase(unittest.TestCase):
    """A standalone window on a throwaway profile, refreshing as if on screen."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        env = patch.dict(os.environ, {"DUSTPAN_CONFIG": f"{tmp.name}/config", "DUSTPAN_DATA": f"{tmp.name}/data"})
        env.start()
        self.addCleanup(env.stop)
        from dustpan.app import Window

        self.window = Window(None, cfg=None)
        self.addCleanup(self.window.store.close)
        self.addCleanup(self.window.destroy)
        mapped = patch.object(self.window, "get_mapped", return_value=True)  # refresh as if on screen
        mapped.start()
        self.addCleanup(mapped.stop)

    def mark(self, project_id):
        return self.window.rows_by_key[project_id].get_child().get_first_child()


@unittest.skipUnless(HAS_DISPLAY, "needs a display")
class IconWindowTest(WindowCase):

    def test_sidebar_shows_icons_and_dots_in_one_width(self):
        from dustpan.widgets import Dot, IconMark, project_mark

        writer = self.window.writer
        garden = writer.add_project("Garden", icon="sprout")
        plain = writer.add_project("Plain")
        self.window.after_edit()
        self.assertIsInstance(self.mark(garden), IconMark)
        self.assertEqual(self.mark(garden).name, "sprout")
        slot = self.mark(plain)
        self.assertIsInstance(slot, Dot)
        self.assertEqual(slot.get_size_request()[0], self.mark(garden).get_size_request()[0])
        # A name a newer client stored, which this one can't draw: the dot.
        self.assertIsInstance(project_mark({"icon": "from-the-future"}), Dot)

    def test_dialog_picks_an_icon_and_saves_it(self):
        from dustpan.dialogs import ProjectDialog

        project_id = self.window.writer.add_project("Dog walking")
        self.window.after_edit()
        dialog = ProjectDialog(self.window, self.window.store.rows("project")[project_id])
        dialog.present(self.window)
        picker = dialog.icon_button.get_popover()
        picker.on_show(picker)
        self.assertEqual(picker.first, "dog")  # the suggestions come first
        picker.entry.set_text("sprout")
        picker.fill()
        picker.pick_first()
        self.assertEqual(dialog.icon, "sprout")
        dialog.save()
        self.assertEqual(self.window.store.rows("project")[project_id].get("icon"), "sprout")
        dialog = ProjectDialog(self.window, self.window.store.rows("project")[project_id])
        dialog.present(self.window)
        dialog.pick_icon(None)
        dialog.save()
        self.assertIsNone(self.window.store.rows("project")[project_id].get("icon"))

    def test_labels_draw_as_tags_not_dots(self):
        """A project without an icon has a dot; a label has the tag, so the two never look alike."""
        from dustpan.app import LABEL
        from dustpan.labelpicker import LabelPicker
        from dustpan.widgets import NO_COLOUR, IconMark, label_mark

        plain = self.window.writer.add_project("Plain")
        label_id = self.window.writer.add_label("Errands", color="#2563eb")
        self.window.after_edit()
        self.assertNotIsInstance(self.mark(plain), IconMark)
        tag = self.mark(LABEL + label_id)
        self.assertIsInstance(tag, IconMark)
        self.assertEqual((tag.name, tag.color, tag.solid), ("tag", "rgb(37,99,235)", True))  # solid, not line work
        self.assertIn(b'fill="rgb(37,99,235)"', icons.svg("tag", tag.color, 16, solid=True))
        self.assertIn(b'fill="none"', icons.svg("tag", tag.color, 16))  # a project's icons stay lines
        picker = LabelPicker(self.window.labels_for_picker())
        self.assertIsInstance(picker.list.get_row_at_index(0).get_child().get_first_child(), IconMark)
        self.assertEqual(label_mark(None).color, IconMark("tag", NO_COLOUR).color)  # labels keep the grey
        from dustpan.widgets import CHIP_TAG_PX, label_chip
        chip_tag = label_chip("Errands", "#2563eb").get_first_child()  # task rows' chips show a small tag too
        self.assertEqual((chip_tag.name, chip_tag.solid, chip_tag.size), ("tag", True, CHIP_TAG_PX))
        self.assertNotIn("tag", [e["name"] for e in icons.search("tag")])  # not offered to projects
        self.assertNotIn("tag", icons.suggest("Price tag"))
        self.assertTrue(icons.known("tag"))  # one stored by another client still draws

    def test_picker_browses_by_category_and_searches_everything(self):
        from dustpan.iconpicker import MOST_FOUND, SUGGESTED, IconPicker

        def shown(picker):
            grid = [c for c in iter_children(picker.content) if isinstance(c, Gtk.FlowBox)][0]
            return [child.get_child().get_tooltip_text() for child in iter_children(grid)]

        picked = []
        picker = IconPicker(lambda: ("Dog walking", "#16a34a", None), picked.append)
        picker.on_show(picker)
        keys = list(picker.row_for)
        self.assertEqual(keys, [SUGGESTED, *icons.LABELS])
        self.assertEqual(picker.sidebar.get_selected_row().key, SUGGESTED)
        self.assertEqual(shown(picker)[0], "dog")

        picker.sidebar.select_row(picker.row_for["animals"])
        animals = [icons.title(e["name"]) for e in icons.ENTRIES if e["category"] == "animals"]
        self.assertEqual(shown(picker), animals)

        picker.entry.set_text("e")  # most icons: the first few hundred, and a note
        picker.fill()
        self.assertIsNone(picker.sidebar.get_selected_row())
        self.assertEqual(len(shown(picker)), MOST_FOUND)
        picker.entry.set_text("")
        picker.fill()
        self.assertEqual(picker.sidebar.get_selected_row().key, "animals")  # back where it was

        # With an icon set, the picker opens on its category. No name: no Suggested.
        picker = IconPicker(lambda: ("", None, "zodiac-leo"), picked.append)
        picker.on_show(picker)
        self.assertNotIn(SUGGESTED, list(picker.row_for))
        self.assertEqual(picker.sidebar.get_selected_row().key, "people")

    def test_theme_colour_draws_in_the_text_colour(self):
        from dustpan.dialogs import ProjectDialog
        from dustpan.widgets import Dot, project_mark

        self.assertIsNone(project_mark({"icon": "house", "color": None}).color)  # read from the theme at each draw
        self.assertIsNone(project_mark({"color": None}).rgba)
        self.assertEqual(project_mark({"icon": "house", "color": "oops"}).color, Dot(None).rgba.to_string())  # the grey
        self.assertIsNotNone(Dot(None).rgba)  # other dots keep the grey

        project_id = self.window.writer.add_project("Home")
        self.window.after_edit()
        dialog = ProjectDialog(self.window, self.window.store.rows("project")[project_id])
        dialog.present(self.window)
        dialog.pick(None)
        dialog.save()
        self.assertIsNone(self.window.store.rows("project")[project_id].get("color"))
        self.assertIsInstance(self.mark(project_id), Dot)

    def test_pickers_focus_their_search_once(self):
        """Regression: an idle grab_focus repeated forever, so a project's name couldn't be typed after picking an icon.

        Both pickers focus their search through focus_soon.
        """
        from gi.repository import GLib

        from dustpan.dialogs import ProjectDialog

        def settle():
            for _ in range(50):
                GLib.MainContext.default().iteration(False)

        dialog = ProjectDialog(self.window)
        dialog.present(self.window)
        picker = dialog.icon_button.get_popover()
        calls = []
        real = picker.entry.grab_focus
        picker.entry.grab_focus = lambda: calls.append(1) or real()
        picker.on_show(picker)
        settle()
        self.assertEqual(len(calls), 1)


def iter_children(widget):
    child = widget.get_first_child()
    while child is not None:
        yield child
        child = child.get_next_sibling()


def texts(widget):
    """Every label's text under widget, in order."""
    found = []
    for child in iter_children(widget):
        if isinstance(child, Gtk.Label):
            found.append(child.get_label())
        found += texts(child)
    return found


@unittest.skipUnless(HAS_DISPLAY, "needs a display")
class PageHeadTest(WindowCase):
    """The page heading (spec/pagehead.md)."""

    def test_a_project_page_is_a_place(self):
        writer = self.window.writer
        home = writer.add_project("Home", icon="house")
        garden = writer.add_project("Garden", parent_id=home)
        writer.add_task("Fix the gate", project_id=home)
        self.window.after_edit()
        self.window.open_page(home)
        head = texts(self.window.page_heading(home, self.window.rows_by_key[home]))
        self.assertEqual(head[:3], ["PROJECT", "Home", "1 open task"])
        self.assertIn("Garden", head)  # its sub-project, to walk into
        self.window.open_page(garden)
        self.assertEqual(texts(self.window.page_heading(garden, self.window.rows_by_key[garden]))[:3],
                         ["HOME", "Garden", "Nothing open"])

    def test_the_inbox_counts_what_it_shows(self):
        from dustpan.app import INBOX

        self.window.writer.quick_add("Call mum today")  # planned, so not in the sidebar's count
        self.window.after_edit()
        self.assertEqual(texts(self.window.page_heading(INBOX, self.window.rows_by_key[INBOX]))[:2],
                         ["Inbox", "1 open task"])

    def test_today_and_the_header_title(self):
        from datetime import date

        from dustpan.app import TODAY

        self.window.after_edit()
        head = texts(self.window.page_heading(TODAY, self.window.rows_by_key[TODAY]))
        self.assertEqual(head[0], f"{date.fromisoformat(self.window.today):%A %-d %B}".upper())
        self.assertEqual(head[1], "Today")
        self.assertEqual(self.window.title.get_title(), "")  # the heading is on screen
        adjustment = self.window.content.get_vadjustment()
        adjustment.configure(200, 0, 1000, 10, 100, 100)
        self.assertEqual(self.window.title.get_title(), "Today")
        adjustment.set_value(0)
        self.assertEqual(self.window.title.get_title(), "")

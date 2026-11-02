"""Reordering the sidebar: the drop rule for its rows, and the writes for projects, labels and views."""

import unittest

from dustpan.dragdrop import AFTER, BEFORE, INSIDE, ItemPlace, place_item
from dustpan.writes import CannotEdit

from .test_writes import WriterCase


class PlaceItemTest(unittest.TestCase):
    def test_before_after_and_inside(self):
        self.assertEqual(place_item("b", None, [], BEFORE, "x"), ItemPlace(None, before="b"))
        self.assertEqual(place_item("b", "p", [], AFTER, "x"), ItemPlace("p", after="b"))
        self.assertEqual(place_item("b", None, ["c"], INSIDE, "x"), ItemPlace("b"))

    def test_after_an_open_parent_is_its_first_child(self):
        self.assertEqual(place_item("b", None, ["c", "d"], AFTER, "x"), ItemPlace("b", before="c"))
        self.assertEqual(place_item("b", None, ["x", "d"], AFTER, "x"), ItemPlace("b", before="d"))
        self.assertEqual(place_item("b", None, ["x"], AFTER, "x"), ItemPlace("b"))

    def test_never_onto_itself_or_its_subtree(self):
        self.assertIsNone(place_item("x", None, [], BEFORE, "x"))
        self.assertIsNone(place_item("c", "x", [], INSIDE, "x", below={"c"}))


class SidebarWritesTest(WriterCase):
    def setUp(self):
        super().setUp()
        for i, pid in enumerate(["work", "home", "garden"]):
            self.seed("project", pid, name=pid.title(), position=(i + 1) * 1000, parent_id=None, archived=False)
        self.seed("project", "shed", name="Shed", position=1000, parent_id="garden", archived=False)
        for i, lid in enumerate(["a", "b", "c"]):
            self.seed("label", lid, name=lid, position=(i + 1) * 1000)
        for i, vid in enumerate(["v1", "v2", "v3"]):
            self.seed("view", vid, name=vid, query="today", position=(i + 1) * 1000, kind="list")

    def order(self, entity, parent=None):
        rows = [r for r in self.store.rows(entity).values()
                if r.get("deleted_at") is None and (entity != "project" or r.get("parent_id") == parent)]
        return [r.id for r in sorted(rows, key=lambda r: (r.get("position"), r.id))]

    def test_place_project_among_siblings(self):
        self.writer.place_project("garden", None, before="work")
        self.assertEqual(self.order("project"), ["garden", "work", "home"])

    def test_nest_and_unnest_a_project_with_undo(self):
        done = self.writer.place_project("home", "garden", after="shed")
        self.assertEqual((self.order("project"), self.order("project", "garden")), (["work", "garden"], ["shed", "home"]))
        self.writer.place_project("shed", None, after="work")
        self.assertEqual(self.order("project"), ["work", "shed", "garden"])
        self.writer.revert(done.undo)
        self.assertIsNone(self.store.rows("project")["home"].get("parent_id"))

    def test_a_project_cant_go_under_itself_or_below(self):
        with self.assertRaises(CannotEdit):
            self.writer.place_project("garden", "shed")
        with self.assertRaises(CannotEdit):
            self.writer.place_project("garden", "garden")

    def test_move_project_stays_among_siblings(self):
        self.writer.move_project("home", -1)
        self.assertEqual(self.order("project"), ["home", "work", "garden"])
        before = len(self.outbox())
        self.writer.move_project("shed", -1)  # an only child: nowhere to go
        self.assertEqual(len(self.outbox()), before)

    def test_place_label_and_view(self):
        self.writer.place_label("c", before="a")
        self.assertEqual(self.order("label"), ["c", "a", "b"])
        self.writer.place_view("v1", after="v3")
        self.assertEqual(self.order("view"), ["v2", "v3", "v1"])
        self.writer.move_view("v1", -1)
        self.assertEqual(self.order("view"), ["v2", "v1", "v3"])

    def test_a_move_writes_only_positions(self):
        before = len(self.outbox())
        self.writer.place_label("c", before="b")
        self.assertEqual({o["field"] for o in self.outbox()[before:]}, {"position"})


if __name__ == "__main__":
    unittest.main()

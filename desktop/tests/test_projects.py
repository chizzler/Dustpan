import unittest

from dustpan.model import project_path, project_sections, snapshot
from dustpan.writes import PROJECT_PALETTE, CannotEdit

from tests.test_writes import WriterCase


class ProjectsTest(WriterCase):
    def project(self, project_id):
        return self.store.rows("project")[project_id]

    def section(self, section_id):
        return self.store.rows("section")[section_id]

    def written(self):
        return {(o["entityId"], o["field"]): o["value"] for o in self.outbox()}

    # ---- projects ----

    def test_add_project_writes_every_field_last_among_siblings(self):
        self.seed("project", "p1", name="Home", color=PROJECT_PALETTE[0], position=self.now + 7)
        project_id = self.writer.add_project("  Garden ", parent_id="p1")
        row = self.project(project_id)
        self.assertEqual(row.get("name"), "Garden")
        self.assertEqual(row.get("parent_id"), "p1")
        self.assertEqual(row.get("position"), self.now)  # no sibling under p1
        self.assertIs(row.get("archived"), False)
        self.assertIsNone(row.get("deleted_at"))
        self.assertEqual(row.get("color"), PROJECT_PALETTE[1])  # the first colour no project uses
        top = self.writer.add_project("Work")
        self.assertEqual(self.project(top).get("position"), self.now + 8)  # past p1, + 1 like the web app
        self.assertEqual(len({o["ts"] for o in self.outbox() if o["entityId"] == top}), 1)

    def test_add_project_refuses_empty_name_and_archived_parent(self):
        self.seed("project", "old", name="Old", archived=True)
        with self.assertRaises(CannotEdit):
            self.writer.add_project("  ")
        with self.assertRaises(CannotEdit):
            self.writer.add_project("x", parent_id="old")
        with self.assertRaises(CannotEdit):
            self.writer.add_project("x", parent_id="missing")
        self.assertEqual(self.store.outbox_count(), 0)

    def test_edit_project_writes_only_changes_and_undoes(self):
        self.seed("project", "p1", name="Home", color="#ef4444", parent_id=None)
        self.writer.edit_project("p1", {"name": "Home", "color": "#ef4444"})
        self.assertEqual(self.store.outbox_count(), 0)
        done = self.writer.edit_project("p1", {"name": " House ", "color": "#3b82f6"})
        self.assertEqual(self.written(), {("p1", "name"): "House", ("p1", "color"): "#3b82f6"})
        self.writer.revert(done.undo)
        self.assertEqual((self.project("p1").get("name"), self.project("p1").get("color")), ("Home", "#ef4444"))

    def test_move_project_writes_parent_and_last_position(self):
        self.seed("project", "a", name="A", parent_id=None, position=1)
        self.seed("project", "b", name="B", parent_id=None, position=2)
        self.seed("project", "c", name="C", parent_id="b", position=self.now + 50)
        self.writer.edit_project("a", {"parent_id": "b"})
        self.assertEqual(self.written(), {("a", "parent_id"): "b", ("a", "position"): self.now + 51})

    def test_move_project_refuses_itself_and_its_descendants(self):
        self.seed("project", "a", name="A", parent_id=None)
        self.seed("project", "b", name="B", parent_id="a")
        self.seed("project", "c", name="C", parent_id="b")
        for parent in ("a", "c"):
            with self.assertRaises(CannotEdit):
                self.writer.edit_project("a", {"parent_id": parent})
        self.writer.edit_project("c", {"parent_id": None})
        self.assertEqual(self.project("c").get("parent_id"), None)

    def test_archive_cascades_and_unarchive_does_not(self):
        self.seed("project", "a", name="A", parent_id=None)
        self.seed("project", "b", name="B", parent_id="a")
        self.seed("project", "c", name="C", parent_id="b", archived=True)
        self.seed("project", "d", name="D", parent_id="b", deleted_at=5)
        done = self.writer.archive_project("a")
        self.assertEqual(self.written(), {("a", "archived"): True, ("b", "archived"): True})
        self.writer.unarchive_project("a")
        self.assertIs(self.project("a").get("archived"), False)
        self.assertIs(self.project("b").get("archived"), True)
        self.writer.revert(done.undo)
        self.assertIs(self.project("b").get("archived"), False)  # false, not null
        self.assertIs(self.project("c").get("archived"), True)

    def test_delete_project_lifts_sub_projects_and_keeps_tasks(self):
        self.seed("project", "top", name="Top", parent_id=None)
        self.seed("project", "mid", name="Mid", parent_id="top")
        self.seed("project", "low", name="Low", parent_id="mid")
        self.seed("task", "t1", title="Task", project_id="mid", completed_at=None)
        done = self.writer.delete_project("mid")
        self.assertEqual(self.written(), {("low", "parent_id"): "top", ("mid", "deleted_at"): self.now})
        self.assertEqual(self.task("t1").get("project_id"), "mid")
        snap = snapshot(self.store)
        self.assertNotIn("t1", {t.id for t in snap.tasks})
        self.assertEqual([n.id for n in snap.projects[0].children], ["low"])
        self.writer.revert(done.undo)
        self.assertEqual(self.project("low").get("parent_id"), "mid")
        self.assertIn("t1", {t.id for t in snapshot(self.store).tasks})

    def test_project_path_stops_at_deleted_ancestors_and_cycles(self):
        self.seed("project", "a", name="A", parent_id=None, deleted_at=5)
        self.seed("project", "b", name="B", parent_id="a")
        self.seed("project", "c", name="C", parent_id="b")
        self.seed("project", "x", name="X", parent_id="y")
        self.seed("project", "y", name="Y", parent_id="x")
        projects = self.store.rows("project")
        self.assertEqual(project_path("c", projects), "B › C")
        self.assertEqual(project_path("x", projects), "Y › X")

    # ---- sections ----

    def test_add_section_goes_last(self):
        self.seed("project", "p1", name="Home")
        first = self.writer.add_section("p1", " Kitchen ")
        self.assertEqual(self.section(first).get("position"), self.now)
        second = self.writer.add_section("p1", "Garden")
        self.assertEqual(self.section(second).get("position"), self.now + 1000)
        self.assertEqual(self.section(first).get("name"), "Kitchen")
        self.assertEqual(self.section(first).get("project_id"), "p1")

    def test_add_section_refuses_inbox_archived_project_and_empty_name(self):
        self.seed("project", "old", name="Old", archived=True)
        for project_id, name in ((None, "x"), ("old", "x"), ("missing", "x")):
            with self.assertRaises(CannotEdit):
                self.writer.add_section(project_id, name)
        self.seed("project", "p1", name="Home")
        with self.assertRaises(CannotEdit):
            self.writer.add_section("p1", " ")
        self.assertEqual(self.store.outbox_count(), 0)

    def test_rename_section(self):
        self.seed("section", "s1", name="Old", project_id="p1")
        self.writer.rename_section("s1", "Old")
        self.assertEqual(self.store.outbox_count(), 0)
        done = self.writer.rename_section("s1", " New ")
        self.assertEqual(self.section("s1").get("name"), "New")
        self.writer.revert(done.undo)
        self.assertEqual(self.section("s1").get("name"), "Old")

    def test_add_section_with_optional_colour_and_icon(self):
        self.seed("project", "p1", name="Home")
        plain = self.writer.add_section("p1", "Next")
        self.assertNotIn("color", self.section(plain).values)
        self.assertNotIn("icon", self.section(plain).values)
        styled = self.writer.add_section("p1", "Waiting", color="#f59e0b", icon="hourglass")
        row = self.section(styled)
        self.assertEqual((row.get("color"), row.get("icon")), ("#f59e0b", "hourglass"))
        self.assertEqual(len({o["ts"] for o in self.outbox() if o["entityId"] == styled}), 1)

    def test_edit_section_changes_one_batch_and_undo_restores_it(self):
        self.seed("section", "s1", name="Old", project_id="p1", color="#123456", icon="house", position=42)
        done = self.writer.edit_section("s1", {"name": " Waiting ", "color": "#f59e0b", "icon": "hourglass"})
        self.assertEqual(self.written(), {("s1", "name"): "Waiting", ("s1", "color"): "#f59e0b",
                                          ("s1", "icon"): "hourglass"})
        self.assertEqual(len({o["ts"] for o in self.outbox()}), 1)
        self.assertEqual((self.section("s1").get("project_id"), self.section("s1").get("position")), ("p1", 42))
        self.writer.revert(done.undo)
        row = self.section("s1")
        self.assertEqual((row.get("name"), row.get("color"), row.get("icon")), ("Old", "#123456", "house"))

    def test_section_style_fields_can_be_omitted_cleared_and_undone(self):
        self.seed("section", "s1", name="Waiting", color="#f59e0b", icon="hourglass")
        self.writer.edit_section("s1", {"color": "#22c55e"})
        self.assertEqual(self.section("s1").get("icon"), "hourglass")
        self.assertEqual(self.written(), {("s1", "color"): "#22c55e"})
        done = self.writer.edit_section("s1", {"color": None, "icon": None})
        self.assertIsNone(self.section("s1").get("color"))
        self.assertIsNone(self.section("s1").get("icon"))
        self.assertEqual(self.written()[("s1", "icon")], None)
        self.writer.revert(done.undo)
        self.assertEqual((self.section("s1").get("color"), self.section("s1").get("icon")),
                         ("#22c55e", "hourglass"))

    def test_unchanged_section_style_including_unknown_icons_writes_nothing(self):
        self.seed("section", "s1", name="Old", color="#ABCDEF", icon="from-the-future")
        done = self.writer.edit_section("s1", {"name": "Old", "color": "#ABCDEF", "icon": "from-the-future"})
        self.assertFalse(done.undo)
        self.assertEqual(self.store.outbox_count(), 0)
        self.writer.edit_section("s1", {"name": "New", "icon": "from-the-future"})
        self.assertEqual(self.written(), {("s1", "name"): "New"})
        self.assertEqual(self.section("s1").get("icon"), "from-the-future")

    def test_invalid_section_styles_do_not_partially_write(self):
        self.seed("project", "p1", name="Home")
        self.seed("section", "s1", name="Old", color="#f59e0b", icon="hourglass")
        for field, bad in (("color", "red"), ("color", 7), ("icon", "no-such-icon"), ("icon", 7)):
            with self.subTest(field=field, bad=bad):
                with self.assertRaises(ValueError):
                    self.writer.add_section("p1", "Bad", **{field: bad})
                with self.assertRaises(ValueError):
                    self.writer.edit_section("s1", {"name": "New", field: bad})
        with self.assertRaises(ValueError):
            self.writer.edit_section("s1", {"project_id": "elsewhere"})
        with self.assertRaises(CannotEdit):
            self.writer.edit_section("s1", {"name": " "})
        self.assertEqual(self.store.outbox_count(), 0)
        self.assertEqual(self.section("s1").get("name"), "Old")
        self.assertEqual(len(self.store.rows("section")), 1)
        self.seed("section", "gone", name="Gone", deleted_at=1)
        for sid in ("gone", "missing"):
            with self.assertRaises(CannotEdit):
                self.writer.edit_section(sid, {"icon": "hourglass"})

    def test_move_section_steps_one_place(self):
        self.seed("project", "p1", name="Home")
        for i, sid in enumerate(("s1", "s2", "s3")):
            self.seed("section", sid, name=sid, project_id="p1", position=(i + 1) * 1000)
        self.writer.move_section("s1", -1)
        self.assertEqual(self.store.outbox_count(), 0)
        self.writer.move_section("s1", 1)
        names = [s.name for s in project_sections(snapshot(self.store), "p1")[1:]]
        self.assertEqual(names, ["s2", "s1", "s3"])
        self.assertEqual(self.written(), {("s1", "position"): 2500})

    def test_delete_section_clears_open_tasks_only(self):
        self.seed("section", "s1", name="Kitchen", project_id="p1")
        self.seed("task", "open", title="Open", project_id="p1", section_id="s1", completed_at=None)
        self.seed("task", "done", title="Done", project_id="p1", section_id="s1", completed_at=5)
        self.seed("task", "gone", title="Gone", project_id="p1", section_id="s1", completed_at=None, deleted_at=5)
        done = self.writer.delete_section("s1")
        self.assertEqual(self.written(), {("s1", "deleted_at"): self.now, ("open", "section_id"): None})
        self.assertEqual(len({o["ts"] for o in self.outbox()}), 1)
        self.writer.revert(done.undo)
        self.assertIsNone(self.section("s1").get("deleted_at"))
        self.assertEqual(self.task("open").get("section_id"), "s1")


if __name__ == "__main__":
    unittest.main()

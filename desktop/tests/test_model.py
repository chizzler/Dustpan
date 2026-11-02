import unittest

from dustpan.model import build_tree, project_sections, snapshot
from dustpan.store import Clock, Row, Store


def row(row_id, parent=None, position=0, parent_ts=0, parent_device="d"):
    r = Row(row_id, {"parent_id": parent, "position": position})
    r.clocks["parent_id"] = Clock(parent_ts, parent_device)
    return r


def ids(nodes):
    return [(n.id, ids(n.children)) for n in nodes]


class BuildTreeTest(unittest.TestCase):
    def tree(self, rows):
        return ids(build_tree(rows, lambda r: r.get("parent_id")))

    def test_siblings_sort_by_position_then_id(self):
        rows = [row("b", position=1), row("a", position=1), row("c", position=0)]
        self.assertEqual(self.tree(rows), [("c", []), ("a", []), ("b", [])])

    def test_missing_parent_is_a_root(self):
        self.assertEqual(self.tree([row("a", parent="gone")]), [("a", [])])

    def test_two_cycle_roots_at_newest_parent_clock(self):
        rows = [row("x", parent="y", parent_ts=10), row("y", parent="x", parent_ts=20)]
        self.assertEqual(self.tree(rows), [("y", [("x", [])])])

    def test_cycle_tie_breaks_on_device_then_id(self):
        rows = [row("x", parent="y", parent_ts=5, parent_device="b"),
                row("y", parent="x", parent_ts=5, parent_device="a")]
        self.assertEqual(self.tree(rows), [("x", [("y", [])])])
        rows = [row("x", parent="y", parent_ts=5), row("y", parent="x", parent_ts=5)]
        self.assertEqual(self.tree(rows), [("y", [("x", [])])])

    def test_three_cycle_with_a_tail(self):
        rows = [row("a", parent="b", parent_ts=1), row("b", parent="c", parent_ts=3),
                row("c", parent="a", parent_ts=2), row("tail", parent="a")]
        self.assertEqual(self.tree(rows), [("b", [("a", [("c", []), ("tail", [])])])])

    def test_self_parent_is_a_root(self):
        self.assertEqual(self.tree([row("a", parent="a")]), [("a", [])])


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)
        self.ts = 0

    def put(self, entity, entity_id, **fields):
        for name, value in fields.items():
            self.ts += 1
            self.store.apply({"id": str(self.ts), "entity": entity, "entityId": entity_id,
                              "field": name, "value": value, "ts": self.ts, "device": "d"})

    def test_hides_deleted_completed_and_orphaned_tasks(self):
        self.put("project", "p", name="P")
        self.put("project", "gone", name="Gone", deleted_at=1)
        self.put("task", "open", title="Open", project_id="p")
        self.put("task", "done", title="Done", project_id="p", completed_at=1)
        self.put("task", "deleted", title="Deleted", project_id="p", deleted_at=1)
        self.put("task", "orphan", title="Orphan", project_id="gone")
        self.put("task", "inbox", title="Inbox", project_id=None)
        snap = snapshot(self.store)
        self.assertEqual([t.id for t in snap.tasks_by_project["p"]], ["open"])
        self.assertEqual([t.id for t in snap.tasks_by_project[None]], ["inbox"])
        self.assertEqual([n.id for n in snap.projects], ["p"])

    def test_archived_parent_lifts_child_project_to_top(self):
        self.put("project", "parent", name="Parent", archived=True)
        self.put("project", "child", name="Child", parent_id="parent")
        self.assertEqual([n.id for n in snapshot(self.store).projects], ["child"])

    def test_stale_section_falls_back_to_no_section(self):
        self.put("project", "p", name="P")
        self.put("project", "q", name="Q")
        self.put("section", "s", name="S", project_id="p", position=1)
        self.put("section", "old", name="Old", project_id="p", deleted_at=1)
        self.put("section", "other", name="Other", project_id="q")
        for tid, sid in [("a", "s"), ("b", "old"), ("c", "other"), ("d", "unknown")]:
            self.put("task", tid, title=tid, project_id="p", section_id=sid)
        secs = project_sections(snapshot(self.store), "p")
        self.assertEqual([(s.id, sorted(n.id for n in s.tasks)) for s in secs],
                         [(None, ["b", "c", "d"]), ("s", ["a"])])

    def test_subtask_follows_parent_section_and_completed_parent_releases_it(self):
        self.put("project", "p", name="P")
        self.put("section", "s", name="S", project_id="p")
        self.put("task", "parent", title="Parent", project_id="p", section_id="s")
        self.put("task", "child", title="Child", project_id="p", parent_id="parent")
        secs = project_sections(snapshot(self.store), "p")
        self.assertEqual(ids(secs[1].tasks), [("parent", [("child", [])])])
        self.put("task", "parent", completed_at=1)
        secs = project_sections(snapshot(self.store), "p")
        self.assertEqual(ids(secs[0].tasks), [("child", [])])


if __name__ == "__main__":
    unittest.main()

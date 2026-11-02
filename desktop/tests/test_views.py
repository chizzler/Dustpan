import unittest

from dustpan.filters import Context
from dustpan.model import count_open, project_sections, snapshot
from dustpan.store import Row, Store
from dustpan.views import (compare_tasks, group_tasks, in_today, in_upcoming, is_inbox_task, manual_order, run_view,
                           sorted_tasks, today_groups, upcoming_groups)

from .test_filters import task
from .vectors import load

TODAY = "2026-10-16"


def ids(tasks):
    return [t.id for t in tasks]


def heading(day):
    return f"day {day}"


class InboxVectorsTest(unittest.TestCase):
    def test_cases(self):
        for v in load("inbox"):
            with self.subTest(v["name"]):
                # Parents chain as p0 (nearest), p1, …; a missing parent is p0 with no row.
                parents = v.get("parents", [])
                rows = {f"p{i}": Row(f"p{i}", {**p, "parent_id": f"p{i + 1}" if i + 1 < len(parents) else None})
                        for i, p in enumerate(parents)}
                has_parent = bool(parents) or v.get("parent_missing")
                row = Row("t", {**v["task"], "parent_id": "p0" if has_parent else None})
                self.assertEqual(is_inbox_task(row, rows.get), v["inbox"])


class TodayUpcomingTest(unittest.TestCase):
    def test_today_takes_hard_dates_and_started_tasks(self):
        tasks = [task("due", due={"date": TODAY}), task("late", due={"date": "2026-10-01"}),
                 task("deadline", deadline=TODAY, due={"date": "2026-10-30"}), task("started", start="2026-10-10"),
                 task("parked-but-due", start="someday", due={"date": TODAY}), task("parked", start="someday"),
                 task("done", due={"date": TODAY}, completed_at=1), task("tomorrow", due={"date": "2026-10-17"})]
        self.assertEqual(ids(t for t in tasks if in_today(t, TODAY)), ["due", "late", "deadline", "started", "parked-but-due"])

    def test_today_groups_earlier_first_and_sorts_by_time(self):
        tasks = [task("all-day", due={"date": TODAY}), task("nine", due={"date": TODAY, "time": "09:00"}),
                 task("passed", deadline="2026-10-12"), task("passed-but-planned", deadline="2026-10-12", due={"date": TODAY}),
                 task("late", due={"date": "2026-10-02"})]
        groups = today_groups(tasks, TODAY)
        self.assertEqual([(g.heading, ids(g.tasks)) for g in groups],
                         [("Earlier", ["late", "passed"]), ("Today", ["nine", "all-day", "passed-but-planned"])])

    def test_upcoming_lists_by_day_with_deadlines_after_dues(self):
        tasks = [task("deadline", deadline="2026-10-18"), task("due", due={"date": "2026-10-18"}),
                 task("soon", due={"date": "2026-10-17", "time": "08:00"}), task("now", due={"date": TODAY}),
                 task("deferred", start="2026-10-20"), task("deferred-in-project", start="2026-10-20", project_id="p"),
                 task("parked", start="someday", due={"date": "2026-10-19"})]
        self.assertTrue(in_upcoming(tasks[0], TODAY))
        groups = upcoming_groups(tasks, TODAY, heading)
        self.assertEqual([(g.key, ids(g.tasks)) for g in groups],
                         [("2026-10-17", ["soon"]), ("2026-10-18", ["due", "deadline"]), ("2026-10-20", ["deferred"])])


class SortGroupTest(unittest.TestCase):
    def setUp(self):
        self.tasks = [task("a", priority=2, due={"date": "2026-10-20"}, position=3, labels=["l2", "l1"]),
                      task("b", priority=1, position=1, project_id="p1"),
                      task("c", priority=4, due={"date": "2026-10-18", "time": "10:00"}, position=2, project_id="gone")]

    def test_due_keeps_undated_last_both_ways(self):
        self.assertEqual(ids(sorted_tasks(self.tasks, compare_tasks("due", "asc"))), ["c", "a", "b"])
        self.assertEqual(ids(sorted_tasks(self.tasks, compare_tasks("due", "desc"))), ["a", "c", "b"])

    def test_priority_descending_lists_p1_first(self):
        self.assertEqual(ids(sorted_tasks(self.tasks, compare_tasks("priority", "desc"))), ["b", "a", "c"])

    def test_manual_order_then_position(self):
        self.assertEqual(ids(sorted_tasks(self.tasks, manual_order(["a", "x"], "asc"))), ["a", "b", "c"])
        self.assertEqual(ids(sorted_tasks(self.tasks, manual_order(["a"], "desc"))), ["c", "b", "a"])

    def test_groups(self):
        labels = [Row("l1", {"name": "one"}), Row("l2", {"name": "two"})]
        projects = [("p1", "Home")]

        def groups(by):
            return [(g.heading, ids(g.tasks)) for g in group_tasks(self.tasks, by, TODAY, labels, projects, heading)]

        self.assertEqual(groups("label"), [("one", ["a"]), ("two", ["a"]), ("No label", ["b", "c"])])
        self.assertEqual(groups("project"), [("Inbox", ["a"]), ("Home", ["b"]), ("Other", ["c"])])
        self.assertEqual(groups("due"), [("day 2026-10-18", ["c"]), ("day 2026-10-20", ["a"]), ("No date", ["b"])])
        self.assertEqual(groups("priority"), [("Priority 1", ["b"]), ("Priority 2", ["a"]), ("No priority", ["c"])])
        self.assertEqual(groups("none"), [("", ["a", "b", "c"])])

    def test_run_view(self):
        ctx = Context(TODAY, self.tasks, [], [])
        view = Row("v", {"query": "p1 | p2", "group_by": "someday-option", "sort_by": "priority", "sort_dir": "desc"})
        result = run_view(view, ctx, self.tasks, [], [("p1", "Home")], heading)
        self.assertEqual([(g.key, ids(g.tasks)) for g in result.groups], [("inbox", ["a"]), ("p1", ["b"])])
        self.assertEqual(result.count, 2)
        broken = run_view(Row("v", {"query": "p1 &"}), ctx, self.tasks, [], [], heading)
        self.assertEqual((broken.groups, broken.error), ([], 'Expected a term after "&" at position 4'))

    def test_show_completed_counts_open_only(self):
        tasks = self.tasks + [task("d", priority=1, position=5, completed_at=1)]
        view = Row("v", {"query": "p1", "show_completed": True, "group_by": "none"})
        result = run_view(view, Context(TODAY, tasks, [], []), tasks, [], [], heading)
        self.assertEqual((ids(result.groups[0].tasks), result.count), (["b", "d"], 1))


def op(entity, entity_id, field, value):
    return {"id": f"{entity_id}-{field}", "entity": entity, "entityId": entity_id, "field": field, "value": value,
            "ts": 1, "device": "d"}


class SnapshotTest(unittest.TestCase):
    def test_inbox_keeps_planned_tasks_apart(self):
        store = Store(":memory:")
        self.addCleanup(store.close)
        for task_id, fields in {"free": {}, "dated": {"due": {"date": TODAY}}, "sub": {"parent_id": "dated"},
                                "parked": {"start": "someday"}, "p": {"project_id": "p1", "start": "someday"},
                                "q": {"project_id": "p1"}}.items():
            for name, value in {"title": task_id, "deleted_at": None, "project_id": None, **fields}.items():
                store.apply(op("task", task_id, name, value))
        store.apply(op("project", "p1", "name", "Home"))
        store.apply(op("view", "v1", "kind", "dashboard"))
        store.apply(op("view", "v2", "query", "p1"))
        snap = snapshot(store)
        sections = project_sections(snap, None)
        self.assertEqual([(s.name, [n.id for n in s.tasks], s.is_list) for s in sections],
                         [("", ["free"], True), ("Planned, no project", ["dated", "parked"], False)])
        self.assertEqual([n.id for n in sections[1].tasks[0].children], ["sub"])
        self.assertEqual((count_open(snap, None, TODAY), count_open(snap, "p1", TODAY)), (1, 1))
        self.assertEqual(ids(snap.views), ["v2"])


if __name__ == "__main__":
    unittest.main()

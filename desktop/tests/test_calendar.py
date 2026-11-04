import unittest

from dustpan import calendar


def task(task_id, day=None, at=None, **fields):
    due = {"date": day, **({"time": at} if at else {})} if day else None
    return {"id": task_id, "due": due, "priority": 4, "position": 0, "completed_at": None, "deleted_at": None,
            "project_id": None, **fields}


def ids(tasks):
    return [t["id"] for t in tasks]


class MonthTest(unittest.TestCase):
    # The first three cases are month.test.ts's.
    def test_six_weeks_monday_or_sunday_first(self):
        mon = calendar.month_grid("2026-11-15", 1)
        self.assertEqual((len(mon), mon[0][0], mon[5][6]), (6, "2026-10-26", "2026-12-06"))
        sun = calendar.month_grid("2026-11-15", 0)
        self.assertEqual(sun[0][0], "2026-11-01")

    def test_a_month_that_needs_six_rows(self):
        grid = calendar.month_grid("2026-08-10", 1)
        self.assertEqual((grid[0][0], grid[5][0]), ("2026-07-27", "2026-08-31"))

    def test_a_cell_keeps_a_line_for_more(self):
        self.assertEqual(calendar.visible_rows([1, 2, 3], 3), ([1, 2, 3], 0))
        self.assertEqual(calendar.visible_rows([1, 2, 3, 4, 5], 3), ([1, 2], 3))

    def test_add_months_clamps_to_the_last_day(self):
        self.assertEqual(calendar.add_months("2026-01-31", 1), "2026-02-28")
        self.assertEqual(calendar.add_months("2026-11-04", 2), "2027-01-04")
        self.assertEqual(calendar.add_months("2026-01-15", -1), "2025-12-15")

    def test_week_dates(self):
        self.assertEqual(calendar.week_dates("2026-11-04", 1)[0], "2026-11-02")
        self.assertEqual(calendar.week_dates("2026-11-04", 0)[0], "2026-11-01")
        self.assertEqual(calendar.week_dates("2026-11-01", 1)[0], "2026-10-26")


class TasksTest(unittest.TestCase):
    def test_a_day_orders_timed_first_then_priority_then_position(self):
        tasks = [task("p4a", "2026-11-03", position=2), task("p4b", "2026-11-03", position=1),
                 task("p1", "2026-11-03", priority=1), task("late", "2026-11-03", "18:00"),
                 task("early", "2026-11-03", "08:30"), task("other", "2026-11-04")]
        days = calendar.by_day(tasks)
        self.assertEqual(ids(days["2026-11-03"]), ["early", "late", "p1", "p4b", "p4a"])
        self.assertEqual(ids(days["2026-11-04"]), ["other"])

    def test_which_tasks_show(self):
        tasks = [task("in", "2026-11-03"), task("before", "2026-10-01"), task("undated"),
                 task("done", "2026-11-03", completed_at=5), task("gone", "2026-11-03", deleted_at=5),
                 task("archived", "2026-11-03", project_id="old")]
        shown = calendar.calendar_tasks(tasks, {"old"}, "2026-10-26", "2026-12-06")
        self.assertEqual(ids(shown), ["in"])
        with_done = calendar.calendar_tasks(tasks, {"old"}, "2026-10-26", "2026-12-06", show_completed=True)
        self.assertEqual(ids(with_done), ["in", "done"])

    def test_deadline_markers_skip_tasks_due_that_day(self):
        tasks = [task("a", deadline="2026-11-10", title="b"), task("b", "2026-11-10", deadline="2026-11-10"),
                 task("c", deadline="2026-11-10", priority=1, title="z"), task("d", deadline="2026-11-10", completed_at=1),
                 task("e", deadline="2027-01-01")]
        markers = calendar.deadline_markers(tasks, set(), "2026-10-26", "2026-12-06")
        self.assertEqual({day: ids(ts) for day, ts in markers.items()}, {"2026-11-10": ["c", "a"]})

    def test_day_load(self):
        tasks = [task("a", estimate_minutes=300), task("b", estimate_minutes=240), task("c"),
                 task("d", estimate_minutes=60, completed_at=1)]
        self.assertEqual(calendar.day_load(tasks), (540, 1, True))
        self.assertEqual(calendar.day_load(tasks[:1]), (300, 0, False))


if __name__ == "__main__":
    unittest.main()


def h(hours):
    return int(hours * 60)


class LayoutTest(unittest.TestCase):
    """layout.test.ts's cases."""

    def lay(self, blocks, *args):
        placed, overflow = calendar.layout_day(blocks, *args)
        return {b["id"]: b for b in placed}, overflow, placed

    def test_disjoint_and_touching_blocks_take_the_full_width(self):
        m, overflow, _ = self.lay([("a", h(9), h(10)), ("b", h(10), h(11)), ("c", h(13), h(13.5))])
        self.assertEqual(overflow, [])
        self.assertTrue(all((b["lane"], b["lanes"], b["overlap"]) == (0, 1, False) for b in m.values()))

    def test_same_time_side_by_side_ordered_by_id(self):
        m, _, _ = self.lay([("y", h(10), h(10.5)), ("x", h(10), h(10.5))])
        self.assertEqual((m["x"]["lane"], m["y"]["lane"], m["x"]["lanes"], m["x"]["overlap"]), (0, 1, 2, True))

    def test_nested_and_chained(self):
        m, _, _ = self.lay([("inner1", h(9.5), h(10)), ("outer", h(9), h(12)), ("inner2", h(10.5), h(11))])
        self.assertEqual([(m[k]["lane"], m[k]["lanes"]) for k in ("outer", "inner1", "inner2")], [(0, 2), (1, 2), (1, 2)])
        m, _, _ = self.lay([("a", h(9), h(10)), ("b", h(9.5), h(10.5)), ("c", h(10), h(11))])
        self.assertEqual([m[k]["lane"] for k in "abc"], [0, 1, 0])

    def test_clusters_size_independently(self):
        m, _, _ = self.lay([("a", h(9), h(10)), ("b", h(9), h(10)), ("c", h(9), h(10)), ("d", h(14), h(15))])
        self.assertEqual(([m[k]["lanes"] for k in "abc"], m["d"]["lanes"]), ([3, 3, 3], 1))

    def test_no_two_visible_blocks_collide(self):
        blocks = [(f"t{i}", (i * 37) % 600 + 360, (i * 37) % 600 + 360 + 15 + (i * 13) % 90) for i in range(30)]
        _, _, placed = self.lay(blocks, 100)
        for x in placed:
            self.assertLess(x["lane"], x["lanes"])
            for y in placed:
                if x["id"] != y["id"] and x["lane"] == y["lane"]:
                    self.assertFalse(x["start"] < y["end"] and y["start"] < x["end"])

    def test_caps_at_four_lanes(self):
        m, overflow, placed = self.lay([(k, h(10), h(11)) for k in "abcdef"])
        self.assertEqual([b["id"] for b in placed if not b["hidden"]], ["a", "b", "c"])
        self.assertEqual(overflow, [dict(lane=3, lanes=4, start=h(10), end=h(11), ids=["d", "e", "f"])])
        _, overflow, placed = self.lay([(k, h(10), h(11)) for k in "abcd"])
        self.assertEqual((overflow, [b["lane"] for b in placed]), ([], [0, 1, 2, 3]))

    def test_repairs_empty_blocks_and_ignores_input_order(self):
        _, _, placed = self.lay([("z", 600, 600), ("w", 600, 590)])
        self.assertEqual([b["end"] for b in placed], [601, 601])
        blocks = [("a", 540, 600), ("b", 570, 630), ("c", 600, 660), ("d", 540, 720), ("e", 800, 830)]
        self.assertEqual(calendar.layout_day(blocks), calendar.layout_day(list(reversed(blocks))))

    def test_short_blocks_sit_side_by_side_without_the_marker(self):
        m, _, placed = self.lay([("hot", 810, 825), ("etsy", 825, 830), ("news", 830, 840), ("plan", 840, 850)], 4, 25)
        self.assertGreater(len({b["lane"] for b in placed}), 1)
        self.assertFalse(any(b["overlap"] for b in placed))
        m, _, _ = self.lay([("a", 600, 660), ("b", 630, 690), ("c", 720, 780)], 4, 25)
        self.assertTrue(m["a"]["overlap"] and m["b"]["overlap"])
        self.assertEqual((m["c"]["lane"], m["c"]["lanes"]), (0, 1))


class BlockTest(unittest.TestCase):
    def test_block_for(self):
        self.assertEqual(calendar.block_for(task("a", "2026-11-04", "09:30", estimate_minutes=90)), (570, 660, True))
        self.assertEqual(calendar.block_for(task("b", "2026-11-04", "23:45")), (1425, 1440, False))
        self.assertIsNone(calendar.block_for(task("c", "2026-11-04")))
        self.assertIsNone(calendar.parse_time("24:00"))

import unittest
from datetime import datetime

from dustpan import calendar_rules as calendar
from dustpan.dragdrop import Stretch, ToDay, ToSlot


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

    def test_completed_tasks_show_on_their_due_or_the_day_they_were_done(self):
        noon = int(datetime(2026, 11, 5, 12).timestamp() * 1000)
        tasks = [task("open", "2026-11-03"), task("done-due", "2026-11-03", completed_at=noon),
                 task("done-undated", completed_at=noon), task("skipped", "2026-11-03", completed_at=noon, skipped=True)]
        shown = calendar.calendar_tasks(tasks, set(), "2026-10-26", "2026-12-06", show_completed=True)
        self.assertEqual(ids(shown), ["open", "done-due", "done-undated"])
        days = calendar.by_day(shown)
        self.assertEqual({day: ids(ts) for day, ts in days.items()},
                         {"2026-11-03": ["open", "done-due"], "2026-11-05": ["done-undated"]})

    def test_completed_tasks_come_after_open_ones(self):
        tasks = [task("done", "2026-11-03", "08:00", completed_at=1), task("open", "2026-11-03")]
        self.assertEqual(ids(calendar.by_day(tasks)["2026-11-03"]), ["open", "done"])

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

    def test_spare_blocks_go_behind_the_marker_first(self):
        blocks = [("done1", 540, 600), ("done2", 545, 600), ("done3", 550, 600), ("open1", 555, 600), ("open2", 560, 600)]
        placed, overflow = calendar.layout_day(blocks, min_length=25, spare={"done1", "done2", "done3"})
        m = {b["id"]: b for b in placed}
        self.assertEqual([b["id"] for b in placed], ["done1", "done2", "done3", "open1", "open2"])  # time order
        self.assertEqual([(m[k]["lane"], m[k]["hidden"]) for k in ("open1", "open2", "done1")],
                         [(0, False), (1, False), (2, False)])
        self.assertEqual(overflow, [dict(lane=3, lanes=4, start=545, end=600, ids=["done2", "done3"])])
        # Without spare, the layout is the web app's: the latest starts are hidden.
        _, overflow = calendar.layout_day(blocks, min_length=25)
        self.assertEqual(overflow[0]["ids"], ["open1", "open2"])

    def test_spare_blocks_fill_gaps_left_by_the_others(self):
        # Five open blocks overlap at 9:00; a runs on to 10:30, so f and done join the cluster.
        blocks = [("a", h(9), h(10.5)), *((k, h(9), h(10)) for k in "bcde"),
                  ("done", h(10), h(11)), ("f", h(10.25), h(11))]
        placed, overflow = calendar.layout_day(blocks, spare={"done"})
        m = {b["id"]: b for b in placed}
        self.assertEqual(overflow[0]["ids"], ["d", "e"])  # the others alone overflow, as without spare
        self.assertEqual([(m[k]["lane"], m[k]["hidden"]) for k in ("f", "done")], [(1, False), (2, False)])

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


PX = 48 / 60  # 48 px an hour, 12 px a slot


class StretchTest(unittest.TestCase):
    """calendar.test.ts's cases for the bottom edge and the keyboard steps."""

    def test_resizes_in_whole_slots(self):
        start = 10 * 60
        bottom = (start + 30) * PX
        self.assertEqual(calendar.resize_estimate(start, bottom + 2 * 12, PX), 60)
        self.assertEqual(calendar.resize_estimate(start, bottom + 2 * 12 + 5, PX), 60)
        self.assertEqual(calendar.resize_estimate(start, bottom - 12, PX), 15)
        self.assertEqual(calendar.resize_estimate(start, 0, PX), 15)
        self.assertEqual(calendar.resize_estimate(start, 0, 0), 15)

    def test_steps_the_estimate(self):
        for current, delta, want in ((30, 15, 45), (30, -15, 15), (15, -15, 15), (None, 15, 45), (None, -15, 15),
                                     (20, 15, 30), (20, -15, 15), (10080, 15, 10080)):
            self.assertEqual(calendar.step_estimate(current, delta), want, (current, delta))

    def test_steps_the_start_keeping_the_end(self):
        for start, estimate, delta, want in ((600, 60, -15, (585, 75)), (600, 60, 15, (615, 45)),
                                             (600, 15, 15, (600, 15)), (600, None, -15, (585, 45)),
                                             (605, 30, 15, (615, 20)), (0, 30, -15, (0, 30))):
            self.assertEqual(calendar.step_start(start, estimate, delta), want, (start, estimate, delta))


class GridPrefsTest(unittest.TestCase):
    def test_defaults_and_repairs(self):
        default = {"startHour": 6, "endHour": 22, "dayLength": 480}
        self.assertEqual(calendar.grid_prefs(None), default)
        self.assertEqual(calendar.grid_prefs("junk"), default)
        self.assertEqual(calendar.grid_prefs({"startHour": 8, "endHour": 18, "dayLength": 360}),
                         {"startHour": 8, "endHour": 18, "dayLength": 360})
        self.assertEqual(calendar.grid_prefs({"startHour": 7.5, "endHour": 30, "dayLength": 0}), default)
        self.assertEqual(calendar.grid_prefs({"startHour": 23}), {**default, "startHour": 23, "endHour": 24})
        self.assertEqual(calendar.grid_prefs({"endHour": 4}), {**default, "startHour": 3, "endHour": 4})
        self.assertEqual(calendar.grid_prefs({"startHour": 18, "endHour": 9}), default)
        self.assertEqual(calendar.grid_prefs({"startHour": True}), default)


class GridMovesTest(unittest.TestCase):
    def moves(self, *args, on_grid=True, **fields):
        return calendar.grid_moves(task("t", *args, **fields), 6 * 60, on_grid)

    def test_a_timed_block(self):
        m = self.moves("2026-11-05", "09:00", estimate_minutes=60)
        self.assertEqual(list(m), list(calendar.GRID_MOVES))
        self.assertEqual(m["earlier"], ToSlot("2026-11-05", "08:45"))
        self.assertEqual(m["later"], ToSlot("2026-11-05", "09:15"))
        self.assertEqual(m["day-before"], ToSlot("2026-11-04", "09:00"))
        self.assertEqual(m["day-after"], ToSlot("2026-11-06", "09:00"))
        self.assertEqual(m["shorter"], Stretch(45))
        self.assertEqual(m["longer"], Stretch(75))
        self.assertEqual(m["start-earlier"], Stretch(75, ToSlot("2026-11-05", "08:45")))
        self.assertEqual(m["start-later"], Stretch(45, ToSlot("2026-11-05", "09:15")))
        self.assertEqual(m["unschedule"], ToSlot("2026-11-05"))

    def test_the_ends_of_the_day_and_the_shortest_block(self):
        m = self.moves("2026-11-05", "00:00", estimate_minutes=15)
        self.assertIsNone(m["earlier"])
        self.assertIsNone(m["shorter"])
        self.assertIsNone(m["start-later"])
        self.assertIsNone(self.moves("2026-11-05", "23:45")["later"])

    def test_without_an_estimate_it_stretches_from_thirty_minutes(self):
        m = self.moves("2026-11-05", "09:00")
        self.assertEqual((m["shorter"], m["longer"]), (Stretch(15), Stretch(45)))

    def test_without_a_time_the_arrows_put_it_on_the_grid(self):
        m = self.moves("2026-11-05")
        self.assertEqual(m["earlier"], ToSlot("2026-11-05", "06:00"))
        self.assertEqual(m["day-after"], ToSlot("2026-11-06"))
        self.assertTrue(all(m[k] is None for k in ("shorter", "longer", "start-earlier", "start-later", "unschedule")))

    def test_month_moves_days_only_and_keeps_the_time(self):
        self.assertEqual(self.moves("2026-11-30", "09:00", on_grid=False),
                         {"day-before": ToDay("2026-11-29"), "day-after": ToDay("2026-12-01")})
        self.assertEqual(self.moves(), {})

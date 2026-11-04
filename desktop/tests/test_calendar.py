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

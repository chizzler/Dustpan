import unittest

from dustpan.ordering import plan_move


class PlanMoveTest(unittest.TestCase):
    """The scenarios of OpenSpec manual-ordering, "Fractional insertion and renumbering"."""

    def test_one_write_at_the_midpoint(self):
        items = [("a", 1000), ("b", 2000), ("x", 3000)]
        self.assertEqual(plan_move(items, "x", 1, 0), [("x", 1500)])

    def test_ends_and_empty_lists(self):
        items = [("a", 1000), ("b", 2000)]
        self.assertEqual(plan_move(items, "x", 0, 0), [("x", 0)])
        self.assertEqual(plan_move(items, "x", 9, 0), [("x", 3000)])
        self.assertEqual(plan_move([], "x", 0, 77), [("x", 77)])

    def test_no_move_writes_nothing(self):
        self.assertEqual(plan_move([("a", 1), ("x", 2), ("b", 3)], "x", 1, 0), [])

    def test_equal_neighbours_renumber_the_smallest_window(self):
        items = [("a", 1000), ("b", 2000), ("c", 2000), ("d", 5000)]
        changes = dict(plan_move(items, "x", 2, 0))
        order = sorted({**dict(items), **changes}.items(), key=lambda kv: (kv[1], kv[0]))
        self.assertEqual([k for k, _ in order], ["a", "b", "x", "c", "d"])
        self.assertNotIn("a", changes)
        self.assertNotIn("d", changes)


if __name__ == "__main__":
    unittest.main()

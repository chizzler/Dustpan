import unittest

from dustpan.dragdrop import (AFTER, BEFORE, BOTTOM, DOWN, END, HEAD, INDENT, INSIDE, OUTDENT, TOP, UP, Place, Slot, ToDay,
                              ToProject, describe, level, nudge, resolve, zone)
from dustpan.store import Row

# A section as a project list shows it:
#   a
#     a1
#       a1x
#     a2
#   b
#   c
ROWS = [Slot("a", 0), Slot("a1", 1, "a"), Slot("a1x", 2, "a1"), Slot("a2", 1, "a"), Slot("b", 0), Slot("c", 0)]
INDEX = {slot.id: i for i, slot in enumerate(ROWS)}


def drop(hit, where=None, depth=0, moving="x", rows=ROWS):
    hit = INDEX.get(hit, hit)
    return resolve(rows, "p1", "s1", hit, where, depth, moving)


class ZoneTest(unittest.TestCase):
    """OpenTodo's listDrop.dropZone, and Pragmatic's hitbox table."""

    def test_quarters_with_nesting(self):
        self.assertEqual([zone(y, 40) for y in (0, 9, 10, 30, 31, 40)],
                         [BEFORE, BEFORE, INSIDE, INSIDE, AFTER, AFTER])

    def test_halves_without_nesting(self):
        self.assertEqual([zone(y, 40, inside=False) for y in (0, 19, 20, 40)], [BEFORE, BEFORE, AFTER, AFTER])

    def test_level_rounds_to_the_nearest_indent(self):
        self.assertEqual([level(x, 24) for x in (-30, 0, 11, 13, 30, 40)], [-1, 0, 0, 1, 1, 2])


class ResolveTest(unittest.TestCase):
    def test_before_and_after_at_the_rows_level(self):
        self.assertEqual(drop("b", BEFORE).target, Place("p1", "s1", None, before="b"))
        self.assertEqual(drop("a2", BEFORE, depth=1).target, Place("p1", "s1", "a", before="a2"))
        # Before a2 is also after a1x, so a deeper pointer lands under a1.
        self.assertEqual(drop("a2", BEFORE, depth=5).target, Place("p1", "s1", "a1", after="a1x"))
        self.assertEqual(drop("b", AFTER).target, Place("p1", "s1", None, before="c"))
        self.assertEqual(drop("c", AFTER).target, Place("p1", "s1", None, after="c"))

    def test_inside_makes_the_last_subtask(self):
        found = drop("b", INSIDE)
        self.assertEqual((found.target, found.ring), (Place("p1", "s1", "b"), "b"))

    def test_after_an_open_parent_is_the_top_of_its_subtasks(self):
        """OpenTodo's dropTarget rule: the line under a parent sits above its first child."""
        for depth in (0, 1, 3):
            self.assertEqual(drop("a", AFTER, depth=depth).target, Place("p1", "s1", "a", before="a1"))

    def test_the_pointer_picks_the_level_where_groups_close(self):
        """Pragmatic's reparent: after a2, the end of a's subtasks, the level is 0 or 1."""
        self.assertEqual(drop("a2", AFTER, depth=1).target, Place("p1", "s1", "a", after="a2"))
        self.assertEqual(drop("a2", AFTER, depth=0).target, Place("p1", "s1", None, before="b"))
        # Clamped: never deeper than the row above, never shallower than the row below.
        self.assertEqual(drop("a2", AFTER, depth=4).depth, 1)
        self.assertEqual(drop("a2", AFTER, depth=-2).depth, 0)
        # After a1x three levels close: under a1, under a, or the top level.
        self.assertEqual(drop("a1x", AFTER, depth=2).target, Place("p1", "s1", "a1", after="a1x"))
        self.assertEqual(drop("a1x", AFTER, depth=1).target, Place("p1", "s1", "a", before="a2"))

    def test_the_end_of_a_list_after_a_subtree(self):
        rows = ROWS[:4]
        self.assertEqual(drop(END, depth=0, rows=rows).target, Place("p1", "s1", None, after="a"))
        self.assertEqual(drop(END, depth=2, rows=rows).target, Place("p1", "s1", "a", after="a2"))

    def test_heading_and_empty_list(self):
        self.assertEqual(drop(HEAD, depth=3).target, Place("p1", "s1", None, before="a"))
        self.assertEqual(resolve([], "p1", "s1", HEAD, None, 0, "x").target, Place("p1", "s1"))
        self.assertEqual(resolve([], "p1", "s1", END, None, 2, "x").target, Place("p1", "s1"))

    def test_the_dragged_subtree_is_the_gap_it_left(self):
        """Dragging a in place: its rows stand for the gap, so sideways movement only changes its level."""
        found = drop("a1", INSIDE, depth=0, moving="a")
        self.assertIsNone(found.ring)
        self.assertEqual(found.target, Place("p1", "s1", None, before="b"))
        # Drag a2 left in place: out of a, before b.
        self.assertEqual(drop("a2", BEFORE, depth=0, moving="a2").target, Place("p1", "s1", None, before="b"))
        # Or keep it under a, after a1.
        self.assertEqual(drop("a2", AFTER, depth=1, moving="a2").target, Place("p1", "s1", "a", after="a1"))

    def test_never_under_itself(self):
        """A task's own subtasks are no target for it; the drop lands in the gap it left."""
        for hit, where in (("a1", INSIDE), ("a1x", INSIDE), ("a2", AFTER)):
            target = drop(hit, where, depth=2, moving="a").target
            self.assertNotIn(target.parent_id, {"a", "a1", "a2", "a1x"})

    def test_the_line_sits_below_prev(self):
        found = drop("a2", AFTER, depth=0)
        self.assertEqual((found.prev, found.next, found.depth), ("a2", "b", 0))
        found = drop(HEAD)
        self.assertEqual((found.prev, found.next), (None, "a"))


class NudgeTest(unittest.TestCase):
    """Keyboard moves: OpenSpec manual-ordering "Keyboard moves" and subtasks "Move between parents"."""

    def move(self, task_id, how):
        return nudge(ROWS, "p1", "s1", task_id, how)

    def test_up_and_down_among_siblings(self):
        self.assertEqual(self.move("b", UP), Place("p1", "s1", None, before="a"))
        self.assertEqual(self.move("b", DOWN), Place("p1", "s1", None, after="c"))
        self.assertEqual(self.move("a2", UP), Place("p1", "s1", "a", before="a1"))

    def test_top_and_bottom(self):
        self.assertEqual(self.move("c", TOP), Place("p1", "s1", None, before="a"))
        self.assertEqual(self.move("a", BOTTOM), Place("p1", "s1", None, after="c"))

    def test_nothing_at_the_edges(self):
        """The first task and Alt+Up: nothing changes."""
        for task_id, how in (("a", UP), ("a", TOP), ("c", DOWN), ("c", BOTTOM), ("a2", DOWN), ("a1x", UP),
                             ("a", INDENT), ("a1", INDENT), ("b", OUTDENT), ("gone", UP)):
            self.assertIsNone(self.move(task_id, how), (task_id, how))

    def test_indent_under_the_sibling_above(self):
        """Tab: the last subtask of the task above at its level, which may have subtasks already."""
        self.assertEqual(self.move("b", INDENT), Place("p1", "s1", "a"))
        self.assertEqual(self.move("a2", INDENT), Place("p1", "s1", "a1"))

    def test_outdent_right_after_the_old_parent(self):
        self.assertEqual(self.move("a1x", OUTDENT), Place("p1", "s1", "a", after="a1"))
        self.assertEqual(self.move("a1", OUTDENT), Place("p1", "s1", None, after="a"))


class DescribeTest(unittest.TestCase):
    NAMES = {"p1": "Home", "p2": "Work", "s1": "Doing", "a": "Plan trip"}

    def text(self, target, **task):
        return describe(target, Row("t", dict(task)), self.NAMES, lambda day: "Thu 5 Nov")

    def test_each_kind_of_change(self):
        self.assertEqual(self.text(ToDay("2026-11-05")), "Due Thu 5 Nov")
        self.assertEqual(self.text(ToProject(None), project_id="p1"), "Moved to Inbox")
        self.assertEqual(self.text(ToProject("p2"), project_id="p1"), "Moved to Work")
        self.assertEqual(self.text(Place("p1", None, "a"), project_id="p1"), "Moved under “Plan trip”")
        self.assertEqual(self.text(Place("p1", None), project_id="p1", parent_id="a"), "Moved out of “Plan trip”")
        self.assertEqual(self.text(Place("p1", "s1"), project_id="p1"), "Moved to Doing")
        self.assertEqual(self.text(Place("p2", None), project_id="p1"), "Moved to Work")
        self.assertEqual(self.text(Place("p1", "s1", before="b"), project_id="p1", section_id="s1"), "Order changed")


if __name__ == "__main__":
    unittest.main()

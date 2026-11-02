"""Labels: the rules in labels.py, and the label writes, against OpenTodo's labels spec."""

import unittest

from dustpan.dragdrop import ToLabel, describe
from dustpan.labels import duplicates, find, picker_order, remember, shown
from dustpan.store import Row
from dustpan.writes import CannotEdit, LABEL_PALETTE

from .test_writes import WriterCase


def label(label_id, name, position=0):
    return Row(label_id, {"name": name, "position": position})


class RulesTest(unittest.TestCase):
    def setUp(self):
        self.labels = [label("a", "errand", 1), label("b", "Deep work", 2), label("c", "Café", 3),
                       label("d", "waiting", 4)]

    def names(self, rows):
        return [r.get("name") for r in rows]

    def test_find_ranks_start_then_word_then_inside_then_letters(self):
        self.assertEqual(self.names(find(self.labels, "")), ["errand", "Deep work", "Café", "waiting"])
        self.assertEqual(self.names(find(self.labels, "w")), ["waiting", "Deep work"])
        self.assertEqual(self.names(find(self.labels, "rr")), ["errand"])
        self.assertEqual(self.names(find(self.labels, "dw")), ["Deep work"])
        self.assertEqual(self.names(find(self.labels, "nothing")), [])

    def test_find_ignores_case_and_accents(self):
        self.assertEqual(self.names(find(self.labels, "CAFE")), ["Café"])
        self.assertEqual(self.names(find(self.labels, "cafè")), ["Café"])

    def test_recent_first_then_sidebar_order(self):
        self.assertEqual(self.names(picker_order(self.labels, ["d", "gone", "b"])), ["waiting", "Deep work", "errand", "Café"])
        self.assertEqual(remember(["a", "b"], ["c", "b"]), ["b", "c", "a"])
        self.assertEqual(len(remember([str(i) for i in range(20)], ["x"])), 8)

    def test_duplicates_ignore_case(self):
        self.assertEqual(duplicates([label("a", "errand"), label("b", " Errand "), label("c", "call")]), {"a", "b"})

    def test_shown_keeps_task_order_hides_unknown_and_the_page_label(self):
        by_id = {r.id: r for r in self.labels}
        self.assertEqual(self.names(shown(["d", "zzz", "a", "d"], by_id)), ["waiting", "errand"])
        self.assertEqual(self.names(shown(["d", "a"], by_id, skip="a")), ["waiting"])


class LabelWritesTest(WriterCase):
    def setUp(self):
        super().setUp()
        self.seed("label", "errand", name="errand", color="#ef4444", position=1)
        self.seed("label", "call", name="call", color="#f97316", position=2)
        self.seed("task", "t1", title="One", labels=["errand"])
        self.seed("task", "t2", title="Two", labels=["call", "errand"])
        self.seed("task", "t3", title="Gone", labels=["errand"], deleted_at=5)

    def labels_of(self, task_id):
        return self.task(task_id).get("labels")

    def test_add_takes_the_first_unused_colour_and_refuses_a_name_in_use(self):
        new = self.writer.add_label("  Garden ")
        row = self.store.rows("label")[new]
        self.assertEqual((row.get("name"), row.get("color")), ("Garden", LABEL_PALETTE[2]))
        with self.assertRaisesRegex(CannotEdit, "already a label called “errand”"):
            self.writer.add_label("ERRAND")
        with self.assertRaises(CannotEdit):
            self.writer.add_label("  ")

    def test_rename_is_one_op_and_never_touches_tasks(self):
        self.outbox_before = len(self.outbox())
        done = self.writer.edit_label("errand", {"name": "errands", "color": "#22c55e"})
        ops = self.outbox()[self.outbox_before:]
        self.assertEqual({(o["entity"], o["field"]) for o in ops}, {("label", "name"), ("label", "color")})
        self.assertEqual(self.labels_of("t1"), ["errand"])
        with self.assertRaises(CannotEdit):
            self.writer.edit_label("errand", {"name": "Call"})
        # Changing only the case of its own name is fine.
        self.writer.edit_label("errand", {"name": "Errands"})
        self.writer.revert(done.undo)
        self.assertEqual(self.store.rows("label")["errand"].get("color"), "#ef4444")

    def test_move(self):
        self.writer.move_label("call", -1)
        order = sorted(self.store.rows("label").values(), key=lambda r: (r.get("position"), r.id))
        self.assertEqual([r.id for r in order], ["call", "errand"])
        before = len(self.outbox())
        self.writer.move_label("call", -1)  # already first
        self.assertEqual(len(self.outbox()), before)

    def test_delete_takes_the_id_off_live_tasks_and_undo_puts_it_back(self):
        done = self.writer.delete_label("errand")
        self.assertEqual((self.labels_of("t1"), self.labels_of("t2")), ([], ["call"]))
        self.assertEqual(self.labels_of("t3"), ["errand"])  # deleted tasks are left alone
        self.assertIsNotNone(self.store.rows("label")["errand"].get("deleted_at"))
        self.writer.revert(done.undo)
        self.assertEqual((self.labels_of("t1"), self.labels_of("t2")), (["errand"], ["call", "errand"]))
        self.assertIsNone(self.store.rows("label")["errand"].get("deleted_at"))

    def test_merge_rewrites_once_and_deletes_the_source(self):
        self.writer.merge_labels("errand", "call")
        self.assertEqual((self.labels_of("t1"), self.labels_of("t2")), (["call"], ["call"]))
        self.assertIsNotNone(self.store.rows("label")["errand"].get("deleted_at"))
        with self.assertRaises(CannotEdit):
            self.writer.merge_labels("call", "call")

    def test_change_task_labels_reads_the_current_array(self):
        self.writer.change_task_labels("t1", add=["call"])
        self.writer.change_task_labels("t1", add=["Garden"], remove=["errand"])
        names = {r.id: r.get("name") for r in self.store.rows("label").values()}
        self.assertEqual([names[i] for i in self.labels_of("t1")], ["call", "Garden"])
        before = len(self.outbox())
        done = self.writer.change_task_labels("t1", add=["call"])  # already there: nothing written
        self.assertEqual((len(self.outbox()), done.undo), (before, []))

    def test_dropping_on_a_label_adds_it_and_nothing_else(self):
        self.seed("task", "t4", title="Four", labels=["call"], position=7, due={"date": "2026-11-09"})
        done = self.writer.drop("t4", ToLabel("errand"))
        self.assertEqual(self.labels_of("t4"), ["call", "errand"])
        self.assertEqual({o["field"] for o in self.outbox() if o["entityId"] == "t4"}, {"labels"})
        self.writer.revert(done.undo)
        self.assertEqual(self.labels_of("t4"), ["call"])
        self.assertEqual(describe(ToLabel("errand"), self.task("t4"), {"errand": "errand"}, str), "Added errand")

    def test_dropping_on_a_label_it_has_writes_nothing(self):
        before = len(self.outbox())
        done = self.writer.drop("t1", ToLabel("errand"))
        self.assertEqual((done.undo, len(self.outbox())), ([], before))
        self.writer.delete_label("call")
        with self.assertRaises(CannotEdit):
            self.writer.drop("t1", ToLabel("call"))

    def test_edit_takes_ids_or_names(self):
        self.writer.edit("t1", {"labels": ["call", "errand", "New one"]})
        ids = self.labels_of("t1")
        self.assertEqual(ids[:2], ["call", "errand"])
        self.assertEqual(self.store.rows("label")[ids[2]].get("name"), "New one")


if __name__ == "__main__":
    unittest.main()

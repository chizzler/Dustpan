import unittest
from datetime import datetime

from dustpan.clock import HybridClock
from dustpan.dates import due_instant
from dustpan.dragdrop import Place, ToDay, ToProject
from dustpan.ids import default_reminder_id, detached_id, occurrence_id
from dustpan.store import Store
from dustpan.writes import CannotEdit, Writer


def op(entity, entity_id, field, value, ts=1, device="other"):
    return {"id": f"{entity_id}-{field}-{ts}", "entity": entity, "entityId": entity_id,
            "field": field, "value": value, "ts": ts, "device": device}


class WriterCase(unittest.TestCase):
    """A writer on an empty store, with a fixed clock and today."""

    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)
        self.now = 1_000_000
        clock = HybridClock(self.store, now=lambda: self.now)
        self.today = "2026-11-02"
        self.writer = Writer(self.store, clock=clock, now=lambda: self.now, today=lambda: self.today)
        self.store.set_meta("user_id", "me")

    def seed(self, entity, entity_id, **fields):
        for name, value in fields.items():
            self.store.apply(op(entity, entity_id, name, value))

    def task(self, task_id):
        return self.store.rows("task")[task_id]

    def outbox(self):
        return [o for _, o in self.store.outbox_batch(1000)]


class WriterTest(WriterCase):
    def test_add_writes_every_field_in_one_stamped_batch(self):
        self.seed("project", "p1", name="Home")
        task_id = self.writer.add_task("  Buy milk ", project_id="p1")
        row = self.task(task_id)
        self.assertEqual(row.get("title"), "Buy milk")
        self.assertEqual(row.get("project_id"), "p1")
        self.assertEqual(row.get("priority"), 4)
        self.assertNotIn("section_id", row.values)
        ops = self.outbox()
        self.assertEqual(len({o["ts"] for o in ops}), 1)
        self.assertEqual({o["device"] for o in ops}, {self.store.get_meta("device")})
        self.assertEqual(len({o["id"] for o in ops}), len(ops))

    def test_add_goes_past_a_task_moved_beyond_now(self):
        self.seed("task", "t1", title="Far", position=self.now + 5_000)
        task_id = self.writer.add_task("New")
        self.assertEqual(self.task(task_id).get("position"), self.now + 6_000)

    def test_add_refuses_empty_title_and_missing_project(self):
        with self.assertRaises(CannotEdit):
            self.writer.add_task("   ")
        with self.assertRaises(CannotEdit):
            self.writer.add_task("x", project_id="nope")
        self.assertEqual(self.store.outbox_count(), 0)

    def test_subtask_takes_parents_project_and_no_section(self):
        self.seed("project", "p1", name="Work")
        self.seed("task", "t1", title="Parent", project_id="p1", section_id="s1")
        child = self.writer.add_task("Child", parent_id="t1")
        row = self.task(child)
        self.assertEqual((row.get("project_id"), row.get("parent_id")), ("p1", "t1"))
        self.assertNotIn("section_id", row.values)

    def test_complete_cascades_to_open_descendants(self):
        self.seed("task", "a", title="A", completed_at=None)
        self.seed("task", "b", title="B", parent_id="a", completed_at=None)
        self.seed("task", "c", title="C", parent_id="b", completed_at=None)
        self.seed("task", "d", title="D", parent_id="a", completed_at=5)
        done = self.writer.complete("a")
        self.assertEqual(sorted(eid for _, eid, _ in done.undo), ["a", "b", "c"])
        self.assertEqual(self.task("c").get("completed_by"), "me")
        self.assertEqual(self.task("d").get("completed_at"), 5)

    def test_undo_reopens_what_complete_closed(self):
        self.seed("task", "a", title="A", completed_at=None)
        self.seed("task", "b", title="B", parent_id="a", completed_at=None)
        done = self.writer.complete("a")
        self.writer.revert(done.undo)
        self.assertIsNone(self.task("a").get("completed_at"))
        self.assertIsNone(self.task("b").get("completed_by"))

    def test_completing_a_series_records_the_occurrence_and_moves_on(self):
        self.seed("task", "s", title="Water plants", recurrence="every 3 days", priority=2,
                  due={"date": "2026-11-01", "time": "08:00"}, deadline="2026-11-03", **{"fields.f1": "x"})
        done = self.writer.complete("s")
        series = self.task("s")
        self.assertIsNone(series.get("completed_at"))
        self.assertEqual(series.get("due"), {"date": "2026-11-04", "time": "08:00"})
        self.assertEqual(series.get("deadline"), "2026-11-06")
        self.assertEqual(done.next_due, "2026-11-04")
        record = self.task(occurrence_id("s", "2026-11-01"))
        self.assertEqual((record.get("series_id"), record.get("recurrence")), ("s", None))
        self.assertEqual(record.get("due"), {"date": "2026-11-01", "time": "08:00"})
        self.assertEqual((record.get("completed_by"), record.get("priority")), ("me", 2))
        self.assertEqual(record.get("fields.f1"), "x")
        self.assertEqual(record.get("deadline"), "2026-11-03")

    def test_undo_of_a_series_completion_puts_it_back(self):
        self.seed("task", "s", title="S", recurrence="every day", due={"date": "2026-11-02"})
        done = self.writer.complete("s")
        self.writer.revert(done.undo)
        self.assertEqual(self.task("s").get("due"), {"date": "2026-11-02"})
        self.assertIsNotNone(self.task(occurrence_id("s", "2026-11-02")).get("deleted_at"))

    def test_last_occurrence_completes_the_series(self):
        self.seed("task", "s", title="S", recurrence="every day for 1 time", due={"date": "2026-11-02"})
        done = self.writer.complete("s")
        self.assertIsNotNone(self.task("s").get("completed_at"))
        self.assertIsNone(done.next_due)

    def test_skip_moves_on_without_a_record_and_a_habit_records_it(self):
        self.seed("task", "s", title="S", recurrence="every day", due={"date": "2026-11-02"})
        self.writer.skip("s")
        self.assertEqual(self.task("s").get("due"), {"date": "2026-11-03"})
        self.assertNotIn(occurrence_id("s", "2026-11-02"), self.store.rows("task"))
        self.seed("task", "h", title="H", recurrence="every day", due={"date": "2026-11-02"}, habit=True)
        self.writer.skip("h")
        self.assertIs(self.task(occurrence_id("h", "2026-11-02")).get("skipped"), True)

    def test_skip_refuses_the_last_occurrence(self):
        self.seed("task", "s", title="S", recurrence="every day until 2026-11-02", due={"date": "2026-11-02"})
        with self.assertRaises(CannotEdit):
            self.writer.skip("s")

    def test_detach_makes_an_open_copy(self):
        self.seed("task", "s", title="S", recurrence="every week", due={"date": "2026-11-02"})
        done = self.writer.detach("s")
        copy = self.task(detached_id("s", "2026-11-02"))
        self.assertEqual(done.task_id, copy.id)
        self.assertIsNone(copy.get("completed_at"))
        self.assertEqual(self.task("s").get("due"), {"date": "2026-11-09"})

    def test_setting_a_rule_stores_it_canonical_and_dates_an_undated_task(self):
        self.seed("task", "a", title="A", due=None)
        self.writer.edit("a", {"recurrence": "Every  Mon, fri"})
        self.assertEqual(self.task("a").get("recurrence"), "every monday, friday")
        self.assertEqual(self.task("a").get("due"), {"date": "2026-11-02"})  # a Monday
        with self.assertRaises(CannotEdit):
            self.writer.edit("a", {"recurrence": "every blue moon"})
        self.writer.edit("a", {"recurrence": ""})
        self.assertIsNone(self.task("a").get("recurrence"))

    def test_edit_writes_only_changed_fields(self):
        self.seed("task", "a", title="A", priority=4)
        self.writer.edit("a", {"priority": 1})
        self.assertEqual([o["field"] for o in self.outbox()], ["priority"])

    def test_clearing_due_ends_the_repeat_and_setting_it_unparks(self):
        self.seed("task", "a", title="A", recurrence="every day", due={"date": "2026-11-01"})
        self.writer.edit("a", {"due": None})
        self.assertIsNone(self.task("a").get("recurrence"))
        self.seed("task", "b", title="B", start="someday")
        self.writer.edit("b", {"due": {"date": "2026-11-02"}})
        self.assertIsNone(self.task("b").get("start"))

    def test_bad_due_is_refused(self):
        self.seed("task", "a", title="A")
        for due in ({"date": "2026-02-30"}, {"date": "2026-11-01", "time": "9:00"},
                    {"date": "2026-11-01", "tz": "Europe/Berlin"}, {"date": "2026-11-01", "x": 1}):
            with self.assertRaises(CannotEdit, msg=due):
                self.writer.edit("a", {"due": due})

    def test_due_change_moves_relative_reminders_in_the_same_batch(self):
        self.seed("task", "a", title="A", due={"date": "2026-11-01", "time": "10:00"})
        self.seed("reminder", "r1", task_id="a", kind="relative", offset_minutes=-30,
                  fire_at=1, delivered_at=2, dismissed_at=None)
        self.seed("reminder", "r2", task_id="a", kind="absolute", fire_at=7)
        due = {"date": "2026-11-02", "time": "10:00", "tz": "Australia/Sydney"}
        self.writer.edit("a", {"due": due})
        r1 = self.store.rows("reminder")["r1"]
        self.assertEqual(r1.get("fire_at"), due_instant(due) - 30 * 60_000)
        self.assertIsNone(r1.get("delivered_at"))
        self.assertEqual(r1.clocks["fire_at"].ts, self.task("a").clocks["due"].ts)
        self.assertEqual(self.store.rows("reminder")["r2"].get("fire_at"), 7)
        self.assertNotIn("dismissed_at", {o["field"] for o in self.outbox() if o["entityId"] == "r1"})

    def test_scheduling_adds_the_default_reminder_once(self):
        self.seed("user_prefs", "me", reminder_default_timed="-30", reminder_default_dated="")
        self.seed("task", "a", title="A", due=None)
        due = {"date": "2026-11-06", "time": "15:00"}
        self.writer.edit("a", {"due": due})
        rid = default_reminder_id("me", "a")
        reminder = self.store.rows("reminder")[rid]
        self.assertEqual((reminder.get("offset_minutes"), reminder.get("fire_at")), (-30, due_instant(due) - 30 * 60_000))
        self.writer.edit("a", {"due": {"date": "2026-11-07", "time": "15:00"}})
        self.assertEqual(len(self.store.rows("reminder")), 1)

    def test_reminder_actions(self):
        self.seed("task", "a", title="A", due={"date": "2026-11-06", "time": "15:00"})
        rid = self.writer.add_reminder("a", "relative", offset_minutes=-10)
        self.assertEqual(self.store.rows("reminder")[rid].get("fire_at"),
                         due_instant({"date": "2026-11-06", "time": "15:00"}) - 10 * 60_000)
        self.writer.dismiss(rid)
        self.assertEqual(self.store.rows("reminder")[rid].get("dismissed_at"), self.now)
        self.writer.snooze(rid, self.now + 600_000)
        self.assertIsNone(self.store.rows("reminder")[rid].get("dismissed_at"))
        self.writer.delete_reminder(rid)
        self.assertEqual(self.store.rows("reminder")[rid].get("deleted_at"), self.now)
        absolute = self.writer.add_reminder("a", "absolute", fire_at=123)
        self.assertEqual(self.store.rows("reminder")[absolute].get("kind"), "absolute")

    def test_move_to_another_project_carries_the_subtree(self):
        self.seed("project", "p1", name="One")
        self.seed("project", "p2", name="Two")
        self.seed("section", "s2", name="Doing", project_id="p2")
        self.seed("task", "x", title="Other", project_id="p2", section_id="s2", position=50)
        self.seed("task", "a", title="A", project_id="p1", section_id="s1", parent_id="root", position=1)
        self.seed("task", "b", title="B", project_id="p1", section_id="s1", parent_id="a")
        self.writer.edit("a", {"project_id": "p2", "section_id": "s2"})
        a, b = self.task("a"), self.task("b")
        self.assertEqual((a.get("project_id"), a.get("section_id"), a.get("parent_id")), ("p2", "s2", None))
        self.assertEqual(a.get("position"), 1050)
        self.assertEqual((b.get("project_id"), b.get("section_id"), b.get("parent_id")), ("p2", None, "a"))

    def test_move_refuses_a_section_of_another_project(self):
        self.seed("project", "p1", name="One")
        self.seed("section", "s9", name="Elsewhere", project_id="p9")
        self.seed("task", "a", title="A", project_id="p1")
        with self.assertRaises(CannotEdit):
            self.writer.edit("a", {"section_id": "s9"})

    def test_local_edit_beats_a_newer_looking_remote_op_already_seen(self):
        self.seed("task", "a", title="A")
        self.store.apply(op("task", "a", "title", "Remote", ts=self.now + 60_000, device="zzz"))
        self.writer.clock.receive(self.now + 60_000)
        self.writer.edit("a", {"title": "Mine"})
        self.assertEqual(self.task("a").get("title"), "Mine")

    def test_add_with_a_due_date_and_reopen(self):
        task_id = self.writer.add_task("Call", due={"date": self.today})
        self.assertEqual(self.task(task_id).get("due"), {"date": self.today})
        self.writer.complete(task_id)
        done = self.writer.reopen(task_id)
        self.assertEqual((self.task(task_id).get("completed_at"), self.task(task_id).get("completed_by")), (None, None))
        self.writer.revert(done.undo)
        self.assertEqual(self.task(task_id).get("completed_at"), self.now)

    def test_quick_add(self):
        self.seed("project", "p1", name="Home")
        self.seed("project", "p2", name="Work Stuff")
        self.seed("label", "l1", name="Phone", position=1)
        task_id = self.writer.quick_add("Call Sam tomorrow at 15:00 #workstuff @phone @new-one p1 +30m "
                                        "remind me 1 hour before", project_id="p1")
        task = self.task(task_id)
        labels = self.store.rows("label")
        self.assertEqual({k: task.get(k) for k in ("title", "project_id", "priority", "estimate_minutes", "due")},
                         {"title": "Call Sam", "project_id": "p2", "priority": 1, "estimate_minutes": 30,
                          "due": {"date": "2026-11-03", "time": "15:00"}})
        self.assertEqual(task.get("labels")[0], "l1")
        self.assertEqual(labels[task.get("labels")[1]].get("name"), "new-one")
        reminder = next(r for r in self.store.rows("reminder").values() if r.get("task_id") == task_id)
        self.assertEqual((reminder.get("kind"), reminder.get("offset_minutes")), ("relative", -60))
        self.assertEqual(len({o["ts"] for o in self.outbox()}), 1)

    def test_quick_add_reads_a_sector_only_when_turned_on(self):
        today = {"date": self.today}
        off = self.task(self.writer.quick_add("Plan it this week", due=today))
        self.assertEqual((off.get("title"), off.get("sector"), off.get("due")), ("Plan it this week", None, today))
        self.seed("user_prefs", "me", time_sectors="on")
        on = self.task(self.writer.quick_add("Plan it this week", due=today))
        self.assertEqual((on.get("title"), on.get("sector"), on.get("due")), ("Plan it", "2026-W45", None))

    def test_quick_add_keeps_the_page_place_and_date_unless_the_line_sets_them(self):
        self.seed("project", "p1", name="Home")
        self.seed("section", "s1", name="Garden", project_id="p1")
        in_section = self.task(self.writer.quick_add("Weed beds 25m/1h", project_id="p1", section_id="s1"))
        self.assertEqual((in_section.get("project_id"), in_section.get("section_id"), in_section.get("due")),
                         ("p1", "s1", None))
        entry = next(iter(self.store.rows("time_entry").values()))
        self.assertEqual((entry.get("task_id"), entry.get("ended_at") - entry.get("started_at")), (in_section.id, 25 * 60_000))
        today = {"date": self.today}
        self.assertEqual(self.task(self.writer.quick_add("Call mum", due=today)).get("due"), today)
        parked = self.task(self.writer.quick_add("Learn piano someday", due=today))
        self.assertEqual((parked.get("title"), parked.get("due"), parked.get("start")), ("Learn piano", None, "someday"))
        with self.assertRaises(CannotEdit):
            self.writer.quick_add("tomorrow p1")

    def test_delete_takes_the_subtree_and_undo_brings_it_back(self):
        self.seed("task", "a", title="A", deleted_at=None)
        self.seed("task", "b", title="B", parent_id="a", deleted_at=None)
        self.seed("task", "c", title="C", deleted_at=None)
        done = self.writer.delete_task("a")
        self.assertEqual([self.task(t).get("deleted_at") for t in "abc"], [self.now, self.now, None])
        self.writer.revert(done.undo)
        self.assertEqual([self.task(t).get("deleted_at") for t in "ab"], [None, None])

    def test_labels_estimate_and_deadline(self):
        self.seed("label", "l1", name="Phone", position=1)
        self.seed("task", "a", title="A")
        self.writer.edit("a", {"labels": ["phone", "Garden"], "estimate_minutes": 45, "deadline": "2026-11-20"})
        a = self.task("a")
        garden = a.get("labels")[1]
        self.assertEqual((a.get("labels")[0], self.store.rows("label")[garden].get("name")), ("l1", "Garden"))
        self.assertEqual((a.get("estimate_minutes"), a.get("deadline")), (45, "2026-11-20"))
        ops = self.outbox()
        self.assertLess(next(i for i, o in enumerate(ops) if o["entity"] == "label"),
                        next(i for i, o in enumerate(ops) if o["field"] == "labels"))
        for bad in ({"estimate_minutes": 0}, {"deadline": "2026-02-30"}):
            with self.assertRaises(CannotEdit):
                self.writer.edit("a", bad)

    def test_notes_are_markdown_in_description_alone(self):
        self.seed("task", "a", title="A", notes_doc="ydoc:v1:AAA=")
        self.writer.edit("a", {"description": "- [ ] Passport\n\n"})
        self.assertEqual(self.task("a").get("description"), "- [ ] Passport")
        self.assertEqual([o["field"] for o in self.outbox()], ["description"])  # notes_doc is the web app's
        with self.assertRaises(CannotEdit):
            self.writer.edit("a", {"description": "é" * 11000})  # 66 KB once escaped as JSON

    def test_deadline_reminders_follow_the_deadline_not_the_due(self):
        self.seed("task", "a", title="A", deadline="2026-11-20", due={"date": "2026-11-10"})
        rid = self.writer.add_reminder("a", "deadline", offset_minutes=-1440)
        self.assertEqual(self.store.rows("reminder")[rid].get("fire_at"), due_instant({"date": "2026-11-19"}))
        self.writer.edit("a", {"due": {"date": "2026-11-12"}})
        self.assertEqual(self.store.rows("reminder")[rid].get("fire_at"), due_instant({"date": "2026-11-19"}))
        self.writer.edit("a", {"deadline": "2026-11-25"})
        self.assertEqual(self.store.rows("reminder")[rid].get("fire_at"), due_instant({"date": "2026-11-24"}))
        self.writer.edit("a", {"deadline": None})
        self.assertIsNone(self.store.rows("reminder")[rid].get("fire_at"))

    def test_typed_moments(self):
        self.now = int(datetime(2026, 11, 2, 10, 0).timestamp() * 1000)
        self.assertEqual(self.writer.moment("tomorrow 9am"), due_instant({"date": "2026-11-03", "time": "09:00"}))
        self.assertEqual(self.writer.moment("at 8"), due_instant({"date": "2026-11-03", "time": "08:00"}))
        self.assertEqual(self.writer.moment("at 14:30"), due_instant({"date": "2026-11-02", "time": "14:30"}))
        for bad in ("", "soon", "30 min before", "tomorrow 9am buy milk"):
            with self.assertRaises(CannotEdit):
                self.writer.moment(bad)

    def test_subtask_from_quick_add(self):
        self.seed("project", "p1", name="Home")
        self.seed("task", "a", title="A", project_id="p1", section_id="s1")
        sub = self.task(self.writer.quick_add("Buy paint p2", parent_id="a"))
        self.assertEqual((sub.get("parent_id"), sub.get("project_id"), sub.get("priority")), ("a", "p1", 2))
        self.assertNotIn("section_id", sub.values)

    def test_move_within_and_between_lists(self):
        self.seed("project", "p1", name="Home")
        self.seed("section", "s1", name="Doing", project_id="p1", deleted_at=None)
        for task_id, position, extra in (("a", 1000, {}), ("b", 2000, {}), ("c", 3000, {}),
                                         ("d", 1000, {"section_id": "s1"}), ("e", 500, {"parent_id": "a"})):
            self.seed("task", task_id, title=task_id, project_id="p1", position=position, deleted_at=None, **extra)
        before = self.store.outbox_count()
        self.writer.drop("c", Place("p1", None, before="a"))
        self.assertEqual(self.store.outbox_count() - before, 1)
        self.assertEqual(self.task("c").get("position"), 0)
        self.writer.drop("b", Place("p1", "s1", after="d"))
        self.assertEqual((self.task("b").get("section_id"), self.task("b").get("position")), ("s1", 2000))
        self.writer.drop("d", Place("p1", None, "a"))
        self.assertEqual((self.task("d").get("parent_id"), self.task("d").get("position")), ("a", 1500))
        self.writer.drop("e", Place("p1", None, after="c"))
        self.assertEqual((self.task("e").get("parent_id"), self.task("e").get("position")), (None, 500))
        for task_id, bad in (("a", Place("p1", None, "a")), ("a", Place("p1", None, "d")), ("a", Place("p1", "nope")),
                             ("a", Place("p1", None, before="gone"))):
            with self.assertRaises(CannotEdit):
                self.writer.drop(task_id, bad)

    def test_drop_undo_puts_back_every_field(self):
        self.seed("project", "p1", name="Home")
        self.seed("task", "a", title="A", project_id="p1", position=1000, deleted_at=None)
        self.seed("task", "b", title="B", project_id="p1", position=2000, deleted_at=None)
        done = self.writer.drop("b", Place("p1", None, "a"))
        self.assertEqual(self.task("b").get("parent_id"), "a")
        self.assertEqual(done.undo, [("task", "b", {"parent_id": None, "position": 2000})])
        self.writer.revert(done.undo)
        self.assertEqual((self.task("b").get("parent_id"), self.task("b").get("position")), (None, 2000))

    def test_drop_into_another_project_carries_the_subtree(self):
        self.seed("project", "p1", name="Home")
        self.seed("project", "p2", name="Work")
        self.seed("section", "s1", name="Doing", project_id="p1", deleted_at=None)
        self.seed("task", "a", title="A", project_id="p1", section_id="s1", position=1, deleted_at=None)
        self.seed("task", "a1", title="A1", project_id="p1", section_id="s1", parent_id="a", deleted_at=None)
        self.seed("task", "x", title="X", project_id="p2", position=500, deleted_at=None)
        self.writer.drop("a", Place("p2", None, "x"))
        a, a1 = self.task("a"), self.task("a1")
        self.assertEqual((a.get("project_id"), a.get("section_id"), a.get("parent_id")), ("p2", None, "x"))
        self.assertEqual((a1.get("project_id"), a1.get("section_id"), a1.get("parent_id")), ("p2", None, "a"))
        # A subtask dropped on the Inbox in the sidebar leaves its parent and project.
        self.writer.drop("a1", ToProject(None))
        a1 = self.task("a1")
        self.assertEqual((a1.get("project_id"), a1.get("parent_id")), (None, None))

    def test_drop_on_a_day_keeps_the_time_and_unparks(self):
        self.seed("task", "a", title="A", deleted_at=None, due={"date": "2026-11-03", "time": "14:30", "tz": "Europe/Berlin"})
        self.seed("task", "b", title="B", deleted_at=None, start="someday")
        self.writer.drop("a", ToDay("2026-11-05"))
        self.assertEqual(self.task("a").get("due"), {"date": "2026-11-05", "time": "14:30", "tz": "Europe/Berlin"})
        self.writer.drop("b", ToDay("2026-11-02"))
        self.assertEqual((self.task("b").get("due"), self.task("b").get("start")), ({"date": "2026-11-02"}, None))

    def test_a_drop_that_changes_nothing_writes_nothing(self):
        self.seed("project", "p1", name="Home")
        self.seed("task", "a", title="A", project_id="p1", position=1000, deleted_at=None, due={"date": "2026-11-05"})
        before = self.store.outbox_count()
        for target in (ToDay("2026-11-05"), ToProject("p1"), Place("p1", None)):
            self.assertEqual(self.writer.drop("a", target).undo, [])
        self.assertEqual(self.store.outbox_count(), before)
        self.seed("task", "done", title="Done", project_id="p1", completed_at=5, deleted_at=None)
        with self.assertRaises(CannotEdit):
            self.writer.drop("done", ToProject(None))

    def test_views(self):
        self.seed("view", "old", position=self.now + 10, deleted_at=None)
        view_id = self.writer.add_view(" Urgent ", "p1 & due <= today", group_by="due")
        view = self.store.rows("view")[view_id]
        self.assertEqual({k: view.get(k) for k in ("name", "query", "kind", "group_by", "sort_by", "pinned", "position")},
                         {"name": "Urgent", "query": "p1 & due <= today", "kind": "list", "group_by": "due",
                          "sort_by": "due", "pinned": True, "position": self.now + 11})
        self.assertNotIn("show_completed", view.values)
        before = self.store.outbox_count()
        self.writer.edit_view(view_id, {"name": "Urgent", "query": "p1", "show_completed": False})
        self.assertEqual([o["field"] for o in self.outbox()[before:]], ["query"])
        for bad in ({"query": "p1 &"}, {"query": "  "}, {"name": ""}):
            with self.assertRaises(CannotEdit):
                self.writer.edit_view(view_id, bad)
        self.writer.delete_view(view_id)
        self.assertEqual(self.store.rows("view")[view_id].get("deleted_at"), self.now)


if __name__ == "__main__":
    unittest.main()


class SectorWriteTest(WriterCase):
    def test_choosing_a_sector_clears_the_other_whens_and_keeps_the_deadline(self):
        self.seed("task", "t1", title="Budget", due={"date": "2026-11-05"}, start="2026-11-04", evening=True,
                  deadline="2026-11-20")
        self.writer.edit("t1", {"sector": "2026-W46"})
        task = self.task("t1")
        self.assertEqual({k: task.get(k) for k in ("sector", "due", "start", "evening", "deadline")},
                         {"sector": "2026-W46", "due": None, "start": None, "evening": False, "deadline": "2026-11-20"})

    def test_a_date_clears_the_sector_in_the_same_batch(self):
        self.seed("task", "t1", title="Budget", sector="2026-W45")
        self.seed("task", "t2", title="Other")
        self.writer.edit("t1", {"due": {"date": "2026-11-06"}})
        self.writer.edit("t2", {"due": {"date": "2026-11-06"}})
        self.assertEqual(self.task("t1").get("sector"), "")
        self.assertNotIn("sector", {o["field"] for o in self.outbox() if o["entityId"] == "t2"})
        self.assertEqual(len({o["ts"] for o in self.outbox() if o["entityId"] == "t1"}), 1)

    def test_a_drop_on_a_day_clears_the_sector(self):
        self.seed("task", "t1", title="Budget", sector="2026-W45")
        self.writer.drop("t1", ToDay("2026-11-06"))
        self.assertEqual((self.task("t1").get("due"), self.task("t1").get("sector")), ({"date": "2026-11-06"}, ""))

    def test_refuses_bad_sectors_and_repeating_tasks(self):
        self.seed("task", "t1", title="Weekly", due={"date": "2026-11-05"}, recurrence="every week")
        for sector in ("2026-W60", "this week"):
            with self.assertRaises(CannotEdit):
                self.writer.edit("t1", {"sector": sector})
        with self.assertRaises(CannotEdit):
            self.writer.edit("t1", {"sector": "2026-W46"})

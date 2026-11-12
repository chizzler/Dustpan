import unittest
from unittest.mock import Mock

from dustpan import trash
from dustpan.api import Api, ApiError, Offline
from dustpan.model import snapshot
from dustpan.store import Row, Store
from dustpan.sync import Syncer
from dustpan.writes import CannotEdit, Writer
from tests.test_sync import FakeApi
from tests.test_writes import WriterCase


class ItemsTest(unittest.TestCase):
    def test_lists_deleted_items_newest_first_and_folds_subtasks(self):
        projects = {"p": Row("p", {"name": "Work", "deleted_at": 20, "color": "#abcdef"})}
        tasks = {r.id: r for r in [
            Row("a", {"title": "Parent", "deleted_at": 30, "project_id": "p"}),
            Row("b", {"title": "Child", "deleted_at": 30, "parent_id": "a"}),
            Row("c", {"deleted_at": 30, "parent_id": "b"}),
            Row("d", {"title": "Earlier", "deleted_at": 10, "parent_id": "a"}),
            Row("live", {"project_id": "p"}),
        ]}
        items = trash.items(tasks, projects)
        self.assertEqual([i.id for i in items], ["a", "p", "d"])
        self.assertEqual((items[0].subtasks, items[0].project_name), (2, "Work"))
        self.assertEqual(items[1].color, "#abcdef")

    def test_cycles_and_self_parents_still_have_a_visible_restore_target(self):
        tasks = {r.id: r for r in [
            Row("a", {"deleted_at": 10, "parent_id": "b"}),
            Row("b", {"deleted_at": 10, "parent_id": "a"}),
            Row("self", {"deleted_at": 10, "parent_id": "self"}),
        ]}
        items = trash.items(tasks, {})
        self.assertEqual(len(items), 2)
        self.assertEqual(sorted(i.subtasks for i in items), [0, 1])

    def test_retention_rounds_up_and_never_goes_negative(self):
        day = trash.DAY_MS
        for now, expected in [(100, 30), (101, 30), (100 + day, 29),
                              (100 + 30 * day - 1, 1), (100 + 30 * day, 0), (100 + 31 * day, 0)]:
            self.assertEqual(trash.remaining_days(100, 30, now), expected)
        self.assertIsNone(trash.remaining_days(100, 0, 200))


class RestoreTest(WriterCase):
    def test_restore_keeps_fields_and_restores_only_the_subtree_deleted_together(self):
        self.seed("project", "p", name="Work")
        self.seed("section", "s", project_id="p")
        self.seed("task", "a", title="Parent", project_id="p", section_id="s", deleted_at=10,
                  description="Notes", completed_at=5, priority=1)
        self.seed("task", "b", parent_id="a", project_id="p", deleted_at=10)
        self.seed("task", "c", parent_id="b", project_id="p", deleted_at=10)
        self.seed("task", "old", parent_id="a", deleted_at=9)
        done = self.writer.restore_task("a")
        for tid in ("a", "b", "c"):
            self.assertIsNone(self.task(tid).get("deleted_at"))
        self.assertEqual(self.task("old").get("deleted_at"), 9)
        self.assertEqual(self.task("a").get("section_id"), "s")
        self.assertEqual(self.task("a").get("description"), "Notes")
        self.assertEqual(self.task("a").get("completed_at"), 5)
        self.assertEqual(self.task("a").get("priority"), 1)
        self.assertEqual({o["field"] for o in self.outbox()}, {"deleted_at"})
        self.writer.revert(done.undo)
        self.assertEqual([self.task(t).get("deleted_at") for t in ("a", "b", "c")], [10, 10, 10])

    def test_restore_to_inbox_moves_the_whole_subtree_and_undo_puts_it_back(self):
        self.seed("project", "p", deleted_at=20)
        self.seed("section", "s", project_id="p")
        self.seed("task", "a", project_id="p", section_id="s", deleted_at=10, parent_id="gone")
        self.seed("task", "b", project_id="p", parent_id="a", deleted_at=10)
        done = self.writer.restore_task("a")
        self.assertEqual(done.task_id, "a")
        for tid in ("a", "b"):
            self.assertIsNone(self.task(tid).get("project_id"))
            self.assertIsNone(self.task(tid).get("section_id"))
        self.assertIsNone(self.task("a").get("parent_id"))
        self.assertEqual(self.task("b").get("parent_id"), "a")
        self.assertEqual({t.id for t in snapshot(self.store).tasks}, {"a", "b"})
        self.writer.revert(done.undo)
        self.assertEqual(self.task("a").get("section_id"), "s")
        self.assertEqual(self.task("b").get("project_id"), "p")
        self.assertEqual(self.task("a").get("parent_id"), "gone")

    def test_missing_project_also_restores_to_inbox(self):
        self.seed("task", "a", project_id="missing", deleted_at=10)
        self.writer.restore_task("a")
        self.assertIsNone(self.task("a").get("project_id"))

    def test_deleted_or_missing_parent_is_cleared_but_a_live_parent_is_kept(self):
        self.seed("task", "gone", deleted_at=20)
        self.seed("task", "live", title="Live")
        for parent in ("gone", "missing", "live"):
            tid = "child-" + parent
            self.seed("task", tid, parent_id=parent, deleted_at=10)
            self.writer.restore_task(tid)
            self.assertEqual(self.task(tid).get("parent_id"), "live" if parent == "live" else None)

    def test_stale_section_is_cleared(self):
        self.seed("project", "p", name="Work")
        self.seed("section", "gone", project_id="p", deleted_at=20)
        self.seed("section", "other", project_id="elsewhere")
        for section in ("gone", "missing", "other"):
            self.seed("task", section, project_id="p", section_id=section, deleted_at=10)
            self.writer.restore_task(section)
            self.assertIsNone(self.task(section).get("section_id"))

    def test_project_restore_reveals_tasks_but_does_not_restore_separately_deleted_tasks(self):
        self.seed("project", "p", name="Work", deleted_at=20)
        self.seed("task", "a", project_id="p")
        self.seed("task", "b", project_id="p", deleted_at=10)
        self.assertEqual(snapshot(self.store).tasks, [])
        done = self.writer.restore_project("p")
        self.assertEqual([t.id for t in snapshot(self.store).tasks], ["a"])
        self.assertEqual(len(self.outbox()), 1)
        self.writer.revert(done.undo)
        self.assertEqual(self.store.rows("project")["p"].get("deleted_at"), 20)

    def test_restoring_live_or_missing_items_is_refused(self):
        for entity, restore in [("task", self.writer.restore_task), ("project", self.writer.restore_project)]:
            self.seed(entity, "live", deleted_at=None)
            for eid in ("missing", "live"):
                with self.assertRaises(CannotEdit):
                    restore(eid)
        self.assertEqual(self.store.outbox_count(), 0)


class PurgeTest(WriterCase):
    def setUp(self):
        super().setUp()
        self.api = Mock()
        for tid in ("a", "b", "c"):
            self.seed("task", tid, deleted_at=10)

    def test_queue_deduplicates_including_within_one_request(self):
        trash.queue(self.store, [("task", "a"), ("task", "a")])
        trash.queue(self.store, [("task", "a"), ("task", "b")])
        self.assertEqual(self.store.get_meta(trash.PENDING), [["task", "a"], ["task", "b"]])

    def test_success_waits_for_sync_markers_before_removing_local_data(self):
        trash.queue(self.store, [("task", "a")])
        self.assertEqual(trash.send(self.store, self.api), 1)
        self.api.purge.assert_called_once_with("task", "a")
        self.assertIn("a", self.store.rows("task"))
        self.assertEqual(trash.pending(self.store), set())

    def test_offline_preserves_remaining_requests_but_not_completed_ones(self):
        trash.queue(self.store, [("task", t) for t in ("a", "b", "c")])
        self.api.purge.side_effect = [None, Offline("offline")]
        with self.assertRaises(Offline):
            trash.send(self.store, self.api)
        self.assertEqual(trash.pending(self.store), {("task", "b"), ("task", "c")})
        self.api.purge.side_effect = None
        self.assertEqual(trash.send(self.store, self.api), 2)

    def test_temporary_errors_are_retained_for_retry(self):
        for status in (401, 429, 500, 503):
            with self.subTest(status=status):
                trash.queue(self.store, [("task", "a")])
                self.api.purge.side_effect = ApiError(status, "http_error", "try later")
                with self.assertRaises(ApiError):
                    trash.send(self.store, self.api)
                self.assertIn(("task", "a"), trash.pending(self.store))

    def test_already_gone_or_restored_on_server_requests_are_dropped(self):
        for status, code in [(404, "not_found"), (409, "not_deleted")]:
            trash.queue(self.store, [("task", "a")])
            self.api.purge.side_effect = ApiError(status, code, "gone")
            self.assertEqual(trash.send(self.store, self.api), 0)
            self.assertEqual(trash.pending(self.store), set())

    def test_locally_restored_or_missing_targets_are_not_sent(self):
        self.writer.restore_task("a")
        trash.queue(self.store, [("task", "a"), ("task", "missing")])
        self.assertEqual(trash.send(self.store, self.api), 0)
        self.api.purge.assert_not_called()
        self.assertEqual(trash.pending(self.store), set())

    def test_forbidden_is_dropped_but_reported_to_the_caller(self):
        trash.queue(self.store, [("task", "a")])
        self.api.purge.side_effect = ApiError(403, "forbidden", "not allowed")
        with self.assertRaises(ApiError):
            trash.send(self.store, self.api)
        self.assertEqual(trash.pending(self.store), set())

    def test_requests_queued_during_network_call_are_not_lost(self):
        trash.queue(self.store, [("task", "a")])
        self.api.purge.side_effect = lambda *_: trash.queue(self.store, [("task", "b")])
        trash.send(self.store, self.api)
        self.assertEqual(trash.pending(self.store), {("task", "b")})

    def test_unsent_or_held_edits_delay_purge(self):
        self.seed("task", "new", title="New")
        self.writer.delete_task("new")
        trash.queue(self.store, [("task", "new")])
        self.assertEqual(trash.send(self.store, self.api), 0)
        held = self.outbox()
        self.store.outbox_remove(seq for seq, _ in self.store.outbox_batch(1000))
        self.store.set_meta("held_ops", held)
        self.assertEqual(trash.send(self.store, self.api), 0)
        self.api.purge.assert_not_called()
        self.assertIn(("task", "new"), trash.pending(self.store))


class SyncTrashTest(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)

    def test_retention_is_remembered_including_disabled_and_absent_values(self):
        for response, expected in [({"trashRetentionDays": 7}, 7), ({}, 7), ({"trashRetentionDays": 0}, 0)]:
            Syncer(self.store, FakeApi([response])).run()
            self.assertEqual(self.store.get_meta(trash.RETENTION), expected)

    def test_purge_runs_after_delete_upload_and_then_pulls_markers(self):
        writer = Writer(self.store, now=lambda: 1000)
        tid = writer.add_task("Temporary")
        writer.delete_task(tid)
        trash.queue(self.store, [("task", tid)])
        api = FakeApi([{}, {"purged": [{"entity": "task", "entityId": tid}], "cursor": 10}])

        def purge(entity, eid):
            self.assertEqual((entity, eid), ("task", tid))
            self.assertEqual(len(api.requests), 1)
            self.assertEqual(self.store.outbox_count(), 0)
            self.assertTrue(any(o["field"] == "deleted_at" and o["value"] == 1000 for o in api.requests[0]["ops"]))

        api.purge = purge
        result = Syncer(self.store, api).run()
        self.assertEqual(result.purged, 1)
        self.assertEqual(self.store.rows("task"), {})
        self.assertEqual(trash.pending(self.store), set())
        self.assertEqual(self.store.get_meta("cursor"), 10)

    def test_purge_api_uses_delete_and_quotes_the_id(self):
        api = Api("https://example.invalid/", "token")
        api._send = Mock(return_value={})
        api.purge("task", "a/b ?")
        request = api._send.call_args.args[0]
        self.assertEqual(request.get_method(), "DELETE")
        self.assertEqual(request.full_url, "https://example.invalid/api/v1/tasks/a%2Fb%20%3F/purge")
        self.assertEqual(request.get_header("Authorization"), "Bearer token")

    def test_server_limit_holds_delete_and_purge_until_next_sync(self):
        writer = Writer(self.store, now=lambda: 1000)
        tid = writer.add_task("Temporary")
        Syncer(self.store, FakeApi([])).run()
        writer.delete_task(tid)
        trash.queue(self.store, [("task", tid)])

        def limited(body):
            return {"rejected": [{"id": o["id"], "reason": "limit_ops_hour"} for o in body["ops"]]}

        api = FakeApi([limited])
        api.purge = Mock()
        self.assertEqual(Syncer(self.store, api).run().held, 1)
        api.purge.assert_not_called()
        self.assertIn(("task", tid), trash.pending(self.store))
        api.responses = [{}, {"purged": [{"entity": "task", "entityId": tid}]}]
        self.assertEqual(Syncer(self.store, api).run().purged, 1)
        api.purge.assert_called_once_with("task", tid)

    def test_cascaded_markers_remove_all_named_entities_and_their_outbox_ops(self):
        entities = [("project", "p"), ("task", "a"), ("task", "b"), ("section", "s"), ("reminder", "r")]
        for entity, eid in entities:
            op = {"id": eid, "entity": entity, "entityId": eid, "field": "deleted_at",
                  "value": 10, "ts": 10, "device": "other"}
            self.store.apply(op)
            self.store.outbox_add([op])
        markers = [{"entity": entity, "entityId": eid} for entity, eid in entities]
        result = Syncer(self.store, FakeApi([{"purged": markers}])).run()
        self.assertEqual(result.purged, 5)
        self.assertEqual(list(self.store.all_fields()), [])
        self.assertEqual(self.store.outbox_count(), 0)


class LocalPurgeTest(WriterCase):
    def test_local_task_purge_removes_deleted_descendants_children_and_queued_ops(self):
        p = self.writer.add_project("Work")
        parent = self.writer.add_task("Parent", project_id=p, due={"date": "2026-11-05", "time": "09:00"})
        child = self.writer.add_task("Child", parent_id=parent)
        separate = self.writer.add_task("Deleted earlier", parent_id=parent)
        kept = self.writer.add_task("Keep me", project_id=p)
        rem = self.writer.add_reminder(parent, "relative", offset_minutes=-10)
        self.seed("time_entry", "te1", task_id=parent, user_id="me", started_at=100, ended_at=200)
        self.seed("comment", "c1", task_id=child, author_id="me", body="note")

        self.now = 2_000_000
        self.writer.delete_task(separate)
        self.now = 3_000_000
        self.writer.delete_task(parent)
        trash.queue(self.store, [("task", parent)])
        self.store.set_meta("held_ops", [{"id": "h1", "entity": "task", "entityId": parent,
                                          "field": "title", "value": "x", "ts": 1, "device": "d"}])

        removed = trash.purge_local(self.store, [("task", parent)])
        self.assertEqual(removed, 6)  # parent, child, separate, rem, te1, c1
        self.assertEqual(set(self.store.rows("task")), {kept})
        self.assertEqual(self.store.rows("reminder"), {})
        self.assertEqual(self.store.rows("time_entry"), {})
        self.assertEqual(self.store.rows("comment"), {})
        self.assertEqual(trash.pending(self.store), set())
        self.assertEqual(self.store.get_meta("held_ops"), [])
        self.assertFalse(any(o["entityId"] in {parent, child, separate, rem} for o in self.outbox()))

    def test_local_project_purge_removes_sections_tasks_and_cascades(self):
        p = self.writer.add_project("Drop")
        sec = self.writer.add_section(p, "Todo")
        live_task = self.writer.add_task("Live inside deleted project", project_id=p, section_id=sec)
        rem = self.writer.add_reminder(live_task, "absolute", fire_at=5_000_000)
        self.seed("project_prefs", p, feed_seen_at=100)
        other = self.writer.add_task("Inbox stays")
        self.writer.delete_project(p)

        removed = trash.purge_local(self.store, [("project", p)])
        self.assertGreaterEqual(removed, 5)
        self.assertEqual(self.store.rows("project"), {})
        self.assertEqual(self.store.rows("section"), {})
        self.assertEqual(set(self.store.rows("task")), {other})
        self.assertNotIn(rem, self.store.rows("reminder"))
        self.assertEqual(self.store.rows("project_prefs"), {})
        self.assertTrue(all(o["entityId"] == other for o in self.outbox()))

    def test_local_purge_skips_live_or_missing_targets_and_cleans_pending(self):
        live_task = self.writer.add_task("Still open")
        trash.queue(self.store, [("task", live_task), ("task", "missing")])
        self.assertEqual(trash.purge_local(self.store, [("task", live_task), ("task", "missing")]), 0)
        self.assertIn(live_task, self.store.rows("task"))
        self.assertEqual(trash.pending(self.store), set())

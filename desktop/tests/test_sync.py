import unittest

from dustpan import trash
from dustpan.clock import HybridClock
from dustpan.ids import default_reminder_id, occurrence_id
from dustpan.model import CLEARED_SUBTASKS, FOLDED_TASKS
from dustpan.store import Store
from dustpan.sync import (AccountMismatch, ClockSkew, Syncer, UnsupportedAccount, is_reserved_device,
                          migrate_account, reset_for_account)
from dustpan.api import Offline
from dustpan.writes import Writer


def op(entity_id, field, value, ts, device="other"):
    return {"id": f"{entity_id}-{field}-{ts}", "entity": "task", "entityId": entity_id,
            "field": field, "value": value, "ts": ts, "device": device}


class FakeApi:
    """Answers sync requests from a list of prepared responses."""

    def __init__(self, responses, encrypted=False, user_id="me", base_url=None, token=None):
        self.responses = list(responses)
        self.requests = []
        self.encrypted = encrypted
        self.user_id = user_id
        self.base_url = base_url
        self.token = token
        self.generation = "g1"

    def me(self):
        return {"user": {"id": self.user_id}, "encryption": {"enabled": self.encrypted}}

    def sync(self, body):
        self.requests.append(body)
        planned = self.responses.pop(0) if self.responses else {}
        if callable(planned):
            planned = planned(body)
        # Like a real server, a new generation sticks once announced.
        self.generation = planned.get("generation", self.generation)
        res = {"ops": [], "cursor": body["cursor"], "hasMore": False,
               "serverTime": 1_000, "generation": self.generation}
        res.update(planned)
        return res


class SyncTest(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)

    def run_sync(self, *responses, **kwargs):
        api = FakeApi(responses, **kwargs)
        result = Syncer(self.store, api).run()
        return api, result.received

    def queue_local(self, entity_id, field, value, ts):
        local = op(entity_id, field, value, ts, device=self.store.device())
        local["id"] = f"local-{field}"
        self.store.apply(local)
        self.store.outbox_add([local])
        return local

    def test_pages_until_no_more(self):
        api, received = self.run_sync(
            {"ops": [op("t1", "title", "A", 1)], "cursor": 1, "hasMore": True},
            {"ops": [op("t2", "title", "B", 2)], "cursor": 2},
        )
        self.assertEqual(received, 2)
        self.assertEqual([r["cursor"] for r in api.requests], [0, 1])
        self.assertEqual(self.store.get_meta("cursor"), 2)
        self.assertEqual(set(self.store.rows("task")), {"t1", "t2"})

    def test_device_id_is_stable_and_sent(self):
        api, _ = self.run_sync()
        api2, _ = self.run_sync()
        self.assertEqual(api.requests[0]["device"], api2.requests[0]["device"])

    def test_purge_marker_deletes_entity(self):
        self.run_sync({"ops": [op("t1", "title", "A", 1)], "cursor": 1})
        self.run_sync({"purged": [{"entity": "task", "entityId": "t1"}], "cursor": 2})
        self.assertEqual(self.store.rows("task"), {})

    def test_backfill_seq_is_echoed(self):
        api, _ = self.run_sync({"backfillSeq": 7, "hasMore": True}, {})
        self.assertEqual([r["backfillAck"] for r in api.requests], [0, 7])

    def test_encrypted_account_is_refused(self):
        with self.assertRaises(UnsupportedAccount):
            self.run_sync(encrypted=True)

    def test_generation_change_reseeds_with_stored_clocks(self):
        self.run_sync({"ops": [op("t1", "title", "A", 5, device="phone"),
                               op("t1", "priority", 2, 6, device="server:abc")], "cursor": 9})
        api, _ = self.run_sync({"generation": "g2", "cursor": 9}, {"cursor": 3})
        self.assertEqual(api.requests[1]["cursor"], 0)
        sent = {o["field"]: o for o in api.requests[1]["ops"]}
        self.assertEqual((sent["title"]["ts"], sent["title"]["device"]), (5, "phone"))
        # A reserved device would get the batch refused; ours replaces it.
        self.assertEqual(sent["priority"]["ts"], 6)
        self.assertEqual(sent["priority"]["device"], self.store.get_meta("device"))
        self.assertEqual(self.store.get_meta("generation"), "g2")
        self.assertEqual(self.store.outbox_count(), 0)

    def test_reseed_skips_other_authors_comments(self):
        def comment(cid, author):
            return {"id": cid, "entity": "comment", "entityId": cid, "field": "author_id",
                    "value": author, "ts": 1, "device": "x"}
        self.run_sync({"ops": [comment("c1", "me"), comment("c2", "someone")], "cursor": 2})
        api, _ = self.run_sync({"generation": "g2"}, {})
        self.assertEqual([o["entityId"] for o in api.requests[1]["ops"]], ["c1"])

    def test_restore_downloads_own_fields_missing_after_a_purge(self):
        device = self.store.device()
        own = op("t1", "title", "Back in the archive", 5, device=device)
        self.run_sync({"ops": [own], "cursor": 9})
        self.store.purge("task", "t1")

        def pull(body):
            # The real server skips ops authored by the request's device.
            return {"ops": [] if body["device"] == device else [own], "cursor": 1}

        api, _ = self.run_sync({"generation": "g2"}, pull)
        self.assertNotEqual(api.requests[1]["device"], device)
        self.assertEqual(self.store.rows("task")["t1"].get("title"), "Back in the archive")
        self.assertEqual(self.store.device(), device)
        self.assertEqual(self.store.rows("task")["t1"].clocks["title"].device, device)
        self.assertIsNone(self.store.get_meta("reseed_device"))
        api, _ = self.run_sync()
        self.assertEqual(api.requests[0]["device"], device)

    def test_recovery_request_identity_survives_interruption_and_pagination(self):
        self.run_sync({"ops": [op("t1", "title", "Keep", 5)], "cursor": 9})
        device = self.store.device()

        def disconnect(body):
            raise Offline("lost upload acknowledgement")

        api = FakeApi([{"generation": "g2"}, disconnect])
        with self.assertRaises(Offline):
            Syncer(self.store, api).run()
        replay_device = self.store.get_meta("reseed_device")
        self.assertIsNotNone(replay_device)
        self.assertNotEqual(replay_device, device)
        self.assertGreater(self.store.outbox_count(), 0)
        resumed = FakeApi([{"hasMore": True, "cursor": 1}, {"cursor": 2}])
        resumed.generation = "g2"
        Syncer(self.store, resumed).run()
        self.assertEqual([r["device"] for r in resumed.requests], [replay_device, replay_device])
        self.assertEqual(self.store.device(), device)
        self.assertIsNone(self.store.get_meta("reseed_device"))
        self.assertEqual(self.store.outbox_count(), 0)

    def test_refused_op_gives_way_to_the_servers_value(self):
        self.queue_local("t1", "title", "Mine", 50)
        server_value = op("t1", "title", "Theirs", 10, device="server:x")
        api = FakeApi([{"rejected": [{"id": "local-title", "reason": "forbidden"}], "ops": [server_value]}])
        result = Syncer(self.store, api).run()
        self.assertEqual(result.refused, 1)
        self.assertEqual(self.store.rows("task")["t1"].get("title"), "Theirs")
        self.assertEqual(self.store.outbox_count(), 0)

    def test_refusal_keeps_a_newer_local_edit(self):
        self.queue_local("t1", "title", "First", 50)
        def edit_meanwhile(body):
            # The user edited again while the request was out.
            newer = op("t1", "title", "Second", 60, device=self.store.device())
            self.store.apply(newer)
            return {"rejected": [{"id": "local-title", "reason": "forbidden"}]}
        Syncer(self.store, FakeApi([edit_meanwhile])).run()
        self.assertEqual(self.store.rows("task")["t1"].get("title"), "Second")

    def test_clock_skew_restamps_and_resends_with_the_same_id(self):
        far = 1_000 + 10 * 60_000
        self.queue_local("t1", "title", "A", far)
        self.queue_local("t1", "priority", 1, far)
        self.store.set_meta("clock_last", far)
        api = FakeApi([{"rejected": [{"id": "local-title", "reason": "clock_skew", "serverTime": 1_000},
                                     {"id": "local-priority", "reason": "clock_skew", "serverTime": 1_000}]}])
        Syncer(self.store, api).run()
        resent = api.requests[1]["ops"]
        self.assertEqual({o["id"] for o in resent}, {"local-title", "local-priority"})
        self.assertEqual(len({o["ts"] for o in resent}), 1)
        self.assertLess(resent[0]["ts"], far)
        self.assertEqual(self.store.rows("task")["t1"].clocks["title"].ts, resent[0]["ts"])

    def test_endless_clock_skew_is_an_error(self):
        self.queue_local("t1", "title", "A", 5)
        refuse = {"rejected": [{"id": "local-title", "reason": "clock_skew"}]}
        with self.assertRaises(ClockSkew):
            self.run_sync(*[refuse] * 5)

    def test_limited_ops_are_held_and_offered_next_time(self):
        self.queue_local("t1", "title", "A", 5)
        api = FakeApi([{"rejected": [{"id": "local-title", "reason": "limit_ops_hour"}]}])
        result = Syncer(self.store, api).run()
        self.assertEqual((result.held, self.store.outbox_count()), (1, 0))
        self.assertEqual(self.store.rows("task")["t1"].get("title"), "A")
        api2, _ = self.run_sync()
        self.assertEqual([o["id"] for o in api2.requests[0]["ops"]], ["local-title"])

    def test_clock_skew_feature_is_announced(self):
        api, _ = self.run_sync()
        self.assertIn("clock_skew", api.requests[0]["features"])

    def test_reserved_devices(self):
        for device in ("server", "server:1", "agent:x", "caldav:x", "public:x", "rule:x", "page:x"):
            self.assertTrue(is_reserved_device(device), device)
        for device in ("3c54-abcd", "assistant:x", "serverless"):
            self.assertFalse(is_reserved_device(device), device)


class StandaloneConnectTest(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)
        self.now = 1_000_000
        clock = HybridClock(self.store, now=lambda: self.now)
        self.writer = Writer(self.store, clock=clock, now=lambda: self.now, today=lambda: "2026-11-12")

    def test_connecting_later_adopts_identity_compacts_edits_and_uploads_in_dependency_order(self):
        self.writer.set_prefs({"reminder_default_timed": -30, "reminder_default_dated": -1440, "time_format": "24h"})
        proj = self.writer.add_project("Home")
        sec = self.writer.add_section(proj, "Chores")
        timed = self.writer.quick_add("Pay rent 2026-11-20 09:00 15m/1h", project_id=proj, section_id=sec)
        self.writer.edit(timed, {"title": "Pay rent v2"})
        self.writer.edit(timed, {"title": "Pay rent final"})
        done_task = self.writer.add_task("Wash dishes", project_id=proj)
        self.writer.complete(done_task)
        gone = self.writer.add_task("Temporary scratch")
        self.writer.delete_task(gone)
        trash.purge_local(self.store, [("task", gone)])

        old_default_rid = default_reminder_id("local", timed)
        self.store.set_meta("notified", {old_default_rid: 999})

        api = FakeApi([{"cursor": 25, "serverTime": self.now}], user_id="u_alice",
                      base_url="https://todo.example.com", token="ot_1")
        Syncer(self.store, api, clock=self.writer.clock).run()

        self.assertEqual(self.store.get_meta("user_id"), "u_alice")
        self.assertEqual(self.store.outbox_count(), 0)
        sent = api.requests[0]["ops"]

        # Superseded title edits were compacted to one op with the final title, and purged task never uploaded.
        timed_titles = [o for o in sent if o["entity"] == "task" and o["entityId"] == timed and o["field"] == "title"]
        self.assertEqual(len(timed_titles), 1)
        self.assertEqual(timed_titles[0]["value"], "Pay rent final")
        self.assertFalse(any(o["entityId"] == gone for o in sent))

        # Local identity was rewritten to u_alice for completions, time entries and default reminders.
        self.assertEqual(self.store.rows("task")[done_task].get("completed_by"), "u_alice")
        self.assertTrue(any(o["entity"] == "task" and o["entityId"] == done_task
                            and o["field"] == "completed_by" and o["value"] == "u_alice" for o in sent))
        entries = list(self.store.rows("time_entry").values())
        self.assertEqual(entries[0].get("user_id"), "u_alice")
        self.assertTrue(any(o["entity"] == "time_entry" and o["field"] == "user_id" and o["value"] == "u_alice"
                            for o in sent))

        new_default_rid = default_reminder_id("u_alice", timed)
        self.assertNotIn(old_default_rid, self.store.rows("reminder"))
        self.assertIn(new_default_rid, self.store.rows("reminder"))
        self.assertEqual(self.store.get_meta("notified"), {new_default_rid: 999})

        # Because the default reminder id was remapped to u_alice, switching due to date-only still updates it.
        self.writer.edit(timed, {"due": {"date": "2026-11-20"}})
        self.assertEqual(self.store.rows("reminder")[new_default_rid].get("offset_minutes"), -1440)

        # Tasks are ordered before reminders and time entries.
        entities = [o["entity"] for o in sent]
        self.assertLess(max(i for i, e in enumerate(entities) if e == "task"),
                        min(i for i, e in enumerate(entities) if e == "time_entry"))

        # Untouched user_prefs fields were never emitted.
        pref_fields = {o["field"] for o in sent if o["entity"] == "user_prefs"}
        self.assertEqual(pref_fields, {"reminder_default_timed", "reminder_default_dated", "time_format"})

    def test_connecting_later_merges_with_existing_server_data_without_losing_either_side(self):
        self.writer.set_prefs({"time_format": "24h"})
        local_proj = self.writer.add_project("Local Project")
        local_task = self.writer.add_task("Local Task", project_id=local_proj)

        server_ops_page1 = [
            {"id": "s1", "entity": "project", "entityId": "srv_proj", "field": "name",
             "value": "Server Project", "ts": 500, "device": "web"},
            {"id": "s2", "entity": "task", "entityId": "srv_task", "field": "title",
             "value": "Server Task", "ts": 500, "device": "web"},
            {"id": "s3", "entity": "task", "entityId": "srv_task", "field": "project_id",
             "value": "srv_proj", "ts": 500, "device": "web"},
        ]
        server_ops_page2 = [
            {"id": "s4", "entity": "user_prefs", "entityId": "me", "field": "week_start",
             "value": "sun", "ts": 500, "device": "web"},
        ]
        api = FakeApi([
            {"ops": server_ops_page1, "cursor": 3, "hasMore": True},
            {"ops": server_ops_page2, "cursor": 4, "hasMore": False},
        ], user_id="u_alice")
        Syncer(self.store, api).run()

        self.assertEqual(set(self.store.rows("project")), {local_proj, "srv_proj"})
        self.assertEqual(set(self.store.rows("task")), {local_task, "srv_task"})
        prefs = self.store.rows("user_prefs")["me"]
        self.assertEqual(prefs.get("time_format"), "24h")
        self.assertEqual(prefs.get("week_start"), "sun")
        self.assertTrue(any(o["entityId"] == local_task for o in api.requests[0]["ops"]))

    def test_large_standalone_upload_keeps_compound_entities_whole_and_handles_multi_batch_skew(self):
        far = 10_000_000
        clock = HybridClock(self.store, now=lambda: far)
        writer = Writer(self.store, clock=clock, now=lambda: far, today=lambda: "2026-11-12")
        # 45 tasks (495 ops) + time entries straddling the 500-op boundary + more tasks (> 1,500 ops total).
        for n in range(130):
            if n == 45:
                writer.quick_add("Boundary work 20m/1h")
            else:
                writer.add_task(f"Task {n}")

        seen_entries = set()
        accepted_tasks = set()
        skewed_once = set()

        def server(body):
            entry_ids_in_batch = {o["entityId"] for o in body["ops"] if o["entity"] == "time_entry"}
            for eid in entry_ids_in_batch:
                entry_fields = {o["field"] for o in body["ops"] if o["entity"] == "time_entry" and o["entityId"] == eid}
                self.assertTrue({"task_id", "user_id", "started_at"} <= entry_fields,
                                f"time_entry {eid} was split across batches: {entry_fields}")
            rejected = []
            rejected_ids = set()
            for o in body["ops"]:
                if o["ts"] > 2_000_000 and o["id"] not in skewed_once:
                    skewed_once.add(o["id"])
                    rejected.append({"id": o["id"], "reason": "clock_skew", "serverTime": 1_000_000})
                    rejected_ids.add(o["id"])
            for o in body["ops"]:
                if o["id"] not in rejected_ids:
                    if o["entity"] == "task" and o["field"] == "title":
                        accepted_tasks.add(o["entityId"])
                    elif o["entity"] == "time_entry":
                        seen_entries.add(o["entityId"])
            return {"rejected": rejected, "serverTime": 1_000_000, "cursor": len(accepted_tasks)}

        api = FakeApi([server] * 12, user_id="u_alice")
        Syncer(self.store, api).run()
        self.assertEqual(len(accepted_tasks), 130)
        self.assertEqual(len(seen_entries), 1)
        self.assertEqual(self.store.outbox_count(), 0)

    def test_account_switch_guard_and_rekey_migration(self):
        proj = self.writer.add_project("Work")
        sec = self.writer.add_section(proj, "Next")
        label = self.writer.add_label("urgent")
        series = self.writer.add_task("Standup", project_id=proj, section_id=sec, due={"date": "2026-11-10"})
        self.writer.edit(series, {"recurrence": "every day", "labels": ["urgent"]})
        self.writer.complete(series)
        old_rec = occurrence_id(series, "2026-11-10")
        self.writer.set_prefs({"reminder_default_dated": -1440})
        dated = self.writer.add_task("Tax", project_id=proj, due={"date": "2026-11-20"})
        self.store.set_meta(FOLDED_TASKS, [series])
        self.store.set_meta(CLEARED_SUBTASKS, {old_rec: [self.now, series]})

        api_u1 = FakeApi([{"cursor": 10}], user_id="u1", base_url="https://todo.example.com", token="tok_u1")
        Syncer(self.store, api_u1).run()

        # Rotating token for the same account works seamlessly.
        api_u1_rotated = FakeApi([{"cursor": 10}], user_id="u1", base_url="https://todo.example.com", token="tok_u1_new")
        Syncer(self.store, api_u1_rotated).run()

        # Connecting to a different account without explicit migration raises AccountMismatch.
        api_u2 = FakeApi([{"cursor": 1}], user_id="u2", base_url="https://todo.example.com", token="tok_u2")
        with self.assertRaises(AccountMismatch):
            Syncer(self.store, api_u2).run()

        # Explicit migration re-keys every entity id, updates derived ids and uploads cleanly to u2.
        migrate_account(self.store, "u2", ["https://todo.example.com", "x"])
        api_u2 = FakeApi([{"cursor": 50}], user_id="u2", base_url="https://todo.example.com", token="tok_u2")
        Syncer(self.store, api_u2).run()
        self.assertEqual(self.store.get_meta("user_id"), "u2")
        self.assertNotIn(proj, self.store.rows("project"))
        self.assertEqual(len(self.store.rows("project")), 1)
        new_proj = next(iter(self.store.rows("project")))
        new_series = next(tid for tid, t in self.store.rows("task").items() if t.get("title") == "Standup" and t.get("recurrence"))
        self.assertEqual(self.store.rows("task")[new_series].get("project_id"), new_proj)
        self.assertIn(occurrence_id(new_series, "2026-11-10"), self.store.rows("task"))
        new_dated = next(tid for tid, t in self.store.rows("task").items() if t.get("title") == "Tax")
        self.assertIn(default_reminder_id("u2", new_dated), self.store.rows("reminder"))
        self.assertNotIn(label, self.store.rows("label"))
        self.assertEqual(self.store.get_meta(FOLDED_TASKS), [new_series])

        # Reset for account clears synced entities while keeping device id.
        device = self.store.device()
        reset_for_account(self.store, "u3")
        self.assertEqual(self.store.device(), device)
        self.assertEqual(list(self.store.all_fields()), [])
        self.assertEqual(self.store.get_meta("user_id"), "u3")


if __name__ == "__main__":
    unittest.main()

import unittest

from dustpan.store import Store
from dustpan.sync import ClockSkew, Syncer, UnsupportedAccount, is_reserved_device


def op(entity_id, field, value, ts, device="other"):
    return {"id": f"{entity_id}-{field}-{ts}", "entity": "task", "entityId": entity_id,
            "field": field, "value": value, "ts": ts, "device": device}


class FakeApi:
    """Answers sync requests from a list of prepared responses."""

    def __init__(self, responses, encrypted=False):
        self.responses = list(responses)
        self.requests = []
        self.encrypted = encrypted
        self.generation = "g1"

    def me(self):
        return {"user": {"id": "me"}, "encryption": {"enabled": self.encrypted}}

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


if __name__ == "__main__":
    unittest.main()

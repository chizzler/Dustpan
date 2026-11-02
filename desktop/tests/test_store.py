import unittest

from dustpan.clock import HybridClock
from dustpan.store import Store, wins


def op(field, value, ts, device="d1", entity="task", entity_id="t1"):
    return {"id": f"{entity_id}-{field}-{ts}-{device}", "entity": entity, "entityId": entity_id,
            "field": field, "value": value, "ts": ts, "device": device}


class WinnerRuleTest(unittest.TestCase):
    def test_newer_timestamp_wins(self):
        self.assertTrue(wins(2, "a", 1, "z"))
        self.assertFalse(wins(1, "z", 2, "a"))

    def test_equal_timestamp_breaks_on_device(self):
        self.assertTrue(wins(5, "b", 5, "a"))
        self.assertFalse(wins(5, "a", 5, "b"))
        self.assertFalse(wins(5, "a", 5, "a"))


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)

    def test_apply_keeps_the_winner_in_any_order(self):
        ops = [op("title", "old", 1), op("title", "new", 3), op("title", "mid", 2)]
        for order in (ops, list(reversed(ops))):
            store = Store(":memory:")
            for o in order:
                store.apply(o)
            self.assertEqual(store.rows("task")["t1"].get("title"), "new")
            store.close()

    def test_apply_is_idempotent(self):
        self.assertTrue(self.store.apply(op("title", "a", 1)))
        self.assertFalse(self.store.apply(op("title", "a", 1)))

    def test_fields_merge_independently(self):
        self.store.apply(op("title", "a", 5, "d1"))
        self.store.apply(op("priority", 1, 2, "d2"))
        row = self.store.rows("task")["t1"]
        self.assertEqual((row.get("title"), row.get("priority")), ("a", 1))
        self.assertEqual(row.clocks["priority"].device, "d2")

    def test_purge_removes_fields_and_queued_ops(self):
        self.store.apply(op("title", "a", 1))
        self.store.outbox_add([op("title", "b", 2)])
        self.store.purge("task", "t1")
        self.assertEqual(self.store.rows("task"), {})
        self.assertEqual(self.store.outbox_count(), 0)

    def test_meta_round_trips_json(self):
        self.store.set_meta("cursor", 42)
        self.assertEqual(self.store.get_meta("cursor"), 42)
        self.assertIsNone(self.store.get_meta("missing"))


class ClockTest(unittest.TestCase):
    def setUp(self):
        self.store = Store(":memory:")
        self.addCleanup(self.store.close)
        self.now = 1_000_000
        self.clock = HybridClock(self.store, now=lambda: self.now)

    def test_stamps_strictly_increase_when_wall_clock_goes_back(self):
        first = self.clock.stamp()
        self.now -= 10_000
        self.assertGreater(self.clock.stamp(), first)

    def test_receive_moves_past_seen_timestamps(self):
        self.clock.receive(self.now + 500)
        self.assertGreater(self.clock.stamp(), self.now + 500)

    def test_follows_server_only_beyond_two_seconds(self):
        self.clock.follow_server(self.now + 1_500)
        self.assertEqual(self.clock.offset, 0)
        self.clock.follow_server(self.now + 60_000)
        self.assertEqual(self.clock.offset, 60_000)

    def test_far_future_seed_comes_back_to_server_time(self):
        self.clock.receive(self.now + 10 * 60_000)
        self.clock.follow_server(self.now)
        self.assertEqual(self.clock.last, self.now)


if __name__ == "__main__":
    unittest.main()

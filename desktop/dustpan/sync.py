"""The sync exchange with an OpenTodo server. See spec/sync.md, "Exchange"."""

import uuid
from dataclasses import dataclass
from datetime import datetime

from .clock import HybridClock

BATCH = 500
FEATURES = ["backfill_ack", "clock_skew"]
MAX_SKEW_ROUNDS = 3

# Device ids only the server may write. A batch holding one is refused whole.
RESERVED_DEVICE_PREFIXES = ("agent:", "caldav:", "public:", "issues:", "calsync:", "rule:", "page:")

# Entities only their author may write; a re-seed sends back only our own.
AUTHORED = {"comment": "author_id", "attachment": "author_id", "time_entry": "user_id"}


class UnsupportedAccount(Exception):
    pass


class ClockSkew(Exception):
    """The server keeps refusing our ops as too far in the future."""


@dataclass
class Result:
    received: int = 0  # ops pulled
    refused: int = 0  # local changes the server didn't accept
    held: int = 0  # ops a server limit held back, kept for later


def is_reserved_device(device):
    return device == "server" or device.startswith("server:") or device.startswith(RESERVED_DEVICE_PREFIXES)


def tz_offset_minutes():
    return int(datetime.now().astimezone().utcoffset().total_seconds() // 60)


class Syncer:
    def __init__(self, store, api, clock=None):
        self.store = store
        self.api = api
        self.clock = clock or HybridClock(store)

    @property
    def device(self):
        with self.store.transaction():
            return self.store.device()

    def check_account(self):
        """Learn who we are, once. Refuse accounts this client can't handle yet."""
        if self.store.get_meta("user_id") is not None:
            return
        me = self.api.me()
        if me.get("encryption", {}).get("enabled"):
            raise UnsupportedAccount("end-to-end encrypted accounts are not supported yet")
        with self.store.transaction():
            self.store.set_meta("user_id", me["user"]["id"])

    def run(self):
        """Exchange until the outbox is empty and nothing remains to pull.

        Returns a Result. Raises api.Offline, api.ApiError or ClockSkew.
        """
        self.check_account()
        device = self.device
        result = Result()
        skew_rounds = 0
        with self.store.transaction():
            self._requeue_held()
        while True:
            batch = self.store.outbox_batch(BATCH)
            body = {
                "device": device,
                "cursor": self.store.get_meta("cursor", 0),
                "ops": [op for _, op in batch],
                "features": FEATURES,
                "backfillAck": self.store.get_meta("backfill_ack", 0),
                "tzOffset": tz_offset_minutes(),
            }
            res = self.api.sync(body)
            rejected = res.get("rejected") or []
            skewed = [r for r in rejected if r.get("reason") == "clock_skew"]
            limited = [r for r in rejected if r.get("reason", "").startswith("limit_")]
            refused = [r for r in rejected if r not in skewed and r not in limited]
            if skewed:
                skew_rounds += 1
                if skew_rounds > MAX_SKEW_ROUNDS:
                    raise ClockSkew("this device's clock is far off and the server keeps refusing its changes")
            sent = {op["id"]: op for _, op in batch}
            with self.store.transaction():
                self.store.outbox_remove(seq for seq, _ in batch)
                self.clock.follow_server(res["serverTime"])
                self._restamp(sent, skewed, res["serverTime"])
                result.held = self._hold(sent, limited)
                for r in refused:
                    if op := sent.get(r.get("id")):
                        self.store.forget(op)
                        result.refused += 1
                if self._generation_changed(res.get("generation")):
                    self._reseed(res["generation"])
                    continue
                for op in res.get("ops", []):
                    self.clock.receive(op["ts"])
                    self.store.apply(op)
                for marker in res.get("purged", []):
                    self.store.purge(marker["entity"], marker["entityId"])
                if "backfillSeq" in res:
                    self.store.set_meta("backfill_ack", res["backfillSeq"])
                self.store.set_meta("cursor", res["cursor"])
            result.received += len(res.get("ops", []))
            if not res.get("hasMore") and self.store.outbox_count() == 0:
                return result

    def _restamp(self, sent, skewed, server_time):
        """Stamp ops refused for clock skew again and queue them. Ops that shared a stamp share the new one."""
        ops = sorted((sent[r["id"]] for r in skewed if r.get("id") in sent), key=lambda o: o["ts"])
        if not ops:
            return
        times = [r["serverTime"] for r in skewed if isinstance(r.get("serverTime"), (int, float))]
        self.clock.refused(times[0] if times else server_time)
        fresh = {}
        again = []
        for op in ops:
            if op["ts"] not in fresh:
                fresh[op["ts"]] = self.clock.stamp()
            self.store.restamp(op, fresh[op["ts"]])
            again.append({**op, "ts": fresh[op["ts"]]})
        self.store.outbox_add(again)

    def _hold(self, sent, limited):
        """Keep ops a server limit refused. Returns how many are held."""
        held = self.store.get_meta("held_ops", [])
        known = {op["id"] for op in held}
        held += [sent[r["id"]] for r in limited if r.get("id") in sent and r["id"] not in known]
        self.store.set_meta("held_ops", held)
        return len(held)

    def _requeue_held(self):
        held = self.store.get_meta("held_ops", [])
        if held:
            self.store.outbox_add(held)
            self.store.set_meta("held_ops", [])

    def _generation_changed(self, generation):
        if not generation:
            return False
        stored = self.store.get_meta("generation")
        if stored is None:
            self.store.set_meta("generation", generation)
            return False
        return stored != generation

    def _reseed(self, generation):
        """The server was restored from a backup: send back everything we hold."""
        me = self.store.get_meta("user_id")
        device = self.store.device()
        authors = {}
        for entity, author_field in AUTHORED.items():
            authors[entity] = {
                entity_id: row.get(author_field) for entity_id, row in self.store.rows(entity).items()
            }
        ops = []
        for entity, entity_id, name, value, ts, op_device in self.store.all_fields():
            if entity in authors and authors[entity].get(entity_id) != me:
                continue
            if entity == "attachment" and name == "uploaded_at":
                continue
            ops.append({
                "id": str(uuid.uuid4()),
                "entity": entity,
                "entityId": entity_id,
                "field": name,
                "value": value,
                "ts": ts,
                # Deviation from the web app, see spec/sync.md, "Re-seed after a restore".
                "device": device if is_reserved_device(op_device) else op_device,
            })
        self.store.outbox_add(ops)
        self.store.set_meta("cursor", 0)
        self.store.set_meta("backfill_ack", 0)
        self.store.set_meta("generation", generation)

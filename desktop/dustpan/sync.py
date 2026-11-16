"""The sync exchange with an OpenTodo server. See spec/sync.md, "Exchange"."""

import hashlib
import json
import uuid
from dataclasses import dataclass
from datetime import datetime

from . import trash
from .clock import HybridClock
from .ids import default_reminder_id, detached_id, occurrence_id
from .model import CLEARED_SUBTASKS, FOLDED_TASKS
from .writes import LOCAL_USER

BATCH = 500
MAX_REQUEST_BYTES = 4 * 1024 * 1024
FEATURES = ["backfill_ack", "clock_skew"]
MAX_SKEW_ROUNDS = 3

# Device ids only the server may write. A batch holding one is refused whole.
RESERVED_DEVICE_PREFIXES = ("agent:", "caldav:", "public:", "issues:", "calsync:", "rule:", "page:")

# Entities only their author may write; a re-seed sends back only our own.
AUTHORED = {"comment": "author_id", "attachment": "author_id", "time_entry": "user_id"}

# Upload parents and tasks before reminders, comments, attachments and time entries.
ENTITY_ORDER = ("project", "section", "field", "label", "view", "task", "reminder",
                "comment", "attachment", "time_entry", "user_prefs", "project_prefs", "review")
ENTITY_RANK = {name: i for i, name in enumerate(ENTITY_ORDER)}
LEAD_FIELDS = ("project_id", "task_id", "user_id", "author_id", "series_id", "recurrence", "kind", "started_at")
FIELD_RANK = {name: i for i, name in enumerate(LEAD_FIELDS)}
BATCH_WHOLE = frozenset(("reminder", "comment", "attachment", "time_entry"))

# Store meta: bumped whenever local data is adopted, migrated or replaced for an account.
# A sync started before the bump must not send or apply anything after it.
ACCOUNT_EPOCH = "account_epoch"


class UnsupportedAccount(Exception):
    pass


class AccountMismatch(UnsupportedAccount):
    """The server token belongs to a different OpenTodo user than the stored synced data."""


class AccountChanged(Exception):
    """The local account changed while a sync was running. Its work was discarded."""


class ClockSkew(Exception):
    """The server keeps refusing our ops as too far in the future."""


@dataclass
class Result:
    received: int = 0  # ops pulled
    refused: int = 0  # local changes the server didn't accept
    held: int = 0  # ops a server limit held back, kept for later
    purged: int = 0  # entities the server deleted for good


def is_reserved_device(device):
    return device == "server" or device.startswith("server:") or device.startswith(RESERVED_DEVICE_PREFIXES)


def tz_offset_minutes():
    return int(datetime.now().astimezone().utcoffset().total_seconds() // 60)


def _op_order_key(op):
    return (
        ENTITY_RANK.get(op["entity"], len(ENTITY_ORDER)),
        op["entity"],
        op["entityId"],
        FIELD_RANK.get(op["field"], len(LEAD_FIELDS)),
        op["field"],
    )


def _account_key(api):
    url = getattr(api, "base_url", None)
    token = getattr(api, "token", None)
    if not url or not token:
        return None
    return [url, hashlib.sha256(token.encode()).hexdigest()]


def verify_account(api):
    """Fetch /api/v1/me, refuse unsupported accounts, and return (user_id, account_key)."""
    me = api.me()
    if me.get("encryption", {}).get("enabled"):
        raise UnsupportedAccount("end-to-end encrypted accounts are not supported yet")
    return me["user"]["id"], _account_key(api)


def _rewrite_local_op(op, user_id, reminder_map):
    out = dict(op)
    if out["entity"] == "reminder" and out["entityId"] in reminder_map:
        out["entityId"] = reminder_map[out["entityId"]]
    if out["entity"] == "task" and out["field"] == "completed_by" and out["value"] == LOCAL_USER:
        out["value"] = user_id
    elif out["field"] == AUTHORED.get(out["entity"]) and out["value"] == LOCAL_USER:
        out["value"] = user_id
    return out


def _bump_epoch(store):
    store.set_meta(ACCOUNT_EPOCH, store.get_meta(ACCOUNT_EPOCH, 0) + 1)


def adopt_standalone(store, user_id, account_key=None):
    """Adopt standalone local data under user_id in one transaction before first sync."""
    with store.transaction():
        if store.get_meta("user_id") not in (None, LOCAL_USER):
            raise AccountChanged("this device was connected to an account in the meantime")
        _bump_epoch(store)
        device = store.device()
        stored_fields = list(store.all_fields())
        queued = [op for _, op in store.outbox_batch(store.outbox_count())]
        held = store.get_meta("held_ops", [])
        if stored_fields or queued or held:
            task_ids = {eid for entity, eid, *_ in stored_fields if entity == "task"}
            task_ids.update(val for entity, _, name, val, *_ in stored_fields
                            if entity == "reminder" and name == "task_id" and isinstance(val, str))
            reminder_ids = {eid for entity, eid, *_ in stored_fields if entity == "reminder"}
            reminder_map = {
                old_rid: default_reminder_id(user_id, tid)
                for tid in task_ids
                if (old_rid := default_reminder_id(LOCAL_USER, tid)) in reminder_ids
                and old_rid != default_reminder_id(user_id, tid)
            }
            rewritten_fields = []
            fields_changed = False
            for entity, eid, name, value, ts, op_device in stored_fields:
                mapped = _rewrite_local_op(
                    {"entity": entity, "entityId": eid, "field": name, "value": value, "ts": ts, "device": op_device},
                    user_id, reminder_map,
                )
                if mapped["entityId"] != eid or mapped["value"] != value:
                    fields_changed = True
                rewritten_fields.append(mapped)
            if fields_changed:
                store.clear_fields()
                for op in rewritten_fields:
                    store.apply(op)
            if reminder_map and (notified := store.get_meta("notified")):
                store.set_meta("notified", {reminder_map.get(k, k): v for k, v in notified.items()})

            known_ids = {}
            for op in [*queued, *held]:
                mapped = _rewrite_local_op(op, user_id, reminder_map)
                known_ids[(mapped["entity"], mapped["entityId"], mapped["field"])] = mapped["id"]

            if store.get_meta("generation") is None:
                ops = []
                for entity, eid, name, value, ts, op_device in store.all_fields():
                    if entity == "attachment" and name == "uploaded_at":
                        continue
                    ops.append({
                        "id": known_ids.get((entity, eid, name)) or str(uuid.uuid4()),
                        "entity": entity,
                        "entityId": eid,
                        "field": name,
                        "value": value,
                        "ts": ts,
                        "device": device if is_reserved_device(op_device) else op_device,
                    })
                ops.sort(key=_op_order_key)
                store.clear_outbox()
                store.outbox_add(ops)
                store.set_meta("held_ops", [])
                store.set_meta("cursor", 0)
                store.set_meta("backfill_ack", 0)
            else:
                store.clear_outbox()
                store.outbox_add([_rewrite_local_op(op, user_id, reminder_map) for op in queued])
                if held:
                    store.set_meta("held_ops", [_rewrite_local_op(op, user_id, reminder_map) for op in held])
        store.set_meta("user_id", user_id)
        if account_key is not None:
            store.set_meta("account_key", account_key)


def migrate_account(store, user_id, account_key=None):
    """Re-key local entities with fresh IDs and queue them for upload to another OpenTodo account.

    Re-keying prevents server-wide entity-id ownership conflicts even when switching
    between two accounts on the same OpenTodo server.
    """
    with store.transaction():
        _bump_epoch(store)
        # Items waiting for a server purge belong to the old account. Delete them here
        # rather than upload them to the new account.
        for entity, entity_id in trash.expand_purge(store, store.get_meta(trash.PENDING) or []):
            store.purge(entity, entity_id)
        old_uid = store.get_meta("user_id") or LOCAL_USER
        device = store.device()
        stored_fields = list(store.all_fields())
        rows_by_entity = {}
        for entity, eid, name, value, *_ in stored_fields:
            rows_by_entity.setdefault(entity, {}).setdefault(eid, {})[name] = value

        skip_entities = {"attachment"}
        skip_rows = set()
        for entity, author_field in AUTHORED.items():
            if entity in skip_entities:
                continue
            for eid, vals in rows_by_entity.get(entity, {}).items():
                if vals.get(author_field) not in (old_uid, LOCAL_USER):
                    skip_rows.add((entity, eid))

        id_map = {}
        for entity, by_id in rows_by_entity.items():
            if entity in ("user_prefs", "review", "project_prefs") or entity in skip_entities:
                continue
            if entity in ("task", "reminder"):
                continue
            for eid in by_id:
                if (entity, eid) not in skip_rows:
                    id_map[eid] = str(uuid.uuid4())

        tasks = rows_by_entity.get("task", {})
        for tid, vals in tasks.items():
            if not vals.get("series_id"):
                id_map[tid] = str(uuid.uuid4())
        for tid, vals in tasks.items():
            if tid in id_map:
                continue
            old_series = vals.get("series_id")
            new_series = id_map.get(old_series)
            mapped = None
            if new_series:
                days = [vals.get("occurrence_date"), (vals.get("due") or {}).get("date") if isinstance(vals.get("due"), dict) else None]
                for day in (d for d in days if isinstance(d, str) and d):
                    if tid == occurrence_id(old_series, day):
                        mapped = occurrence_id(new_series, day)
                        break
                    if tid == detached_id(old_series, day):
                        mapped = detached_id(new_series, day)
                        break
            id_map[tid] = mapped or str(uuid.uuid4())

        for rid, vals in rows_by_entity.get("reminder", {}).items():
            old_tid = vals.get("task_id")
            new_tid = id_map.get(old_tid)
            if not new_tid:
                skip_rows.add(("reminder", rid))
                continue
            if rid in (default_reminder_id(old_uid, old_tid), default_reminder_id(LOCAL_USER, old_tid)):
                id_map[rid] = default_reminder_id(user_id, new_tid)
            else:
                id_map[rid] = str(uuid.uuid4())

        for entity in ("comment", "time_entry"):
            for eid, vals in rows_by_entity.get(entity, {}).items():
                if vals.get("task_id") not in id_map:
                    skip_rows.add((entity, eid))
                    id_map.pop(eid, None)

        nullable_refs = {
            ("project", "parent_id"), ("note", "project_id"), ("rule", "project_id"),
            ("task", "project_id"), ("task", "parent_id"), ("task", "section_id"), ("task", "series_id"),
            ("comment", "parent_id"),
        }
        required_refs = {
            ("section", "project_id"), ("field", "project_id"), ("reminder", "task_id"),
            ("comment", "task_id"), ("time_entry", "task_id"),
        }
        list_refs = {
            ("task", "labels"), ("note", "labels"), ("task", "blocked_by"),
            ("label", "manual_order"), ("view", "panels"), ("view", "manual_order"), ("slot", "task_ids"),
        }

        ops = []
        store.clear_fields()
        for entity, eid, name, value, ts, op_device in stored_fields:
            if entity in skip_entities or (entity, eid) in skip_rows:
                continue
            if entity in ("user_prefs", "review"):
                new_eid = eid
            elif entity == "project_prefs":
                new_eid = id_map.get(eid)
                if not new_eid:
                    continue
            else:
                new_eid = id_map.get(eid)
                if not new_eid:
                    continue

            if entity == "task" and name.startswith("fields."):
                def_id = name[len("fields."):]
                if def_id not in id_map:
                    continue
                name = "fields." + id_map[def_id]
            elif (entity, name) in nullable_refs:
                value = id_map.get(value) if isinstance(value, str) and value else None
            elif (entity, name) in required_refs:
                if not (isinstance(value, str) and value in id_map):
                    continue
                value = id_map[value]
            elif (entity, name) in list_refs and isinstance(value, list):
                value = [id_map[x] for x in value if isinstance(x, str) and x in id_map]
            elif (entity, name) == ("task", "split_from"):
                series = value.get("series") if isinstance(value, dict) else None
                value = {"series": id_map[series], "date": value["date"]} if series in id_map else None
            elif (entity, name) == ("task", "completed_by"):
                value = user_id if value is not None else None
            elif (entity, name) == ("task", "assignee_id"):
                value = user_id if value in (old_uid, LOCAL_USER) else None
            elif (entity, name) in (("task", "rotation"), ("task", "note_mentions"), ("comment", "mentions")):
                value = []
            elif name == "workspace_id":
                value = None
            elif name == AUTHORED.get(entity):
                value = user_id
            elif (entity, name) == ("frame", "source") and isinstance(value, str) and ":" in value:
                kind, _, ref = value.partition(":")
                value = f"{kind}:{id_map[ref]}" if ref in id_map else ""
            elif (entity, name) == ("user_prefs", "favourites") and isinstance(value, str) and value:
                parts = []
                for entry in value.split(","):
                    kind, sep, ref = entry.partition(":")
                    if sep and ref in id_map:
                        parts.append(f"{kind}:{id_map[ref]}")
                value = ",".join(parts)
            elif entity == "review" and name in ("focus", "slots") and isinstance(value, str) and value:
                value = ",".join(id_map[x] for x in value.split(",") if x in id_map)
            elif (entity, name) == ("review", "focus_slots") and isinstance(value, str) and value:
                slots = []
                for entry in value.split(","):
                    slot, sep, ref = entry.partition(":")
                    if sep and ref in id_map:
                        slots.append(f"{slot}:{id_map[ref]}")
                value = ",".join(slots)

            op = {
                "id": str(uuid.uuid4()),
                "entity": entity,
                "entityId": new_eid,
                "field": name,
                "value": value,
                "ts": ts,
                "device": device if is_reserved_device(op_device) else op_device,
            }
            store.apply(op)
            ops.append(op)

        ops.sort(key=_op_order_key)
        store.clear_outbox()
        store.outbox_add(ops)
        if folded := store.get_meta(FOLDED_TASKS):
            store.set_meta(FOLDED_TASKS, [id_map[i] for i in folded if i in id_map])
        if cleared := store.get_meta(CLEARED_SUBTASKS):
            store.set_meta(CLEARED_SUBTASKS, {
                id_map[k]: [v[0], id_map.get(v[1])] for k, v in cleared.items() if k in id_map and isinstance(v, list) and len(v) == 2
            })
        if recent := store.get_meta("recent_labels"):
            store.set_meta("recent_labels", [id_map[i] for i in recent if i in id_map])
        if notified := store.get_meta("notified"):
            store.set_meta("notified", {id_map[k]: v for k, v in notified.items() if k in id_map})
        for key, val in (("cursor", 0), ("backfill_ack", 0), ("generation", None), ("reseed_device", None),
                         ("held_ops", []), (trash.PENDING, []), (trash.RETENTION, None), ("user_id", user_id)):
            store.set_meta(key, val)
        if account_key is not None:
            store.set_meta("account_key", account_key)


def reset_for_account(store, user_id, account_key=None):
    """Clear local synced entities and prepare to pull fresh from user_id's OpenTodo account."""
    with store.transaction():
        _bump_epoch(store)
        store.clear_fields()
        store.clear_outbox()
        for key, val in (("cursor", 0), ("backfill_ack", 0), ("generation", None), ("reseed_device", None),
                         ("held_ops", []), (trash.PENDING, []), (trash.RETENTION, None), ("notified", None),
                         (FOLDED_TASKS, []), (CLEARED_SUBTASKS, {}), ("recent_labels", []), ("user_id", user_id)):
            store.set_meta(key, val)
        if account_key is not None:
            store.set_meta("account_key", account_key)


class Syncer:
    def __init__(self, store, api, clock=None):
        self.store = store
        self.api = api
        self.clock = clock or HybridClock(store)
        self.user_id = None
        self.epoch = None

    @property
    def device(self):
        with self.store.transaction():
            return self.store.device()

    def check_account(self):
        """Learn who we are, adopting standalone local data on first connect and refusing unsupported accounts."""
        stored_user = self.store.get_meta("user_id")
        key = _account_key(self.api)
        if stored_user is not None and stored_user != LOCAL_USER:
            if key is None or self.store.get_meta("account_key") == key:
                self.user_id = stored_user
                return
        user_id, key = verify_account(self.api)
        self.user_id = user_id
        if stored_user in (None, LOCAL_USER):
            adopt_standalone(self.store, user_id, account_key=key)
            return
        if stored_user != user_id:
            raise AccountMismatch(
                "this device holds data from another OpenTodo account; reconnect in Settings to choose how to handle it"
            )
        if key is not None:
            with self.store.transaction():
                self.store.set_meta("account_key", key)

    def _next_batch(self, byte_budget):
        """Bound the encoded payload and count without splitting a multi-field child entity."""
        batch = self.store.outbox_batch(BATCH + 1)
        size, count = 0, 0
        for _, op in batch[:BATCH]:
            # json.dumps uses comma-space between array elements. Allow it even for the first.
            size += len(json.dumps(op).encode()) + 2
            if size > byte_budget:
                break
            count += 1
        if batch and not count:
            raise ValueError("A queued change is too large to sync")
        if len(batch) <= count:
            return batch
        tail_op = batch[count - 1][1]
        split = batch[:count]
        if tail_op["entity"] not in BATCH_WHOLE:
            return split
        tail = (tail_op["entity"], tail_op["entityId"])
        if (batch[count][1]["entity"], batch[count][1]["entityId"]) != tail:
            return split
        trimmed = [item for item in split if (item[1]["entity"], item[1]["entityId"]) != tail]
        if not trimmed:
            raise ValueError("A queued entity is too large to sync in one request")
        return trimmed

    def run(self):
        """Push edits, pull changes, then send queued purges and pull their markers."""
        self.check_account()
        with self.store.transaction():
            # Pin the account this sync belongs to. A switch after this point is caught by _check_account_same.
            self.epoch = self.store.get_meta(ACCOUNT_EPOCH, 0)
            if self.store.get_meta("user_id") != self.user_id:
                raise AccountChanged("the account changed before sync started")
        result = self._exchange()
        if trash.send(self.store, self.api):
            again = self._exchange()
            result.received += again.received
            result.refused += again.refused
            result.held = again.held
            result.purged += again.purged
        return result

    def _exchange(self):
        """Exchange until the outbox is empty and nothing remains to pull.

        Returns a Result. Raises api.Offline, api.ApiError, ClockSkew or AccountChanged.
        """
        device = self.device
        result = Result()
        skew_counts = {}
        with self.store.transaction():
            self._check_account_same()
            self._requeue_held()
        while True:
            with self.store.transaction():
                self._check_account_same()
                body = {
                    # A restore can bring back fields we no longer hold, including our own
                    # old writes. Pull under a temporary identity so the server echoes them.
                    "device": self.store.get_meta("reseed_device") or device,
                    "cursor": self.store.get_meta("cursor", 0),
                    "ops": [],
                    "features": FEATURES,
                    "backfillAck": self.store.get_meta("backfill_ack", 0),
                    "tzOffset": tz_offset_minutes(),
                }
                batch = self._next_batch(MAX_REQUEST_BYTES - len(json.dumps(body).encode()))
                body["ops"] = [op for _, op in batch]
            res = self.api.sync(body)
            rejected = res.get("rejected") or []
            skewed = [r for r in rejected if r.get("reason") == "clock_skew"]
            limited = [r for r in rejected if r.get("reason", "").startswith("limit_")]
            refused = [r for r in rejected if r not in skewed and r not in limited]
            for r in skewed:
                op_id = r.get("id", "")
                skew_counts[op_id] = skew_counts.get(op_id, 0) + 1
                if skew_counts[op_id] > MAX_SKEW_ROUNDS:
                    raise ClockSkew("this device's clock is far off and the server keeps refusing its changes")
            sent = {op["id"]: op for _, op in batch}
            with self.store.transaction():
                self._check_account_same()
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
                if "trashRetentionDays" in res:
                    self.store.set_meta(trash.RETENTION, res["trashRetentionDays"])
                if "backfillSeq" in res:
                    self.store.set_meta("backfill_ack", res["backfillSeq"])
                self.store.set_meta("cursor", res["cursor"])
                if not res.get("hasMore") and self.store.outbox_count() == 0:
                    self.store.set_meta("reseed_device", None)
            result.received += len(res.get("ops", []))
            result.purged += len(res.get("purged", []))
            if not res.get("hasMore") and self.store.outbox_count() == 0:
                return result

    def _check_account_same(self):
        """Call inside a transaction. Raises AccountChanged if the account was switched since this exchange began."""
        if self.store.get_meta(ACCOUNT_EPOCH, 0) != self.epoch:
            raise AccountChanged("the account changed during sync; nothing from that sync was kept")

    def _restamp(self, sent, skewed, server_time):
        """Stamp ops refused for clock skew again and queue them. Ops that shared a stamp share the new one."""
        ops = sorted((sent[r["id"]] for r in skewed if r.get("id") in sent), key=lambda o: (o["ts"], _op_order_key(o)))
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
        ops.sort(key=_op_order_key)
        self.store.outbox_add(ops)
        self.store.set_meta("cursor", 0)
        self.store.set_meta("backfill_ack", 0)
        self.store.set_meta("generation", generation)
        # Persist across an interrupted re-seed. The actual device and all field clocks
        # stay unchanged; only the request identity changes until the full pull finishes.
        self.store.set_meta("reseed_device", str(uuid.uuid4()))

"""Local copy of the synced state: one last-writer-wins register per field.

See spec/sync.md, "Local store".
"""

import json
import sqlite3
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field

SCHEMA = """
CREATE TABLE IF NOT EXISTS fields (
    entity    TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    field     TEXT NOT NULL,
    value     TEXT NOT NULL,
    ts        INTEGER NOT NULL,
    device    TEXT NOT NULL,
    PRIMARY KEY (entity, entity_id, field)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS outbox (
    seq       INTEGER PRIMARY KEY AUTOINCREMENT,
    entity    TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    op        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def wins(ts, device, cur_ts, cur_device):
    """The winner rule: newer timestamp, then greater device id."""
    return ts > cur_ts or (ts == cur_ts and device > cur_device)


@dataclass
class Clock:
    ts: int
    device: str


@dataclass
class Row:
    """One entity folded from its fields."""

    id: str
    values: dict = field(default_factory=dict)
    clocks: dict = field(default_factory=dict)

    def get(self, name, default=None):
        return self.values.get(name, default)


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, timeout=10, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)

    def close(self):
        self.db.close()

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("COMMIT")

    # ---- meta ----

    def get_meta(self, key, default=None):
        row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set_meta(self, key, value):
        self.db.execute(
            "INSERT INTO meta (key, value) VALUES (?, ?) "
            "ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            (key, json.dumps(value)),
        )

    def device(self):
        """This device's id, created on first use."""
        device = self.get_meta("device")
        if device is None:
            device = str(uuid.uuid4())
            self.set_meta("device", device)
        return device

    # ---- fields ----

    def apply(self, op):
        """Store op if it wins over the current value. Returns True when it did."""
        cur = self.db.execute(
            "SELECT ts, device FROM fields WHERE entity = ? AND entity_id = ? AND field = ?",
            (op["entity"], op["entityId"], op["field"]),
        ).fetchone()
        if cur and not wins(op["ts"], op["device"], cur[0], cur[1]):
            return False
        self.db.execute(
            "INSERT OR REPLACE INTO fields (entity, entity_id, field, value, ts, device) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (op["entity"], op["entityId"], op["field"], json.dumps(op["value"]), op["ts"], op["device"]),
        )
        return True

    def forget(self, op):
        """Drop a field while it still holds op, so any value the server sends wins."""
        self.db.execute(
            "DELETE FROM fields WHERE entity = ? AND entity_id = ? AND field = ? AND ts = ? AND device = ?",
            (op["entity"], op["entityId"], op["field"], op["ts"], op["device"]),
        )

    def restamp(self, op, ts):
        """Move a field's clock to ts while it still holds op."""
        self.db.execute(
            "UPDATE fields SET ts = ? WHERE entity = ? AND entity_id = ? AND field = ? AND ts = ? AND device = ?",
            (ts, op["entity"], op["entityId"], op["field"], op["ts"], op["device"]),
        )

    def purge(self, entity, entity_id):
        """Remove an entity the server purged, with any queued ops for it."""
        self.db.execute("DELETE FROM fields WHERE entity = ? AND entity_id = ?", (entity, entity_id))
        self.db.execute("DELETE FROM outbox WHERE entity = ? AND entity_id = ?", (entity, entity_id))

    def clear_fields(self):
        self.db.execute("DELETE FROM fields")

    def clear_outbox(self):
        self.db.execute("DELETE FROM outbox")

    def all_fields(self):
        """Yield (entity, entity_id, field, value, ts, device) for every stored field."""
        for entity, entity_id, name, value, ts, device in self.db.execute(
            "SELECT entity, entity_id, field, value, ts, device FROM fields"
        ):
            yield entity, entity_id, name, json.loads(value), ts, device

    def rows(self, entity):
        """Fold every field of one entity kind into rows, keyed by id."""
        rows = {}
        for entity_id, name, value, ts, device in self.db.execute(
            "SELECT entity_id, field, value, ts, device FROM fields WHERE entity = ?", (entity,)
        ):
            row = rows.get(entity_id)
            if row is None:
                row = rows[entity_id] = Row(entity_id)
            row.values[name] = json.loads(value)
            row.clocks[name] = Clock(ts, device)
        return rows

    # ---- outbox ----

    def outbox_add(self, ops):
        self.db.executemany(
            "INSERT INTO outbox (entity, entity_id, op) VALUES (?, ?, ?)",
            ((op["entity"], op["entityId"], json.dumps(op)) for op in ops),
        )

    def outbox_batch(self, limit):
        """The oldest queued ops, as (seq, op) pairs."""
        return [
            (seq, json.loads(op))
            for seq, op in self.db.execute("SELECT seq, op FROM outbox ORDER BY seq LIMIT ?", (limit,))
        ]

    def outbox_remove(self, seqs):
        self.db.executemany("DELETE FROM outbox WHERE seq = ?", ((s,) for s in seqs))

    def outbox_count(self):
        return self.db.execute("SELECT count(*) FROM outbox").fetchone()[0]

"""Hybrid logical clock for stamping ops. See spec/sync.md, "Clock"."""

import time

SKEW_TOLERANCE_MS = 2_000
MAX_AHEAD_MS = 5 * 60_000


def wall_ms():
    return time.time_ns() // 1_000_000


class HybridClock:
    """State lives in the store's meta table, so it survives restarts."""

    def __init__(self, store, now=wall_ms):
        self.store = store
        self.now = now

    @property
    def last(self):
        return self.store.get_meta("clock_last", 0)

    @property
    def offset(self):
        return self.store.get_meta("clock_offset", 0)

    def stamp(self):
        """A timestamp for a new local op, strictly after every one seen."""
        ts = max(self.now() + self.offset, self.last + 1)
        self.store.set_meta("clock_last", ts)
        return ts

    def receive(self, ts):
        """Move past a timestamp seen on an incoming op."""
        if ts > self.last:
            self.store.set_meta("clock_last", ts)

    def follow_server(self, server_time):
        """Correct for a wrong local clock after an exchange."""
        skew = server_time - self.now()
        self.store.set_meta("clock_offset", skew if abs(skew) > SKEW_TOLERANCE_MS else 0)
        if self.last > server_time + MAX_AHEAD_MS:
            self.store.set_meta("clock_last", server_time)

    def refused(self, server_time):
        """The server refused ops for clock skew: restart from its time."""
        self.follow_server(server_time)
        if self.last > server_time:
            self.store.set_meta("clock_last", server_time)

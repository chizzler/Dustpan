"""The live update stream: the server says when there's something to pull.

See spec/writes.md, "Live updates". Events carry only a cursor, never data.
"""

import json
import random
import threading

from .api import ApiError, Offline

FIRST_RETRY_S = 1
MAX_RETRY_S = 30


def parse(lines):
    """Yield the data of each "ops" event in a server-sent event stream, as a dict."""
    event, data = None, []
    for raw in lines:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if not line:
            if event == "ops":
                try:
                    value = json.loads("\n".join(data) or "{}")
                except ValueError:
                    value = {}
                yield value if isinstance(value, dict) else {}
            event, data = None, []
        elif line.startswith(":"):
            continue
        else:
            name, _, value = line.partition(":")
            value = value.removeprefix(" ")
            if name == "event":
                event = value
            elif name == "data":
                data.append(value)


class EventStream:
    """Keeps one stream open on a background thread, reconnecting with backoff.

    on_wake(cursor or None) runs on that thread after connecting and on every ops event.
    on_live(bool) reports whether the stream is connected.
    """

    def __init__(self, api, device, on_wake, on_live):
        self.api = api
        self.device = device
        self.on_wake = on_wake
        self.on_live = on_live
        self.stopped = threading.Event()

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def stop(self):
        self.stopped.set()

    def _run(self):
        delay = FIRST_RETRY_S
        while not self.stopped.is_set():
            try:
                with self.api.events(self.device) as resp:
                    self.on_live(True)
                    delay = FIRST_RETRY_S
                    self.on_wake(None)
                    for data in parse(resp):
                        if self.stopped.is_set():
                            return
                        cursor = data.get("cursor")
                        self.on_wake(cursor if isinstance(cursor, int) else None)
            except (Offline, ApiError, OSError):
                pass
            self.on_live(False)
            self.stopped.wait(delay * random.uniform(0.5, 1.0))
            delay = min(delay * 2, MAX_RETRY_S)

"""Minimal HTTP client for the OpenTodo API, standard library only."""

import json
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT_S = 30
# The event stream pings every 25 s, so a silent minute means the connection is dead.
STREAM_TIMEOUT_S = 60


class Offline(Exception):
    """The server could not be reached, or did not answer in time."""


class ApiError(Exception):
    """The server answered with an error."""

    def __init__(self, status, code, message):
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code


class Api:
    def __init__(self, base_url, token):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def get(self, path):
        return self._send(urllib.request.Request(self.base_url + path, headers=self._headers()))

    def post(self, path, body):
        return self._send(urllib.request.Request(
            self.base_url + path,
            data=json.dumps(body).encode(),
            method="POST",
            headers={**self._headers(), "Content-Type": "application/json"},
        ))

    def delete(self, path):
        return self._send(urllib.request.Request(self.base_url + path, method="DELETE", headers=self._headers()))

    def _headers(self):
        return {"Authorization": "Bearer " + self.token}

    def _send(self, req):
        with self._open(req, TIMEOUT_S) as resp:
            try:
                return json.load(resp)
            except (TimeoutError, ConnectionError) as err:
                raise Offline(str(err)) from None

    def _open(self, req, timeout):
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as err:
            try:
                detail = json.load(err).get("error", {})
            except ValueError:
                detail = {}
            raise ApiError(err.code, detail.get("code", "http_error"), detail.get("message", err.reason)) from None
        except (urllib.error.URLError, TimeoutError, ConnectionError) as err:
            raise Offline(str(err)) from None

    def me(self):
        return self.get("/api/v1/me")

    def sync(self, body):
        return self.post("/api/v1/sync", body)

    def purge(self, entity, entity_id):
        """Delete a task or project in the Trash for good. 409 not_deleted if it isn't there."""
        return self.delete(f"/api/v1/{entity}s/{urllib.parse.quote(entity_id, safe='')}/purge")

    def events(self, device):
        """Open the live event stream. Returns a response to read lines from."""
        path = "/api/v1/sync/events?" + urllib.parse.urlencode({"device": device})
        headers = {**self._headers(), "Accept": "text/event-stream"}
        return self._open(urllib.request.Request(self.base_url + path, headers=headers), STREAM_TIMEOUT_S)

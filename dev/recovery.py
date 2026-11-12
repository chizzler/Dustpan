#!/usr/bin/env python3
"""End-to-end recovery tests against the real pinned server, entirely inside bubblewrap.

No downloads, live HTTP requests, GUI activation, or writes to original databases.
Artifacts stay in a private directory under dist/recovery (ignored by Git).
"""

import argparse
from contextlib import contextmanager
from dataclasses import asdict
from datetime import date, timedelta
import hashlib
from http.cookiejar import CookieJar
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
BASE = "http://127.0.0.1:18099"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def snapshot(source, destination):
    """Copy a coherent SQLite snapshot, including committed WAL contents."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True) as src:
        with sqlite3.connect(destination) as dst:
            src.backup(dst)
            # Keep checkpoints self-contained and readable on the read-only input mount.
            dst.execute("PRAGMA journal_mode=DELETE")
            require(dst.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "bad SQLite snapshot")


def outer(args):
    os.umask(0o077)
    require(shutil.which("bwrap"), "bubblewrap is required; there is no unsandboxed fallback")
    binary = args.binary.resolve()
    require(binary.is_file(), f"missing server binary: {binary}; see dev/server.sh")
    sums = binary.parent / "SHA256SUMS"
    expected = next((line.split()[0] for line in sums.read_text().splitlines()
                     if line.split()[-1].lstrip("*") == binary.name), None)
    require(expected and digest(binary) == expected, "server binary does not match SHA256SUMS")
    real = [args.archive, args.client_db, args.config]
    require(all(real) or not any(real), "real replay needs --archive, --client-db and --config together")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=time.strftime("%Y%m%d-%H%M%S-"), dir=output))
    (work / "home").mkdir()
    etc = work / "etc"
    etc.mkdir()
    (etc / "fonts").mkdir()
    (etc / "passwd").write_text(f"recovery:x:{os.getuid()}:{os.getgid()}:Recovery:/work/home:/bin/false\n")
    (etc / "group").write_text(f"recovery:x:{os.getgid()}:\n")
    (etc / "machine-id").write_text(secrets.token_hex(16) + "\n")
    inputs = {"server_sha256": digest(binary), "host_network_namespace": os.readlink("/proc/self/ns/net")}
    if all(real):
        stage = work / "inputs"
        stage.mkdir()
        shutil.copyfile(args.archive, stage / "server.archive")
        snapshot(args.client_db, stage / "client.db")
        config = dict(line.split("=", 1) for line in args.config.read_text().splitlines()
                      if "=" in line and not line.lstrip().startswith("#"))
        token = config.get("OPENTODO_TOKEN", "").strip()
        require(token, "no OPENTODO_TOKEN in replay config")
        (stage / "token").write_text(token)
        inputs.update(archive_sha256=digest(stage / "server.archive"), client_sha256=digest(stage / "client.db"))
    inputs["source_sha256"] = {str(p.relative_to(ROOT)): digest(p)
                               for p in sorted((ROOT / "desktop/dustpan").rglob("*.py"))}
    inputs["harness_sha256"] = digest(Path(__file__).resolve())
    save(work / "inputs.json", inputs)
    command = ["bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--clearenv",
               "--ro-bind", "/usr", "/usr", "--symlink", "usr/lib", "/lib",
               "--symlink", "usr/lib", "/lib64", "--symlink", "usr/bin", "/bin",
               "--ro-bind", str(etc), "/etc", "--ro-bind", "/etc/fonts", "/etc/fonts",
               "--proc", "/proc", "--dev", "/dev",
               "--tmpfs", "/tmp", "--bind", str(work), "/work",
               "--ro-bind", str(ROOT / "desktop"), "/source/desktop",
               "--ro-bind", str(Path(__file__).resolve()), "/source/recovery.py",
               "--ro-bind", str(binary), "/opentodo",
               "--setenv", "PATH", "/usr/bin", "--setenv", "HOME", "/work/home",
               "--setenv", "PYTHONPATH", "/source/desktop", "--setenv", "PYTHONDONTWRITEBYTECODE", "1",
               "--setenv", "TZ", "UTC", "--setenv", "LANG", "C.UTF-8", "--chdir", "/work"]
    if all(real):
        command += ["--ro-bind", str(stage), "/work/inputs"]
    if args.gui_smoke:
        display = os.environ.get("WAYLAND_DISPLAY", "")
        require(display, "--gui-smoke requires a Wayland session")
        wayland = Path(display) if display.startswith("/") else Path(os.environ["XDG_RUNTIME_DIR"]) / display
        require(wayland.is_socket(), "Wayland socket is missing")
        command += ["--ro-bind", str(wayland), "/display/wayland", "--setenv", "WAYLAND_DISPLAY", "/display/wayland",
                    "--setenv", "GDK_BACKEND", "wayland", "--setenv", "GSETTINGS_BACKEND", "memory",
                    "--setenv", "GSK_RENDERER", "cairo",
                    "--setenv", "DUSTPAN_RECOVERY_GUI", "1"]
    command += ["--", "/usr/bin/python3", "/source/recovery.py", "--inside"]
    print(f"Recovery artifacts: {work}", flush=True)
    result = subprocess.run(command)
    print(f"Report: {work / 'report.md'}", flush=True)
    return result.returncode


def http(method, path, body=None, opener=None, token=None):
    require(path.startswith("/api/v1/"), "test HTTP must use a relative API path")
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(BASE + path, method=method, data=data, headers=headers)
    with (opener or urllib.request.build_opener()).open(request, timeout=10) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


class Server:
    def __init__(self, folder):
        self.folder = folder
        self.folder.mkdir(parents=True, exist_ok=True)
        self.data = folder / "server"
        self.log = (folder / "server.log").open("ab")
        self.process = None

    def start(self):
        require(self.process is None, "server already started")
        env = {**os.environ, "OPENTODO_DATA_DIR": str(self.data), "OPENTODO_ADDR": "127.0.0.1:18099",
               "OPENTODO_PUSH": "off", "OPENTODO_BACKUP_SCHEDULE": "off",
               "OPENTODO_SETUP_TOKEN": "recovery-test-only", "OPENTODO_LOG_LEVEL": "warn"}
        self.process = subprocess.Popen(["/opentodo"], env=env, stdout=self.log, stderr=self.log)
        end = time.monotonic() + 20
        while time.monotonic() < end:
            require(self.process.poll() is None, "scratch server exited; see server.log")
            try:
                http("GET", "/api/v1/auth/status")
                return
            except (OSError, urllib.error.URLError):
                time.sleep(0.05)
        raise RuntimeError("scratch server startup timed out")

    def stop(self):
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process = None

    def restore(self, archive, expect_success=True):
        self.stop()
        result = subprocess.run(["/opentodo", "restore", "--data-dir", str(self.data), str(archive)],
                                stdout=self.log, stderr=self.log)
        require((result.returncode == 0) == expect_success, "unexpected restore outcome; see server.log")

    def close(self):
        self.stop()
        self.log.close()


def fields(store):
    return {(e, i, f): {"value": v, "ts": ts, "device": d} for e, i, f, v, ts, d in store.all_fields()}


def manifest(state):
    return [{"entity": e, "id": i, "field": f, **v} for (e, i, f), v in sorted(state.items())]


class Oracle:
    """Expected LWW state from the pre-restore baseline and intended local write journal.

    Deliberately does not call Store.apply, Store.wins, or Syncer._reseed.
    Semantic assertions below independently check what the intended actions mean.
    """
    def __init__(self, state):
        self.state = dict(state)

    def add(self, ops):
        for op in ops:
            key = op["entity"], op["entityId"], op["field"]
            old = self.state.get(key)
            candidate = {"value": op["value"], "ts": op["ts"], "device": op["device"]}
            if old is None or (candidate["ts"], candidate["device"]) > (old["ts"], old["device"]):
                self.state[key] = candidate

    def delete(self, entity, entity_id):
        self.state = {k: v for k, v in self.state.items() if k[:2] != (entity, entity_id)}


class Client:
    def __init__(self, folder, name, token, source=None):
        from dustpan.store import Store
        self.folder = folder / name
        self.folder.mkdir(parents=True)
        self.path = self.folder / "dustpan.db"
        if source:
            snapshot(source, self.path)
        self.store = Store(self.path)
        if not source:
            with self.store.transaction():
                self.store.set_meta("device", name)
        (self.folder / "token").write_text(token)

    def write(self, action, *args, oracle=None, stamp=None, **kwargs):
        from dustpan.clock import HybridClock
        from dustpan.writes import Writer
        clock = HybridClock(self.store) if stamp is None else HybridClock(self.store, now=lambda: stamp)
        writer = Writer(self.store, clock=clock)
        result = getattr(writer, action)(*args, **kwargs)
        if oracle:
            oracle.add([op for _, op in self.store.outbox_batch(self.store.outbox_count())])
        return result

    def sync(self, fault="none"):
        result = subprocess.run([sys.executable, "/source/recovery.py", "--worker", str(self.folder), fault],
                                capture_output=True, text=True, timeout=45)
        with (self.folder / "worker.log").open("a") as log:
            log.write(result.stdout + result.stderr)
        require(result.returncode == (75 if fault != "none" else 0),
                f"client sync failed ({self.folder.name}); see worker.log")
        if fault == "none":
            report = json.loads(result.stdout)
            require(not report["refused"] and not report["held"], "unexpected refused/held operations")
            require(self.store.outbox_count() == 0, "outbox did not drain")
            require(not self.store.get_meta("held_ops", []), "held operations remain")
            require(not self.store.get_meta("pending_purges", []), "pending purge did not drain")

    def close(self):
        self.store.close()


def worker(folder, fault):
    from dustpan.api import Api
    from dustpan.store import Store
    from dustpan.sync import Syncer

    store = Store(folder / "dustpan.db")
    initial_generation = store.get_meta("generation")
    require(initial_generation is not None or fault == "none", "fault requires a synced checkpoint")

    class ObservedApi(Api):
        uploads = 0

        def sync(self, body):
            reseeding = store.get_meta("generation") != initial_generation and bool(body["ops"])
            if reseeding:
                self.uploads += 1
                if fault == "interrupt" and self.uploads == 2:
                    os._exit(75)  # first re-seed batch was committed locally; next remains queued
            response = super().sync(body)
            trace = {"cursor": body["cursor"], "ops": len(body["ops"]),
                     "ids": [o["id"] for o in body["ops"]], "generation": response.get("generation"),
                     "duplicates": response.get("duplicates", 0), "rejected": response.get("rejected", []),
                     "hasMore": response.get("hasMore"), "backfillAck": body["backfillAck"]}
            with (folder / "exchanges.jsonl").open("a") as out:
                out.write(json.dumps(trace) + "\n")
            if reseeding and fault == "lost-response" and self.uploads == 1:
                os._exit(75)  # accepted by server, killed before caller can acknowledge it locally
            return response

    try:
        result = Syncer(store, ObservedApi(BASE, (folder / "token").read_text())).run()
        print(json.dumps(asdict(result)))
    finally:
        store.close()


def check_state(client, expected, label, clocks=True):
    from dustpan.sync import is_reserved_device
    actual = fields(client.store)
    differences = []
    for key in sorted(actual.keys() | expected.keys()):
        a, e = actual.get(key), expected.get(key)
        if a is None or e is None or a["value"] != e["value"]:
            differences.append({"key": key, "expected": e, "actual": a})
        elif clocks and (a["ts"] != e["ts"] or (not is_reserved_device(e["device"]) and a["device"] != e["device"])):
            differences.append({"key": key, "expected": e, "actual": a})
    save(client.folder / f"{label}-differences.json", differences)
    require(not differences, f"{len(differences)} field differences for {client.folder.name}; see {label}-differences.json")


def check_value(state, entity, entity_id, field, value):
    require(state[(entity, entity_id, field)]["value"] == value, f"wrong expected {entity}.{field}")


def generation(server):
    with sqlite3.connect(server.data / "opentodo.db") as db:
        return db.execute("SELECT value FROM settings WHERE key='generation'").fetchone()[0]


def make_fixture(folder):
    """Create T0 through the real backup service, plus ahead/offline client checkpoints."""
    server = Server(folder)
    clients = []
    try:
        server.start()
        cookies = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))
        http("POST", "/api/v1/auth/register", {"email": "recovery@example.invalid", "name": "Recovery",
             "password": secrets.token_urlsafe(32), "setupToken": "recovery-test-only"}, opener=cookies)
        token = http("POST", "/api/v1/tokens", {"name": "recovery-only", "scope": "admin"}, opener=cookies)["secret"]
        (folder / "token").write_text(token)
        a = Client(folder, "fixture-a", token)
        b = Client(folder, "fixture-b", token)
        clients += [a, b]
        a.sync()
        project = a.write("add_project", "Recovery project")
        nested = a.write("add_project", "Nested project", parent_id=project)
        section = a.write("add_section", project, "Doing")
        parent = a.write("add_task", "Parent", project_id=project, section_id=section)
        child = a.write("add_task", "Child", parent_id=parent)
        label = a.write("add_label", "recovery-label")
        due_day = (date.today() + timedelta(days=3)).isoformat()
        due = {"date": due_day, "time": "10:00", "tz": "Australia/Melbourne"}
        a.write("edit", parent, {"labels": [label], "description": "# Recovery\n\nKeep **all** of this.",
                                 "due": due, "estimate_minutes": 45, "priority": 2})
        reminder = a.write("add_reminder", parent, "relative", offset_minutes=-30)
        series = a.write("add_task", "Repeat", project_id=nested, due={"date": due_day})
        a.write("edit", series, {"recurrence": "every day"})
        trash_task = a.write("add_task", "Delete after archive")
        purge_after = a.write("add_task", "Purge after archive")
        queued = a.write("add_task", "Queued permanent deletion")
        tie = a.write("add_task", "Equal timestamp conflict")
        purge_before = a.write("add_task", "Purged before archive")
        a.sync()
        b.sync()
        snapshot(b.path, folder / "stale-before-purge.db")
        a.write("delete_task", purge_before)
        a.sync()
        from dustpan.api import Api
        Api(BASE, token).purge("task", purge_before)
        a.sync()
        b.sync()
        # A REST-created task supplies real server:<boot> field clocks.
        rest = http("POST", "/api/v1/tasks", {"title": "REST origin", "project_id": nested}, token=token)["id"]
        a.sync()
        b.sync()
        baseline = fields(a.store)
        require(any(v["device"].startswith("server:") for v in baseline.values()), "missing reserved-device coverage")
        save(folder / "baseline.json", manifest(baseline))
        snapshot(a.path, folder / "t0-a.db")
        snapshot(b.path, folder / "t0-b.db")
        old_generation = generation(server)
        http("POST", "/api/v1/backups/run", {}, token=token)
        end = time.monotonic() + 20
        while time.monotonic() < end:
            status = http("GET", "/api/v1/backups", token=token)
            if status.get("lastRun") and not status.get("running"):
                require(status["lastRun"]["status"] == "succeeded", "T0 archive creation failed")
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("backup timed out")
        archive = folder / "t0.tar.gz"
        shutil.copyfile(server.data / "backups" / status["lastRun"]["archiveName"], archive)
        oracle = Oracle(baseline)
        uploaded = a.write("add_task", "Created after archive", project_id=project, oracle=oracle)
        a.write("edit", parent, {"title": "Edited after archive", "due": {**due, "time": "11:00"}}, oracle=oracle)
        a.write("complete", series, oracle=oracle)
        a.write("delete_task", trash_task, oracle=oracle)
        # Cross both the 500-op upload boundary and the 1000-op pull boundary.
        bulk = [a.write("add_task", f"Batch task {n:03}", project_id=nested, oracle=oracle) for n in range(85)]
        a.sync()
        # B stays stale, and both clients now work offline.
        stamp = time.time_ns() // 1_000_000 + 1000
        b.write("edit", parent, {"priority": 1, "description": "Offline B note"}, stamp=stamp, oracle=oracle)
        a.write("edit", parent, {"priority": 3}, stamp=stamp + 1, oracle=oracle)
        offline = a.write("add_task", "Never uploaded", project_id=project, oracle=oracle)
        # Same timestamp, different device IDs: fixture-b must win.
        a.write("edit", tie, {"title": "Tie A"}, stamp=stamp + 50, oracle=oracle)
        b.write("edit", tie, {"title": "Tie B"}, stamp=stamp + 50, oracle=oracle)
        require(oracle.state[("task", tie, "title")]["ts"] == stamp + 50, "tie timestamp was not controlled")
        require(len(oracle.state) > 1000, "fixture does not exercise pagination")
        check_value(oracle.state, "task", parent, "title", "Edited after archive")
        check_value(oracle.state, "task", parent, "priority", 3)
        check_value(oracle.state, "task", parent, "description", "Offline B note")
        check_value(oracle.state, "task", tie, "title", "Tie B")
        check_value(oracle.state, "task", child, "parent_id", parent)
        check_value(oracle.state, "task", uploaded, "project_id", project)
        check_value(oracle.state, "task", offline, "title", "Never uploaded")
        check_value(oracle.state, "reminder", reminder, "task_id", parent)
        require(oracle.state[("reminder", reminder, "fire_at")]["value"] > baseline[("reminder", reminder, "fire_at")]["value"],
                "due edit did not move relative reminder")
        check_value(oracle.state, "task", series, "due", {"date": (date.fromisoformat(due_day) + timedelta(days=1)).isoformat()})
        from dustpan.ids import occurrence_id
        record = occurrence_id(series, due_day)
        check_value(oracle.state, "task", record, "series_id", series)
        require(sum(1 for (e, i, f), v in oracle.state.items() if e == "task" and f == "series_id" and v["value"] == series) == 1,
                "expected exactly one occurrence record")
        require(oracle.state[("task", trash_task, "deleted_at")]["value"] is not None, "missing deletion")
        snapshot(a.path, folder / "ahead-a.db")
        snapshot(b.path, folder / "offline-b.db")
        save(folder / "expected.json", manifest(oracle.state))
        ids = dict(parent=parent, child=child, project=project, nested=nested, section=section, label=label,
                   reminder=reminder, series=series, record=record, trash=trash_task, purge_before=purge_before,
                   purge_after=purge_after, queued=queued, rest=rest, tie=tie, uploaded=uploaded, offline=offline, bulk=bulk)
        save(folder / "ids.json", ids)
        return dict(folder=folder, token=token, archive=archive, baseline=baseline, expected=oracle.state,
                    generation=old_generation, ids=ids)
    finally:
        for client in clients:
            client.close()
        server.close()


@contextmanager
def restored(folder, fixture, profiles):
    server = Server(folder)
    clients = {}
    try:
        server.restore(fixture["archive"])
        require(generation(server) != fixture["generation"], "restore did not change generation")
        server.start()
        for name, source in profiles.items():
            clients[name] = Client(folder, name, fixture["token"], fixture["folder"] / source)
        yield server, clients
    finally:
        for client in clients.values():
            client.close()
        server.close()


def verify_rest(token, expected):
    """An independent HTTP projection, including tombstones; clocks checked by clients."""
    export = http("GET", "/api/v1/export", token=token)
    collections = {"task": "tasks", "project": "projects", "section": "sections", "label": "labels",
                   "view": "views", "reminder": "reminders"}
    for entity, collection in collections.items():
        wanted = {i for e, i, _ in expected if e == entity}
        rows = {row["id"]: row for row in export.get(collection, [])}
        require(set(rows) == wanted, f"REST export {collection} ID mismatch")
        for (e, i, field), value in expected.items():
            if e == entity:
                require(rows[i].get(field) == value["value"], f"REST export mismatch: {e}.{field}")


def converge(server, clients, fixture, expected):
    for _ in range(2):
        for client in clients.values():
            client.sync()
    for client in clients.values():
        check_state(client, expected, "converged")
    fresh = Client(server.folder, "fresh-observer", fixture["token"])
    try:
        fresh.sync()
        check_state(fresh, expected, "downloaded")
        verify_rest(fixture["token"], expected)
        before = fields(fresh.store)
        cursor = fresh.store.get_meta("cursor")
        server.stop()
        server.start()
        for client in [*clients.values(), fresh]:
            client.sync()
        require(fields(fresh.store) == before and fresh.store.get_meta("cursor") == cursor,
                "repeated sync/restart changed recovered data or cursor")
        for client in clients.values():
            check_state(client, expected, "after-restart")
    finally:
        fresh.close()


def recovery_case(folder, fixture, order, fault="none"):
    profiles = {"A": "ahead-a.db", "B": "offline-b.db"}
    with restored(folder, fixture, profiles) as (server, clients):
        first = clients[order[0]]
        if fault != "none":
            require(order[0] == "A", "fault fixture requires ahead client first")
            first.sync(fault)
            require(first.store.outbox_count() > 0, "interruption left nothing to resume")
            require(first.store.get_meta("generation") == generation(server), "generation transition was not committed")
        for name in order:
            clients[name].sync()
        converge(server, clients, fixture, fixture["expected"])
        traces = [json.loads(line) for line in (first.folder / "exchanges.jsonl").read_text().splitlines()]
        all_traces = [json.loads(line) for client in clients.values()
                      for line in (client.folder / "exchanges.jsonl").read_text().splitlines()]
        require(any(t["ops"] == 500 for t in all_traces), "upload batch boundary was not exercised")
        require(any(t["hasMore"] for t in traces) or any(
            json.loads(line)["hasMore"] for line in (folder / "fresh-observer/exchanges.jsonl").read_text().splitlines()),
            "pull pagination was not exercised")
        if fault == "lost-response":
            require(any(t["duplicates"] > 0 for t in traces), "ambiguous upload was not retried as duplicates")
        save(folder / "expected.json", manifest(fixture["expected"]))


def purge_before_case(folder, fixture):
    with restored(folder, fixture, {"stale": "stale-before-purge.db"}) as (server, clients):
        converge(server, clients, fixture, fixture["baseline"])


def purge_after_case(folder, fixture):
    from dustpan.api import Api
    with restored(folder, fixture, {"A": "t0-a.db", "stale": "t0-b.db"}) as (server, clients):
        a, stale = clients["A"], clients["stale"]
        a.sync()
        a.write("delete_task", fixture["ids"]["purge_after"])
        a.sync()
        Api(BASE, fixture["token"]).purge("task", fixture["ids"]["purge_after"])
        a.sync()
        require(fixture["ids"]["purge_after"] not in a.store.rows("task"), "purge did not reach A")
        server.restore(fixture["archive"])
        server.start()
        # No surviving client retains the lost purge marker. The archive's live task returns.
        converge(server, {"stale": stale, "A": a}, fixture, fixture["baseline"])


def queued_purge_case(folder, fixture):
    from dustpan import trash
    with restored(folder, fixture, {"A": "t0-a.db", "stale": "t0-b.db"}) as (server, clients):
        a = clients["A"]
        oracle = Oracle(fixture["baseline"])
        target = fixture["ids"]["queued"]
        a.write("delete_task", target, oracle=oracle)
        trash.queue(a.store, [("task", target)])
        oracle.delete("task", target)
        converge(server, clients, fixture, oracle.state)


def mass_delete_case(folder, fixture):
    with restored(folder, fixture, {"A": "t0-a.db", "B": "t0-b.db"}) as (server, clients):
        a = clients["A"]
        oracle = Oracle(fixture["baseline"])
        # Simulate an unwanted deletion which reached every device.
        a.sync()
        for target in (fixture["ids"]["parent"], fixture["ids"]["series"]):
            a.write("delete_task", target, oracle=oracle)
        a.sync()
        clients["B"].sync()
        server.restore(fixture["archive"])
        server.start()
        converge(server, clients, fixture, oracle.state)


def corrupt_case(folder, fixture):
    server = Server(folder)
    try:
        server.restore(fixture["archive"])
        db = server.data / "opentodo.db"
        before = digest(db)
        gen = generation(server)
        safety = set(server.data.glob("*.pre-restore-*"))
        corrupt = folder / "corrupt.tar.gz"
        data = bytearray(fixture["archive"].read_bytes())
        data[len(data) // 2] ^= 0xFF
        corrupt.write_bytes(data)
        server.restore(corrupt, expect_success=False)
        require(digest(db) == before, "corrupted archive modified existing database")
        require(set(server.data.glob("*.pre-restore-*")) == safety, "failed restore made a safety copy")
        require(generation(server) == gen, "failed restore changed generation")
        server.start()
        converge(server, {}, fixture, fixture["baseline"])
    finally:
        server.close()


def real_case(folder):
    """Replay staged originals only; preserve backup fields missing from the client."""
    from dustpan.sync import AUTHORED
    inputs = Path("/work/inputs")
    server = Server(folder)
    clients = []
    try:
        archive = inputs / "server.archive"
        token = (inputs / "token").read_text()
        server.restore(archive)
        restored_generation = generation(server)
        server.start()
        before = Client(folder, "archive-observer", token)
        clients.append(before)
        before.sync()
        baseline = fields(before.store)
        a = Client(folder, "snapshot-replay", token, inputs / "client.db")
        clients.append(a)
        require(a.store.get_meta("generation") not in (None, restored_generation), "snapshot needs an established older generation")
        user_id = a.store.get_meta("user_id")
        require(user_id == before.store.get_meta("user_id"), "token and client snapshot belong to different accounts")
        oracle = Oracle(baseline)
        skipped = 0
        for (entity, eid, field), value in fields(a.store).items():
            if entity in AUTHORED:
                row = a.store.rows(entity).get(eid)
                if row.get(AUTHORED[entity]) != user_id:
                    skipped += 1
                    continue
            if entity == "attachment" and field == "uploaded_at":
                skipped += 1
                continue
            oracle.add([{"entity": entity, "entityId": eid, "field": field, **value}])
        # Explicit permanent-delete intentions are a different operation, not an absent field.
        require(not a.store.get_meta("pending_purges", []), "real snapshot has pending purges; review their expected cascades first")
        save(folder / "expected.json", manifest(oracle.state))
        fixture = {"token": token}
        converge(server, {"snapshot": a}, fixture, oracle.state)
        save(folder / "coverage.json", {"backup_fields": len(baseline), "expected_fields": len(oracle.state),
             "skipped_authored_or_uploaded_fields": skipped, "attachment_file_recovery": "not tested",
             "gui": "manual trial required"})
    finally:
        for client in clients:
            client.close()
        server.close()


def gui_worker(folder):
    """Exercise recovered data through actual GTK pages on a separate D-Bus session."""
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    gi.require_version("Graphene", "1.0")
    from gi.repository import Gdk, Gio, GLib, Graphene, Gtk
    from dustpan.app import App, Window
    from dustpan.dialogs import TaskDialog

    os.environ["DUSTPAN_DATA"] = str(folder)
    os.environ["DUSTPAN_CONFIG"] = str(folder / "config")
    app = App()
    app.set_flags(Gio.ApplicationFlags.NON_UNIQUE)
    failures = []
    captures = []
    pending = []
    before = None
    dialog = None

    def capture(widget, name):
        snap = Gtk.Snapshot()
        rect = Graphene.Rect().init(0, 0, widget.get_width(), widget.get_height())
        # snapshot_child excludes the toplevel's CSS background. Make the PNG opaque.
        found, background = widget.get_style_context().lookup_color("window_bg_color")
        if not found:
            background = Gdk.RGBA()
            background.parse("#fafafa")
        snap.append_color(background, rect)
        widget.snapshot_child(widget.get_child(), snap)
        node = snap.to_node()
        require(node is not None, f"no rendered content for {name}")
        path = folder / f"{name}.png"
        require(widget.get_renderer().render_texture(node, rect).save_to_png(str(path)), "screenshot failed")
        captures.append(path.name)

    def step():
        nonlocal before, dialog
        try:
            window = app.main_window()
            require(isinstance(window, Window) and window.get_mapped(), "recovered GTK window did not map")
            if before is None:
                before = fields(window.store)
                project_ids = {p.id for p in window.snap.live_projects}
                projects = [k for k in window.rows_by_key if k in project_ids]
                require(projects, "no project to inspect")
                tasks = [t for t in window.snap.all_tasks.values() if not t.get("deleted_at") and not t.get("completed_at")]
                require(tasks, "no open task to inspect")
                projects.sort(key=lambda pid: sum(t.get("project_id") == pid for t in tasks), reverse=True)
                dated = max(tasks, key=lambda t: bool(t.get("due")) * 10 + bool((t.get("due") or {}).get("time")) * 5
                            + bool(t.get("description")) * 3 + bool(t.get("recurrence")) * 2)
                for key in ("completed", "trash"):
                    if key not in window.rows_by_key:
                        window.show_hidden_page(key)
                def select(key):
                    window.sidebar.select_row(window.rows_by_key[key])
                pending.extend([
                    (lambda: select(projects[0]), lambda: capture(window, "project")),
                    (lambda: select("completed"), lambda: capture(window, "completed")),
                    (lambda: select("trash"), lambda: capture(window, "trash")),
                ])
                def open_calendar():
                    window.show_calendar(True)
                    if dated.get("due"):
                        window.calendar.anchor = dated.get("due")["date"]
                    window.calendar.switcher.set_active_name("month")
                    window.calendar.refresh()
                pending.append((open_calendar, lambda: capture(window.calendar, "calendar-month")))
                for view in ("week", "day"):
                    pending.append((lambda view=view: window.calendar.switcher.set_active_name(view),
                                    lambda view=view: capture(window.calendar, "calendar-" + view)))
                def open_editor():
                    nonlocal dialog
                    dialog = TaskDialog(window, dated)
                    dialog.present(window)
                pending.append((open_editor, lambda: capture(window, "task-editor")))
            if pending:
                prepare, shoot = pending.pop(0)
                prepare()
                def after_paint():
                    try:
                        shoot()
                    except Exception:
                        failures.append(traceback.format_exc())
                    GLib.timeout_add(100, step)
                    return GLib.SOURCE_REMOVE
                GLib.timeout_add(400, after_paint)
            else:
                if dialog:
                    dialog.close()
                require(fields(window.store) == before, "GUI inspection changed synced fields")
                save(folder / "gui.json", {"captures": captures, "synced_fields_unchanged": True, "failures": failures})
                app.quit()
        except Exception:
            failures.append(traceback.format_exc())
            app.quit()
        return GLib.SOURCE_REMOVE

    GLib.timeout_add(1500, step)
    GLib.timeout_add_seconds(20, lambda: (failures.append("GUI smoke timeout"), app.quit(), False)[-1])
    app.run(["dustpan-recovery-smoke"])
    require(not failures and len(captures) == 7, "GUI smoke failed: " + "\n".join(failures))


def gui_case(folder, source):
    server = Server(source)
    try:
        snapshot(source / "fresh-observer/dustpan.db", folder / "dustpan.db")
        token_file = source / "snapshot-replay/token" if (source / "snapshot-replay/token").exists() else source / "A/token"
        (folder / "config").write_text(f"OPENTODO_URL={BASE}\nOPENTODO_TOKEN={token_file.read_text()}\n")
        server.start()
        result = subprocess.run(["dbus-run-session", "--", sys.executable, "/source/recovery.py", "--gui-worker", str(folder)],
                                text=True, capture_output=True, timeout=30)
        (folder / "gui.log").write_text(result.stdout + result.stderr)
        require(result.returncode == 0, "GTK smoke failed; see gui.log")
    finally:
        server.close()


def require_sandbox():
    require({name for _, name in socket.if_nameindex()} == {"lo"}, "sandbox has a non-loopback network interface")
    require(not Path("/home").exists(), "host home must not be mounted")
    require(Path("/work").is_dir() and Path("/opentodo").is_file(), "not inside rehearsal sandbox")
    host_ns = json.loads(Path("/work/inputs.json").read_text())["host_network_namespace"]
    require(os.readlink("/proc/self/ns/net") != host_ns, "network namespace was not isolated")


def inside():
    require_sandbox()
    version = subprocess.check_output(["/opentodo", "version"], text=True).strip()
    require("0.22.0" in version, f"expected pinned OpenTodo v0.22.0, got {version}")
    results = []

    def run(name, function, limitation=None):
        folder = Path("/work") / name
        folder.mkdir()
        started = time.monotonic()
        try:
            value = function(folder)
            entry = {"scenario": name, "status": "PASS", "seconds": round(time.monotonic() - started, 2)}
            if limitation:
                entry.update(status="KNOWN_LIMITATION", detail=limitation)
            print(f"{entry['status']}: {name}", flush=True)
        except Exception as error:
            value = None
            (folder / "failure.txt").write_text(traceback.format_exc())
            entry = {"scenario": name, "status": "FAIL", "detail": str(error)}
            print(f"FAIL: {name}: {error}", flush=True)
        results.append(entry)
        save(Path("/work/results.json"), results)
        return value

    fixture = run("fixture", make_fixture)
    if fixture:
        for name, order, fault in (("ahead-first", "AB", "none"), ("stale-first", "BA", "none"),
                                   ("interrupted-reseed", "AB", "interrupt"),
                                   ("lost-upload-response", "AB", "lost-response")):
            run(name, lambda f, order=order, fault=fault: recovery_case(f, fixture, order, fault))
        run("purge-before-backup", lambda f: purge_before_case(f, fixture))
        run("queued-offline-purge", lambda f: queued_purge_case(f, fixture))
        run("corrupted-archive", lambda f: corrupt_case(f, fixture))
        run("purge-after-backup", lambda f: purge_after_case(f, fixture),
            "A purge after the archive is lost on rollback; a surviving old task can return. No durable client purge ledger exists.")
        run("mass-deletion", lambda f: mass_delete_case(f, fixture),
            "Archive rollback does not undo unwanted deletions retained by clients; re-seeding replays them.")
    if Path("/work/inputs").exists() and not any(r["status"] == "FAIL" for r in results):
        run("real-backup-replay", real_case)
    if os.environ.get("DUSTPAN_RECOVERY_GUI") and not any(r["status"] == "FAIL" for r in results):
        source = Path("/work/real-backup-replay" if Path("/work/inputs").exists() else "/work/ahead-first")
        run("gui-smoke", lambda folder: gui_case(folder, source))
    outcome = "FAIL" if any(r["status"] == "FAIL" for r in results) else "PASS_WITH_LIMITATIONS"
    lines = ["# Linux recovery rehearsal", "", f"Outcome: **{outcome}**", "", f"Server: {version}", "",
             "Network: private loopback only. Filesystem: host home absent; sources read-only.", "",
             "| Scenario | Result |", "| --- | --- |"]
    lines += [f"| {r['scenario']} | {r['status']} |" for r in results]
    lines += ["", "## Details", ""]
    lines += [f"- {r['scenario']}: {r['detail']}" for r in results if "detail" in r]
    lines += ["", "## Remaining manual checks", "",
              "Open a disposable recovered copy on a separate application bus. Inspect project/section/subtask hierarchy,",
              "notes, Trash, calendar dates, recurrence and reminders. Do not connect the production app to this server.",
              "Desktop notification delivery, attachment bytes and recovery of post-archive data absent from every surviving",
              "client are not established by this test. Real replay is included only when all three input paths were supplied.", ""]
    Path("/work/report.md").write_text("\n".join(lines))
    print(outcome, flush=True)
    return int(any(r["status"] == "FAIL" for r in results))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--gui-worker":
        require_sandbox()
        gui_worker(Path(sys.argv[2]))
        return 0
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        require_sandbox()
        worker(Path(sys.argv[2]), sys.argv[3])
        return 0
    if sys.argv[1:] == ["--inside"]:
        return inside()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "dev/bin/v0.22.0/opentodo-linux-amd64")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/recovery")
    parser.add_argument("--archive", type=Path, help="optional real server archive (copied before use)")
    parser.add_argument("--client-db", type=Path, help="matching real client database (SQLite snapshot before use)")
    parser.add_argument("--config", type=Path, help="matching token config; its server URL is never used")
    parser.add_argument("--gui-smoke", action="store_true", help="render recovered GTK pages on Wayland, on a private D-Bus session")
    return outer(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())

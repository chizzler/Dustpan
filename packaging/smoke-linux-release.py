#!/usr/bin/env python3
"""Exercise a built package on fresh data, a private bus and an isolated real server.

No host installation, personal profile, live server or desktop notification service is used.
Notification transport/actions are checked against a private Freedesktop notification service;
actual desktop rendering and a real login remain manual checks.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.request
from http.cookiejar import CookieJar

ROOT = Path(__file__).resolve().parents[1]


def outer():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    package = args.package.resolve()
    output = (args.output or package.parent / "runtime-smoke").resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    extracted = work / "package"
    extracted.mkdir()
    subprocess.run(["bsdtar", "-xf", str(package), "-C", str(extracted)], check=True)
    binary = ROOT / "dev/bin/v0.22.0/opentodo-linux-amd64"
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    assert any(line.split()[0] == digest and line.split()[-1].lstrip("*") == binary.name
               for line in (binary.parent / "SHA256SUMS").read_text().splitlines())
    (work / "home").mkdir()
    etc = work / "etc"
    etc.mkdir()
    (etc / "fonts").mkdir()
    (etc / "passwd").write_text(f"smoke:x:{os.getuid()}:{os.getgid()}:Smoke:/work/home:/bin/false\n")
    (etc / "group").write_text(f"smoke:x:{os.getgid()}:\n")
    (etc / "machine-id").write_text(secrets.token_hex(16) + "\n")
    display = os.environ.get("WAYLAND_DISPLAY", "")
    assert display, "a Wayland display is required"
    socket = Path(display) if display.startswith("/") else Path(os.environ["XDG_RUNTIME_DIR"]) / display
    assert socket.is_socket()
    inputs = {"package_sha256": hashlib.sha256(package.read_bytes()).hexdigest(), "server_sha256": digest,
              "host_network_namespace": os.readlink("/proc/self/ns/net")}
    (work / "inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    command = ["bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--clearenv",
               "--ro-bind", "/usr", "/usr", "--symlink", "usr/lib", "/lib",
               "--symlink", "usr/lib", "/lib64", "--symlink", "usr/bin", "/bin",
               "--ro-bind", str(etc), "/etc", "--ro-bind", "/etc/fonts", "/etc/fonts",
               "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--bind", str(work), "/work",
               "--ro-bind", str(extracted), "/package", "--ro-bind", str(binary), "/opentodo",
               "--ro-bind", str(ROOT / "dev/recovery.py"), "/source/dev/recovery.py",
               "--ro-bind", str(Path(__file__).resolve()), "/source/packaging/smoke.py",
               "--ro-bind", str(socket), "/display/wayland", "--setenv", "WAYLAND_DISPLAY", "/display/wayland",
               "--setenv", "GDK_BACKEND", "wayland", "--setenv", "GSK_RENDERER", "cairo",
               "--setenv", "GIO_USE_VFS", "local", "--setenv", "GTK_A11Y", "none",
               "--setenv", "GSETTINGS_BACKEND", "memory", "--setenv", "LANG", "C.UTF-8",
               "--setenv", "PATH", "/usr/bin", "--setenv", "HOME", "/work/home",
               "--setenv", "PYTHONPATH", "/package/usr/lib/dustpan", "--setenv", "PYTHONDONTWRITEBYTECODE", "1",
               "--setenv", "DUSTPAN_CONFIG", "/work/home/.config/dustpan/config",
               "--setenv", "DUSTPAN_DATA", "/work/home/.local/share/dustpan", "--chdir", "/work",
               "--", "dbus-run-session", "--", "python3", "/source/packaging/smoke.py", "--inside"]
    print(f"Runtime evidence: {work}", flush=True)
    result = subprocess.run(command)
    print(f"Result: {work / 'result.json'}", flush=True)
    return result.returncode


def inside():
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gio, GLib
    from dustpan import config, trash
    from dustpan.api import Api
    from dustpan.app import App
    from dustpan.clock import wall_ms
    from dustpan.dialogs import SectionDialog, SettingsDialog
    from dustpan.store import Store
    from dustpan.sync import Syncer, reset_for_account, verify_account

    work = Path("/work")
    assert os.readlink("/proc/self/ns/net") != json.loads((work / "inputs.json").read_text())["host_network_namespace"]
    assert not Path("/home/chee").exists()
    assert "/package/usr/lib/dustpan" in config.__file__
    spec = importlib.util.spec_from_file_location("recovery", "/source/dev/recovery.py")
    recovery = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = recovery
    spec.loader.exec_module(recovery)
    server = recovery.Server(work / "server-fixture")
    app = None
    peer = None
    checks = []

    def pump(until=lambda: True, timeout=10):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for _ in range(100):
                if not GLib.MainContext.default().pending():
                    break
                GLib.MainContext.default().iteration(False)
            if until():
                return
            time.sleep(0.01)
        raise AssertionError("runtime check timed out")

    def passed(name):
        checks.append(name)
        print(f"PASS: {name}", flush=True)

    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                      GLib.Variant("(su)", ("org.freedesktop.Notifications", 0)), None, Gio.DBusCallFlags.NONE, -1, None)
        xml = '''<node><interface name="org.freedesktop.Notifications">
          <method name="GetCapabilities"><arg type="as" direction="out"/></method>
          <method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/>
            <arg type="s" direction="out"/><arg type="s" direction="out"/></method>
          <method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/>
            <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/>
            <arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
            <arg type="u" direction="out"/></method>
          <method name="CloseNotification"><arg type="u" direction="in"/></method>
          <signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
        </interface></node>'''
        notifications, closed = [], []

        def notify(_connection, _sender, _path, _iface, method, parameters, invocation):
            if method == "GetCapabilities":
                invocation.return_value(GLib.Variant("(as)", (["actions", "body"],)))
            elif method == "GetServerInformation":
                invocation.return_value(GLib.Variant("(ssss)", ("Release smoke", "Dustpan", "1", "1.2")))
            elif method == "Notify":
                notifications.append(parameters.unpack())
                invocation.return_value(GLib.Variant("(u)", (len(notifications),)))
            elif method == "CloseNotification":
                closed.append(parameters.unpack()[0])
                invocation.return_value(None)

        bus.register_object("/org/freedesktop/Notifications", Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], notify)
        app = App(background=True)
        assert app.register(None)
        app.activate()
        window = app.main_window()
        assert window is not None and not window.get_visible() and window.cfg is None
        project = window.writer.add_project("Fresh package")
        sid = window.writer.add_section(project, "Waiting", color="#f59e0b", icon="hourglass")
        tid = window.writer.add_task("Packaged reminder", project_id=project, section_id=sid)
        rid = window.writer.add_reminder(tid, "absolute", fire_at=wall_ms() - 500)
        window.check_reminders()
        pump(lambda: bool(notifications))
        assert notifications[-1][3] == "Packaged reminder"
        passed("standalone hidden startup and reminder delivery over private D-Bus")
        actions = notifications[-1][5]
        snooze = next(actions[i] for i in range(0, len(actions), 2) if actions[i + 1] == "Snooze 10 min")
        bus.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked",
                        GLib.Variant("(us)", (1, snooze)))
        pump(lambda: window.store.rows("reminder")[rid].get("fire_at") > wall_ms())
        pump(lambda: bool(closed))
        window.writer.snooze(rid, wall_ms() - 500)
        window.check_reminders()
        pump(lambda: len(notifications) == 2)
        actions = notifications[-1][5]
        dismiss = next(actions[i] for i in range(0, len(actions), 2) if actions[i + 1] == "Dismiss")
        bus.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked",
                        GLib.Variant("(us)", (2, dismiss)))
        pump(lambda: window.store.rows("reminder")[rid].get("dismissed_at") is not None)
        passed("notification Snooze and Dismiss actions and withdrawal")

        second = subprocess.Popen([sys.executable, "-m", "dustpan"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        pump(lambda: window.get_visible() and second.poll() is not None)
        assert second.returncode == 0, second.stderr.read().decode()
        window.close()
        pump(lambda: not window.get_visible())
        assert app.main_window() is window
        app.activate()
        pump(lambda: window.get_mapped())
        passed("normal activation hands off to the hidden instance; close hides without quitting")

        template = Path("/package/usr/share/doc/dustpan/dustpan-autostart.desktop")
        installed = work / "home/.config/autostart/io.github.chizzler.Dustpan.desktop"
        installed.parent.mkdir(parents=True)
        installed.write_bytes(template.read_bytes())
        assert "Exec=/usr/bin/dustpan --background" in installed.read_text()
        subprocess.run(["desktop-file-validate", str(installed)], check=True)
        passed("opt-in autostart entry validates and specifies hidden startup (actual login untested)")

        os.environ["OPENTODO_ALLOW_SIGNUP"] = "true"  # two throwaway accounts, inside the private namespace only
        server.start()

        def account(email):
            cookies = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))
            recovery.http("POST", "/api/v1/auth/register", {"email": email, "name": "Release smoke",
                          "password": secrets.token_urlsafe(32), "setupToken": "recovery-test-only"}, opener=cookies)
            token = recovery.http("POST", "/api/v1/tokens", {"name": "release-smoke", "scope": "admin"}, opener=cookies)["secret"]
            cfg = config.Config(recovery.BASE, token)
            uid, key = verify_account(Api(cfg.url, cfg.token))
            return cfg, uid, key

        cfg, uid, key = account("first@example.invalid")
        other_cfg, other_uid, other_key = account("second@example.invalid")
        settings = SettingsDialog(window)
        settings.present(window)
        pump(lambda: settings.get_mapped())
        settings.url_row.set_text(cfg.url)
        settings.token_row.set_text(cfg.token)
        settings._on_connect_clicked()
        pump(lambda: window.cfg == cfg and not window.syncing and window.store.outbox_count() == 0)
        assert config.load() == cfg
        assert config.config_path().stat().st_mode & 0o777 == 0o600
        assert window.store.rows("task")[tid].get("title") == "Packaged reminder"
        passed("Settings connects fresh standalone data to a real isolated server and saves private credentials")

        peer = Store(work / "peer.db")
        peer_sync = Syncer(peer, Api(cfg.url, cfg.token))
        peer_sync.run()
        from dustpan.writes import Writer
        peer_writer = Writer(peer)
        assert peer.rows("section")[sid].get("icon") == "hourglass"
        editor = SectionDialog(window, project, window.store.rows("section")[sid])
        editor.present(settings)
        peer_writer.edit_section(sid, {"color": "#3b82f6", "icon": "dog"})
        peer_sync.run()
        window.sync()
        pump(lambda: not window.syncing and window.store.rows("section")[sid].get("icon") == "dog")
        editor.name_row.set_text("Renamed locally")
        editor.save()
        window.sync()
        pump(lambda: not window.syncing and window.store.outbox_count() == 0)
        peer_sync.run()
        row = peer.rows("section")[sid]
        assert (row.get("name"), row.get("color"), row.get("icon")) == ("Renamed locally", "#3b82f6", "dog")
        assert window.undo_last()
        window.sync()
        pump(lambda: not window.syncing and window.store.outbox_count() == 0)
        peer_sync.run()
        row = peer.rows("section")[sid]
        assert (row.get("name"), row.get("color"), row.get("icon")) == ("Waiting", "#3b82f6", "dog")
        passed("real-server two-Linux-client section edit, concurrent sync and Undo (not a Mac trial)")

        config.clear()
        window.disconnect_sync()
        assert window.cfg is None and tid in window.store.rows("task")
        window.writer.delete_task(tid)
        trash.queue(window.store, [("task", tid)])
        settings._finish_connect(cfg)
        pump(lambda: not window.syncing and not trash.pending(window.store))
        assert tid not in window.store.rows("task")
        passed("disconnect retains local data; queued permanent deletion reaches server after reconnect")

        window.sync()
        assert window.syncing
        settings._change_account(other_cfg, lambda: reset_for_account(window.store, other_uid, other_key))
        pump(lambda: window.cfg == other_cfg and not window.syncing and window.account_change is None)
        assert window.store.get_meta("user_id") == other_uid
        assert not window.store.rows("project")
        assert peer.rows("project")[project].get("name") == "Fresh package"
        passed("account replacement waits for an active sync, keeps accounts separate and pulls the new account")
        settings.force_close()
        result = {"status": "PASS", "checks": checks, "limits": ["real desktop notification rendering not tested",
                  "actual session login not tested", "Mac offline: Swift tests and real Mac/Linux trial pending"]}
    except Exception:
        result = {"status": "FAIL", "checks": checks, "error": traceback.format_exc()}
        print(result["error"], file=sys.stderr)
    finally:
        if app:
            app.quit()
        if peer:
            peer.close()
        server.close()
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(inside() if sys.argv[1:] == ["--inside"] else outer())

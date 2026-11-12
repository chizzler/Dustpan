"""Entry point. With no arguments, start the app.

  python -m dustpan          the desktop app
  python -m dustpan --background
                             the app with its window hidden, for login: reminders and sync run
  python -m dustpan sync     sync once and print what came in
  python -m dustpan tree     print projects, sections and tasks from the local copy
  python -m dustpan --version
"""

import sys

from . import config
from .api import Api, ApiError, Offline
from .model import project_sections, snapshot
from .store import Store
from .sync import AccountChanged, ClockSkew, Syncer, UnsupportedAccount


def cmd_sync():
    try:
        cfg = config.load()
    except config.ConfigMissing as err:
        print(f"OpenTodo sync is not configured ({err}). Connect in Settings or set OPENTODO_URL and OPENTODO_TOKEN.",
              file=sys.stderr)
        return 1
    store = Store(config.database_path())
    try:
        result = Syncer(store, Api(cfg.url, cfg.token)).run()
        cursor = store.get_meta("cursor")
    except (Offline, ApiError, ClockSkew, UnsupportedAccount, AccountChanged) as err:
        print(f"sync failed: {err}", file=sys.stderr)
        return 1
    finally:
        store.close()
    print(f"received {result.received} ops, cursor {cursor}")
    if result.refused:
        print(f"{result.refused} local changes were not accepted")
    if result.held:
        print(f"{result.held} changes held back by a server limit")
    return 0


def print_tasks(nodes, depth):
    for node in nodes:
        print("    " * depth + "- " + node.row.get("title", ""))
        print_tasks(node.children, depth + 1)


def print_project(snap, project_id, name, depth):
    print("  " * depth + f"# {name}")
    for sec in project_sections(snap, project_id):
        indent = "  " * depth + "  "
        if sec.id:
            print(f"{indent}## {sec.name}")
        print_tasks(sec.tasks, depth + 1 if not sec.id else depth + 2)


def cmd_tree():
    store = Store(config.database_path())
    try:
        snap = snapshot(store)
    finally:
        store.close()
    print_project(snap, None, "Inbox", 0)

    def walk(nodes, depth):
        for node in nodes:
            print_project(snap, node.id, node.row.get("name", ""), depth)
            walk(node.children, depth + 1)

    walk(snap.projects, 0)
    return 0


def main():
    args = sys.argv[1:]
    if not args or args == ["--background"]:
        from .app import main as app_main
        return app_main(background=bool(args))
    if args == ["--version"]:
        from . import __version__
        print(f"Dustpan {__version__}")
        return 0
    commands = {"sync": cmd_sync, "tree": cmd_tree}
    if args[0] not in commands or len(args) > 1:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return commands[args[0]]() or 0


sys.exit(main())

# Dustpan desktop client

The Omarchy client. Python, GTK 4 and libadwaita. No packages from PyPI.

Needs `python`, `python-gobject`, `gtk4` and `libadwaita` from the official Arch repos.

## Develop

Run everything from the repo root.

```sh
dev/server.sh          # local OpenTodo v0.18.0 on 127.0.0.1:8080 (downloads and checks it once)
dev/seed.py            # sample data, once per fresh server
dev/client.sh          # the app, against the dev server
dev/client.sh sync     # sync once, no window
dev/client.sh tree     # print the local copy as a tree
python3 -m unittest discover -s desktop/tests -t desktop
```

`dev/credentials` holds the dev account and token. It's created once and ignored by git.
The client keeps its dev data in `dev/data/client`.

`DUSTPAN_SCREENSHOT=<folder> dev/client.sh` saves one PNG per sidebar page, then quits.
`DUSTPAN_THEME=/usr/share/omarchy/themes/<name>/colors.toml` shows the app in another Omarchy theme.

## Layout

| File | Role |
| --- | --- |
| `dustpan/store.py` | SQLite: one last-writer-wins register per field, outbox, meta |
| `dustpan/clock.py` | Hybrid logical clock |
| `dustpan/sync.py` | The sync exchange, refused ops, purge and re-seed |
| `dustpan/writes.py` | Local edits: one stamped batch per action |
| `dustpan/trash.py` | Trash listing, retention countdown and queued permanent deletions |
| `dustpan/ordering.py` | Manual order: the positions a move writes |
| `dustpan/dragdrop.py` | Drag and drop rules: where a drop lands and what it means, without GTK |
| `dustpan/recurrence.py` | Repeat rules: parse, canonical form, next date |
| `dustpan/recurring.py` | What completing, skipping and splitting a repeating task write |
| `dustpan/reminders.py` | When reminders fire, snooze, default reminders |
| `dustpan/ids.py` | Deterministic ids shared with the server |
| `dustpan/events.py` | The live update stream |
| `dustpan/filters.py` | The filter query language: parse, then test tasks |
| `dustpan/views.py` | What the Inbox, Today, Upcoming and saved views list, and in what order |
| `dustpan/quickadd/` | Quick add: read a line into task fields, in six languages |
| `dustpan/model.py` | Display rules: trees, sections, what's hidden |
| `dustpan/querytools.py` | The query helper without GTK: suggestions, and the conditions the builder adds |
| `dustpan/labels.py` | Labels without GTK: matching as you type, the picker's order, duplicates, chips |
| `dustpan/markdown.py` | Notes: the web app's Markdown subset, parsed, and as Pango markup |
| `dustpan/dates.py` | Due date display, and the instant a due denotes |
| `dustpan/api.py` | HTTP client, standard library only |
| `dustpan/config.py` | XDG paths and the config file |
| `dustpan/app.py` | The GTK window and its pages |
| `dustpan/dialogs.py` | The task and view editors |
| `dustpan/dragging.py` | Drag and drop in GTK: sources, page and sidebar targets, the drop line, autoscroll |
| `dustpan/querybar.py` | The query box: suggestions as you type, Not, and + Condition |
| `dustpan/labelpicker.py` | The label picker: type to find, Enter to add, remove or create |
| `dustpan/noteview.py` | Notes in GTK: the formatted view, and the Write and Preview editor |
| `dustpan/rowactions.py` | Keys and the right-click menu on each task row |
| `dustpan/theme.py` | The Omarchy theme's palette, as libadwaita colour variables, without GTK |
| `data/` | Launcher entry and icon, for `install.sh`. The icon's source is `dustpan-v1.vectorcraft` (VectorCraft) |
| `dustpan/widgets.py` | Styles, following the Omarchy theme, and small shared widgets |

The protocol rules these follow are in [`../spec/`](../spec/README.md).

The recurrence, reminder, date, filter, Inbox and quick-add tests read OpenTodo's shared vectors and docs from a clone beside this repo (`../opentodo`)
(or `$OPENTODO_SRC`), and skip without it.

A second copy started while one runs just hands over to the first. To drive a test copy alongside your own,
create the app with `Gio.ApplicationFlags.NON_UNIQUE`,
or run it on its own bus: `dbus-run-session -- dev/client.sh`.

## Real use

`desktop/install.sh` adds `~/.local/bin/dustpan`, a launcher entry, the icon, and an autostart entry.
They run this checkout, so a `git pull` updates the app. `desktop/install.sh --remove` takes them out again.

Put `OPENTODO_URL=…` and `OPENTODO_TOKEN=…` in `~/.config/dustpan/config` (mode 600).
The URL must be https. Plain http works only for this machine (`localhost`, `127.0.0.1`, `::1`).
Data goes in `~/.local/share/dustpan/`.

**Projects and sections.** The + beside Projects makes a project. Right-click a project for its menu,
or use the pencil on its page to rename it, recolour it, move it under another, archive or delete it.
Archived projects are listed under Archived, at the foot of the sidebar. Each section heading has a ⋮ menu:
rename, move up or down, delete. "Add section" is at the end of a project's page.

**Completed subtasks.** Finished subtasks stay under their open parent, dimmed and struck through, in project
and Inbox lists and in the task editor. The small broom beside a parent clears its completed subtasks from
the list, with Undo. They remain in Completed. Clearing is remembered on this device; reopening a subtask
shows it again.

**Closing the window hides it.** Sync and reminders carry on. Ctrl+Q quits.

**Trash.** Deleted tasks and projects appear in Trash, including a Restore action with Undo.
Delete for good and Empty Trash ask first, then wait for sync when offline. The server's retention
period is shown above the list. Hide Trash from its sidebar menu; bring it back from ⋯ above the sidebar.
At login the autostart entry runs `dustpan --background`: no window until you open Dustpan.
Hidden, it uses about 115 MB (most of it GTK) and about 10 ms of CPU a minute. It skips page rebuilds until shown.

**After pulling or changing code, quit with Ctrl+Q and reopen.** The launcher only shows the copy already running,
which keeps the code it started with.

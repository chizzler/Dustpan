# Dustpan for Linux

A native GTK 4 and libadwaita task manager for Omarchy and Arch Linux. Tasks live locally in SQLite so
you can install, open and start adding tasks right away, with optional sync to your own
[OpenTodo](https://github.com/OpenTodoApp/OpenTodo) server whenever you want multi-device sync.

Nested projects, sections, subtasks, priorities, labels, recurrence, reminders, Markdown notes,
natural-language quick add, filters, saved views, Undo and Trash are included. A companion calendar
provides Month, Week and Day views, scheduling and duration resizing. Colours follow the Omarchy theme,
with Adwaita as the fallback.

## Install

For a locally built Arch package:

```sh
sudo pacman -U dustpan-@VERSION@-1-any.pkg.tar.zst
```

Pacman installs the dependencies from the Arch repositories. The package installs `/usr/bin/dustpan`,
a launcher entry, the icon and the application files under `/usr/lib/dustpan`. The build folder can
be removed afterward. Python packages from PyPI are not needed.

If you used the checkout-based installer, run `desktop/install.sh --remove` from that old checkout
before switching. This removes its `~/.local/bin/dustpan`, launcher and autostart entry; configuration
and task data stay in place. The old launcher can otherwise shadow the packaged version.

## Standalone use and optional OpenTodo sync

Open Dustpan from the launcher, or run `dustpan`. No server is required: tasks, reminders, preferences and
Trash (including permanent deletion) work locally out of the box in
`~/.local/share/dustpan/dustpan.db` (or under `XDG_DATA_HOME` when set).
Open **Settings** (`Ctrl+,` or the gear button) to configure default reminders, date/time formats, week and
day start, and quick-add options.

To sync across devices, run an OpenTodo server (tested with **OpenTodo v0.22.0**, with an unencrypted
personal account). Create a device-specific token in its web app under Settings → Integrations → API tokens,
then enter your server URL and API token under **Settings → OpenTodo sync** in Dustpan. Existing local tasks,
projects, labels, views and preferences upload automatically and merge with any data already on the server.

You can also configure sync directly in `~/.config/dustpan/config` (mode `600`):

```ini
OPENTODO_URL=https://todo.example.com
OPENTODO_TOKEN=your-api-token
```

The URL must use https; plain http is allowed only for localhost. Closing the window hides it so reminders
(and sync, when connected) continue; Ctrl+Q quits. Quit and reopen after an update.

## Start at login (optional)

The package does not enable autostart for everyone. To keep sync and reminders running from login:

```sh
mkdir -p ~/.config/autostart
cp /usr/share/doc/dustpan/dustpan-autostart.desktop ~/.config/autostart/io.github.chizzler.Dustpan.desktop
```

It starts hidden. Open Dustpan normally to show its window. Remove that copied entry to disable autostart.
Notifications require a running notification service.

## Calendar keys

`d`, `w`, `m` select Day, Week, Month. `[` / `]` step through dates, `t` returns to today,
and `h` toggles completed tasks. Click a task or use `j` / `k` to select it; Enter edits,
`c` completes or reopens, Delete deletes, Esc clears selection and `.` opens its menu.
Left/Right move it by a day. In Day/Week, Up/Down move it by 15 minutes, Shift+Up/Down change its
length, Alt+Shift+Up/Down move its start while keeping its end, and `u` removes its time.

## Current limits

- Release blocker: switching OpenTodo accounts during active sync can send new-account data to the previous
  account and mix its response into local data. Avoid switching accounts in the running app until fixed.
- Release blocker: deleting previously synced items for good after disconnect loses their server deletion;
  the server copy remains and can return. Keep sync configured and let permanent deletion reach the server.
- Encrypted accounts and complete shared-project membership handling are not supported.
- The calendar does not yet show future repeat occurrences or multi-day bars.
- Time sectors can be shown, filtered and used in quick add, but cannot be set in the editor.
- Tracked-time, workspace and custom-field filters cannot be evaluated by this client.
- Saved-view drop targets and manual ordering within saved views are unfinished.
- Archive restore followed by client re-seeding has been rehearsed end to end. A rollback can lose
  permanent deletions newer than the archive, bringing old tasks back. It also replays unwanted soft
  deletions still held by clients; restoring the server alone does not undo accidental mass deletion.

## Build and test

The source archive contains a `PKGBUILD.in` template, launcher and desktop files under `packaging/aur`.
The AUR recipe distributed with a release supplies the version, download URL and SHA-256 checksum.
Run `makepkg --check` beside that recipe and its source archive to build and test without installing.

To run just the tests from this source archive:

```sh
OPENTODO_SRC="$PWD/desktop/tests/upstream" python -m unittest discover -s desktop/tests -t desktop
```

Fixtures are included from the pinned OpenTodo release, so tests need no server or network.
The package requires Python 3.11+, PyGObject, Pycairo, GTK 4 and libadwaita 1.7+.

## License

AGPL-3.0-only. See `LICENSE` and `NOTICE.md`, including attribution for the OpenTodo ports and fixtures.

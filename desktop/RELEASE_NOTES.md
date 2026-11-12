# Dustpan for Linux 0.12.4 — release draft

A native GTK 4 / libadwaita task manager for Omarchy and Arch Linux. Tasks live in a local SQLite database
so it works standalone out of the box, with optional sync to your own OpenTodo server.

## Included

- Nested projects, sections, subtasks, priorities, labels, due dates, estimates and deadlines.
- Repeating tasks, reminders and desktop notifications.
- Natural-language quick add in six languages.
- Today, Upcoming, Anytime, Completed, filters and saved views.
- Markdown task notes, drag and drop, keyboard actions, Undo, and Trash with restore.
- A companion Month, Week and Day calendar, including task placement, duration resizing, keyboard moves
  and an option to show completed tasks.
- Collapsible subtasks, a progress pie on parent tasks, and an offer to complete a finished parent.
- Colours that follow the Omarchy theme, with Adwaita as the fallback.

## Since v0.12.3

- Subtask progress, the parent-completion prompt, and delayed sorting of completed subtasks.
- Clickable project names on grouped task rows.
- Desktop visual polish and the Dustpan icon.
- A remembered calendar toggle for completed tasks (`h`).
- Refused HTTP redirects to prevent forwarding the API token to another host or an insecure URL.
- Fixed calendar Open, Complete, Reopen and Delete actions, including their keyboard shortcuts and menus.
- Fixed recovery pulls to include old writes from the same device when a restore brings back data it had purged.
- Standalone support: open and use Dustpan without server configuration, configure preferences locally
  (including default reminders), permanently delete items from Trash locally, and connect to OpenTodo later
  to upload local tasks and merge server data. The account-switching and disconnected-deletion issues below
  remain release blockers.

## Install

The Arch package installs the app, launcher, icon and dependencies through pacman. Open Dustpan and start
adding tasks locally; connecting an OpenTodo server (tested with OpenTodo v0.22.0) is optional in Settings.
See the README included with the source archive for package setup and migration instructions.
Autostart is opt-in. The checkout-based installer remains available for development use.

## Known limits

- Release blocker: switching accounts during active sync can send new-account data to the previous account
  and apply its response to local data. Avoid switching OpenTodo accounts in the running app until fixed.
- Release blocker: deleting previously synced items for good after disconnect discards their server deletion.
  The server copy remains and can return in later pulls. Keep sync configured and let deletion reach the server.
- Personal accounts; encrypted accounts and complete shared-project membership handling are not supported.
- Future repeating-task occurrences and multi-day bars are not yet shown on the calendar.
- Saved-view drag targets and manual ordering within saved views remain unfinished.
- A server rollback can lose permanent deletions newer than the archive, letting old tasks return.
  Restoring the server alone also does not undo accidental soft deletions still held by clients.

This is a pre-1.0 release.

## Validation

The current suite ran 331 Python tests with no failures and one GTK display test skipped. The two standalone
release blockers above were reproduced separately with temporary databases and fake connections.
The earlier 314-test recovery and package validation predates standalone support; release artifacts need
rebuilding and revalidation. Calendar row key handlers have also been
exercised in a separate GTK window using a temporary database with sync disabled.
An isolated real-server recovery rehearsal covers restore/re-seed, both reconnect orders, conflicts,
pagination, interrupted uploads, lost acknowledgements, purge behavior and corrupted archives.
A copied real server archive and client backup recover all 949 expected fields through a fresh client and REST.

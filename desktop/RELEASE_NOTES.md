# Dustpan for Linux 0.12.6

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

- Section colours and icons: Add and Edit section offer a name, colour (None first) and icon, with
  suggestions from the section's name. Headings show a coloured icon, an icon in the text colour,
  a coloured dot, or the name alone. Edits have Undo and preserve unknown icons when untouched.
- Fixed: saving a section editor could overwrite an unrelated rename, colour or icon synced while it
  was open. Only fields changed since opening are submitted; Undo restores only those fields.
- Project icons: pick one of Lucide's 1,854 line icons for a project, with suggestions from its name.
  The picker browses 30 categories from a sidebar, or searches them all. They sync through OpenTodo;
  its web app shows the 411 in its own catalogue, and the project's dot for the rest.
- Labels show as a solid tag in their colour, so they never look like a project's dot or line icon.
  Task rows and the editor show a small one in each label chip.
- A Theme colour for projects: no colour of their own, drawn in the theme's text colour.
- A large heading on every page. A project shows its icon, where it sits and its sub-projects.
- Fixed: after choosing an icon or a label, the picker kept taking the focus, so a name couldn't be typed.
- Completed subtasks settle below open ones 2 seconds after the last tick.
- Subtask progress, the parent-completion prompt, and delayed sorting of completed subtasks.
- Clickable project names on grouped task rows.
- Quick add's preview starts with the title it will save (`→ Call Sam · Tomorrow 3:00pm · p1`),
  so a word read as a date can't vanish unseen.
- Fixed: quick add read "sun", "sat" and "wed" as days mid-sentence, so `Sit in the sun` became *Sit in the*,
  due Sunday. They're now a date only with a cue: `on`/`next` before, a time or tag after, or at the line's end.
- Desktop visual polish and the Dustpan icon.
- A remembered calendar toggle for completed tasks (`h`).
- Refused HTTP redirects to prevent forwarding the API token to another host or an insecure URL.
- Fixed calendar Open, Complete, Reopen and Delete actions, including their keyboard shortcuts and menus.
- Fixed recovery pulls to include old writes from the same device when a restore brings back data it had purged.
- Standalone support: open and use Dustpan without server configuration, configure preferences locally
  (including default reminders), permanently delete items from Trash locally, and connect to OpenTodo later
  to upload local tasks and merge server data.
- Switching OpenTodo accounts now waits for any running sync to finish, and a sync interrupted by a switch
  keeps nothing. Deleting previously synced items for good while disconnected now reaches the server on reconnect.

## Install

The Arch package installs the app, launcher, icon and dependencies through pacman. Open Dustpan and start
adding tasks locally; connecting an OpenTodo server (tested with OpenTodo v0.22.0) is optional in Settings.
See the README included with the source archive for package setup and migration instructions.
Autostart is opt-in. The checkout-based installer remains available for development use.

## Known limits

- Personal accounts; encrypted accounts and complete shared-project membership handling are not supported.
- Future repeating-task occurrences and multi-day bars are not yet shown on the calendar.
- Saved-view drag targets and manual ordering within saved views remain unfinished.
- A server rollback can lose permanent deletions newer than the archive, letting old tasks return.
  Restoring the server alone also does not undo accidental soft deletions still held by clients.

This is a pre-1.0 release.

## Validation

The current source suite ran 378 Python tests with no failures or skips with display access. Regression
tests cover account switching during sync, permanent deletion after disconnect, and section editor saves
after concurrent updates (including explicit clearing, no-op saves and Undo). Section headings and editors
were visually checked using throwaway data in dark and light palettes; the shared icon picker was also
checked in the dark palette.
The 0.12.6 Arch package passed local and clean-Arch builds, packaged imports/assets, desktop-entry validation
and disposable install/reinstall/removal. The release archive's 378 tests also pass with display access
using only its bundled upstream fixtures; headless package builds skip the 21 GTK checks.
A fresh packaged-app profile passed hidden startup, normal activation of the same instance, close-to-hide,
Settings connection, upload of standalone data, account replacement during active sync and queued permanent
deletion after reconnect, against an isolated real OpenTodo v0.22.0 server. Two Linux clients passed section
styling, concurrent editing and Undo over that server. Reminder delivery, Snooze, Dismiss and withdrawal pass
over a private notification service. The opt-in autostart entry validates; actual session login and desktop
notification rendering were not tested. The Mac is offline, so Swift tests and a real Mac/Linux trial remain
pending. Calendar row key handlers have also been
exercised in a separate GTK window using a temporary database with sync disabled.
An isolated real-server recovery rehearsal covers restore/re-seed, both reconnect orders, conflicts,
pagination, interrupted uploads, lost acknowledgements, purge behavior and corrupted archives.
A copied real server archive and client backup recover all 949 expected fields through a fresh client and REST.

# Client spec

The parts of OpenTodo's protocol that the Omarchy client implements.
OpenTodo's own docs are the reference. This file records what we use, what we skip, and where we differ.
The Mac client has its own Swift core and [guide](../apple/README.md). It follows these rules, and the specs note
where the Mac differs (an "On the Mac" section).

Pinned to **OpenTodo v0.22.0**. Local clone: `../opentodo`, beside this repo, at tag `v0.22.0`. The tests read its vectors.
Most of the client was ported from v0.18.0 and still matches. The v1 API only grows from v0.22.0.
What the client doesn't do yet is listed under "Behind the server".

- Sync protocol: `docs/sync.md`
- REST API and auth: `docs/api.md`
- Recurrence grammar: `docs/recurrence.md`
- Filter grammar: `docs/filters.md`
- Test vectors: `web/src/lib/*.vectors.json`

When the pin moves, re-read the sync doc's schema table and diff the vectors.

## Slices

| Slice | Scope | Spec | Since |
| --- | --- | --- | --- |
| 1 | Read-only: pull, store, show projects, sections and tasks | [sync.md](sync.md) | 0.12.0 |
| 2 | Basic writes: add, complete, rename, due, priority, move | [writes.md](writes.md) | 0.12.0 |
| 3 | Recurrence and reminders, against the vectors | [recurrence.md](recurrence.md) | 0.12.0 |
| 4a | Filters, Today, Upcoming, saved views | [views.md](views.md) | 0.12.0 |
| 4b | Quick add, against the vectors | [quickadd.md](quickadd.md) | 0.12.0 |
| 5 | Everyday editing: delete, subtasks, labels, estimates, deadlines, reorder, more reminders | [writes.md](writes.md) | 0.12.0 |
| 6 | Drag and drop: nest, place, move to projects and dates, with keyboard and menu alternatives (6c partly built) | [dragdrop.md](dragdrop.md) | 0.12.0 |
| 7 | Projects and sections: create, nest, rename, colour, archive, delete | [projects.md](projects.md) | 0.12.0 |
| 8 | Task notes in Markdown: write, preview, first line on the row | [notes.md](notes.md) | 0.12.0 |
| 9 | Labels: chips, a picker, labels in the sidebar, rename, recolour, reorder, merge, delete, drop on a label | [labels.md](labels.md) | 0.12.0 |
| 10 | Built-in Anytime and Completed pages, and the Filter page (the query helper) | [views.md](views.md) | 0.12.0 |
| 11 | Trash: restore, permanent deletion, offline queue and retention | [trash.md](trash.md) | 0.12.0 |
| — | Time sectors (show, filter, quick add, write rules) and the `notes` filter terms, from OpenTodo v0.22.0 | [sectors.md](sectors.md) | 0.12.0 |
| 12 | Calendar, in a companion window: Month, Week and Day, placing and stretching (12d, repeats and multi-day, not built) | [calendar.md](calendar.md) | 0.12.0–0.12.2 |
| — | Fold a task's subtasks away in project and Inbox lists | [folding.md](folding.md) | 0.12.3 |
| — | Subtask progress, the offer to complete the parent, clickable project labels, completed subtasks settling | [progress.md](progress.md) | 0.12.4 |
| — | Project icons and the Theme colour | [icons.md](icons.md) | 0.12.5 |
| — | Page heading: a large title on every page, with sub-projects to open | [pagehead.md](pagehead.md) | 0.12.5 |
| — | Section colours and icons: editor, headings, sync and Undo | [projects.md](projects.md#sections) | 0.12.6 |

The restore and re-seed rehearsal is described in [dev/RECOVERY.md](../dev/RECOVERY.md).

## Behind the server

Server features since v0.18.0 that the client doesn't show or set yet. Their data syncs and is kept.

- **Time sectors**: shown, filtered and read by quick add (see [sectors.md](sectors.md)), but not set from the editor.
- **Multi-day tasks** (`span`, v0.19.0): Upcoming lists them by their due date, not once under their first day.
- **Sorting a view by a custom field** (v0.22.0): falls back to due date.
- Objectives, routines, themes, reusable lists, rotation, location reminders: ignored.

To catch up with a later release: check out its tag in `../opentodo`, run the tests, and port until they pass.

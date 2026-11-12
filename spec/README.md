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

| Slice | Scope | Spec | Status |
| --- | --- | --- | --- |
| 1 | Read-only: pull, store, show projects, sections and tasks | [sync.md](sync.md) | done 2026-10-31 |
| 2 | Basic writes: add, complete, rename, due, priority, move | [writes.md](writes.md) | done 2026-10-31 |
| 3 | Recurrence and reminders, against the vectors | [recurrence.md](recurrence.md) | done 2026-10-31 |
| 4a | Filters, Today, Upcoming, saved views | [views.md](views.md) | done 2026-10-31, tried and approved |
| 4b | Quick add, against the vectors | [quickadd.md](quickadd.md) | done 2026-10-31, tried and approved |
| 5 | Everyday editing: delete, subtasks, labels, estimates, deadlines, reorder, more reminders | [writes.md](writes.md) | done 2026-10-31, tried and approved |
| 6 | Drag and drop: nest, place, move to projects and dates, with keyboard and menu alternatives | [dragdrop.md](dragdrop.md) | 6a done 2026-11-01, tried and approved; 6b done 2026-11-01, tried and approved; 6c to come |
| 7 | Projects and sections: create, nest, rename, colour, archive, delete | [projects.md](projects.md) | done 2026-11-01 |
| 8 | Task notes in Markdown: write, preview, first line on the row | [notes.md](notes.md) | done 2026-11-02, tried and approved |
| 9 | Labels: chips, a picker, labels in the sidebar, rename, recolour, reorder, merge, delete | [labels.md](labels.md) | done 2026-11-02, tried and approved; drop on a label 2026-11-02 |
| 10 | Built-in Anytime and Completed pages, and the Filter page (the query helper) | [views.md](views.md) | done 2026-11-02, tried and approved (Filter 2026-11-02; Anytime and Completed 2026-11-04) |
| 11 | Trash: restore, permanent deletion, offline queue and retention | [trash.md](trash.md) | done 2026-11-03, tried and approved 2026-11-04 |
| Server update | Catch up with v0.22.0: time sectors (show, filter, quick add, write rules), the `notes` filter terms | [sectors.md](sectors.md) | done 2026-11-04, owner trial pending |
| 12 | Calendar, in a companion window: Month, then Week and Day, placing, repeating and multi-day tasks | [calendar.md](calendar.md) | 12a, 12b and 12c done 2026-11-04, tried and approved (12c: the keys, menu and grid settings not yet tried); 12d to come |
| — | Fold a task's subtasks away in project and Inbox lists | [folding.md](folding.md) | done 2026-11-04, tried and approved (0.12.3) |
| — | Subtask progress: a pie in the parent's circle, and the offer to complete the parent | [progress.md](progress.md) | built 2026-11-05 (0.12.4); pie tried and approved, prompt trial pending |
| — | Clickable project label on grouped rows; completed subtasks settle below open siblings | [dev diary](../dev-diary.md) | built 2026-11-06 (0.12.4); project link tried and approved, settling trial pending |
| Recovery | Real-server restore/re-seed, interrupted uploads, purge boundaries, copied actual backups, GTK smoke | [recovery guide](../dev/RECOVERY.md) | passed 2026-11-12; permanent-deletion rollback and accidental-deletion limits confirmed |

## Behind the server

Server features since v0.18.0 that the client doesn't show or set yet. Their data syncs and is kept.

- **Time sectors**: shown, filtered and read by quick add (see [sectors.md](sectors.md)), but not set from the editor.
- **Multi-day tasks** (`span`, v0.19.0): Upcoming lists them by their due date, not once under their first day.
- **Sorting a view by a custom field** (v0.22.0): falls back to due date.
- Objectives, routines, themes, reusable lists, rotation, location reminders: ignored.

To catch up with a later release: check out its tag in `../opentodo`, run the tests, and port until they pass.

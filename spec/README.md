# Client spec

The parts of OpenTodo's protocol that Dustpan clients implement.
OpenTodo's own docs are the reference. This file records what we use, what we skip, and where we differ.

Pinned to **OpenTodo v0.18.0**. Local clone: `../opentodo`, beside this repo, at tag `v0.18.0`.

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
| 10 | Built-in Anytime and Completed pages, and the Filter page (the query helper) | [views.md](views.md) | done 2026-11-02; the Filter page tried and approved |
| 11 | Trash: restore, permanent deletion, offline queue and retention | [trash.md](trash.md) | done 2026-11-03; automated GTK smoke test passed, owner trial pending |

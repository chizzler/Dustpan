# Trash

Deleted tasks and projects, newest deletion first. Based on OpenTodo v0.18.0's
`internal/httpapi/trash.go`, `internal/sync/trash.go` and `web/src/lib/trash.ts`.

## Listing and restoring

- Trash is a built-in sidebar page, with an item count. It can be hidden and brought back from ⋯.
  No quick add, editing or task drop targets on this page.
- A task's descendants deleted at the same time are folded into its row. Descendants deleted separately
  have their own rows. Cycles still expose a restore target, using the ordinary display tree rule.
- A project's live tasks are hidden, not tombstoned; only the project appears for them.
- Restore is an ordinary offline-capable write, with Undo. A task clears `deleted_at` on itself and the
  subtree deleted with it; its other fields, including completion, stay unchanged.
- If its project is deleted or missing, the whole restored subtree moves to the Inbox, clearing
  `project_id` and `section_id`. The restored root's `parent_id` is cleared; child relationships survive.
  Otherwise a deleted or missing parent is cleared, as is a stale section on the root.
- Restoring a project clears only its `deleted_at`. Its live tasks become visible again; independently
  deleted tasks stay deleted, and sub-projects moved up by deletion stay where they are.

## Permanent deletion

- Delete for good and Empty Trash ask first. Empty Trash acts on the items currently listed on this device,
  not unseen items on the server. Neither operation has Undo.
- **Never connected (no server configured, and no account ever adopted):** targets and their cascades are deleted
  immediately from `fields`, `outbox`, `held_ops` and `pending_purges` in one transaction, following OpenTodo's
  `expandPurge` rules.
- **Connected, or disconnected after being connected:** requests are stored in device-local `pending_purges`
  metadata as `[entity, id]` pairs. The server may hold a copy, so a local delete alone would let it return.
  Queuing is atomic and deduplicated. Pending rows stay visible with their Restore and Delete buttons disabled.
  While disconnected, they wait for the next sync after reconnecting.
- Switching to a different account deletes pending items and their cascades locally. They belong to the old
  account and are not uploaded to the new one.
- After a successful sync exchange, send `DELETE /api/v1/tasks/{id}/purge` or
  `/api/v1/projects/{id}/purge`. Targets with unsent or server-limit-held edits wait for a later sync.
  This also works with the command-line `sync` command.
- A successful purge is followed by another sync to pull `purged` markers. Only those markers remove
  local entities and their outbox ops; the server names every cascaded entity.
- Missing or locally restored targets are dropped without a request. Server 404 and `not_deleted` also
  drop the request. Forbidden requests are dropped and reported as a sync error. Offline, authentication,
  rate-limit and server failures keep the request for retry and report the error.
- Acknowledging a request cannot overwrite other requests queued while the network call was in flight.
- Purging a project also removes its tasks and sections. Purging a task removes its deleted descendants,
  including ones deleted separately, and associated data such as reminders.

## Retention

In standalone mode, trashed items are kept until manually deleted for good. When connected, sync's
`trashRetentionDays` is remembered locally (assuming 30 days until learned; zero means kept until manually
purged). The page shows days remaining rounded up, never below zero. The server, not this client, enforces expiry.

## On the Mac (0.13.0)

The desktop's slice 11. Built 2026-11-12, tried and approved.

- `Trash.swift` ports `trash.py`; `Writer.restoreTask` and `restoreProject` port the desktop's writes. The tests are
  ports of `test_trash.py`, apart from the API's URL quoting, which was checked by hand.
- `Syncer.run` sends queued purges after the exchange and, when the server took any, exchanges again for the markers.
  The API builds each path from encoded components, so an id with a slash stays one component.
- **Sidebar:** Trash after Filter, with its item count. Hideable like the other optional pages (`hidden_pages`, key
  `trash`), from the row's menu or View ▸ Hide Trash.
- **The page:** the retention line, then one row per item with Restore and Delete for Good (also in the row's menu).
  Empty Trash… is in the toolbar. Both deletes ask first; a queued row is greyed and says "deleting for good…".
- Restore has a toast and Edit ▸ Undo. A task restored to the Inbox says so.
- Deleting a project with open tasks still asks first on the Mac (from 0.10.0); the desktop doesn't.
- **0.18.0:** standalone, as on the desktop. `purgeLocal` and `expandPurge` port the desktop's, with its tests.
  Data never connected to an account is deleted at once; once it has been, Delete for Good queues for the server, even
  disconnected. Standalone, the retention line says items are kept until deleted for good.

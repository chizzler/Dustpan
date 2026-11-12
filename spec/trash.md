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
- **Standalone (no server configured):** targets and their cascades are deleted immediately from `fields`,
  `outbox`, `held_ops` and `pending_purges` in one transaction, following OpenTodo's `expandPurge` rules.
- **Connected to OpenTodo:** requests are stored in device-local `pending_purges` metadata as `[entity, id]` pairs.
  Queuing is atomic and deduplicated. Pending rows stay visible with their Restore and Delete buttons disabled.
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

## Known standalone release blocker

**P2 — Permanent deletion after disconnect:** for previously synced items, local purge also discards the
queued tombstone and leaves no server purge request. Reconnecting does not delete the server copy, which can
return in later pulls. Retain a durable deletion record until the server acknowledges deletion. Until fixed,
keep sync configured and let permanent deletion reach the server. See [the sync review](sync.md#standalone-release-blockers-reviewed-2026-11-12).

## Retention

In standalone mode, trashed items are kept until manually deleted for good. When connected, sync's
`trashRetentionDays` is remembered locally (assuming 30 days until learned; zero means kept until manually
purged). The page shows days remaining rounded up, never below zero. The server, not this client, enforces expiry.

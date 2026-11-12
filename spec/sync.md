# Sync

What the desktop client implements from `docs/sync.md` (v0.18.0).

## Local store

One SQLite file. Every field of every entity is its own last-writer-wins register:
`(entity, entity_id, field) → (value, ts, device)`.

- The store keeps ops for entities and fields the client doesn't use yet.
  New features then need no full resync, and a re-seed sends everything back.
- `meta` holds the device id, cursor, generation, clock seed, clock offset and backfill progress.
- `outbox` holds ops waiting to upload, oldest first.

## Winner rule

An op replaces the stored field when `op.ts > cur.ts`, or `op.ts == cur.ts` and `op.device > cur.device`.
Device ids compare as byte strings.

## Clock

- A local op is stamped `max(now + offset, last + 1)`.
- Every received op moves `last` to at least its `ts`.
- After each exchange: if `|serverTime − now| > 2 s`, `offset = serverTime − now`, else `offset = 0`.
  If `last > serverTime + 5 min`, `last = serverTime`.
- `last` and `offset` persist in `meta`.

## Exchange

`POST /api/v1/sync` with `{device, cursor, ops, features, backfillAck, tzOffset}`.

1. Take up to 500 ops from the outbox.
2. Send them with the stored cursor.
3. On success: drop the sent ops from the outbox, apply returned ops, delete `purged` entities, store the cursor.
4. Repeat while `hasMore` or the outbox isn't empty.

- **Generation.** The first value seen is adopted. A different value means the server was restored: re-seed (below).
- **Backfill.** The client announces `backfill_ack` and echoes the last applied `backfillSeq` as `backfillAck`.
- **Refused ops.** `clock_skew`, `limit_…` and the rest are handled as in [writes.md](writes.md#refused-ops).
  The client announces `clock_skew`.
- **Errors.** 30 s timeout. Network failure or timeout shows "offline". Anything else shows "error".
- **Triggers.** When OpenTodo sync is configured: at start, 250 ms after a local edit, on a live wake-up, on demand,
  and every 30 s (5 minutes while the live stream is connected). In standalone mode no connection attempts or sync
  subtitles run. See [writes.md](writes.md#live-updates).

## Standalone use and connecting later

Without `OPENTODO_URL` and `OPENTODO_TOKEN`, Dustpan opens directly in standalone mode using the same SQLite store.
Local completions, default reminders and quick-add time entries use the placeholder actor `"local"`, and preference
controls write changed fields on `("user_prefs", "me")`.

When OpenTodo sync is enabled later:

1. `GET /api/v1/me` verifies the server and learns `user_id` (refusing encrypted accounts).
2. In one transaction before the first exchange, `"local"` is rewritten to `user_id` on `task.completed_by` and
   authored entities (`time_entry.user_id`, etc.), default reminder ids derived from `"local"` are renamed to
   `default_reminder_id(user_id, task_id)`, and stored fields are queued once per `(entity, entityId, field)` in
   dependency order (`project` and `task` before `reminder` and `time_entry`), without splitting an entity across
   500-op batches.
3. The exchange uploads local ops from `cursor = 0` and pulls any existing server data, merging both sides by
   per-field last-writer-wins.
4. If the local store already synced with a different OpenTodo `user_id`, automatic sync refuses with `AccountMismatch`;
   Settings offers either re-keying local entities with fresh UUIDs to upload into the new account, or replacing local
   data with the new account.

## Account switching and disconnected deletion

Two bugs were found in review on 2026-11-12 and fixed on 2026-11-13.

- **P1 — Account switching raced an active sync.** Settings could migrate or replace local data while a sync
  worker still used the old account's connection. The old response could be applied to the new data, and
  new-account tasks could be uploaded to the old account.
  - **Fix, in the app:** every account change in Settings goes through `Window.begin_account_change`. It stops
    the live stream and pending sync timers, blocks new syncs, waits for any running sync to finish, then
    changes the data and reconnects.
  - **Fix, in the sync engine:** `adopt_standalone`, `migrate_account` and `reset_for_account` bump the
    `account_epoch` meta value. A `Syncer` run pins the epoch at its start. It checks the epoch in the same
    transaction that reads each batch and applies each response. If the epoch has changed, it raises
    `AccountChanged` and keeps nothing. This also covers the command-line `sync`, which runs in its own process.
- **P2 — Permanent deletion after disconnect lost the server deletion.** Deleting a previously synced task for
  good while disconnected removed it locally and recorded nothing for the server. Reconnecting left the server
  copy, and later pulls brought it back.
  - **Fix:** only data never connected to an account (`user_id` unset or `"local"`, and no server configured)
    is deleted locally at once. Otherwise permanent deletion is queued in `pending_purges`, even while
    disconnected, and sent on the next sync. See [trash.md](trash.md#permanent-deletion).
  - Switching to a different account deletes items still waiting for a purge, with their cascades, instead of
    uploading them to the new account.

Regression tests cover each case: switching during a request, replacing during a request, switching during a
purge, deleting after disconnect then reconnecting, and switching with purges pending.

## Re-seed after a restore

In one transaction: every stored field becomes a new op `{id: new uuid, entity, entityId, field, value, ts, device}`
with the field's stored clock. Add them to the outbox, set `cursor = 0`, store the new generation.

**Full recovery pull (2026-11-12).** The server normally omits ops authored by the requesting
device. After a restore it may hold old fields this device has since purged, including fields
the device originally wrote itself. During re-seeding the request therefore uses a temporary
`reseed_device` UUID, persisted in meta until the final page and an empty outbox. The real device
identity and field clocks are unchanged. An interrupted exchange resumes with the same temporary
request identity. Once the recovery pull completes, ordinary requests use the real device again.

Skipped, as in the web app: comments, attachments and time entries by other authors, and `attachment.uploaded_at`.

**Deviation.** The server refuses a whole batch if any op has a reserved device
(`server:…`, `agent:`, `caldav:`, `public:`, `issues:`, `calsync:`, `rule:`, `page:`).
Fields written through REST carry `server:<boot id>`.
The web app re-sends them unchanged, so its re-seed would fail with 400 `invalid_op` (checked on v0.18.0 with a direct request).
This client keeps the stored `ts` and replaces a reserved device with its own.
Only the tie-break between equal timestamps changes. **Report upstream.**

**Rehearsed 2026-11-12.** The real pinned server's archive restore, generation change, client re-seed,
both reconnect orders, interrupted batches and lost upload responses pass in an isolated sandbox.
A copied production archive and client backup recover all 949 expected fields. See
[the recovery harness](../dev/RECOVERY.md) for the checks, evidence and repeatable command.

**Recovery limits.** A purge after the archive can be lost on rollback: the archive predates the
marker and clients have discarded the entity without retaining a durable purge ledger. The old
task can return. Conversely, unwanted soft deletions still held by clients are replayed after
restore; archive rollback alone does not undo a mistaken mass deletion. Both behaviors have
dedicated end-to-end scenarios and are reported as known limitations, not successful repairs.

## Not implemented yet

- Shared projects: removing projects no longer listed in `memberships`.
- End-to-end encrypted accounts.

## Display rules (slice 1)

- **Hidden:** entities with `deleted_at` set, archived projects, completed top-level tasks, tasks whose project is deleted or unknown.
- **Order:** siblings sort by `(position, id)`.
- **Project tree:** a project whose parent is missing, deleted or archived shows at the top level.
- **Task tree:** a subtask nests under its parent when the parent is visible in the same project.
  Otherwise it shows at the top level. A subtask follows its parent's section.
- **Completed subtasks:** completed children stay in project and Inbox trees under an open ancestor, dimmed and struck through.
  A broom on a parent with completed children hides those finished subtrees from the local list, with Undo.
  They remain in Completed. The local cleanup is remembered across restarts; reopening or moving a child makes it visible again.
- **Cycles:** in a parent cycle, the member whose `parent_id` has the newest clock (`ts`, then device, then id) becomes a root.
- **Sections:** a task whose `section_id` names a deleted, unknown or other-project section shows under "No section".
  "No section" comes first, then sections in order.
- **Due dates:** a zoned due shows in the local time zone.

Doc inconsistency to check: "Deletes" says deleting a project leaves its tasks' `project_id` alone.
"Trees: sub-projects" says it writes `project_id = null` on open tasks. The display rules above handle both.

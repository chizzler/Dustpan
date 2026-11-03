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
- **Triggers.** At start, 250 ms after a local edit, on a live wake-up, on demand,
  and every 30 s (5 minutes while the live stream is connected). See [writes.md](writes.md#live-updates).

## Re-seed after a restore

In one transaction: every stored field becomes a new op `{id: new uuid, entity, entityId, field, value, ts, device}`
with the field's stored clock. Add them to the outbox, set `cursor = 0`, store the new generation.

Skipped, as in the web app: comments, attachments and time entries by other authors, and `attachment.uploaded_at`.

**Deviation.** The server refuses a whole batch if any op has a reserved device
(`server:…`, `agent:`, `caldav:`, `public:`, `issues:`, `calsync:`, `rule:`, `page:`).
Fields written through REST carry `server:<boot id>`.
The web app re-sends them unchanged, so its re-seed would fail with 400 `invalid_op` (checked on v0.18.0 with a direct request).
This client keeps the stored `ts` and replaces a reserved device with its own.
Only the tie-break between equal timestamps changes. **Report upstream.**

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

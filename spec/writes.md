# Writes

What the desktop client writes, from `docs/sync.md` and the web app's `web/src/lib/ops.ts` (v0.18.0).

## One edit, one batch

Every user action becomes one batch, in one local transaction:

1. Read the current rows inside the transaction.
2. Plan the changes: `(entity, entityId, {field: value})`. Only fields the user changed.
3. Stamp one timestamp for the whole batch. Every op gets it and our device id.
4. Apply the ops to the local store (they win: the stamp is after every seen op).
5. Add them to the outbox.

Sync runs 250 ms after an edit.

Timestamps in values (`created_at`, `completed_at`) are wall-clock ms, not the hybrid clock.

## Tasks

| Action | Ops |
| --- | --- |
| Add | `title`, `description: ""`, `project_id`, `parent_id`, `priority: 4`, `due: null`, `labels: []`, `position`, `created_at`, `completed_at: null`, `deleted_at: null`, `estimate_minutes: null`, and `section_id` only when set |
| Complete | `completed_at: now`, `completed_by: me` on the task and every open descendant. A repeating task rolls forward instead: see [recurrence.md](recurrence.md) |
| Reopen | `completed_at: null`, `completed_by: null`. Only the task. Undo after a complete reopens what the complete closed |
| Rename | `title`, trimmed, never empty |
| Priority | `priority`, 1–4 (4 is "none") |
| Due | `due`. Clearing it on a repeating task also writes `recurrence: null`. Setting it on a parked task (`start: "someday"`) writes `start: null` |
| Labels | `labels`, ids in the order typed. The editor takes names: a name with no label creates one first, in the same batch |
| Estimate | `estimate_minutes`, 1–10080, or null |
| Deadline | `deadline`, a date that exists, or null |
| Delete | `deleted_at: now` on the task and every live descendant. Undo clears them |
| Move | See below |
| Reorder, nest, drop | See "Manual order" below, and [dragdrop.md](dragdrop.md) |

- **New position.** The wall time, unless some task's position is already past it: then the largest position + 1000.
- **Subtasks** take the parent's project and no section. They follow the parent's section on screen.
- **`completed_by`** is added to every batch that writes `completed_at` without it: us when completing, null when reopening.

## Moves

Moving a task to another project or section writes, in one batch:

- `project_id` if the project changed, and `project_id` on every descendant not already there
  (with `section_id: null` on any descendant that had one).
- `section_id`: the target section, or null.
- `parent_id: null` if the task was a subtask. A moved subtask leaves its parent.
- `position`: the target list's last open top-level task + 1000, or the wall time when the list is empty.

The target section must be live and in the target project. The target project must be live and not archived.

**Not handled:** shared projects. A move between sharing scopes must copy and tombstone instead,
or the server refuses it with `scope_change`. This client doesn't track memberships yet, so all projects count as personal.

## Manual order

From `docs/sync.md` ("Order rule") and OpenSpec `manual-ordering`, ported from `web/src/lib/ordering.ts` and `move.ts`.

- A list sorts by `(position, id)`. The lists are each section's top-level tasks and each parent's subtasks, open tasks only.
- Every drag ends in `Writer.drop(task_id, target)`: one batch, with an undo that puts back every field it wrote.
  Where the pointer lands, and the other targets, are in [dragdrop.md](dragdrop.md).
- A move writes the midpoint between the new neighbours: one op. When no distinct number fits, the smallest window of
  neighbours around the gap is spread evenly with the moved task. A move into another list also writes `section_id`
  or `parent_id`, in the same batch. Into another project, it also writes `project_id` on the task and its subtree,
  and clears a section left over from the old project.
- Refused: a task under itself or one of its subtasks, a section of another project, a completed task.
- A drop that changes nothing writes nothing.
- Only project pages and the Inbox can be reordered. Today, Upcoming and saved views keep their own sort.

## Reminders follow the due date

Every batch that writes a task's `due` also writes, for each live `relative` reminder of that task:

- `fire_at`: the due instant + `offset_minutes`, or null without a due.
  A date-only due counts as 09:00 local. A zoned due is its wall time in its own zone.
  A time in a daylight-saving gap moves forward to the transition; one in an overlap takes the first occurrence
  (`zoned.vectors.json`).
- `delivered_at: null` and `dismissed_at: null` when the firing time moved and they were set.

Same batch means same timestamp, so the due and the firing times always come from one edit.
Deadline reminders follow `deadline` the same way, at 09:00 local on the deadline plus the offset, and ignore `due`.
A reminder the batch already times (a new default reminder) keeps that value.
Default reminders are in [recurrence.md](recurrence.md#reminders).

## Zoned dues in the editor

The editor shows a zoned due in its own zone, with the zone named.
Editing the date or time keeps the zone. Clearing the time drops it.

## Refused ops

The server lists refused ops in `rejected`, with a reason.

- **`clock_skew`.** Our clock ran more than 5 minutes fast. Follow the server's clock, set `last` to `serverTime` if it's more than 2.5 minutes ahead (OpenTodo #651),
  stamp the refused ops again (ops that shared a timestamp share the new one) and queue them with the same ids.
  The stored field's clock follows when it still holds that op. More than 3 such rounds in one exchange is an error.
  The client sends the `clock_skew` feature.
- **`limit_…`.** A server limit, not a verdict. Hold the ops and offer them again at the next exchange.
- **Anything else** (`forbidden`, `scope_change`, `not_a_member`, …). Forget the field locally, when it still holds that op.
  The server's value, sent back in the same response, then applies. The app says how many changes weren't accepted.

## Live updates

`GET /api/v1/sync/events?device=<id>` is a server-sent event stream. An `ops` event carries only a cursor.

- On connect, sync once.
- On an `ops` event, sync when its cursor is newer than ours, or when it has none.
- On error, reconnect after 1 s, doubling to 30 s, with jitter.
- A read timeout of 60 s catches a dead connection (the server pings every 25 s).
- Polling continues: every 30 s while disconnected, every 5 minutes while connected.

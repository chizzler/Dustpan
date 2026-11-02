# Recurrence and reminders

What the desktop client implements from `docs/recurrence.md`, `docs/reminders.md` and
`docs/default-reminders.md` (v0.18.0).

## Ported, and checked against the vectors

| Our module | OpenTodo source | Vectors |
| --- | --- | --- |
| `recurrence.py` | `web/src/lib/recurrence.ts` | `recurrence.vectors.json`: parse, next, first, preview, deadline |
| `recurring.py` | `web/src/lib/recurring.ts` | covered by our own tests |
| `ids.py` | `web/src/lib/ids.ts` | the fixed values in `ids.test.ts` |
| `reminders.py` (default reminders) | `web/src/lib/defaultReminder.ts` | `defaultReminder.vectors.json` |
| `dates.py` (`due_instant`) | `web/src/lib/reminderTime.ts` | `zoned.vectors.json` |

Dates in recurrence are floating `YYYY-MM-DD` and never pass through a time zone.

## Repeating tasks

| Action | Ops, in one batch |
| --- | --- |
| Complete | The occurrence record (id `NameID("occurrence", seriesId + ":" + date)`, a copy of the series with `completed_at`, `recurrence: null`, `series_id`), and the series' next `due`. A deadline and a start date move by the same days. A habit's record has `skipped: false` |
| Complete the last occurrence | A plain completion of the series |
| Skip | The series' next `due`. A habit also writes the record with `skipped: true` |
| Split off this occurrence | A copy with id `NameID("occurrence", seriesId + ":detach:" + date)`, open, no rule, and the series' next `due` |
| Set a rule | `recurrence` in canonical form. An undated task also gets `due`: the first occurrence from today |
| Clear the due date | Also `recurrence: null` |

- **Today** is the logical today: `user_prefs.day_start` (00:00–06:00) moves the day boundary.
- **Copied fields.** The record copies title, description, project, parent, priority, due, labels, position, estimate,
  and, when set, section, deadline, start, evening, day part, energy and every `fields.<id>`.
- **Undo** writes the series' old dates back and tombstones the record or copy.
  Completing again later resurrects the same record id.
- Habit streaks and the month grid aren't shown yet.

## Reminders

- **Kinds.** The editor adds relative reminders from presets (at due time, 10 or 30 minutes, 1 hour, 1 day before),
  deadline reminders (on the deadline, 1 day before), and absolute ones from a typed time ("tomorrow 9am"),
  read with quick add. A time alone is today if it's still ahead, else tomorrow. It shows and deletes every kind.
- **Default reminders.** When a write gives a task its first due date, the batch adds the user's default
  (`user_prefs.reminder_default_timed` / `reminder_default_dated`) as an ordinary relative reminder with
  id `NameID("default-reminder", userId + "\0" + taskId)`. When the due switches between dated and timed,
  an untouched default switches too. The defaults can only be set in the web app for now.
- **Follow-ups.** Every batch that writes a task's `due` writes `fire_at` for its relative reminders,
  except ones the batch already times (a new default reminder).
- **Snooze** writes `fire_at` and clears `delivered_at` and `dismissed_at`. **Dismiss** writes `dismissed_at`.

## Desktop notifications

While the app runs, it checks every 30 s and after every change.

- **Due:** `fire_at ≤ now`, not deleted, not dismissed for this firing (`dismissed_at ≥ fire_at`),
  and the task is live and open, with no deleted project above it.
- **Once per firing per device.** The `notified` meta key maps reminder id → the `fire_at` already shown.
  On the first run, reminders that fired more than 24 hours ago are marked as seen, not shown.
- A notification is withdrawn when its reminder stops being due (dismissed or snoozed anywhere, task completed).
- Buttons: **Snooze 10 min** and **Dismiss**. Clicking the notification opens the task.
- `delivered_at` is the server's field. The client never writes it.

**Not yet:** reminders only fire while the window is open. Closing the window quits the app.

**Not yet:** on a shared project, a due change pulled from another member doesn't recompute our relative reminders.

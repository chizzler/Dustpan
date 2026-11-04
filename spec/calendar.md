# Calendar

What the desktop client implements from `docs/calendar-views.md`, `docs/place-tasks-on-the-calendar.md`,
`docs/time-blocking.md`, `docs/months-and-year.md` and the web app's `calendar.ts`, `month.ts`,
`occurrences.ts` and `span.ts` (v0.22.0).

## Decided (2026-11-04)

- **A companion window, not a page.** The calendar opens in its own window, beside the main one.
  Hyprland tiles it next to the main window; on two monitors it can live on the other one.
  The main window is unchanged, so a task can be dragged from a list onto a day.
- **A calendar icon in the main window's header** opens and closes it. Whether it was open is remembered on this
  device (`meta.calendar_open`), and it reopens with the app.
- **Month is the default view.**
- Both windows read the same store. A sync or an edit refreshes both.

## Slices

| Slice | Scope | Status |
| --- | --- | --- |
| 12a | The window and its toggle. Month: six weeks, open tasks per day, deadlines, day load. Drop a task on a day. | done, tried and approved |
| 12b | Week and Day: a time grid, blocks as tall as their estimate, the Unscheduled lane, the line for now. Drops on a 15-minute slot or the lane (brought forward from 12c). | built |
| 12c | Stretch a block to change its estimate, keyboard and menu moves on the grid, grid hours and day length in settings. | |
| 12d | Repeating tasks' coming dates (`occurrences.vectors.json`) and multi-day bars (`span`). | |
| Later | Plan (two weeks), Year, stacked months, other calendars' events. | |

## Month (12a)

Ported to `calendar.py`, from `month.ts` and `calendar.ts`.

- **Grid.** Six weeks from the first day of the week (`user_prefs.week_start`) holding the 1st.
  Today is marked. Days of other months and past days are dimmed.
- **Which tasks.** Open, live tasks due in the shown range, outside archived projects (`calendarTasks`).
  A zoned due counts on the viewer's day.
- **Order in a day.** Timed tasks first, by time. Then by priority, then position (`cellTasks`).
- **Crowded days** show as many as fit, then "+N more", which lists the rest in a popover.
  (The web app expands the day in place.)
- **Deadlines.** A ◆ with the task's title on its deadline day, unless the task is due that day
  already (`deadlineMarkers`). Never part of the load.
- **Load.** With any estimates, a day shows planned hours against the day length: "3h / 8h", red when over (`dayLoad`).
  The day length is per device, 8 hours by default (`meta.calendar_grid`, as the web app's `calendar.grid`).
- **Moves.** Drop a task on a day: it gets that date and keeps its time (`ToDay`, as in slice 6), with Undo.
  Tasks drag from the calendar as well as from the main window's lists.
- **Keys.** `[` and `]` go back and forward a month, `t` comes back to today.
- Clicking a task opens its editor.

## Week and Day (12b)

Ported to `calendar.py`, from `calendar.ts` (`blockFor`) and `layout.ts` (`layoutDay`, with its tests).

- **Switching.** Day, Week and Month in the header, or `d`, `w`, `m`. The view is remembered on this device
  (`meta.calendar_view`). `[` and `]` step by a day, a week or a month.
- **The grid** is the whole day, 48 px an hour, opened at the grid's first hour (6:00 by default,
  `meta.calendar_grid.startHour`, as the web app's per-device `calendar.grid`). Hours outside the grid are shaded.
  It keeps its scroll position across refreshes and views.
- **Blocks.** A task with a time is a block at that time, as tall as its estimate, in its project's colour
  (grey for the Inbox). Without an estimate it is drawn 30 minutes long with a dashed edge, and counts for nothing.
  A block is drawn at least 25 minutes tall. Blocks that would cover each other sit side by side; more than four
  lanes keep three and a "+N more" in the fourth.
- **Headers.** Each day shows its date, its load, its deadlines (◆) and the **Unscheduled** lane: tasks due that day
  with no time. A Week lane shows three before "+N more"; Day shows nine.
- **Now.** A red line at the current minute on today, moved once a minute. Earlier hours of today and past days are dimmed.
- **Drops** (`ToSlot`). On the grid: a ghost shows where the task will land, at the 15-minute slot under the pointer,
  as long as its estimate. The task gets that date and time, as a floating time (a zoned due loses its zone).
  On a day's header: that date with no time. On a Month day: that date, keeping the time (`ToDay`). Undo for each.

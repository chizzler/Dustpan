# Calendar

What the desktop client implements from `docs/calendar-views.md`, `docs/place-tasks-on-the-calendar.md`,
`docs/time-blocking.md`, `docs/months-and-year.md` and the web app's `calendar.ts`, `month.ts`,
`occurrences.ts` and `span.ts` (v0.22.0).

## The window

- **A companion window, not a page.** The calendar opens in its own window, beside the main one.
  Hyprland tiles it next to the main window; on two monitors it can live on the other one.
  The main window is unchanged, so a task can be dragged from a list onto a day.
- **A calendar icon in the main window's header** opens and closes it. Whether it was open is remembered on this
  device (`meta.calendar_open`), and it reopens with the app.
- **Month is the default view.**
- Both windows read the same store. A sync or an edit refreshes both.

## Parts

| Part | Scope |
| --- | --- |
| 12a | The window and its toggle. Month: six weeks, open tasks per day, deadlines, day load. Drop a task on a day. |
| 12b | Week and Day: a time grid, blocks as tall as their estimate, the Unscheduled lane, the line for now. Drops on a 15-minute slot or the lane. |
| 12c | Stretch a block to change its estimate, keyboard and menu moves on the grid, grid hours and day length in settings. |
| 12d | Not built: repeating tasks' coming dates (`occurrences.vectors.json`) and multi-day bars (`span`). |
| Later | Not built: Plan (two weeks), Year, stacked months, other calendars' events. |

## Month (12a)

Ported to `calendar_rules.py`, from `month.ts` and `calendar.ts`.

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
- A click selects a task, a double-click opens its editor (as in the main window's lists, from 12c).

## Completed tasks

- **A toggle.** The tick button in the header, or `h`, shows completed tasks too. Off by default.
  Remembered on this device (`meta.calendar_show_completed`). Works in Day, Week and Month.
- **Where.** On their due day and time. A completed task with no due shows on the day it was completed
  (local), in the Unscheduled lane. Subtasks count like any task. A habit's skipped days don't show.
- **How.** Faded and struck through. A line has a tick in place of its project dot; a block keeps its colour, faintly.
  Completed tasks come after the open ones in a day, so they are first to go into "+N more".
  On the grid too: when blocks need more than four lanes, open ones get lanes first, and completed ones
  take the gaps left (`layout_day`'s `spare`).
- **What they do.** They never count towards the day's load. They don't drag or stretch, and the arrow keys
  don't move them, as completed rows in the main window. `c` or the menu reopens one.

## Week and Day (12b)

Ported to `calendar_rules.py`, from `calendar.ts` (`blockFor`) and `layout.ts` (`layoutDay`, with its tests).

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

## Stretching, keys and settings (12c)

Ported to `calendar_rules.py` from `calendar.ts` (`resizeEstimate`, `stepEstimate`, `stepStart`, `nudgeDue`,
`normalizeGridPrefs`), with their tests. The keys follow `docs/place-tasks-on-the-calendar.md`.

- **Stretch.** Drag a block's bottom edge (the lowest 6 px; the pointer shows a resize cursor). The start stays,
  the block follows in whole 15-minute slots, from 15 minutes to a week. An unestimated block stretches from its
  drawn 30 minutes. Only the estimate is written (`Stretch`): a zoned due keeps its zone. Undo.
  The top edge is not draggable yet; Alt+Shift+↑/↓ does that from the keyboard.
- **Select.** Calendar tasks are selected like list rows: a click, or `j` / `k` through the shown tasks
  (each day's lane, then its blocks by time). Enter or a double-click opens, `c` completes, Delete deletes, Esc unselects.
  The selection holds through every rebuild; a task that leaves the view hands it to its neighbour.
- **Keys on the grid** (`grid_moves`). ↑ / ↓ 15 minutes earlier or later (an untimed task goes to the grid's first hour),
  ← / → a day either way, Shift+↑ / ↓ shorter or longer by 15 minutes, Alt+Shift+↑ / ↓ the start 15 minutes either way
  keeping the end, `u` back to the lane keeping the date. Times set this way are floating, as a drop on the grid.
  In Month only ← / → work, and keep the time (`ToDay`). A task moved off the shown range takes the view with it.
  Each move is one write with Undo.
- **Menu.** Right-click, Menu, Shift+F10 or `.`: the main window's row menu, with the grid moves (greyed when they
  would change nothing) instead of the list moves. No Labels item yet.
- **Settings.** The gear in the header: when the grid starts and ends (6:00 to 22:00) and the day length
  (8 hours; 4 to 12 hours). Per device, in `meta.calendar_grid`, read through `grid_prefs`, which repairs bad values.
  The grid opens at its start hour and shades the hours outside; the day length is what the load is measured against.

## On the Mac

The same rules and parts (12a to 12c). `CalendarRules.swift` ports `calendar_rules.py` and `grid_prefs` with the
desktop's tests; `MonthPage.swift` and `TimeGridPage.swift` gather the days. The drop targets `.slot(day, minutes:)`
and `.stretch(estimate, start:)` are the desktop's `ToSlot` and `Stretch`. Sizes are in points. Where the Mac differs:

- **The window** is a `Window` scene, "Calendar": the toolbar's calendar button, View ▸ Show Calendar (⌘K) or the
  Window menu. Quitting doesn't count as closing it (`applicationShouldTerminate` says which).
- **Single keys** (`[`, `]`, `t`, `d`, `w`, `m`, `h`) sit on the toolbar's buttons, so typing in the editor doesn't
  trigger them. The view switch is a segmented control.
- **The title** reads "9–15 Nov", "Week 46, 2026" or "Thu 12 November".
- **Headers** are pinned over the grid inside the same scroll view, so they stay over their columns whatever width the
  scroll bar takes.
- **Opening** a task shows the editor as a sheet on the calendar window. Return opens, as Enter does on the desktop.
  VoiceOver's press selects; its "Open" action opens.
- **Undo** belongs to the window an action was made in, as Mac windows do; the toast shows in the window in front.
  The grid keys use Edit ▸ Undo, with no toast.
- **The menu** opens by right-click only: SwiftUI can't open a context menu from a key, so `.` and Shift+F10 don't.
  It has Edit…, Complete or Reopen, Skip for a repeating task, the moves with their keys (Month has only Day Before
  and Day After), Due Today, Due Tomorrow, Move To and Delete.
- **Settings** are a popover from the toolbar's gear. Changing the start hour scrolls the grid to it.

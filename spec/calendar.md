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

## Apple Calendar (decided 2026-11-12)

**Keep the bespoke calendar; no Apple Calendar integration for now.** The options, for when it comes up again:

- **The server's two-way sync with iCloud** (`docs/calendar-sync.md`). Tasks become events; moving or stretching one in
  Calendar.app moves the task or changes its estimate. No client code, every device benefits. But the server holds
  an iCloud app-specific password, it brings iCloud back in, a repeating task shows only its next date, and it's
  another writer (`calsync:<id>`). Off on the live server.
- **The server's read-only feed** (`docs/calendar-feeds.md`). Calendar.app subscribes to a private URL. No password,
  can't change anything, but one-way and slow to refresh. The same feature can pull other calendars in for us to
  draw (the "other calendars' events" Later item). Off on the live server (`404 feeds_disabled`).
- **EventKit on the Mac and iPhone**, read-only: meetings shown in Dustpan's Week and Day. Native and offline, but
  Apple-only and behind a permission prompt. Writing back would duel with the server's sync.
- **Dragging between Dustpan and Calendar.app** isn't practical: at best an unlinked `.ics` copy.

Turning on either server feature means a config change on the server, only with the owner's say-so.

## Slices

| Slice | Scope | Status |
| --- | --- | --- |
| 12a | The window and its toggle. Month: six weeks, open tasks per day, deadlines, day load. Drop a task on a day. | done, tried and approved |
| 12b | Week and Day: a time grid, blocks as tall as their estimate, the Unscheduled lane, the line for now. Drops on a 15-minute slot or the lane (brought forward from 12c). | done, tried and approved |
| 12c | Stretch a block to change its estimate, keyboard and menu moves on the grid, grid hours and day length in settings. | done; stretching tried and approved, the keys, menu and settings not yet tried |
| 12d | Repeating tasks' coming dates (`occurrences.vectors.json`) and multi-day bars (`span`). | |
| Later | Plan (two weeks), Year, stacked months, other calendars' events. | |

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

## Completed tasks (2026-11-08)

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

## On the Mac (0.14.0)

Mac slice 12a: the window and Month. Built 2026-11-12, tried and approved the same day.

- `CalendarRules.swift` ports the Month part of `calendar_rules.py` and `grid_prefs`, with their tests, and a check that a
  zoned due lands on the viewer's day. `MonthPage.swift` gathers a month's days for the app.
- **A window of its own** (`Window` scene "Calendar"), opened by the calendar button in the main window's toolbar,
  View ▸ Show Calendar (⌘K) or the Window menu. Whether it's open is kept in `meta.calendar_open`; it reopens with
  the app. Quitting doesn't count as closing (the app delegate's `applicationShouldTerminate` says which).
- **Month** as on the desktop: six weeks from the week start, today marked, other months shaded, past days dimmed,
  timed tasks first, deadlines (◆), and the load against the day length from `meta.calendar_grid`. As many lines as
  the day's height allows, then "+N more" with the rest in a popover.
- **Completed tasks:** the tick in the toolbar, or h, as on the desktop (`meta.calendar_show_completed`). Faded and
  struck through, with a tick for a dot. They don't drag.
- **Keys:** [ and ] a month back and forward, t for today, as single keys on the toolbar's buttons. Typing in the
  task editor's fields doesn't trigger them.
- **Tasks:** a click selects, a double-click opens the editor as a sheet on the calendar window. Open tasks drag
  onto another day, keeping their time (`ToDay`), and from the main window's lists onto a day.
- **Undo and toasts:** each window keeps its own Undo, as Mac windows do: an action is undone in the window it was
  made in. The toast shows in the window in front.
- Week and Day (12b), stretching and the grid keys (12c), and the grid settings are still to come.

## On the Mac (0.15.0)

Mac slice 12b: Week and Day. Built 2026-11-12, checked by script, owner trial pending.

- `CalendarRules.swift` gains `blockFor` and `layoutDay` with the desktop's LayoutTest and BlockTest; `TimeGridPage.swift`
  gathers a week's or a day's columns. The drop target `.slot(day, minutes:)` is the desktop's `ToSlot`, with its write test.
- **Switching:** Day, Week and Month in the toolbar's segmented control, or d, w and m (`meta.calendar_view`).
  [ and ] step by a day, a week or a month. The title says "9–15 Nov", "Week 46, 2026" or "Thu 12 November".
- **The grid:** 48 points an hour, opened at the grid's start hour, hours outside it and the past shaded, a line each hour.
  The scroll position holds across refreshes and switching views, Month included.
- **Headers** are pinned over the grid inside the same scroll view, so they stay over their columns whatever width the
  scroll bar takes. Each has its weekday, date, load, deadlines and the Unscheduled lane (three tasks in Week, nine in
  Day, then "+N more").
- **Blocks** as on the desktop: estimate-tall, at least 25 minutes, project colour with a bar on the left, dashed and
  30 minutes long without an estimate, side by side where they overlap, the fourth lane "+N more" when crowded.
  Completed ones (with the tick on) are faded and struck through and go behind the "+N" first. A click selects,
  a double-click opens the editor, open ones drag.
- **Now:** a red line at the current minute on today, moved once a minute.
- **Drops:** on the grid, a ghost at the 15-minute slot under the pointer as long as the task's estimate; the task gets
  that date and a floating time. On a header: that date, no time. Undo for each.
- Not yet: stretching, the grid keys and menu, and the grid settings (12c).

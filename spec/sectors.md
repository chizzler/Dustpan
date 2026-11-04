# Time sectors

What the desktop client implements from `docs/time-sectors.md` and the web app's `sectors.ts`, `sectorNames.ts`
and `sectorWrites.ts` (v0.22.0).

A task's `sector` plans it for a period instead of a day: an ISO week `2026-W45`, a month `2026-11`
or a quarter `2026-Q4`. The stored value never changes by itself. "This week" and "carried over" are worked out
on each device from today and `user_prefs.week_start`.

## Ported, and checked

| Our module | OpenTodo source | Checked against |
| --- | --- | --- |
| `sectors.py` | `web/src/lib/sectors.ts`, `internal/sector` | `sectors.vectors.json` |
| `sectors.label` | `sectorNames.ts` (`sectorLabel`) | our own tests |
| `quickadd` | `internal/quickadd` (sector phrases) | `nlp/quickadd.vectors.json` |
| `filters.py` | `sector`, `no sector`, `carried`, `sector:` | `docs/filters.md`, `filter/evaluate.vectors.json` |
| `views.py` | `inbox.ts`, `views.ts` (`inAnytime`) | `inbox.vectors.json` |

## Rules

- **Placed.** A sector places a task: it leaves the Inbox and Anytime. With no date it is never overdue.
- **The date wins.** A row with both a date and a sector shows the date.
- **Rows.** A sector shows where the date would be: "This week", "Week 47", "February 2027", "Q1 2027".
  Once its period has ended it reads "From week 43", in the quiet tone, never the overdue colour.
- **One "when" at a time** (`Writer._sector_clears`, like `sectorWrites.ts`). Any batch that gives a sectored task a do-on
  date, a start or Someday also writes `sector: ""`. Choosing a sector clears `due`, `start`, `evening` and `day_part`.
  The deadline stays. A repeating task keeps its date and refuses a sector.
- **Quick add** reads "this week", "sometime next month" and the rest, in all six languages, only when
  `user_prefs.time_sectors` is `"on"`, and only on a line without a date. The page's own date (Today, an Upcoming day)
  gives way to it, as it does to Someday.

## Not yet

- Choosing a sector in the editor, and the switch itself. Both live in the web app for now.
- The Calendar's "Plan from a list" and the weekly review's sector groups (`sectors.group` is ported for them).

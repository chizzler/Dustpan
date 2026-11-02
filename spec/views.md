# Filters and views

What the desktop client implements from `docs/filters.md`, `docs/saved-views.md`, `docs/today-and-upcoming.md`
and the `view` entity in `docs/sync.md` (v0.18.0).

## Ported, and checked

| Our module | OpenTodo source | Checked against |
| --- | --- | --- |
| `filters.py` (parser) | `web/src/lib/filter/parse.ts`, `internal/filter` | every worked example and the error table in `docs/filters.md`, `internal/filter/testdata/limits.json` and `formatted.txt` |
| `filters.py` (evaluation) | `web/src/lib/filter/evaluate.ts`, `dependencies.ts` | our own tests |
| `views.py` (Inbox) | `web/src/lib/inbox.ts` | `inbox.vectors.json` |
| `views.py` (Today, Upcoming, sort, group) | `web/src/lib/views.ts` | our own tests |

There are no shared vectors for evaluation. The parser's messages match OpenTodo's word for word.
Positions count characters (code points), like the Go parser.

## The filter language

Every term in the grammar parses, so a view saved on another device never shows a parse error here
just because this client lacks a feature.

- **Evaluated:** labels, projects with and without sub-projects, priorities, every date term and period,
  the keywords, `search:`, `origin`, `energy`, day parts, `habit`, `blocked` and `unblocked`.
- **Not yet:** `available` (project flows), `tracked` (time entries), `workspace:` and custom fields.
  They match nothing and the view shows a warning, like an unknown label name. `!available` therefore matches every task.
- **Open tasks only** unless the query says `completed` or `open`, or compares the completion date.
  Deleted tasks and a habit's skipped day never match.
- **Names** ignore case and are looked up every time. Several labels or projects with one name all match.
  An unknown name matches nothing and warns.
- **Dates** compare calendar days in the device's zone. A zoned due converts first.
  `created` and `completed` count the user's day start. Weeks start on `user_prefs.week_start`; `system` reads as Monday.
- **Blocked:** a task waiting for a live, open task. In a cycle, the member whose `blocked_by` has the newest clock
  stops blocking, the same on every device.
- Tasks of archived and deleted projects are never listed.

## Built-in pages

- **Inbox:** open tasks with no project and no plan (a due date, a start date or Someday). A subtask follows a placed parent out.
  A deadline, a reminder or a label alone doesn't place a task. Planned tasks without a project are listed below,
  under **Planned, no project**, and don't count.
- **Today:** due or deadline today or earlier, or a start date that has come. A hard date beats Someday and deferral.
  **Earlier** holds tasks due before today, and passed deadlines not planned for today. Then today's tasks by time.
  Adding here makes a task due today.
- **Upcoming:** due after today, or only a deadline ahead, grouped by day. Deferred and parked tasks stay out,
  except a deferred one with no project and no due, listed on its start day. On each day, tasks due then come
  before ones with only a deadline. Adding here makes a task due tomorrow.
- **Sidebar counts** leave out parked and deferred tasks.

Today and Upcoming list subtasks on their own, with their project and parent named on the row.

## Saved views

A `view` is a query with display options. The client reads and writes these fields:

| Field | Written as |
| --- | --- |
| `name`, `query` | trimmed; the query must parse |
| `kind` | `list`. Dashboards (`dashboard`) aren't shown yet |
| `group_by` | `project`, `due`, `priority`, `label`, `none` |
| `sort_by`, `sort_dir` | `due`, `priority`, `position` (manual order), `created`, `deadline`, `title`; `asc` or `desc` |
| `show_completed` | only when true at creation |
| `pinned`, `position`, `color`, `panels`, `created_at`, `deleted_at` | at creation: pinned, last in the sidebar, the default colour, no panels |

- **Unknown values read as defaults** (`project`, `due`, `asc`) and are never rewritten. The editor writes only the fields you change.
- **Sorting.** Undated tasks stay last under a due or deadline sort, both ways. Priority descending lists p1 first.
  Ties fall back to due, priority, position and id. Manual order reads `manual_order`, then the rest by position.
  The client can't reorder by hand yet.
- **Grouping.** By project: Inbox first, then the sidebar's order, headed with the project's path.
  By due: Earlier, Today, Tomorrow, each later day, No date. By label: a task is listed under each of its labels.
- **Show completed** lists completed matches too, unless the query names a state itself. The sidebar counts open matches only.
- A query this client can't parse shows the error and no results.
- **Delete** writes `deleted_at`, with Undo.

**Reordering** (2026-11-02): drag a view in the sidebar, Move up or down in its menu, or Alt+↑ / Alt+↓.
See "In the sidebar" in dragdrop.md.

**Not yet:** dashboards and boards, `layout`, `hidden_props`, `on_drop`, `icon`, pinning, and a start view.

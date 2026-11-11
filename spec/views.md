# Filters and views

What the desktop client implements from `docs/filters.md`, `docs/saved-views.md`, `docs/today-and-upcoming.md`
and the `view` entity in `docs/sync.md` (v0.18.0; the `notes` and `sector` terms from v0.22.0).

## Ported, and checked

| Our module | OpenTodo source | Checked against |
| --- | --- | --- |
| `filters.py` (parser) | `web/src/lib/filter/parse.ts`, `internal/filter` | every worked example and the error table in `docs/filters.md`, `internal/filter/testdata/limits.json` and `formatted.txt` |
| `filters.py` (evaluation) | `web/src/lib/filter/evaluate.ts`, `dependencies.ts` | `filter/evaluate.vectors.json` (v0.22.0; tracked time and custom fields skipped), and our own tests |
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
- **Anytime** (2026-11-02): open, active tasks with no due date, no deadline and no start, by project
  (`views.in_anytime`, the web app's `inAnytime`). Adding here adds an undated task to the Inbox.
- **Completed** (2026-11-02): completed tasks newest first, under a heading per day: Today, Yesterday,
  then the weekday and date (`views.logbook`, the web app's `logbookGroups`). The day follows the user's day start.
  100 at first; **Show more** adds 100, and says how many are older. A task reopens from its check button.
  Tasks in archived or deleted projects are left out, as everywhere.
- **Filter** (2026-11-02, tried and approved): the query helper. See "The Filter page" below.
- **Sidebar counts** leave out parked and deferred tasks.

Today and Upcoming list subtasks on their own, with their project and parent named on the row.

**Anytime, Completed and Filter can be hidden, never deleted.** They're part of the app, not saved views,
so they're the same on every device and match the web app's built-in pages. "Hide from sidebar" in a page's menu
hides it on this device (store meta `hidden_pages`), with Undo. The ⋯ button above the sidebar shows or hides each.
A hidden page that's open stays listed until you leave it.

## The Filter page

Built 2026-11-02. Ctrl+F opens it with the query focused. The view editor uses the same query box (`querybar.py`).

- **Results as you type,** grouped by project and sorted by due date, with the open match count, the parse error,
  or the warnings for terms this client can't evaluate. Only the results are redrawn, so typing keeps its place.
- **Suggestions** for the word at the cursor, when it's at the end: after `@` the labels, after `#` or `##` the
  projects, otherwise the keywords with what they mean (`querytools.suggest`). Accents don't matter when typing;
  the name is written as stored. ↑ ↓ pick, Enter or Tab take, Esc hides. Names that need it are quoted.
- **+ Condition** adds a term with `&`: When, Priority, State, Label, Project (each also with its sub-projects).
  **Not** adds the opposite of the next one. A query whose top level is an `|` is bracketed first, so it keeps
  its meaning. Terms are written as the web builder writes them, and every one is tested to parse.
- **Save as view…** opens the view editor with the query filled in. It's off while the query doesn't parse.

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
- **Delete** asks first ("The view goes from every device. Your tasks stay."), then writes `deleted_at`, with Undo.

**Reordering** (2026-11-02): drag a view in the sidebar, Move up or down in its menu, or Alt+↑ / Alt+↓.
See "In the sidebar" in dragdrop.md.

**Not yet:** dashboards and boards, `layout`, `hidden_props`, `on_drop`, `icon`, pinning, and a start view.

## On the Mac (0.12.0)

Anytime, Completed and the Filter page, from the desktop's slice 10. Today, Upcoming and saved views came in 0.4.0.

- `Views.swift` gains `anytimeGroups`, `logbook` and `filterResults`; `QueryTools.swift` ports `querytools.py`.
  The tests are ports of `test_querytools.py`.
- **Sidebar:** Anytime, Completed and Filter under the Inbox. "Hide from Sidebar" in a row's menu, or View ▸ Hide …,
  writes the same `hidden_pages` meta as the desktop, with Undo. View ▸ Show … brings a page back: the Mac's
  place for the desktop's ⋯ menu. The desktop's Trash key in that list is kept but not shown yet.
- **Filter** is View ▸ Filter… (⇧⌘F). ⌘F is Edit ▸ Find and ⌥⌘F Find and Replace, from `TextEditingCommands`.
  Opening the page puts the focus in the query; the sidebar leaves it there. The query lives in the app model,
  so it's kept while other pages are shown, as on the desktop, but not across launches.
- **Suggestions** use SwiftUI's `textInputSuggestions`: the system's list under the field, ↓ ↑ and Return to take one.
  Offered only with the insertion point at the end (the field's `TextSelection`).
- **+ Condition** is a menu of the same groups; **Not** is a toggle button beside it, as on the desktop.
  After a condition, the insertion point goes to the end.
- Results are worked out as you type, without the desktop's 150 ms pause: SwiftUI redraws only the list.
- **Show More** on Completed adds 100 at a time, while the page is open.
- The view editor's query field is the same `QueryField`.

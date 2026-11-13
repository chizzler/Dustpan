# Labels

Status: built 2026-11-02 (slice 9), tried and approved. Dropping a task on a label added the same day.

OpenTodo's rules are in `openspec/specs/labels/spec.md` and `docs/sync.md` ("Task labels"). The web app's code is
`web/src/lib/labels.ts`. A label has `name`, `color`, `position`, `created_at` and `deleted_at`.
`task.labels` is an array of label ids, written whole: last writer wins for the array.

## On a task

- **Rows show chips:** the label's solid tag in its colour, 10 px, then its name. The editor's chips match. Two at most, then "+n", whose tooltip names them all.
  On a label's own page, that label's chip is left out. Ids of deleted or unknown labels are kept but not shown.
- **The picker** opens with `L` (or Shift+L) on a selected task, "Labels…" in its menu, or + in the task editor.
  - Type to find: name start first, then word start, then anywhere, then the letters in order. Case and accents are ignored.
  - With nothing typed: labels assigned lately on this device first (store meta `recent_labels`), then sidebar order.
  - ↑ ↓ move, Enter adds or removes the highlighted label and clears the search for the next one. Click does the same.
    If no label has the typed name, the last row is "Create label …".
  - Esc closes. From a row, the changes are written as **one batch when the picker closes**, with one toast and Undo,
    and the task keeps the focus. In the editor they're written on Save, like its other fields.
  - The search has no delay, so Enter always acts on what was typed.
- **Every write reads the task's current array first**, in the same transaction (`Writer.change_task_labels`),
  so edits in a row on this device never lose a label.
- **The editor** shows chips with ×, and + for the picker. `L` opens it when no text field has the focus.
  The old comma-separated field is gone.
- **Quick add** still takes `@label`. On a label's page, it also gives the task that label.

## In the sidebar

- **Labels**, between Projects and Views, lists live labels by position, with their open-task count.
  + makes a new label. A label whose name another shares shows a warning: merge them from its menu.
- **Each label shows a solid tag** in its colour, not a dot or a line icon, so it never looks like a project.
  The label picker and a label's page heading show the same tag ([icons.md](icons.md#the-desktop)).
- **A label's page** lists its open tasks across projects. They're grouped by project unless the label's own
  `group_by`, `sort_by` and `sort_dir` say otherwise, as the web app reads them. An empty page says how to add tasks.
- **The menu** (right-click): Edit label…, Move up, Move down, Merge into…, Delete….
- **Reorder** by dragging a label in the sidebar, or Alt+↑ / Alt+↓ on a focused one (dragdrop.md, "In the sidebar").
  The pencil on a label's page opens the editor, which also has Merge and Delete.

## Dropping a task on a label

- **Drag a task onto a label in the sidebar** to add that label (`dragdrop.ToLabel`). Its other labels, its place,
  project and dates stay. The toast says "Added errand", with Undo.
- **A task that already has the label** is left alone, and the toast says "It already has errand".
- **Label rows don't open on hover** during a drag, as project rows do: a label's page has nowhere to place a task.
- `L` stays the keyboard way.

## Managing

| Action | Writes | Undo |
| --- | --- | --- |
| New label | name, the first unused colour, `position` = now, `created_at`, `deleted_at: null` | — |
| Rename, recolour | one op per changed field. No task is written | yes |
| Move up or down | `position`, with the shared midpoint rule (`ordering.plan_move`) | yes |
| Delete | the id taken off every live task, one op each, then `deleted_at` | yes |
| Merge into | every live task with the source carries the target instead, once; then the source's `deleted_at` | yes |

- **Names are unique, ignoring case.** Creating or renaming to a name in use is refused, naming the existing label.
  Duplicates made on two devices offline both stay, with the warning above.
- **Delete asks first** when tasks carry the label, and says how many. With none, it just deletes, with Undo.
- **Merge** picks the label to keep by typing, never the label itself, then confirms with both names and the number
  of tasks that change.
- **Colours** are the web app's twelve (`LABEL_COLOURS`), with names for tooltips and screen readers.

## Not done

- Pinning labels to a Favourites group (`user_prefs.favourites`).
- A labels overview page, and `@` completion in quick add.

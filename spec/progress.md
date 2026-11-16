# Subtask progress

What the desktop client implements from OpenSpec `subtasks` ("Parent progress", "Completing a parent"),
`docs/notes-and-subtasks.md` and the web app's `lib/subtasks.ts` and `TaskRow.tsx` (v0.22.0).

## Upstream

- A task with at least one subtask that isn't deleted shows "done/total" over its **direct** subtasks (`progressOf`).
  Completed subtasks count; deleted ones don't. Grandchildren count only on their own parent.
- The web row shows it as text, "3/5", in the quiet group of counts at the end of the row (calm-rows D7).
  Its accessible label is "3 of 5 subtasks completed".
- It's computed from local data on every page, so it works offline and updates when another device syncs.
- Ticking the last open subtask doesn't complete the parent. It offers to, and Enter accepts.

## Where we differ

- **A pie in the check circle.** The count is in the tooltip. The row also shows "3/5", as upstream.

The list behavior otherwise follows upstream.

## Rules

- **Which tasks.** Every open task with at least one direct subtask that isn't deleted. That's on every page that
  shows its row: project lists, the Inbox, Today, Upcoming, Anytime, saved views and Filter.
  The pie belongs to the task, not the page, so it looks the same everywhere. A subtask with its own subtasks gets one too.
- **What counts.** Direct subtasks that aren't deleted, done or open, as `progressOf` counts them.
  Subtasks swept away by the broom still count. Sweeping tidies the list; it doesn't undo work.
  Without them the pie would shrink when you sweep. The web app has no broom and counts them too.
  Subtasks in other projects or hidden by the page's filter count as well.
- **The pie.** A wedge from 12 o'clock, clockwise, filling done/total of the circle's inside.
  It sits inside the border with a small gap, so the border still reads as the circle.
  It's filled in the circle's colour: the priority colour for P1 to P3, else the plain border colour.
- **None done.** A faint inner ring in the same colour, where the pie would be. It marks the task as a parent.
- **All done.** A full disc. The task is still open, so the circle keeps its normal border.
- **Hover and focus.** The pie fades back and the tick shows over it, as on every other circle.
- **Done parents** show the normal done circle with no pie. Completing a parent completes its subtasks anyway.
- **Tooltip and screen readers.** "Complete (c)" gains a second line, upstream's words: "3 of 5 subtasks completed".
  With swept subtasks: "3 of 5 subtasks completed (2 swept)".
  The accessible description says the same, so the count is never only in the picture.
- **Live.** The pie changes when a subtask is ticked, reopened, added, moved, deleted or synced.

## Completing the last subtask

Upstream's prompt, as part of this slice.

- Ticking the last open direct subtask of an open parent shows a banner at the top of the list:
  "All subtasks of "Plan trip" are done" with a Complete button. Enter accepts while it shows; Esc dismisses it.
  Nothing is written until you accept.
- A banner, not a toast, because the tick already shows its own Undo toast. Upstream also uses a list prompt,
  not its toast.
- Never automatic, as upstream (design D5: an add on another device could race it).
- Only for the subtask's own parent. Accepting doesn't ask again for the grandparent.
- The banner goes when you undo the tick, change page, or the parent stops being ready (a new subtask syncs in).

## Code

`model.progress_map` (a port of `progressMap`), `is_ready` and `ready_parent` (`parentReadyToComplete`) are pure,
and tested with upstream's scenarios. `widgets.Pie` draws the pie with a Gsk path under the tick image:
GTK CSS can't draw a pie for any fraction.

## Not done

- Progress in the task editor's subtask list. Upstream shows it there too.
- Progress on calendar blocks.
- A setting to turn the pie off.

## On the Mac

`Subtasks.swift` ports `progress_map`, `is_ready`, `ready_parent`, `sink_completed` and the broom's
record, with their tests; `projectSections` takes the swept subtasks and the settling ones.

- **The pie** as on the desktop, drawn as a SwiftUI shape over the check's circle: a faint ring for none done, a wedge,
  a full disc for all. "3/5" after the row's details. The tooltip and VoiceOver's value say "3 of 5 subtasks completed".
  No hover tick: the Mac's circles don't show one.
- **The offer** is a bar along the top of the page. Complete is **⌘Return**, not Return: as a window shortcut, plain
  Return took the Add field's own, and the list's table keeps Return to itself. Esc dismisses it.
- **The broom** on an open parent with completed subtasks showing, in project and Inbox lists. Undo in the toast and
  Edit ▸ Undo. Stored in the desktop's `meta.cleared_completed_subtasks`.
- **Settling:** a ticked or reopened subtask keeps its place until 2 s after the last tick on the page, then they all
  move together, animated. Another page settles at once.
- **The project label** on Today, Upcoming and the other grouped pages is a button: it opens the task's project or the
  Inbox, unfolds the way down to the task, and selects and flashes it.

# Drag and drop

Slice 6. Drag a task to change where it lives: its place in a list, its parent, its section, its project, its date or its labels.
Status: designed 2026-11-01. 6a built 2026-11-01, tried and approved. 6b built 2026-11-01, tried and approved. 6c partly built: the sidebar, 2026-11-02.
The Mac client's slice 6a (2026-11-06) follows the same rules; see "On the Mac" at the end.

## What slice 5 had

- Each task row in a project or the Inbox is a drag source and its own drop target.
- The top half of a row places before it, the bottom half after it, at the row's own level.
- A section heading places at the top of that section.
- `Writer.move_task` writes the parent, section and position in one batch, with the web app's midpoint rule.

**Problems with this:**
- You can't nest a task under another, or pull a subtask out to a shallower level.
- You can't drop onto a project, the Inbox or Today in the sidebar.
- You can't drop into an empty section's end, or below the last task of a section.
- Each row has its own target, so the marker flickers off in the gaps between rows.
- The list doesn't scroll when you drag near its edge, so long lists can't be crossed.
- No Undo after a drop, and nothing shows where the task landed.
- The drag can't be done any other way, by keyboard or menu.

## What the best apps do

**OpenTodo's web app** is the reference, because it writes the same data.
- **Three zones on a row** (`web/src/app/listDrop.ts`): the top quarter places before, the bottom quarter after, and the middle half nests inside, as the last subtask.
  Below an open parent, "after" means the top of its subtasks, since that is where the line shows.
- **Sidebar drops** (`taskDrop.ts`): onto a project or the Inbox moves the task, like Move. Onto a label adds the label.
  If the task already has the label, nothing is written and the toast says so.
- **Date drops** in the planner and month views: the due date changes to that day, and the time and zone are kept.
- **Today's day-part headings**, and **board columns with an on-drop rule** (`view.on_drop`): a drop writes that rule's fields.
- **Not draggable:** Today, Upcoming and other sorted pages don't reorder by hand. Position only breaks ties there.
- **Feedback:** the dragged row lifts. The drop place shows as a line with a dot at its start. A drop inside rings the row.
  In the sidebar tree, the line starts at the indent of the level the item will land on.
- **Escape**, or a drop outside any list, cancels without writing.
- **Keyboard:** Alt+Up and Alt+Down move one place, and with Shift to the top or bottom. Tab indents under the task above. Shift+Tab outdents.
- **Every move is one batch with one Undo.**

**Todoist.** Dragging a task right under another makes it a subtask. Dragging left makes it a parent task again.
In Upcoming, dragging a task to another day reschedules it. Nesting by drag is off while a list is sorted.

**Things 3.** Drop to-dos on a list in the sidebar to move them. Select several first and they all move together.

**Workflowy.** Drag a bullet one step right to indent it. Its children travel with it.

**OmniFocus.** Drop an item onto another to nest it. A line shows whether it will land beside the item or inside it.
Rows dropped on a sidebar project join that project.

**Fizzy (37signals).** Cards move only between columns, never up or down inside one.
The lesson: where order means nothing, a drag changes a category, not a position. Dragging a card out of Done reopens it.

**Atlassian Pragmatic drag and drop** has the most complete published rules.
- **Hitbox table:** with before, inside and after all allowed, a row splits a quarter, a half and a quarter. With only before and after, it splits in half.
  A blocked operation still shapes the zones, so they don't jump around.
- **Reparent:** at the bottom edge of the last item in a nested group, the pointer's horizontal place picks the level to land on.
- **Trees:** treat each level as its own list. Don't offer "after" on an open parent.
- **Hover:** a collapsed item opens after 500 ms of hovering in its middle.
- **Drag preview:** at most 280 × 280 px, with at most three pieces of information. Several items stack, with a count.
- **Source row:** stays in place at 40% opacity.
- **Line marker:** 2 px in the accent colour, with an 8 px dot at its start. It sits in the middle of the gap between items.
  An empty list shows no line; its area is highlighted instead.
- **After the drop:** update at once. Flash the moved item's background for 700 ms. Open any parents needed so it stays in view.
- **Accessibility:** every drag outcome also sits in the item's menu. Announce what moved, from where and to where. Keep focus on the moved item.

**dnd-kit's sortable tree** computes depth from the sideways offset: offset ÷ indent width, rounded.
The result is clamped. It can't be deeper than the row above's depth + 1, or shallower than the row below's depth.

**Apple's guidelines.**
- Offer another way to do every drag.
- Let people undo a drop.
- Scroll a list when a drag nears its edge.
- Highlight a destination only while it can accept the drop.
- "Spring loading": hovering over a target opens it.
- Keep the dropped item selected afterwards.

**WCAG 2.2, SC 2.5.7** requires a single-pointer alternative to every drag, such as a menu or buttons. Keyboard access is a separate requirement.

**GTK.** `GtkScrolledWindow` doesn't scroll during a drag; apps write it themselves.
Nautilus used a 30 px edge with 100 ms steps. Earlier it widened the edge from 20 to 50 px, because people didn't find it.

**Concurrent moves.** Kleppmann's move operation for replicated trees is the rigorous answer to two devices moving the same subtree.
OpenTodo uses per-field last-writer-wins instead. Its display rule breaks a cycle the same way on every device: the task whose parent clock is newest goes to the top level.
We already do the same (slice 1). The server's model is fixed, so we follow it.

## Design

### One rule: a drop is a placement

Every drop resolves to one target. Each target turns into one batch of ordinary field writes, with one Undo.

| Target | Writes |
| --- | --- |
| Gap in a project or Inbox list, at a level | `parent_id`, `section_id`, `position` (the midpoint rule) |
| Inside a row | `parent_id` = that row, as its last subtask |
| End of a section (the gap above "Add task") | `section_id`, last position |
| Section heading | `section_id`, first position |
| Sidebar project | `project_id`, no section, no parent, at the end; the subtree follows |
| Sidebar Inbox | `project_id` = null; the subtree follows |
| Sidebar Today | `due` = today, keeping any time and zone |
| Upcoming day heading | `due` = that day, keeping any time and zone |
| Saved-view group heading (later) | the grouped field: priority, due date, project, or add the label |
| Saved-view row in manual order (later) | `view.manual_order`, never the task's own position |

These rules hold for every target:
- A subtask moved to another project takes its whole subtree, with one op per task.
- A task can't go under itself or its own subtasks. Such a target shows no marker and accepts nothing.
- Only open tasks drag.
- Completed rows, and the rows of tasks you may not edit, never start a drag.
- A date drop on a parked (Someday) task un-parks it, as editing the due does now.
- A drop that changes nothing writes nothing. A label the task already has is shown with "Already has @x" and no Undo.

### Where the pointer lands

A pure function decides the target from the visible rows and the pointer. GTK passes in numbers, and tests can call it without a window.

1. **Find the row.** Pick the row under the pointer by its bounds. Between rows, take the nearer one.
   One drop target covers the whole list, so the marker never drops out in the gaps.
2. **Pick the zone**, as in OpenTodo:
   - top quarter: before;
   - middle half: inside;
   - bottom quarter: after.
   Below an open parent, "after" means the top of its subtasks.
3. **Pick the level**, as Atlassian's reparent and dnd-kit do.
   Where the gap after a row closes several levels (a last subtask with a shallower row below it), the pointer's sideways place picks the level.
   The level is the pointer's x ÷ the indent width (24 px), rounded.
   It is clamped between the depth of the row below and the depth of the row above.
   So dragging left outdents, and dragging right stays in the group, as in Todoist and Workflowy.
4. **Map to a placement** (`Place`): project, section, parent, and before or after a sibling. `Writer.drop` writes it.

### What the user sees

- **Drag preview:** a small pill with the task's title. With subtasks, it adds "+3". It replaces today's full-row snapshot.
- **The source row** dims to 40% while it is dragged.
- **The drop line:** 2 px in the accent colour, with an 8 px dot, drawn in an overlay over the list.
  It starts at the indent of the target level, so the level is visible. A drop inside rings the row instead.
- **Sidebar rows and headings** highlight while they would accept the drop.
- **Spring loading:** holding a drag over a sidebar project for 700 ms opens its page, so the task can be placed exactly. This follows macOS and the Pragmatic hover delay.
- **Autoscroll:** within 50 px of the list's top or bottom edge, the list scrolls. Speed grows towards the edge.
- **Cancel:** Escape cancels, and so does dropping outside a target (GTK does both). Nothing is written.
- **After the drop:**
  - the moved row flashes for 700 ms and is scrolled into view;
  - a toast names the change, such as "Moved under Plan trip" or "Due Thursday", with Undo;
  - Ctrl+Z undoes it too.

### Other ways to do the same thing

Each target above also has a way that needs no drag. This covers WCAG 2.5.7 and keyboard use.

The keys follow the web app's list shortcuts (`web/src/lib/shortcuts.ts`). `nudge()` in `dragdrop.py` turns a key into the
same `Place` a drag would give, so both go through `Writer.drop`, with the same toast and Undo.

| Key on a focused task | Does |
| --- | --- |
| ↑ ↓, or k j | Focus the task above or below |
| Alt+↑, Alt+↓ | Move it one place among its siblings. Nothing at the edge |
| Alt+Shift+↑, Alt+Shift+↓ | Move it to the top or bottom of its siblings |
| Tab | Make it the last subtask of the sibling above |
| Shift+Tab | Outdent it, to right after its old parent |
| Enter | Open it (so does a double-click) |
| c | Complete it, or reopen a completed one |
| l, Shift+L | Its labels: the picker (see labels.md) |
| Delete, Backspace | Delete it, with Undo |
| Menu, Shift+F10, `.` | Open its menu |
| Esc | Clear the selection |
| Ctrl+Z (anywhere) | The Undo of the toast on screen |
| j, k (no task focused, not typing) | Focus the first or last task, as in the web app |

- **A click selects a task; a double-click or Enter opens it,** as in Things and file managers. Opening on every click
  fought the keys. The selected task is the focused one, with a soft highlight whether chosen by mouse or keyboard,
  plus a ring when the keyboard is in use. A rebuilt page keeps the selected task. After a move or drop the task
  stays focused; after a completion or delete, the next task is.
- **Rows are `TaskRow`s.** A focusable `Gtk.Box` is never a Tab or arrow stop in GTK 4. Its focus handler only
  tries its children. `TaskRow.do_focus` takes the focus itself.
- **The row menu** (right-click, or the keys above) lists Open, Complete, then the six moves with their keys
  (greyed out where they can't go), Due today, Due tomorrow, Move to (the Inbox and each project, with its sections),
  and Delete last. One click does each, which covers WCAG 2.5.7.
- **On Today, Upcoming and saved views** the moves aren't offered, as in the web app. Tab moves focus there as usual.
- **Differs from the web app:** Shift+Tab puts the task right after its old parent, as dragging it left does.
  The web app puts it last among its new siblings, which can send it far down a long list.
- **Not done:** a parent picker. Tab, Shift+Tab and dragging cover nesting.

### Code layout

| File | Holds |
| --- | --- |
| `dustpan/dragdrop.py` | Pure rules, with no GTK. Zone and level from the pointer, target to placement, and the toast text. |
| `dustpan/dragging.py` | GTK glue: the list drop target, the overlay line, autoscroll, spring loading, the drag pill. |
| `dustpan/writes.py` | `Writer.drop(task_id, target)`: one batch per target, from `_plan_place` and `_plan_edit`, with an undo built by `_undoable`. |
| `dustpan/rowactions.py` | GTK: focus, keys and the menu on each task row |
| `app.py` | Builds the targets, and records each row's id, depth, parent and section for `dragdrop.py`. |

The GTK signal handlers stay thin. They call `hover(x, y)` and `drop(x, y)` on `PageDrop` and `SidebarDrop`, and a test driver can call those too.
That way most of the drag path runs in scripted checks, even though a script can't produce a real pointer drag.

## Plan

**6a, nest and place by drag.**
- The one-target list.
- The three zones, and level by x.
- The overlay line and ring, the drag pill and the dimmed source.
- Autoscroll, end-of-section drops, the flash, and the toast with Undo.
- Sidebar drops on projects, the Inbox and Today, with spring loading.
- Upcoming day headings.
- Rows in Today, Upcoming and saved views drag to the sidebar and to day headings, but don't reorder there.

Built 2026-11-01 as planned, with these additions:
- Today's "Today" heading takes drops too, so an overdue task can be dragged up to today.
- A background sync waits until the drop, so the page isn't rebuilt under the pointer.
- A new toast replaces the one on screen, so Undo always means the latest action.
- Drags from other apps are ignored: text dragged in is never read as a task id.

**6b, without a pointer.**
- Focusable rows, Alt+arrows, Tab and Shift+Tab.
- The row menu with Move to, and Ctrl+Z.

Built 2026-11-01 as planned, plus ↑ ↓ (j k), Enter, c and Delete on a focused task, and Due tomorrow in the menu.

**6c, later.**
- ~~Drag projects in the sidebar to reorder or nest them, with the same zones.~~ Done 2026-11-02, with labels and views:
  see "In the sidebar" below.
- Saved-view group headings, and `view.manual_order`.
- ~~Labels in the sidebar as drop targets.~~ Done 2026-11-02, with slice 9 (see labels.md).
- Several selected tasks dragged together, with a count.
- `view.on_drop` rules, once boards exist.

## In the sidebar

Built 2026-11-02. Projects, labels and views can be dragged within their own group. OpenTodo's specs:
`project-organization` ("Move a project", "Cycle prevention"), `labels` ("Reorder labels by drag and by keyboard"),
`custom-views` ("Pinned views in the sidebar").

- **Projects** use the task zones: the top quarter of a row places before it, the bottom quarter after it,
  the middle half nests inside, as the last sub-project. After a project whose sub-projects are shown
  means above its first sub-project, where the line is drawn. A project never goes under itself or below it.
- **Labels and views** use halves: before or after. They don't nest.
- **Only its own kind.** A dragged project ignores label rows, and so on. A dragged row is never a task drop,
  and a task is never a row drop: the row drag (`ItemDrag`) is separate from the task drag.
- **Feedback** on the row under the pointer: a line along its top or bottom edge, or a ring for nesting.
  The task drag's spring (holding a row opens its page) is off for row drags.
- **One batch, with Undo.** A project's parent, when it changes, and the positions, with the shared midpoint rule
  (`ordering.plan_move`). The toast says "Order changed", "Moved “Work” under “Home”" or "… to the top level".
- **Without a pointer:** Move up and Move down in each row's menu (greyed at the ends), and Alt+↑ / Alt+↓ on a
  focused row. Both stay among its siblings and keep the focus. A project's parent is changed in its editor.
- Views got a menu for this: Edit view…, Move up, Move down, Delete. Dashboards aren't listed and keep their positions.
- Rules: `dragdrop.place_item` (no GTK). Writes: `Writer.place_project`, `move_project`, `place_label`, `move_label`,
  `place_view`, `move_view`. Tests: `tests/test_sidebar_order.py`.

## Tests

- **Zones:** a table of pointer positions to before, inside or after. It also covers the "after an open parent" rule.
- **Levels:** clamping at the end of a nested group, from Pragmatic's reparent and dnd-kit's projection.
- **Targets:** each one maps to the expected ops, including subtrees across projects and a refused drop under itself. Undo restores the old values.
- **Scenarios from OpenSpec:** `manual-ordering` ("Ordering within sections and parents"), `subtasks` ("Move between parents", "Cycle prevention") and `labels` ("Drop a task on a label").
- **Live check:** every target on the dev server. Refused must be 0, and REST must read back the same values.
- **By hand:** the drag itself, since a script can't produce one.

## Sources

- OpenTodo v0.18.0: `web/src/app/listDrop.ts`, `taskDrop.ts`, `lib/dnd.ts`; OpenSpec `manual-ordering`, `subtasks`, `labels`, `task-list-presentation`, `planner-view`, `month-view`, `custom-views`, `day-parts`.
- [Atlassian: Pragmatic drag and drop hitbox](https://atlassian.design/components/pragmatic-drag-and-drop/optional-packages/hitbox/about)
- [Atlassian: design guidelines](https://atlassian.design/components/pragmatic-drag-and-drop/design-guidelines)
- [Atlassian: accessibility guidelines](https://atlassian.design/components/pragmatic-drag-and-drop/accessibility-guidelines/)
- [Apple HIG: drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)
- [W3C: Understanding SC 2.5.7 Dragging Movements](https://www.w3.org/WAI/WCAG22/Understanding/dragging-movements)
- [Smart Interface Design Patterns: drag-and-drop UX](https://smart-interface-design-patterns.com/articles/drag-and-drop-ux/)
- [Todoist: sub-tasks](https://todoist.com/help/articles/introduction-to-sub-tasks)
- [Todoist: Upcoming view](https://todoist.com/help/articles/360000031019)
- [Things support: moving to-dos](https://culturedcode.com/things/support/articles/2803582/)
- [Workflowy: drag bullets to indent them](https://blog.workflowy.com/moving-bullets-is-now-easier-than-ever/)
- [OmniFocus 4 manual: the outline](https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-outline/)
- [Fizzy help: moving and prioritising](https://help.fizzy.do/3/fizzy-help-guide/50/moving-prioritizing.md)
- [dnd-kit sortable tree utilities](https://app.unpkg.com/dnd-kit-sortable-tree@0.1.73/files/src/utilities.ts)
- [GNOME Discourse: autoscroll during drag and drop](https://discourse.gnome.org/t/gtkscrolledwindow-auto-scroll-during-drag-n-drop/5727)
- [Nautilus DnD cleanup (old autoscroll constants)](https://lists.gnome.org/archives/commits-list/2022-June/msg10671.html)
- [Kleppmann et al.: a highly-available move operation for replicated trees](https://martin.kleppmann.com/2021/10/07/crdt-tree-move-operation.html)

## On the Mac

Mac slice 6a, 2026-11-06. `DragDrop.swift` ports the rules here (`Placement` is the desktop's `Place`, which
the Swift code already used for a project and section), and `Writer.drop` ports `Writer.drop`. The tests are ports.

**The SwiftUI list** (the default):
- **Each row is its own drop target** (`ListDrop`, an `onDrop` delegate), and so are a section's heading and its
  Add field (the end of the section). The pointer's y in the row picks the zone, its x the level, as above.
  Leaving a target keeps the mark for 150 ms, so it doesn't flicker in the gaps between rows.
- **The whole row width drags**, so a press-and-drag beside the text never selects the rows it crosses.
  Esc clears a selection.
- **The grab point** comes from the pointer's last hover position over the row, since `onDrag` doesn't give one.
- **The drag ends** when the mouse button is up: `onDrag` reports no end, so its source watches the button.
  macOS 26's `onDragSessionUpdated` and `onDropSessionUpdated` would report both, with `draggable(containerItemID:)`;
  not used yet.
- **Autoscroll** is whatever the system list does during a drag. Not written by hand.

**The `NSOutlineView` spike** (View ▸ Outline Task List, project and Inbox pages only), added 2026-11-07:
- AppKit draws the drop line or ring, proposes a parent and child index, scrolls, and opens collapsed rows on hover.
- `resolveDrop(_:projectId:sectionId:parent:before:inside:moving:)` turns that proposal into the same `Drop`,
  so both lists share one rule. Section headings are flat group rows, and a drop on one means the top of its section.
- The outline view reports the drag's start and end itself.
- Not there yet: the row menu, keys, an Add field per section, the label picker, the Inbox's planned tasks.

**Why the spike:** SwiftUI's own list moves (`onMove`, macOS 27's `reorderable`) are flat, with no "inside" and no
level, and nested drag and drop in a SwiftUI `List` has a poor record. `NSOutlineView` is where macOS does tree
drag and drop. Whether the task list moves to it is still open.

**The sidebar** (Mac 0.8.0, 2026-11-07), as "In the sidebar" above:
- **Projects** drag with their own drag, apart from the task drag. Each project row is one drop target for both:
  a task moves into the project, as before; a project lands by the row's zones through `placeItem`, with a line
  along the row's top or bottom edge or a ring to nest. Over itself or its own sub-projects it's refused.
- **Views and labels** reorder with SwiftUI's `onMove`, which is flat and enough for them. Labels already did.
- **Without a pointer:** Move Up and Move Down in each project's and view's menu, as labels have, and ⌥↑ ⌥↓ on the
  selected project, view or label. A project's parent changes by drag only: the Mac has no project editor yet.
- Writes: `Writer.placeProject`, `moveProject` and `moveView`; labels share their helpers. Tests: `SidebarOrderTests.swift`.
- A project drop toasts as the desktop's does. Moves by menu, key or `onMove` have Edit ▸ Undo and no toast, as labels had.

Escape and drops outside a target cancel, as before. Calendar targets don't exist on the Mac yet; 6b (keys and
the row menu's moves) comes later.

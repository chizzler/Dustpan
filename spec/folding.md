# Folding subtasks

What the desktop client implements from `docs/notes-and-subtasks.md`, `docs/keyboard.md` and the web app's
`TaskRow.tsx` and `useListModel.ts` (v0.22.0). Built 2026-11-04 (0.12.3), tried and approved.

## Rules

- **Where.** Project and Inbox lists, the only pages that show subtask trees. Any task with subtasks shown
  under it can fold, done ones too.
- **The leading slot.** Every task row, on every page, has the same 16 px slot before its check, so checks line up
  across tree and flat lists ("One row anatomy" in the web app). A parent shows a chevron there: › folded, ⌄ open.
  It never takes the keyboard focus.
- **Folded rows** show how many open subtasks are folded away ("3 subtasks"), counting every level.
- **Keys** (`rowactions.KEYS`). → unfolds; ← folds. ← on a task with nothing to fold (or already folded) goes to its parent.
  The web app's → also opens a row's details; we have no row details, so a second → does nothing.
- **Menu.** "Fold subtasks" or "Unfold subtasks", with its key, under Labels.
- **Stored on this device**, never synced: `meta.folded_tasks`, a list of task ids, as the web app keeps
  `opentodo.collapsed` in the browser. Ids of tasks that are gone are dropped at the next fold or unfold
  (`model.folded_after`).
- **Focus.** Folding away the focused subtask (with the chevron) puts the focus on the folded task.
- **Drops and moves.** A folded task's subtasks are left out of the list's slots, so a drop or a keyboard move
  treats it as a leaf: a drop after it lands beside it, never among its hidden subtasks.
  A drop inside it, or Tab under it, unfolds it and every task above it first (`model.unfolded_down_to`), so the
  moved task stays in sight. Other folds stay as they were.

## Not done

- **Opening a folded task while dragging over it** (500 ms, `spec/dragdrop.md`). The page doesn't rebuild during a
  drag, by design (`Window.refresh_view`), so a drop inside still works, and unfolds it.
- Fold all and Unfold all.
- Folding in the task editor's subtask list.

## On the Mac (0.12.1)

- **The same rules,** with these differences. `Folding.swift` ports `folded_after` and `unfolded_down_to`, with their
  tests, and `openSlots` leaves a folded task's subtasks out.
- **The leading slot** is only on project and Inbox lists, the pages with trees. The Add field lines up with it.
- **Keys.** ⌘← folds and ⌘→ unfolds, as Finder folds a list's folders: View ▸ Fold Subtasks and Unfold Subtasks.
  A bare ← can't be had: SwiftUI's List is an outline view underneath and takes it before `onKeyPress` does.
  So there's no ← to the parent. The commands are off while an Add field has the focus, so ⌘← and ⌘→ still move
  its insertion point.
- **Menu.** The row menu's Fold Subtasks or Unfold Subtasks, after Labels….
- **Focus.** A selected subtask folded away hands the selection to the row it's folded under.

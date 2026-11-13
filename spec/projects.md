# Projects and sections

Slice 7. Create, nest, rename, colour, archive and delete projects. Create, rename, reorder and delete sections.
From `docs/sync.md` ("Sections", "Deletes", "Trees: sub-projects") and the web app's `web/src/lib/ops.ts`
and `sections.ts` (v0.18.0). Every action is one batch, as in [writes.md](writes.md).

## Projects

| Action | Ops |
| --- | --- |
| Create | `name`, `color`, `position`, `archived: false`, `parent_id`, `created_at`, `deleted_at: null` |
| Rename | `name`, trimmed, never empty |
| Colour | `color`, a hex string, or `null` for Theme ([icons.md](icons.md#the-theme-colour)) |
| Icon | `icon`, a Lucide name or `null`; the web app draws only its catalogue's 411 ([icons.md](icons.md)) |
| Move under another project, or to the top | `parent_id` and `position`, last among the new siblings |
| Archive | `archived: true` on the project and every live descendant not already archived |
| Unarchive | `archived: false` on the project only. Its archived sub-projects stay archived |
| Delete | `deleted_at: now` on the project, and `parent_id` = its parent on each direct live sub-project |

- **Position.** Last among the live siblings: the wall time, or the largest sibling position + 1 when one is past it.
  This is the web app's rule for projects (`+ 1`, not `+ 1000`).
- **Colour.** A new project takes the first of the web app's eight colours that no live project uses,
  else the first. The web app picks one at random. The editor offers the same eight; a colour from elsewhere is kept until changed.
- **Parent.** Must be live and not archived. Never the project itself or one of its descendants.
  A new project under an archived or missing parent is refused. The web app quietly makes it top level instead.
- **Workspaces.** Not written. Absent means the default workspace, which is the only one this account has.
- **Deleting keeps the tasks' `project_id`.** Tasks of a deleted project are hidden, and restoring the project
  brings them back with one op. The "Trees" section of `docs/sync.md` and "Sub-projects" in `docs/api.md`
  say open tasks get `project_id: null`. The web app's `deleteProject` and the "Deletes" section say not. We follow the code.
- **Sub-projects survive a delete.** They move up to the deleted project's parent. A sub-project whose parent
  would be itself (only inside a cycle) goes to the top.
- **Undo** puts back every field the action wrote, as a new batch. Undo of a delete clears the tombstone and puts the
  sub-projects back under it.

On the Mac (0.10.0), all of it. Create from the + on the sidebar's Projects heading, File ▸ New Project… (⌥⌘N), or
New Sub-project… in a project's menu. Edit Project… (its menu, or the pencil on its page) holds name, colour, parent,
Archive and Delete. Delete asks first when the project has open tasks, since the Mac has no Trash yet; Undo works
either way. A section heading's menu renames, moves and deletes it; Add Section is at the end of a project.
The page follows its project: archiving it shows the archived page, deleting it shows Today.
The writes are in `Writes.swift`, tests in `ProjectsTests.swift`, all ported from the desktop's.

Archived projects are hidden from the sidebar, Move to, quick add's `#project`, and every task list.
The sidebar lists them under "Archived", flat, with their path. Their page offers Unarchive.

## Sections

| Action | Ops |
| --- | --- |
| Create | `name`, `project_id`, `position`, `created_at`, `deleted_at: null` |
| Rename | `name`, trimmed, never empty. An unchanged name writes nothing |
| Move up or down | `position`, with the manual-order rule ([writes.md](writes.md#manual-order)): usually one op |
| Delete | `deleted_at: now`, and `section_id: null` on each live open task that names it, in one batch |

- **Position.** Last among the project's live sections + 1000, or the wall time when there are none.
- **`project_id` never changes.** The server's REST API refuses it.
- **Completed tasks keep `section_id`** when their section is deleted. If reopened they show under "No section",
  by the display rule for stale references.
- **The project** must be live and not archived.
- **Not written:** section colour and icon. A section edited here keeps them.

## Not in this slice

- Reordering projects in the sidebar. That is slice 6c, by drag.
- Project notes (`description`, `notes_doc`), view mode, flow, status and custom fields.
- Trash was added later; see [trash.md](trash.md).
- Shared projects. This account has none. Deleting one would need the copy-to-Inbox rule.

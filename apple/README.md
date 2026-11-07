# Dustpan for Mac

The Mac client. SwiftUI, with the protocol in a Swift package the iPhone app will share. No third-party packages:
Foundation, SwiftUI, CryptoKit, UserNotifications and the system's SQLite.

Needs Xcode 27 and macOS 26 or later.

## Develop

Run everything from the repo root, with the dev server going (`dev/server.sh`, see the top README).

```sh
dev/mac.sh                                       # build and run the app against the dev server
swift test --package-path apple/DustpanCore      # unit tests
DUSTPAN_CONFIG=dev/credentials DUSTPAN_DATA=dev/data/mac \
  swift run --package-path apple/DustpanCore dustpan-cli tree   # sync or tree, like dev/client.sh
```

Opening `apple/Dustpan.xcodeproj` and pressing Run does the same as `dev/mac.sh`:
the scheme points `DUSTPAN_CONFIG` and `DUSTPAN_DATA` at `dev/`.
The app keeps its dev data in `dev/data/mac`, apart from the desktop client's and from any real install.

`DUSTPAN_SCREENSHOT=<folder> dev/mac.sh` saves one PNG per sidebar page after the first sync, then quits.
Debug builds only. It uses ScreenCaptureKit on the app's own window, which needs no Screen Recording permission.

## Layout

| Path | Role |
| --- | --- |
| `DustpanCore/` | The Swift package: everything without UI, for Mac and iPhone |
| `DustpanCore/Sources/DustpanCore/JSON.swift` | Any JSON value, read and written with `JSONSerialization` |
| `DustpanCore/Sources/DustpanCore/Store.swift` | SQLite: one last-writer-wins register per field, outbox, meta. The desktop's schema |
| `DustpanCore/Sources/DustpanCore/Clock.swift` | Hybrid logical clock |
| `DustpanCore/Sources/DustpanCore/Sync.swift` | The sync exchange, refused ops, purge and re-seed |
| `DustpanCore/Sources/DustpanCore/Api.swift` | HTTP client, `URLSession` |
| `DustpanCore/Sources/DustpanCore/Config.swift` | The config file and where the database lives |
| `DustpanCore/Sources/DustpanCore/Model.swift` | Display rules: trees, sections, the Inbox, counts |
| `DustpanCore/Sources/DustpanCore/Dates.swift` | Due date display, the instant a due denotes, and the editor's due |
| `DustpanCore/Sources/DustpanCore/Writes.swift` | Local edits: one batch per action, applied and queued, with Undo. Labels too |
| `DustpanCore/Sources/DustpanCore/Labels.swift` | Finding labels as you type, the picker's order, duplicates, the chips a row shows |
| `DustpanCore/Sources/DustpanCore/Ordering.swift` | Manual order: the positions a move writes |
| `DustpanCore/Sources/DustpanCore/DragDrop.swift` | Where a drop lands (zone, level, placement, or an outline view's proposal) and the toast after it. `Writer.drop` writes it. `placeItem`: a project dropped on a sidebar row |
| `DustpanCore/Sources/DustpanCore/QuickAdd.swift` | Quick add: the parser, its context from the user's preferences, and the result. `Writer.quickAdd` writes it |
| `DustpanCore/Sources/DustpanCore/QuickAddWords.swift` | Quick add's vocabularies, tokens and phrase matching |
| `DustpanCore/Sources/DustpanCore/QuickAddAttributes.swift` | `#project`, `@label`, `p1`, `~energy`, `+30m`, `30m/2h` |
| `DustpanCore/Sources/DustpanCore/QuickAddDates.swift` | Date and time phrases |
| `DustpanCore/Sources/DustpanCore/QuickAddRepeats.swift` | Repeat-rule and reminder phrases, and how a typed reminder is stored |
| `DustpanCore/Sources/DustpanCore/Resources/vocab.json` | OpenTodo's quick-add vocabulary, copied unchanged; a test checks it against the clone |
| `DustpanCore/Sources/DustpanCore/Recurrence.swift` | Repeat rules: parser, canonical form, next occurrence, on floating days |
| `DustpanCore/Sources/DustpanCore/Recurring.swift` | What completing, skipping and splitting off a repeating task write |
| `DustpanCore/Sources/DustpanCore/Filter.swift` | The filter language: parser, error messages, evaluation, blocked tasks |
| `DustpanCore/Sources/DustpanCore/Views.swift` | Today, Upcoming, and saved views: sorting and grouping |
| `DustpanCore/Sources/DustpanCore/Sectors.swift` | The part of time sectors the filter language needs |
| `DustpanCore/Sources/DustpanCore/Reminders.swift` | Reminders that follow their dates, default reminders, and which are due to show |
| `DustpanCore/Sources/DustpanCore/Ids.swift` | Deterministic ids |
| `DustpanCore/Sources/DustpanCore/Events.swift` | The live update stream |
| `DustpanCore/Sources/dustpan-cli/` | `sync` and `tree`, for checking against the desktop client |
| `Dustpan/` | The Mac app: window, sidebar, task list, editor, notifications |
| `Dustpan/Dragging.swift` | Drag sources, drop delegates, the drop line, the drag pill, the flash |
| `Dustpan/OutlineTaskList.swift` | Spike: project and Inbox lists on AppKit's `NSOutlineView` (View ▸ Outline Task List) |

The tests read OpenTodo's vectors from the clone beside this repo (`../opentodo`, or `OPENTODO_SRC`), and skip them without it.

Each Swift file is a port of the desktop module of the same name, and its tests are ports of the desktop's.
`dustpan-cli tree` prints the same text as `dev/client.sh tree`, so the two can be diffed.

The package and the app use Swift 6 with `NonisolatedNonsendingByDefault`: sync runs on the caller's actor,
the main actor in the app, and only the network waits happen elsewhere.

## Real use

Put `OPENTODO_URL=…` and `OPENTODO_TOKEN=…` in `~/.config/dustpan/config` (mode 600), as on the desktop.
The URL must be https. Plain http works only for this machine (`localhost`, `127.0.0.1`, `::1`).
Data goes in `~/Library/Application Support/Dustpan/`. The app isn't sandboxed, so it can read the config file.

Give each device its own token: Settings → Integrations → API tokens in the web app.

Install or update the app in `/Applications`, from the repo root. Quit Dustpan first.

```sh
xcodebuild -project apple/Dustpan.xcodeproj -scheme Dustpan -configuration Release \
  -derivedDataPath dev/data/mac-build -quiet build
ditto dev/data/mac-build/Build/Products/Release/Dustpan.app /Applications/Dustpan.app
```

It's signed for this Mac only (ad hoc), which is enough to run it here.

## Versions

The version is `MARKETING_VERSION` in the Xcode project. Tags are `mac-vX.Y.Z`, apart from the desktop's `vX.Y.Z`.
Before 1.0 the minor number follows the Mac client's own slices.

| Version | Date | What |
| --- | --- | --- |
| 0.8.0 | 2026-11-07 | The sidebar's order, from desktop slice 6c: drag a project before, after or into another (the middle of its row), and drag views to reorder them. Move Up and Move Down in project and view menus, and ⌥↑ ⌥↓ on the selected project, view or label. One Undo each. |
| 0.7.0 | 2026-11-07 | Slice 4b, quick add: every Add field and the editor's subtask line read the line like the desktop, in six languages, with a preview of what it sets. Also: a press-and-drag on a row no longer selects rows, Esc clears a selection, and the `NSOutlineView` list spike. |
| 0.6.0 | 2026-11-06 | Slice 6a, drag and drop: drag a task within a list to reorder, nest (middle of a row) or outdent (drag left); onto a section heading or the end of a section; onto the Inbox, a project, Today or a label in the sidebar; onto Today's and Upcoming's day headings. One Undo per drop, a toast, and the moved task flashes. Holding a drag over a project opens it. |
| 0.5.0 | 2026-11-06 | Slice 5, everyday editing and labels: delete with Undo, subtasks, labels, estimate and deadline in the editor, deadline reminders; a label picker (L), labels in the sidebar with their own pages, and rename, recolour, reorder, merge and delete. |
| 0.4.1 | 2026-11-06 | The due date picks its day from an inline month calendar across the editor, as on the desktop. |
| 0.4.0 | 2026-11-06 | Slice 4a, filters and views: Today and Upcoming, and saved views in the sidebar with counts, created, edited and deleted with Undo. The whole filter language parses. |
| 0.3.1 | 2026-11-06 | The editor's date controls: a date field with a calendar popover and a time row of its own. Reminders at a chosen time, and a reminder's offset or time changed in place. |
| 0.3.0 | 2026-11-06 | Slice 3, recurrence and reminders: repeating tasks complete, skip and split off an occurrence; a repeat rule in the editor with a preview; reminders from presets, and notifications with Snooze and Dismiss. |
| 0.2.0 | 2026-11-06 | Slice 2, basic writes: add, complete and reopen with Undo, an editor for title, priority, due, project and section. Sync 250 ms after an edit, and the live stream. |
| 0.1.0 | 2026-11-06 | Slice 1, read-only: sync, the local store, the Inbox and nested projects with sections, subtasks, priorities, due dates, estimates and labels. Syncs at start, every 30 s and on ⌘R. |

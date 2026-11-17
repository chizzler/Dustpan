# Mac releases

## Mac 0.19.1 — 2026-11-17 (preview)

[Download the signed and notarized universal Mac preview](https://github.com/chizzler/Dustpan/releases/tag/mac-v0.19.1).
Requires macOS 26 or later; supports Apple silicon and Intel. Matching source, build metadata and
SHA-256 checksums accompany the app.

- First-launch welcome describes local tasks and optional OpenTodo sync as separate choices, each with its own
  action button, and stays out of the way of existing profiles. The compact window offers **Standalone on This Mac**
  and **Sync to an OpenTodo Server…**, with subtle blue and orange accents. Help can reopen it.
- Background polling and reminders follow the app lifetime; account changes serialize with sync, and cancelled
  requests retain queued edits instead of applying a response. Cancelled delays and live streams stop promptly.
- Checked-in dependency inventory and audit cover package/build hooks, imports, vendored data and linked libraries.

- Sync requests stay within OpenTodo's 4 MiB body limit, including long notes and restored data.
  Reminders, comments, attachments and time entries stay whole across batch boundaries.
- Edits exceeding the 64 KiB encoded field limit are rejected before any part of the action is saved.
- The Mac client counts edits held by server limits and shows a persistent waiting indicator.
- Mac section headings support colours and icons. The experimental outline list is available only
  in Debug builds.
- Section-editor saves preserve unrelated changes synced while the editor was open; Undo touches only
  the fields changed by the save.
- Public setup, privacy, security and contribution guides; automated checks and local Mac packaging.

This is a pre-1.0 preview. See [README.md](README.md) for current limitations.
Earlier history is in [desktop/README.md](desktop/README.md#versions) and
[apple/README.md](apple/README.md#versions).

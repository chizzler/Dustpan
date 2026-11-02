# Notes

Status: built 2026-11-02 (slice 8), tried and approved.

A task's notes are Markdown. OpenTodo keeps them in two fields (`docs/sync.md`, "Mergeable documents"):

- `description`: the note as Markdown text.
- `notes_doc`: the web app's rich-text Yjs document. `description` is its projection.

**Dustpan reads and writes `description` only.** It never writes `notes_doc`.
A plain-text write to `description` is allowed by the protocol (rule 3, "fold-back"): the next device that opens the
note in the web app parses our Markdown into a new body of its document. A rich edit made before our write
and not yet seen loses once, as last-writer-wins.

## Writing

- The editor's Notes group has **Write** (plain Markdown, monospace) and **Preview**. A note opens in Preview;
  an empty one opens in Write. Ctrl+Enter saves the task.
- `Writer.edit(task_id, {"description": text})` trims trailing whitespace and writes the one field.
- The server bounds a value at 64 KB as the JSON it receives. We send `json.dumps`, which escapes non-ASCII,
  so the check is `len(json.dumps(note)) <= 65536`. A longer note is refused before any op exists.

## Showing

`dustpan/markdown.py` is a port of the web app's `web/src/lib/markdown.ts`, so a note looks the same in both:

- paragraphs, with a single newline as a line break; headings; `**strong**`, `*em*` and `_em_` (not inside words),
  `~~strike~~`, `` `code` ``; fenced code; `>` quotes; `-`, `1.` and `- [ ]` lists, nested by indenting; pipe tables.
- **Links only for http(s) and mailto.** Anything else (`javascript:`, `data:`, relative) is shown as its words.
  `![x](https://…)` is a link named x: nothing is loaded from an address.
- **All text is escaped** before it becomes Pango markup. HTML in a note is shown as text.
- Attachment images (`![alt](attachment:id)`) show as "Image: alt". Task links (`[x](?task=id)`) show their words.
  Mentions are not parsed.
- Nesting is bounded (quotes and lists 8 deep, inline formatting 4), as in the web app.

`dustpan/noteview.py` turns the parsed blocks into GTK labels. A task row shows the note's first line, dimmed.
Filters already search notes (`search:`).

## Tests

`tests/test_markdown.py` ports the cases of `markdown.test.ts` that don't depend on React or mentions,
and checks our Pango output instead of HTML.

## Not done

- Ticking a check item in Preview.
- Project notes (`project.description`).
- Comments.

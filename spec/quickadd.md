# Quick add

What the desktop client implements from `docs/quick-add.md` and the web app's `web/src/lib/nlp` (v0.18.0).

## Ported, and checked

| Our module | OpenTodo source |
| --- | --- |
| `quickadd/words.py` | `internal/quickadd/vocab.go`, `tokenize.go` |
| `quickadd/dates.py` | `internal/quickadd/dates.go` |
| `quickadd/repeats.py` | `internal/quickadd/recurrence.go` |
| `quickadd/attributes.py` | `internal/quickadd/attributes.go` |
| `quickadd/reminders.py` | `internal/quickadd/reminders.go` |
| `quickadd/parse.py` | `internal/quickadd/parse.go` |
| `quickadd/settings.py` | `web/src/lib/nlp/settings.ts` |
| `Writer.quick_add` | `toTaskInput` in `web/src/lib/nlp/quickadd.ts`, `createTask` in `web/src/lib/ops.ts` |

The port follows the Go one file for file, so a diff of the pinned Go code shows what to change.
All 160 cases in `web/src/lib/nlp/quickadd.vectors.json` pass, in English, German, French, Italian, Spanish and Portuguese.

**`quickadd/vocab.json` is OpenTodo's file, copied unchanged.** It's the only file taken from OpenTodo,
because the app needs it at run time. A test fails when it no longer matches the pinned clone.

## What a line sets

`Call Sam tomorrow at 3pm #Work @phone p1 +30m every week remind me 1 hour before`

| Part | Sets |
| --- | --- |
| A date or time phrase | `due`. A time alone is today, or the day "in 20 hours" lands on |
| `every …` | `recurrence`, canonical. Without a date, `due` is the rule's first date |
| `deadline friday` | `deadline` |
| `someday` | `start: "someday"`, only when nothing dates the task |
| `tonight`, `this evening` | `evening`, due today |
| `this morning`, `tomorrow afternoon` | `day_part`, only when `user_prefs.day_parts` is on |
| `#Project`, `#Parent/Child` | `project_id`: an exact folded name (the shallowest wins), else the only prefix |
| `@label` | `labels`. A name with no label creates one in the same batch, coloured like the web app |
| `p1`–`p4` | `priority` |
| `~deep`, `~low` | `energy`, only when `user_prefs.energy` is on |
| `+30m`, `45min`, `2h` | `estimate_minutes` |
| `30m/2h` | 30 minutes already spent (a closed `time_entry`) and a 2-hour estimate |
| `remind me …` | a reminder: an offset ("30 min before") or a moment ("tomorrow at 9") |

Text in double quotes is never read. The title is what's left.

## Where we differ

**"sun", "sat" and "wed" are words as well as days.** Upstream reads them as a date anywhere in the line,
so `Sit in the sun` is due Sunday with the title *Sit in the*. Dustpan reads them as a date only when:

- `on`, `by`, `due`, `next` or `this` comes before them, or `deadline`, `until` or a reminder phrase;
- a time or a tag that quick add reads (a known `#project`, `@label`, `p1`, `+30m`, `1h`…) comes after them;
- they end the line, and don't follow `the`, `a`, `an` or a possessive (`my`, `our`…).

So `Call Mum sun` and `Gym sat 6pm` are dated, and `Stack the turtles in the sun today` is due today with the
sun left in. Full names (`sunday`) and `every sun` are unchanged. English only: German's two-letter days already
need their dot upstream. The check is in the parser's free-text scan (`Parser.word_like_day` in `quickadd/parse.py`,
`wordLikeDay` in `QuickAdd.swift`), so `dates.py` stays a straight port. All 160 upstream vectors still pass. Drop this if OpenTodo adopts it.

## The context

- **Languages:** `user_prefs.language` unless it's `system`, then this device's locale (`LC_ALL`, `LC_MESSAGES`, `LANG`).
  English is always active.
- **Numeric dates** (`3/11`): `user_prefs.date_format` when it names an order, else the first language's order.
  English is month first only for the US (or no region).
- **Today** is the logical today. Weeks start on `user_prefs.week_start`.

## In the window

The add-task entry reads every line with quick add. A line under it shows the title that's left and what will be set:
`→ Call Sam · Tomorrow 3:00pm · Work · p1`. Showing the title means a word read as a date can't vanish unseen.
The page fills in what the line leaves out:

- a project page: its project and the section;
- Today: due today. Upcoming: due tomorrow. A line that parks the task (`someday`) gets no date.

A line naming a project overrides the page's project and section.

## Reminders

Typed reminders are resolved against the task's final due, in the same batch:

- an offset is a relative reminder;
- a moment with a due becomes a relative reminder: its offset from the due time (09:00 for a date-only due);
- a moment without a due is absolute: its date, or today if the time is still ahead, else tomorrow.

The user's default reminder still applies to a task that gets its first due, as for every write.

**Not yet:** the web app's chips (dismissing a recognised part), the per-device language list, and suggestions while typing.

## On the Mac

`QuickAdd*.swift` in DustpanCore port these modules file for file, and pass the same 160
vectors. `vocab.json` is a package resource, checked against the clone like the desktop's copy.
`Writer.quickAdd` ports `Writer.quick_add`. The Add fields and the editor's subtask line use it, with the same
preview line. The languages come from `user_prefs.language` and the Mac's first preferred language.

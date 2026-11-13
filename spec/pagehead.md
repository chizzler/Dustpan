# The page heading

Every page opens with a large heading, so a project reads as a place you are in, not a list you are looking at.
Built on the desktop 2026-11-13, in 0.12.5. The Mac comes later.

## The parts

From top to bottom, all left-aligned with the tasks:

- **The eyebrow.** A short line in small capitals, dimmed. It says where you are or when.
- **The title.** 30 px, extra bold, tight letter spacing. A mark before it, at 26 px.
- **The meta line.** A dim count of what is open.
- **Places.** For a project with sub-projects: one pill per sub-project, with its mark. A click opens it.

## Per page

| Page | Eyebrow | Mark | Meta |
| --- | --- | --- | --- |
| Today | The date: "Friday 13 November" | Its sidebar symbol, in the theme's accent colour | "2 to do" |
| Inbox | none | Symbol | Open tasks on the page, planned or not |
| A project | "Project", or its parent's path | Its icon in its colour, or its dot | Open tasks, as the sidebar counts them |
| An archived project | "Archived project" | As above | none |
| A label | "Label" | Its dot | Its open tasks |
| A saved view | "Saved view" | Symbol | none |
| Upcoming, Anytime, Completed, Filter, Trash | none | Symbol | none |

- **A Theme project** ([icons.md](icons.md#the-theme-colour)) draws its mark in the theme's text colour.
- **The accent** is the current Omarchy theme's `accent`, as everywhere in the app; Adwaita's blue without one.
- **No rule under the title.** A bar was tried, short and then full width. The owner found it too much;
  the name and its mark carry the heading.
- **A sub-project's eyebrow is a link** to its parent: "HOME" above "Garden" opens Home.
- **The counts say "Nothing open"** (or "Nothing to do" on Today) rather than zero.
- **The Inbox counts differently from the sidebar.** The sidebar counts only true Inbox tasks: no project, no date.
  The page also lists dated tasks without a project, under "Planned, no project", so its heading counts those too.

## The header bar

The header bar's title stays empty while the heading is on screen: the name shouldn't show twice.
Scrolled past 72 px, the heading is out of sight and the header bar shows the page's name.
Sync messages still show as the header bar's subtitle.

## Code

`dustpan/pagehead.py` builds the widget from plain facts and holds its CSS. `Window.page_heading` in `app.py`
gathers the facts for a page. Tests are in `tests/test_icons.py` (`PageHeadTest`).

## Not yet

- **Large-screen polish.** The heading sits in the same 760 px column as the tasks.
- **The Mac.** It has the same pages and would take the same heading.
- **Editing in place.** Clicking the title or the mark could rename the project or open the icon picker.

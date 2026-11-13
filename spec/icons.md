# Project icons

A project can show an icon instead of its dot, in the project's colour. Like Bear's tag icons, but for projects.
Built on the desktop 2026-11-13, in 0.12.5. The Mac comes later.

## Where the icons come from

- **OpenTodo already has the field.** Projects and sections have an `icon` field (v0.22.0). It syncs like any field.
- **We offer all of [Lucide](https://lucide.dev):** 1,854 icons, version 1.48.0, under the ISC licence.
  Bear's variety was the aim (2026-11-13). The first build offered only OpenTodo's 411.
- **OpenTodo's catalogue is 411 of them**, each with a category and search keywords. Its REST and MCP writes
  refuse any other name, and its web app draws only those. Sync doesn't check, and Dustpan writes through sync.
  So any of the 1,854 can be set here, and the web app shows the project's dot for the other 1,443.
- **OpenTodo's 411 keep OpenTodo's names.** Eight are old Lucide names, such as `trash-2` for `trash`.
  Dustpan writes the old name, so the web app still draws it. Lucide's 264 old names all still draw.
- **Copied in, not installed.** No package, and the app downloads nothing.
- **Bear's own icons can't be used.** They're Bear's artwork. SF Symbols and the GTK icon theme can't either:
  their names differ by platform.

## Files

All in `desktop/dustpan/icons/`:

- **`paths.json`:** every Lucide icon's SVG body, by name, cut as OpenTodo cuts it.
- **`lucide.json`:** Lucide's version, each icon's tags and categories, and its old names.
- **`catalogue.json`:** OpenTodo's `web/src/ui/icons/catalogue.json`, copied unchanged.
- **`LICENSE-lucide.txt`:** Lucide's licence, copied unchanged. The package also installs it beside Dustpan's licence.
- **`sync.py`:** writes the first two from two downloads: `lucide-static` 1.48.0 from npm (the SVG files),
  and Lucide's source at tag 1.48.0 from GitHub (`icons/*.json`). Its docstring has the links, the npm
  checksum and the command. Run by hand.
- **`__init__.py`:** the rules and the categories. No GTK.

A test checks that OpenTodo's 411 have the same path data here as in the pinned OpenTodo clone.
When either pin moves, re-run `sync.py`.

## Categories

The picker has 30. Lucide's own 42 are too many, and an icon sits in several, not always well:
Lucide files the briefcase under transport, the star under weather.

- **OpenTodo's 411 keep OpenTodo's categories**, chosen by hand. Its 16 map onto ours; Work and Learning
  come only from it. "Technology" is Devices, "Symbols" is Shapes and symbols.
- **The rest go by Lucide's categories, the most specific first.** Each shows once, under the first group in
  `PRIORITY` it belongs to: an icon in both Animals and Social goes to Animals.
- **Small Lucide categories are merged.** Seasons into Weather, Buildings into Home, Mail and Notifications into
  Communication, Cursors into Arrows and navigation, and so on. Every category holds at least ten.
- **A user icon goes to People.** Lucide keeps them in its broad Account category, with keys and settings.
- **Order.** Everyday categories first (Work, Home, People, Learning, Food and drink…), the technical last
  (Layout, Development, Accounts and settings, Arrows and navigation). In each, OpenTodo's icons first, in
  its order, then the rest by name.

## Rules

- **Drawing.** Lucide's 24-unit grid, round caps and joins, no fill, 1.5 px lines at every size: lighter than
  Lucide's 2, closer to Bear's. The line colour is the project's colour. GTK renders the SVG at the screen's
  scale, so it stays sharp.
- **An unknown name** (a newer client's) shows the dot. Editing the project keeps the name unless the user picks another.
- **Writes.** `add_project(icon=…)` and `edit_project({"icon": …})`. The icon is `None` or a known name;
  anything else is a programming error (`ValueError`). Clearing writes `null`. Undo restores the old icon.
  A new project without an icon writes no icon field.
- **Search** is the web app's order: exact name, name prefix, in the name, a keyword, then the category
  (our group, its English name, or a Lucide category). Keywords are OpenTodo's and Lucide's tags.
  In a tie, OpenTodo's icons come first, then picker order.
- **Suggestions** come from the project's name, as typed. Whole words only, so "Car" offers the car but not
  the carrot. A word can match an icon's name, a word of its name, a keyword's word, or its category, best in that order.
  A plural also tries its singular ("Books" offers the book). At most eight, OpenTodo's first in a tie.
  Words of one or two letters are skipped.
  Suggestions are only offered; nothing is set for you, because an icon set automatically would sync everywhere.

## The Theme colour

- **A project can have no colour of its own.** It's stored as `color: null` and called **Theme** in the editor.
  Its icon, or its dot, is drawn in the theme's text colour: light on a dark theme, dark on a light one.
  It follows a theme change.
- **OpenTodo allows it.** Sync doesn't check the colour. The web app offers "No colour" for sections and workspaces,
  not projects. There, a Theme project's icon takes the text colour; without an icon its dot may not show.
- **Writes.** `add_project(color=None)` writes `null`. Leaving `color` out still picks the first unused palette colour.
  `edit_project({"color": None})` clears it. Anything but a `#rrggbb` string or `None` is a `ValueError`.
- **The calendar** draws a Theme project's blocks and dots in grey, as for the Inbox.
- **Labels and other dots** keep the grey for a missing colour. Only project marks read the theme.

## The desktop

- **The project editor** has an Icon row below Colour. Its button shows the icon, or the dot and "None".
- **The colour row** starts with Theme, a dot in the text colour, then the eight palette colours.
- **The picker** is a popover, about 560 px wide. A search box across the top. Below it, a sidebar of
  categories, each with its icon and count, and beside it the chosen category's icons, eight to a line,
  drawn in the project's colour. The current icon is highlighted.
- **It opens on** the current icon's category. Without an icon, on "Suggested" when the name gives any,
  shown first in the sidebar. Otherwise on Work.
- **Search covers every icon** and replaces the category, best first. A short query matches most of them,
  so it shows the first 240 and says to type more. Clearing it goes back to the category.
  Enter takes the best match. Esc closes. "No icon" clears it.
- **Why a sidebar.** Thirty categories won't fit in a bar along the bottom; about eight icon tabs would.
  One category at a time also keeps the picker quick: about 10 ms to switch.
- **A new project's colour** is chosen by the writer when none is picked, so its icon previews in grey until then.
- **Shown in** the sidebar (projects and Archived) and Trash. The dot sits in an icon-wide slot,
  so names line up whether their projects have icons or not.
- **Not shown in** the calendar's 7 px dots or the task editor's project list.

## Not yet

- **Section icons.** The field exists, and the web app sets it. The desktop keeps it when editing a section, and
  doesn't show it.
- **The Mac.** It needs the same JSON files as a resource in `DustpanCore`, and the same rules ported with these
  tests. The SVGs would draw as template images so they take the project's colour.
- **Marking which icons the web app shows.** It draws OpenTodo's 411 only. The picker doesn't say which those are.
- **Keyboard into the grid.** Arrow keys from the search box into the icons.

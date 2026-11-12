# Dustpan for Linux

Copyright (C) 2026 Dustpan contributors.

The Dustpan Linux client is distributed under the GNU Affero General Public License,
version 3 only (SPDX: `AGPL-3.0-only`). See `LICENSE` for the full license text.

## OpenTodo

Parts of Dustpan are Python adaptations of [OpenTodo](https://github.com/OpenTodoApp/OpenTodo),
copyright its respective contributors, under `AGPL-3.0-only`. These include the sync and ordering rules,
recurrence, reminders, dates, filters, quick add, task display and calendar behavior.
The quick-add vocabulary is copied from OpenTodo. The release's upstream test fixtures and filter
documentation are copied without modification from OpenTodo v0.22.0.

The initial ports followed v0.18.0; this release targets v0.22.0. Dustpan's changes include the Python
implementation, GTK interface, offline store and client integration, and the behavior recorded in the
release notes. OpenTodo remains a separate project and its server is not bundled.

# Privacy

The Dustpan clients contain no analytics, advertising, telemetry or automatic crash-report upload.
Tasks and preferences are stored locally in SQLite. Standalone mode requires no account or server.

When you connect OpenTodo, Dustpan sends task data and changes to the server URL you configure, using
your API token. That server receives connection metadata such as the device's IP address and time-zone
offset. Its operator controls its logs, storage and backups. Dustpan does not support encrypted accounts.

Notifications use the operating system's local notification service. A reminder can display a task title
on the lock screen, depending on system settings. Opening a link in a task uses your default browser.
Dustpan does not automatically fetch images from Markdown notes.

Disconnecting stops future sync; it keeps the local copy of your tasks. Uninstalling the app also keeps
its data and configuration. Linux data is under `~/.local/share/dustpan` (or `XDG_DATA_HOME`), Mac data is
under `~/Library/Application Support/Dustpan`, and configuration is `~/.config/dustpan/config`.
Deleting local files does not remove server data or backups. See each client's guide before removing data.

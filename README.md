# Dustpan

Native task management for **Linux and macOS**, with local storage and optional sync to your own
[OpenTodo](https://github.com/OpenTodoApp/OpenTodo) server. Start adding tasks without an account.

[Screenshots and Linux downloads](https://chipdust.au/dustpan/)

Nested projects, sections and subtasks, priorities, labels, recurring tasks, reminders, Markdown notes,
natural-language quick add, filters, saved views, Undo and Trash. The companion calendar has Month,
Week and Day views with drag-and-drop scheduling and duration resizing.

**Mac pre-1.0 preview:** [download Mac 0.19.1](https://github.com/chizzler/Dustpan/releases/tag/mac-v0.19.1),
a Developer ID signed and Apple-notarized universal build for Apple silicon and Intel.
Linux **0.12.6** is available from [ChipDust](https://chipdust.au/dustpan/), with source, setup instructions
and checksums. AUR submission is pending while new-account registration is closed.
The iPhone app is planned; no iPhone build is available.

## Get started

| Platform | Requirements | Install and setup |
| --- | --- | --- |
| Linux | Arch Linux / Omarchy; Python 3.11+, GTK 4, libadwaita 1.7+ | [Linux guide](desktop/README.md), [Arch packages](packaging/README.md) |
| Mac | macOS 26+; Xcode 27 only when building from source | [Download](https://github.com/chizzler/Dustpan/releases/tag/mac-v0.19.1), [Mac guide](apple/README.md) |

Open Dustpan and add a task. Settings configures reminders, date/time preferences and quick add.
Reminders require Dustpan to stay running; each client offers an optional way to start at login.

For multi-device sync, connect in Settings using an HTTPS OpenTodo URL and a device-specific API token.
The tested server version is **OpenTodo v0.22.0**, with an unencrypted personal account.
[Deploy your own server](deploy/README.md). Both clients read `~/.config/dustpan/config` once connected;
task data stays on each device and edits queue while offline.

## Current limits

- Encrypted accounts and full shared-project membership handling are not supported.
- The calendar does not project future repeat occurrences or draw multi-day bars.
- Dragging and manual ordering inside saved views remain unfinished.
- A server rollback can bring back permanent deletions newer than the backup. A server restore alone
  does not undo accidental deletions still held by clients. Read the [recovery guide](dev/RECOVERY.md).

## Build and contribute

```sh
python3 -m unittest discover -s desktop/tests -t desktop  # Linux with GTK dependencies installed
swift test --package-path apple/DustpanCore              # Mac
dev/mac.sh                                              # build/run against the dev server
```

Protocol tests use the pinned OpenTodo clone beside this repository (`../opentodo`), or `OPENTODO_SRC`.
Linux source releases bundle the fixtures and their license, so they can be tested without a server.
See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and [RELEASING.md](RELEASING.md) for release gates.

[Release notes](CHANGELOG.md) · [Report a bug](https://github.com/chizzler/Dustpan/issues) ·
[Security reporting](SECURITY.md) · [Privacy](PRIVACY.md)

## License and design

AGPL-3.0-only; see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for OpenTodo and Lucide attribution.
Dustpan is an independent client; the OpenTodo server is not bundled.

[Protocol rules](spec/README.md)

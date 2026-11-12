# Dustpan

A self-hosted Todoist replacement. One OpenTodo server, with my own clients for Omarchy, Mac and iPhone.

| Read | For |
| --- | --- |
| [project.md](project.md) | Goals, decisions, and current status |
| [dev-diary.md](dev-diary.md) | Progress, day by day |
| [spec/](spec/README.md) | The Omarchy client's protocol rules |
| [desktop/](desktop/README.md) | The Omarchy client: how to run and test it, and its versions |
| [apple/](apple/README.md) | The Mac client, and the Swift core the iPhone app will share |
| [deploy/](deploy/README.md) | The server: install, update, backups, restore |
| [Recovery rehearsal](dev/RECOVERY.md) | Isolated Linux restore/re-sync tests, actual-backup replay, evidence and limits |

## Real use

Run the OpenTodo server on a server of your own, with https (see [deploy/](deploy/README.md)).

```sh
desktop/install.sh                # launcher entry, icon, and start hidden at login
deploy/pull-backups.sh --install  # daily copies of the server's archives and the client's database
```

Both clients read their URL and token from `~/.config/dustpan/config`.

Linux AUR release preparation is in [packaging/](packaging/README.md). It builds a Linux-only source
archive and Arch package locally; no release has been submitted or uploaded.

The Omarchy client reports 0.12.4; its latest release tag is v0.12.3 (see [versions](desktop/README.md#versions)).
The Mac client is at 0.11.0: slices 1 to 8, with labels in 5 and the sidebar's order from 6c, are built. 0.9.1 is the one installed (see [Mac versions](apple/README.md#versions)).
The server is pinned to OpenTodo v0.22.0.

## Development

```sh
dev/server.sh    # local OpenTodo server (leave running; Linux x86-64 or Apple silicon)
dev/seed.py      # sample data, once per fresh server
dev/client.sh    # the desktop app, against the dev server
dev/mac.sh       # the Mac app, against the dev server
```

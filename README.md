# Dustpan

A self-hosted Todoist replacement. One OpenTodo server, with my own clients for Omarchy, Mac and iPhone.

| Read | For |
| --- | --- |
| [project.md](project.md) | Goals, decisions, what we learned |
| [dev-diary.md](dev-diary.md) | Progress, day by day |
| [spec/](spec/README.md) | The protocol rules the clients follow |
| [desktop/](desktop/README.md) | The Omarchy client: how to run and test it, and its versions |
| [deploy/](deploy/README.md) | The server: install, update, backups, restore |

## Real use

Run the OpenTodo server on a server of your own, with https (see [deploy/](deploy/README.md)).

```sh
desktop/install.sh                # launcher entry, icon, and start hidden at login
deploy/pull-backups.sh --install  # daily copies of the server's archives and the client's database
```

The client reads its URL and token from `~/.config/dustpan/config`.

The desktop client is at 0.12.2 (`desktop/README.md`, "Versions"). The server is pinned to OpenTodo v0.22.0.

## Development

```sh
dev/server.sh    # local OpenTodo server (leave running)
dev/seed.py      # sample data, once per fresh server
dev/client.sh    # the desktop app, against the dev server
```

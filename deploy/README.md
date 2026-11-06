# Deploy

The OpenTodo server runs on any Debian or Ubuntu server with Caddy, alongside other sites.
Caddy holds the public https address and proxies it to OpenTodo on `127.0.0.1:8080`.
Where it runs is set in `deploy/deploy.env`, which git ignores: copy `deploy.env.example` and fill in `HOST` and `DOMAIN`.

| File | Role |
| --- | --- |
| `deploy.sh` | Installs the pinned release, the unit and the Caddy site, then restarts |
| `opentodo.service` | systemd unit: a throwaway user, data in `/var/lib/opentodo`, push off, daily backups |
| `dustpan.caddy` | The Caddy site, installed as `/etc/caddy/sites/dustpan.caddy` |
| `pull-backups.sh` | Copies the server's archives and a client database snapshot to this PC |
| `deploy.env.example` | The two settings both scripts read: `HOST` and `DOMAIN` |
| `dustpan-backup.*` | The daily user timer for `pull-backups.sh` |

## First time

1. Point the domain's A record at the server. Copy `deploy.env.example` to `deploy.env` and fill it in.
2. `deploy/deploy.sh --setup`. It turns on ufw (22, 80, 443), makes a setup token,
   downloads and checks the release, and starts it.
3. Read the token: `ssh <HOST> cat /etc/opentodo/env`.
4. Open the site. Create the owner account with that token. Sign-up closes after that.
5. In **Settings**, create an API token. Put it in `~/.config/dustpan/config` (mode 600):
   ```
   OPENTODO_URL=https://<domain>
   OPENTODO_TOKEN=ot_…
   ```
6. `deploy/pull-backups.sh` once to check SSH works, then `deploy/pull-backups.sh --install`.

## Update

Change `VERSION` and `SHA256` in `deploy.sh` (and `VERSION` in `dev/server.sh`), then run `deploy/deploy.sh`.
Old releases stay in `/opt/opentodo/<version>`. To roll back, point `/opt/opentodo/current` at one and restart.
Before moving the pin, re-read the sync schema and diff the vectors (`spec/README.md`).

## Backups

- **On the server:** OpenTodo writes one archive a day at 03:00 server time to `/var/lib/opentodo/backups`, and keeps 14.
- **On this PC:** the timer copies those archives to `~/.local/share/dustpan/backups/server`.
  It also snapshots the client's own database to `…/backups/client`. Both are kept for 90 days.
  The client snapshot guards against a server bug that deletes tasks everywhere.
- The timer uses SSH without a prompt. It needs a key with no passphrase, or a running agent.

## Restore

```sh
ssh <HOST>
systemctl stop opentodo
/opt/opentodo/current/opentodo-linux-amd64 restore --data-dir /var/lib/opentodo <archive>
systemctl start opentodo   # systemd hands the files back to the service's user
```

The desktop client's sync is designed to re-seed the server with data newer than the archive.
A full restore followed by a real client sync has not yet been rehearsed.

To rehearse without touching the server, restore a pulled archive into a scratch folder and serve it on another port:

```sh
BIN=dev/bin/v0.22.0/opentodo-linux-amd64
$BIN restore --data-dir /tmp/rehearsal ~/.local/share/dustpan/backups/server/<archive>
OPENTODO_ADDR=127.0.0.1:8099 OPENTODO_DATA_DIR=/tmp/rehearsal OPENTODO_PUSH=off $BIN
```

Rehearsed on 2026-11-05: a v0.18.0 archive restored, migrated and served under v0.22.0.

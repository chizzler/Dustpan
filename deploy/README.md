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
  The local snapshot runs even when SSH fails; a local snapshot failure still allows the server copy to run.
  Either failure makes the timer report a failed run.
- The timer uses SSH without a prompt. It needs a key with no passphrase, or a running agent.

## Restore

```sh
ssh <HOST>
systemctl stop opentodo
/opt/opentodo/current/opentodo-linux-amd64 restore --data-dir /var/lib/opentodo <archive>
systemctl start opentodo   # systemd hands the files back to the service's user
```

The desktop client re-seeds the server with newer fields held by surviving clients. This was
rehearsed end to end on 2026-11-12 using the real v0.22.0 server, isolated test profiles, and
copies of an actual server archive and client backup. See [the recovery harness](../dev/RECOVERY.md).

This recovers the archive plus the winning fields surviving clients still hold. A permanent
deletion after the archive can be lost, allowing an old task to return. An unwanted soft deletion
still held by clients is sent back, so restoring the server alone does not undo accidental mass
deletion. Data absent from both the archive and all clients cannot be reconstructed.

Run the isolated rehearsal from the repository root:

```sh
bash dev/recovery.sh
```

The recovery guide also covers replaying copied actual backups and an optional GTK smoke test.
Earlier, on 2026-11-05, a v0.18.0 archive was restored, migrated and served under v0.22.0;
that earlier check did not reconnect a client.

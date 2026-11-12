# Linux recovery rehearsal

Run from the repository root:

```sh
bash dev/recovery.sh
```

Needs Python 3.11+, Bubblewrap, and the downloaded, checksum-verified OpenTodo v0.22.0
Linux binary under `dev/bin/v0.22.0/`. There are no downloads or PyPI dependencies.
The normal test suite remains `python3 -m unittest discover -s desktop/tests -t desktop`.

The launcher creates a private directory under `dist/recovery/`, then runs the real
server and Linux sync/writer code in a Bubblewrap sandbox. Only loopback networking
is available. The host home is absent, code and the server binary are read-only,
and writes stay inside the run directory. Inherited service settings, proxy
configuration, D-Bus addresses and credentials are cleared. No live HTTP endpoint
is accepted. Failure to establish isolation stops the rehearsal.

## What it proves

The fixture creates two different device profiles, nested projects, a section,
parent/child tasks, a label, Markdown notes, a timed relative reminder, a repeating
task, and REST-origin fields with reserved server clocks. It takes T0 through the
server's actual backup service, then makes already-synced and still-offline changes.
More than 1,000 fields cross both upload and download paging boundaries.

Each case restores T0 into its own server directory and starts clients from saved
SQLite checkpoints:

- Ahead client first, then stale client; repeat with the order reversed.
- Changes to different fields, conflicting changes to one field, and an exact
  timestamp tie resolved by device ID.
- A completed repeating task remains one occurrence record and one series advance;
  a due edit retains the corresponding reminder time change.
- Terminate a client process between committed re-seed batches, then resume.
- Terminate after the server accepts an upload but before the client records its
  acknowledgement; retry and verify the server reports duplicates.
- A purge included in the archive remains effective even against a stale client.
- A queued offline permanent deletion reaches the restored server after its
  tombstone uploads.
- A damaged archive is rejected without changing the existing database, generation
  or safety copies; the existing server still serves the expected data.

Expected field values and clocks are recorded before recovery, with semantic
checks on the intended actions. The expected-state reducer is independent of the
client's merge implementation. Every client and an empty third client must match
that state. The REST export independently checks entity IDs and field values,
including tombstones. Repeated syncs and a server restart must leave data and the
fresh client's cursor unchanged. Unexplained refusals, held ops, nonempty outboxes,
undrained purge requests or field differences fail the run.

## Replay actual backups

Supply all three paths together:

```sh
bash dev/recovery.sh \
  --archive "$HOME/.local/share/dustpan/backups/server/<archive>.tar.gz" \
  --client-db "$HOME/.local/share/dustpan/backups/client/<snapshot>.db" \
  --config "$HOME/.config/dustpan/config"
```

The archive is copied and the database copied through SQLite's backup API, including
committed WAL data. Checkpoints are converted to standalone databases and integrity
checked. Only the token is taken from the config; its server URL is never used.
The staged inputs are mounted read-only. Originals are never opened for writing.
The token must exist in the archived server and belong to the snapshot's account.
The snapshot must already know a previous server generation. Pending permanent
deletes in a real snapshot currently stop the replay for review of their cascades;
the controlled fixture covers queued deletes separately.

The expected result is the archive's accessible data plus the snapshot's winning
fields, not an assumption that everything newer than the archive is recoverable.
Other authors' comments/time entries/attachments and `attachment.uploaded_at` follow
the re-seed exclusions. Attachment bytes are not recovered from client fields.

## GUI smoke and visual review

Add `--gui-smoke` to either command in a Wayland session. This briefly opens the app
on a **private D-Bus session**, using a further copy of the recovered database and
the still-isolated scratch server. Only the Wayland socket is shared; the daily-use
app and its notification service are not contacted.

The smoke renders a project, Completed, Trash, calendar Month/Week/Day and a task
editor. Seven PNGs and a GUI result are saved under `gui-smoke/`. It checks that
the inspection did not change synced fields. The images need visual review;
rendering a window alone does not prove that its contents are correct. Desktop
notification delivery and interactive editing remain separate manual trials.

## Evidence and limits

Each run retains `report.md`, `results.json`, source/binary/input checksums,
expected manifests, difference files, server logs, per-client exchange traces and
SQLite checkpoints. Worker traces include operation IDs, generation, batch sizes,
duplicates and rejection reasons. They omit tokens and operation values. Manifests,
databases and screenshots contain task content: the run directory is mode 0700
and ignored by Git. Keep it private.

Exit code 0 means all assertions passed, **including the two expected limitations**;
the report explicitly says `PASS_WITH_LIMITATIONS`. Any unexpected error returns 1.

- **Permanent deletion after T0:** rollback loses the server's newer purge marker.
  Clients which already applied it retain no durable purge ledger. The archive can
  therefore bring back the task. The test confirms this limitation and checks that
  all clients at least agree on the restored state.
- **Accidental deletion:** restoring an archive does not undo newer tombstones still
  held by clients; re-seeding sends those deletions back. Recovering from a mistaken
  mass deletion needs a separate procedure for reviewing old snapshots and writing
  explicit restores with fresh clocks. This harness does not perform that repair.
- Anything missing from both the archive and every surviving client is outside
  this recovery method. Shared memberships and encrypted accounts remain outside
  the Linux client's supported scope.

Validated on 2026-11-12 with a copied 2026-11-11 server archive and a 2026-11-12
client backup: the archive exposed 831 fields, and the recovered state matched all
949 expected fields through both a fresh client and REST. No production service
was stopped, reconfigured or contacted.

#!/usr/bin/env bash
# Keep copies of Dustpan's data on this PC.
#   - The server's daily archives, pulled from it. They survive losing the box.
#   - A snapshot of this client's own database. It survives a server bug that deletes tasks on every device.
# Both go in ~/.local/share/dustpan/backups. Kept for 90 days.
#   deploy/pull-backups.sh            run once
#   deploy/pull-backups.sh --install  run daily, as a systemd user timer
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# HOST comes from deploy/deploy.env, as for deploy.sh.
# shellcheck source=/dev/null
[[ -f $HERE/deploy.env ]] && source "$HERE/deploy.env"
[[ -n ${HOST:-} ]] || { echo "Set HOST in $HERE/deploy.env first." >&2; exit 1; }
DATA=${XDG_DATA_HOME:-$HOME/.local/share}/dustpan
OUT=$DATA/backups

if [[ ${1:-} == --install ]]; then
  units=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  mkdir -p "$units"
  sed "s|@SCRIPT@|$HERE/pull-backups.sh|" "$HERE/dustpan-backup.service" > "$units/dustpan-backup.service"
  cp "$HERE/dustpan-backup.timer" "$units/"
  systemctl --user daemon-reload
  systemctl --user enable --now dustpan-backup.timer
  exit 0
fi

mkdir -p "$OUT/server" "$OUT/client"

# No --delete: the server keeps 14 days, this PC keeps 90.
rsync -a -e "ssh -o BatchMode=yes" "$HOST:/var/lib/opentodo/backups/" "$OUT/server/"

if [[ -f $DATA/dustpan.db ]]; then
  # SQLite's backup API gives a consistent copy while the app is open.
  python3 - "$DATA/dustpan.db" "$OUT/client/dustpan-$(date +%Y%m%d).db" <<'EOF'
import sqlite3, sys
src, dst = sqlite3.connect(sys.argv[1]), sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()
EOF
fi

find "$OUT" -type f -mtime +90 -delete

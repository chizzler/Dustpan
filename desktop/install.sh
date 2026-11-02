#!/usr/bin/env bash
# Install the desktop client for this user, running from this checkout.
#   desktop/install.sh            launcher, menu entry, icon, and start hidden at login
#   desktop/install.sh --remove   take them all out again (data and config stay)
# A git pull updates the app. Restart it (Ctrl+Q, then open) to pick up changes.
set -euo pipefail

ID=io.github.chizzler.Dustpan
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$HOME/.local/bin/dustpan
APPS=${XDG_DATA_HOME:-$HOME/.local/share}/applications
ICONS=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps
AUTOSTART=${XDG_CONFIG_HOME:-$HOME/.config}/autostart

if [[ ${1:-} == --remove ]]; then
  rm -f "$BIN" "$APPS/$ID.desktop" "$ICONS/$ID.svg" "$AUTOSTART/$ID.desktop"
  exit 0
fi

mkdir -p "$(dirname "$BIN")" "$APPS" "$ICONS" "$AUTOSTART"
cat > "$BIN" <<EOF
#!/bin/sh
PYTHONPATH="$HERE" exec python3 -m dustpan "\$@"
EOF
chmod 755 "$BIN"

sed "s|@BIN@|$BIN|" "$HERE/data/$ID.desktop" > "$APPS/$ID.desktop"
cp "$HERE/data/$ID.svg" "$ICONS/"
# At login: no window, just sync and reminders. Opening Dustpan shows the window.
sed -e "s|@BIN@|$BIN --background|" -e '/^Categories=/d' -e '/^Keywords=/d' \
  "$HERE/data/$ID.desktop" > "$AUTOSTART/$ID.desktop"

update-desktop-database "$APPS" 2>/dev/null || true
echo "Installed. Find Dustpan in the app launcher. It starts hidden at your next login."

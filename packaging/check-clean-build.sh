#!/usr/bin/env bash
# Build and install only inside a disposable official Arch container. No host install or publication.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RELEASE_DIR=$(realpath "${1:-$ROOT/dist/linux}")
read -r _digest SOURCE_NAME < "$RELEASE_DIR/SHA256SUMS"
test -f "$RELEASE_DIR/PKGBUILD"
test -f "$RELEASE_DIR/$SOURCE_NAME"

docker run --rm \
  --mount "type=bind,source=$RELEASE_DIR,target=/input,readonly" \
  --env "DUSTPAN_SOURCE_NAME=$SOURCE_NAME" \
  archlinux:base-devel bash -c '
set -euo pipefail
pacman -Syu --noconfirm --needed namcap
useradd -m builder
printf "builder ALL=(ALL) NOPASSWD: /usr/bin/pacman\n" > /etc/sudoers.d/builder
chmod 440 /etc/sudoers.d/builder
install -d -o builder -g builder /work
cp /input/PKGBUILD "/input/$DUSTPAN_SOURCE_NAME" /work/
chown -R builder:builder /work
runuser -u builder -- bash -c "cd /work && makepkg --syncdeps --check --noconfirm"
namcap /work/PKGBUILD /work/dustpan-*-any.pkg.tar.zst
pacman -U --noconfirm /work/dustpan-*-any.pkg.tar.zst
/usr/bin/dustpan --version
PYTHONPATH=/usr/lib/dustpan python -c "from dustpan.app import Window; from dustpan.quickadd.words import VOCABS; assert VOCABS"
test -f /usr/lib/dustpan/data/io.github.chizzler.Dustpan.svg
test ! -e /etc/xdg/autostart/io.github.chizzler.Dustpan.desktop
pacman -R --noconfirm dustpan
test ! -e /usr/bin/dustpan
printf "PASS: clean Arch build, tests, installed launcher/imports/assets, and removal.\n"
'

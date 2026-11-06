#!/usr/bin/env bash
# Run a local OpenTodo server to develop against.
# Downloads the pinned release once, checks its SHA256 sum, then serves on localhost.
# Data lives in dev/data. Delete that folder to start fresh.
set -euo pipefail

VERSION=v0.22.0
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) ASSET=opentodo-linux-amd64 ;;
  Darwin-arm64) ASSET=opentodo-darwin-arm64 ;;
  *) echo "no OpenTodo build for $(uname -sm)" >&2; exit 1 ;;
esac
BASE=https://github.com/OpenTodoApp/OpenTodo/releases/download/$VERSION

DEV=$(cd "$(dirname "$0")" && pwd)
BIN=$DEV/bin/$VERSION
mkdir -p "$BIN" "$DEV/data"

if [[ ! -x $BIN/$ASSET ]]; then
  curl -fsSL -o "$BIN/SHA256SUMS" "$BASE/SHA256SUMS"
  curl -fsSL -o "$BIN/$ASSET" "$BASE/$ASSET"
  SUM=$(command -v sha256sum || echo "shasum -a 256")
  (cd "$BIN" && grep " $ASSET\$" SHA256SUMS | $SUM -c -)
  chmod +x "$BIN/$ASSET"
fi

export OPENTODO_ADDR=127.0.0.1:8080
export OPENTODO_DATA_DIR=$DEV/data
export OPENTODO_PUSH=off
exec "$BIN/$ASSET"

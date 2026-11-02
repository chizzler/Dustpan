#!/usr/bin/env bash
# Run the desktop client against the local dev server.
# Uses dev/credentials and keeps its data in dev/data/client, apart from any real install.
# Arguments pass through: client.sh sync, client.sh tree, or none for the app.
set -euo pipefail

DEV=$(cd "$(dirname "$0")" && pwd)
export DUSTPAN_CONFIG=$DEV/credentials
export DUSTPAN_DATA=$DEV/data/client
export PYTHONPATH=$DEV/../desktop
exec python3 -m dustpan "$@"

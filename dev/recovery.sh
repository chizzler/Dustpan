#!/bin/bash
# Run the recovery rehearsal in a private network and filesystem namespace.
set -euo pipefail
exec python3 "$(dirname "$0")/recovery.py" "$@"

#!/usr/bin/env bash
# Stop both LND nodes. --wipe also deletes their data for a clean slate.
set -euo pipefail
source "$(dirname "$0")/env.sh"
for n in alice bob; do
  if lncli_node "$n" stop >/dev/null 2>&1; then echo "stopped $n"; else echo "$n not running"; fi
done
if [ "${1:-}" = "--wipe" ]; then rm -rf "$LN_DIR"; echo "wiped $LN_DIR"; fi

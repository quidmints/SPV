#!/usr/bin/env bash
# Stop the regtest bitcoind. Add --wipe to also delete the chain data for a
# clean slate next start.
set -euo pipefail
source "$(dirname "$0")/env.sh"

if "$BITCOIN_CLI" -datadir="$DATADIR" stop >/dev/null 2>&1; then
  echo "stopping bitcoind ..."
  for _ in $(seq 1 20); do "$BITCOIN_CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1 || break; sleep 1; done
else
  echo "bitcoind not running"
fi

if [ "${1:-}" = "--wipe" ]; then
  rm -rf "$DATADIR"
  echo "wiped $DATADIR"
fi

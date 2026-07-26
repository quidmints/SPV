#!/usr/bin/env bash
# Stop the regtest bitcoind. Add --wipe to also delete the chain data for a
# clean slate next start.
set -euo pipefail
source "$(dirname "$0")/env.sh"

if cli stop >/dev/null 2>&1; then
  echo "stopping bitcoind ..."
  # Wait for the PROCESS to exit, not just for RPC to stop answering: bitcoind
  # closes the RPC port BEFORE it finishes flushing and releases the datadir lock,
  # so an RPC-only wait returns early and a following ./start.sh dies with
  # "Cannot obtain a lock on directory ... Bitcoin Core is probably already running".
  for _ in $(seq 1 30); do pgrep -f "bitcoind -datadir=$DATADIR" >/dev/null || break; sleep 1; done
else
  echo "bitcoind not running"
fi

if [ "${1:-}" = "--wipe" ]; then
  rm -rf "$DATADIR"
  echo "wiped $DATADIR"
fi

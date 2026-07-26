#!/usr/bin/env bash
# Regenerate the openChannel e2e fixture from the LIVE regtest node:
# fund a real P2WSH 2-of-2 channel output, confirm it, and emit the
# witness-stripped tx + SPV merkle proof + header chain that the Foundry test
# (evm/test/btc/OpenChannelE2E.t.sol) feeds into the REAL SPVGateway+BTCChannels.
set -euo pipefail
source "$(dirname "$0")/env.sh"

"$BITCOIN_CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1 \
  || { echo "regtest not running — ./start.sh first" >&2; exit 1; }

OUT="$SPV_DIR/evm/test/btc/open_channel_fixture.json"
BTC_CLI="$BITCOIN_CLI" DATADIR="$DATADIR" WALLET="$WALLET" \
  python3 "$SPV_DIR/evm/test/btc/gen_open_channel_fixture.py" > "$OUT"

echo "fixture → ${OUT#$SPV_DIR/}"
echo "now run:  (cd $SPV_DIR/evm && forge test --match-path test/btc/OpenChannelE2E.t.sol -vv)"

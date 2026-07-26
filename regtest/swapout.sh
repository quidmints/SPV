#!/usr/bin/env bash
# Trigger a swap-OUT (USD→BTC): alice (the swapper) makes an invoice to RECEIVE
# BTC, and the EVM obligates the hop to deliver (in production the V4 BTC pool
# emits this when a USD→BTC swap books). The daemon then pays it (bob→alice).
set -euo pipefail
source "$(dirname "$0")/env.sh"
SATS="${1:-20000}"
RPC="http://127.0.0.1:8545"
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
AUX=$(jq -r .aux "$SPV_DIR/evm/test/btc/hopdemo.addrs.json")

INV=$(lncli_node alice addinvoice --amt="$SATS" | jq -r .payment_request)
cast send "$AUX" "obligateSwapOut(uint256,string)" "$SATS" "$INV" \
  --rpc-url "$RPC" --private-key "$PK" >/dev/null
echo "swap-out obligated on-chain: $SATS sat → alice invoice ${INV:0:24}…"

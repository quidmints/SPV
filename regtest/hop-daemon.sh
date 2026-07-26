#!/usr/bin/env bash
# The QU!D hop daemon (thin). Watches bob's LND for SETTLED swap-in invoices and
# AUTONOMOUSLY settles each on-chain via BTCChannels.settleSwapIn — the LN→EVM
# bridge. The invoice memo carries the seller's EVM address (the swap-in bind);
# dedup is on the HTLC payment hash, both off-chain (.hop-processed) and on-chain
# (swapInUsed). Signs with the hop key (anvil acct[0]).
#   ./hop-daemon.sh once   single pass (the demo uses this)
#   ./hop-daemon.sh        watch loop (production)
set -uo pipefail
source "$(dirname "$0")/env.sh"
MODE="${1:-loop}"
RPC="http://127.0.0.1:8545"
HOP_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
TOKEN="0x0000000000000000000000000000000000000000"   # token tag (recorded by MockHopAux)
ADDRS="$SPV_DIR/evm/test/btc/hopdemo.addrs.json"
STATE="$HARNESS_DIR/.hop-processed"

[ -f "$ADDRS" ] || { echo "no $ADDRS — ./start-evm.sh first" >&2; exit 1; }
CH=$(jq -r .ch "$ADDRS"); AUX=$(jq -r .aux "$ADDRS"); touch "$STATE"

# swap-IN (BTC→USD): a settled invoice on bob → credit the seller on-chain.
process_swapins() {
  lncli_node bob listinvoices | jq -c '.invoices[] | select(.state=="SETTLED")' | while read -r inv; do
    rhash=$(echo "$inv" | jq -r .r_hash)
    grep -q "^in:$rhash$" "$STATE" && continue
    seller=$(echo "$inv" | jq -r .memo)
    sats=$(echo "$inv" | jq -r .amt_paid_sat)
    case "$seller" in 0x*[0-9a-fA-F]) ;; *) echo "in:$rhash" >>"$STATE"; continue ;; esac
    cast send "$CH" "settleSwapIn(address,uint256,address,bytes32)" \
        "$seller" "$sats" "$TOKEN" "0x$rhash" \
        --rpc-url "$RPC" --private-key "$HOP_PK" >/dev/null
    echo "in:$rhash" >>"$STATE"
    echo "  swap-IN  → settleSwapIn($seller, $sats sat, 0x${rhash:0:16}…)"
  done
}

# swap-OUT (USD→BTC): an on-chain obligation → the hop PAYS the swapper's invoice.
process_swapouts() {
  local n; n=$(cast call "$AUX" "swapOutCount()(uint256)" --rpc-url "$RPC" 2>/dev/null | tr -d -c '0-9')
  for (( i=0; i<${n:-0}; i++ )); do
    local ob sats invoice paid
    ob=$(cast call "$AUX" "swapOuts(uint256)(uint256,string,bool)" "$i" --rpc-url "$RPC")
    sats=$(echo "$ob"    | sed -n 1p | tr -d -c '0-9')
    invoice=$(echo "$ob" | sed -n 2p | tr -d '"')
    paid=$(echo "$ob"    | sed -n 3p)
    [ "$paid" = "true" ] && continue
    lncli_node bob payinvoice --force "$invoice" >/dev/null
    cast send "$AUX" "markSwapOutPaid(uint256)" "$i" --rpc-url "$RPC" --private-key "$HOP_PK" >/dev/null
    echo "  swap-OUT ← hop paid the swapper's invoice ($sats sat)"
  done
}

process_once() { process_swapins; process_swapouts; }

if [ "$MODE" = once ]; then
  echo "hop daemon: single pass"; process_once
else
  echo "hop daemon: watching bob for swap-in HTLCs (Ctrl-C to stop)"
  while true; do process_once; sleep 3; done
fi

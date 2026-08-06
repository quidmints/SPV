#!/usr/bin/env bash
# Perform a REAL Lightning HTLC swap-in: alice (the BTC seller) pays bob (the
# hop) an invoice for $1 SATS; bob learns the preimage. Emits the fixture the
# Foundry test feeds into settleSwapIn → Aux.creditSwapIn.
#   swapin_fixture.json: { sats, paymentHash (=sha256(preimage)), preimage }
set -euo pipefail
source "$(dirname "$0")/env.sh"
SATS="${1:-50000}"
# The seller's EVM address, carried in the invoice memo (how a swap-in binds the
# BTC payer to the address that should receive QD). Defaults to anvil acct[1].
SELLER="${2:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"

lncli_node alice getinfo >/dev/null 2>&1 || { echo "LN not up — ./start-ln.sh first" >&2; exit 1; }

INV=$(lncli_node bob addinvoice --amt="$SATS" --memo="$SELLER")
PAYREQ=$(echo "$INV" | jq -r .payment_request)
RHASH=$(echo "$INV"  | jq -r .r_hash)        # payment hash, hex

lncli_node alice payinvoice --force "$PAYREQ" >/dev/null

# Poll bob until the invoice is SETTLED, then read the revealed preimage.
for _ in $(seq 1 20); do
  LOOK=$(lncli_node bob lookupinvoice "$RHASH")
  [ "$(echo "$LOOK" | jq -r .state)" = "SETTLED" ] && break
  sleep 1
done
[ "$(echo "$LOOK" | jq -r .state)" = "SETTLED" ] || { echo "invoice not settled" >&2; exit 1; }

PRE=$(echo "$LOOK" | jq -r .r_preimage)       # preimage, hex
PAID=$(echo "$LOOK" | jq -r .amt_paid_sat)

# Write to the .local. sibling, NEVER to the committed vector. The committed
# swapin_fixture.json is the OFFLINE vector — the only thing a machine without the
# bitcoind/LND harness can check the HTLC tie against. Overwriting it here meant it
# was regenerated microseconds before every read (so its committed value was never
# the value under test) and left the tree dirty after every suite run.
cat > "$SPV_DIR/evm/test/btc/swapin_fixture.local.json" <<EOF
{
  "sats": $PAID,
  "seller": "$SELLER",
  "paymentHash": "0x$RHASH",
  "preimage": "0x$PRE"
}
EOF
echo "swap settled — $PAID sat → $SELLER, hash 0x${RHASH:0:16}…, preimage captured → swapin_fixture.local.json"

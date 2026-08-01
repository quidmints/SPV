#!/usr/bin/env bash
# (#114) DEAD-MAN FRESHNESS UTXO — consensus-level proof, on a real bitcoind.
#
# The dead-man design rests on ONE claim that no unit test can settle, because it is a
# property of Bitcoin consensus rather than of our code:
#
#   A pre-signed exit carrying a second "freshness" input becomes UNBROADCASTABLE the
#   moment that input is spent — even though the exit is fully signed, its locktime has
#   matured, and its other input is untouched.
#
# That is what stops a matured, SUPERSEDED exit from force-closing a live channel. If it
# does not hold, the whole freshness-UTXO design is void.
#
#   PASS ⇒ prints READY. Any other output ⇒ the environment or the claim failed; the
#   caller must NOT treat a missing READY as success.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

[ -x "$BITCOIND" ] || { echo "SKIP: bitcoind absent — run regtest/setup.sh"; exit 0; }

DD="$HARNESS_DIR/.regtest-freshness"
cli() { "$BITCOIN_CLI" -regtest -datadir="$DD" -rpcport=$((RPC_PORT + 7)) "$@"; }
cleanup() { cli stop >/dev/null 2>&1 || true; sleep 1; rm -rf "$DD"; }
trap cleanup EXIT

rm -rf "$DD"; mkdir -p "$DD"
"$BITCOIND" -regtest -datadir="$DD" -rpcport=$((RPC_PORT + 7)) -port=$((RPC_PORT + 8)) \
    -fallbackfee=0.0002 -daemon >/dev/null
for _ in $(seq 60); do cli getblockchaininfo >/dev/null 2>&1 && break; sleep 0.5; done

cli createwallet dm >/dev/null
ADDR=$(cli getnewaddress)
cli generatetoaddress 101 "$ADDR" >/dev/null

# Two independent outputs: A stands in for the CHANNEL FUNDING input, B for the shared
# FRESHNESS input. Distinct amounts so they are unambiguous in the UTXO set.
# ONE transaction with both outputs: two separate sends would let the second one select
# the first one's output as its input, destroying it before we ever reference it.
ADDR_B=$(cli getnewaddress)
cli sendmany "" "{\"$ADDR\":0.50,\"$ADDR_B\":0.10}" >/dev/null
cli generatetoaddress 1 "$ADDR" >/dev/null

# Read the outpoints straight from the UTXO set: `gettransaction` details also list the
# CHANGE output of a self-send, so matching on amount there picks the wrong vout and the
# resulting tx references an outpoint that does not exist ("missing-inputs").
read -r TXA VA TXB VB <<<"$(cli listunspent 1 | python3 -c "
import json,sys
u=json.load(sys.stdin)
def pick(amt):
    for x in u:
        if abs(x['amount']-amt) < 1e-9:
            return x
    raise SystemExit(f'no confirmed {amt} BTC utxo')
a,b = pick(0.50), pick(0.10)
print(a['txid'], a['vout'], b['txid'], b['vout'])
")"

TIP=$(cli getblockcount)
LOCK=$((TIP + 2))
DEST=$(cli getnewaddress)

# The pre-signed "exit": spends A (funding) AND B (freshness), CLTV-locked. This mirrors
# `build_deadman_exit_tx` with `freshness = Some(..)`.
RAW=$(cli createrawtransaction \
    "[{\"txid\":\"$TXA\",\"vout\":$VA},{\"txid\":\"$TXB\",\"vout\":$VB}]" \
    "{\"$DEST\":0.59}" "$LOCK")
EXIT_TX=$(cli signrawtransactionwithwallet "$RAW" | python3 -c "import json,sys;print(json.load(sys.stdin)['hex'])")

# Mature the locktime, so the ONLY thing that can stop the broadcast is a spent input.
cli generatetoaddress 3 "$ADDR" >/dev/null

# ── (1) CONTROL: with both inputs unspent, the matured exit IS broadcastable ──────────
# Without this the negative result below would prove nothing — the tx could have been
# malformed all along.
if ! cli testmempoolaccept "[\"$EXIT_TX\"]" | grep -q '"allowed": true'; then
    echo "FAIL(control): a matured, fully-signed exit was rejected while both inputs were unspent"
    cli testmempoolaccept "[\"$EXIT_TX\"]"
    exit 1
fi

# ── (2) ROTATE: spend the FRESHNESS input, exactly as `spend_outpoint_to_self` does ───
ROT=$(cli createrawtransaction "[{\"txid\":\"$TXB\",\"vout\":$VB}]" "{\"$DEST\":0.099}")
ROT_SIGNED=$(cli signrawtransactionwithwallet "$ROT" | python3 -c "import json,sys;print(json.load(sys.stdin)['hex'])")
cli sendrawtransaction "$ROT_SIGNED" >/dev/null
cli generatetoaddress 1 "$ADDR" >/dev/null

# ── (3) THE PROPERTY: the SAME signed exit is now unbroadcastable ─────────────────────
RESULT=$(cli testmempoolaccept "[\"$EXIT_TX\"]")
if echo "$RESULT" | grep -q '"allowed": true'; then
    echo "FAIL: a superseded exit was STILL accepted after its freshness input was spent"
    echo "$RESULT"
    exit 1
fi
echo "$RESULT" | grep -q "missing-inputs\|bad-txns-inputs-missingorspent" || {
    echo "FAIL: rejected, but not for the expected reason (spent input):"; echo "$RESULT"; exit 1; }

echo "READY: freshness-UTXO invalidation holds at consensus"
echo "  (1) matured 2-input exit accepted while freshness unspent"
echo "  (2) freshness input spent (rotation)"
echo "  (3) same signed exit now rejected: missing-inputs"

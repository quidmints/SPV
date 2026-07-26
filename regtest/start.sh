#!/usr/bin/env bash
# Boot a local regtest bitcoind, create the wallet, and mature the coinbase
# (mine 101 blocks — instant on regtest). Idempotent: safe to re-run.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ -x "$BITCOIND" ] || { echo "run ./setup.sh first" >&2; exit 1; }
mkdir -p "$DATADIR"

cat > "$DATADIR/bitcoin.conf" <<EOF
regtest=1
server=1
txindex=1
fallbackfee=0.0002
rpcuser=quid
rpcpassword=quid
# ZMQ feeds so an LND node can follow the chain (see start-ln.sh).
zmqpubrawblock=tcp://127.0.0.1:$ZMQ_BLOCK
zmqpubrawtx=tcp://127.0.0.1:$ZMQ_TX
[regtest]
rpcport=$RPC_PORT
EOF

if cli getblockchaininfo >/dev/null 2>&1; then
  echo "bitcoind already running (height $(cli getblockcount))"
else
  "$BITCOIND" -datadir="$DATADIR" -daemon >/dev/null
  echo -n "waiting for RPC"
  for _ in $(seq 1 30); do cli getblockchaininfo >/dev/null 2>&1 && break; echo -n "."; sleep 1; done
  echo
fi

# Wallet (create or load).
if ! cli listwallets | grep -q "\"$WALLET\""; then
  cli -named createwallet wallet_name="$WALLET" >/dev/null 2>&1 \
    || cli loadwallet "$WALLET" >/dev/null 2>&1 || true
fi

# Mature coinbase: regtest needs 100 confirmations before coinbase is spendable.
H=$(cli getblockcount)
if [ "$H" -lt 101 ]; then
  ADDR=$(wcli getnewaddress)
  cli generatetoaddress $((101 - H)) "$ADDR" >/dev/null
fi

# A chain-following LND (start-ln.sh) reports synced_to_chain=true only once
# bitcoind leaves initialblockdownload (IBD). bitcoind stays in IBD whenever the
# chain TIP is stale (tip timestamp older than ~24h) — which is EXACTLY what a
# datadir persisted from a prior session looks like (its last block is days old).
# The node then spins on "synced_to_chain=false" until start-ln.sh times out,
# and the whole swap-in orchestration reports a spurious failure. Mining one block
# with a current timestamp bumps the tip to "now" and clears IBD, so re-runs
# against an old datadir sync cleanly (no wipe required — the harness is idempotent).
if cli getblockchaininfo | grep -q '"initialblockdownload": true'; then
  ADDR=$(wcli getnewaddress)
  cli generatetoaddress 1 "$ADDR" >/dev/null
  echo "mined a fresh block to clear IBD (persisted datadir had a stale tip)"
fi

echo "regtest up — height $(cli getblockcount), balance $(wcli getbalance) BTC, rpc 127.0.0.1:$RPC_PORT (quid:quid)"

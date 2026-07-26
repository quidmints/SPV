#!/usr/bin/env bash
# Shared paths/config for the QU!D regtest harness. Sourced by the other scripts.
# Everything lives UNDER this folder (no /tmp, no sudo, no system install).
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPV_DIR="$(cd "$HARNESS_DIR/.." && pwd)"

BITCOIN_VERSION="28.1"
CORE_DIR="$HARNESS_DIR/.bitcoin-core/bitcoin-$BITCOIN_VERSION"
BITCOIND="$CORE_DIR/bin/bitcoind"
BITCOIN_CLI="$CORE_DIR/bin/bitcoin-cli"

DATADIR="$HARNESS_DIR/.regtest"
RPC_PORT=18443
WALLET="quid"
ZMQ_BLOCK=28332
ZMQ_TX=28333

LND_VERSION="v0.20.1-beta"

# ── Release-artifact platform — ONE table, both downloaders derive from it ──
# bitcoin-core and LND name their releases differently (and bitcoin uses `aarch64`
# on linux but `arm64` on darwin), so the mapping is spelled out per host rather
# than string-munged from `uname`. setup.sh and setup-ln.sh consume these; neither
# does its own detection.
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64|Linux/amd64)   BTC_PLAT=x86_64-linux-gnu    ; LND_PLAT=linux-amd64  ;;
  Linux/aarch64|Linux/arm64)  BTC_PLAT=aarch64-linux-gnu   ; LND_PLAT=linux-arm64  ;;
  Darwin/x86_64)              BTC_PLAT=x86_64-apple-darwin ; LND_PLAT=darwin-amd64 ;;
  Darwin/arm64)               BTC_PLAT=arm64-apple-darwin  ; LND_PLAT=darwin-arm64 ;;
  *) echo "unsupported host $(uname -s)/$(uname -m) — install bitcoin-core $BITCOIN_VERSION into $CORE_DIR and LND $LND_VERSION into .lnd-dist/ manually" >&2; exit 1 ;;
esac

# ── Lightning (LND) — two nodes: alice (LP/seller) + bob (hop) ──
LND_DIST="$HARNESS_DIR/.lnd-dist/lnd-$LND_PLAT-$LND_VERSION"
LND="$LND_DIST/lnd"
LNCLI="$LND_DIST/lncli"
LN_DIR="$HARNESS_DIR/.lnd"
# node → "rpcport p2pport restport"
ln_ports() { case "$1" in
  alice) echo "10009 9735 8091" ;;
  bob)   echo "10010 9736 8092" ;;
esac }
# lncli bound to a node (no macaroons on regtest).
lncli_node() { local n="$1"; shift
  read -r rpc _ _ <<<"$(ln_ports "$n")"
  "$LNCLI" --network=regtest --rpcserver="127.0.0.1:$rpc" \
    --lnddir="$LN_DIR/$n" --no-macaroons "$@"; }

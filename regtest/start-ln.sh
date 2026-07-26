#!/usr/bin/env bash
# Bring up two LND nodes on the regtest bitcoind and open an alice→bob channel.
#   alice = LP / BTC seller   bob = the QU!D hop
# Idempotent: re-running is a no-op once the channel is active.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ -x "$LND" ] || { echo "run ./setup-ln.sh first" >&2; exit 1; }
require_node
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

# A node counts as ready only when its RPC is up AND it is synced to the CURRENT
# regtest chain. Bare `getinfo` succeeding is NOT enough: a node left over from a
# previous regtest (the chain was regenerated, e.g. by the §9b fixture work) is
# stuck forever on "-8: Block height out of range" while its RPC still answers —
# which is exactly the stall that made this test look unrunnable.
node_synced() { lncli_node "$1" getinfo 2>/dev/null | jq -e '.synced_to_chain == true' >/dev/null 2>&1; }

start_node() {
  local n="$1"; read -r rpc p2p _ <<<"$(ln_ports "$n")"
  local d="$LN_DIR/$n"
  if node_synced "$n"; then echo "  $n already up + synced"; return; fi
  # Not synced → either not running, or a STALE instance pinned to an old/taller
  # chain. Kill any leftover process and wipe its chain/wallet state (regtest is
  # ephemeral; noseedbackup regenerates the wallet, and BOB_PUB is read live), so
  # it re-syncs cleanly from the current chain instead of spinning on out-of-range.
  pkill -f "lnd --lnddir=$d" 2>/dev/null || true
  sleep 1
  rm -rf "$d"; mkdir -p "$d"
  cat > "$d/lnd.conf" <<EOF
[Application Options]
no-macaroons=true
noseedbackup=true
norest=true
debuglevel=error
rpclisten=127.0.0.1:$rpc
listen=127.0.0.1:$p2p
[Bitcoin]
bitcoin.active=true
bitcoin.regtest=true
bitcoin.node=bitcoind
[Bitcoind]
bitcoind.rpchost=127.0.0.1:$RPC_PORT
bitcoind.rpcuser=quid
bitcoind.rpcpass=quid
bitcoind.zmqpubrawblock=tcp://127.0.0.1:$ZMQ_BLOCK
bitcoind.zmqpubrawtx=tcp://127.0.0.1:$ZMQ_TX
EOF
  # Fully DETACH the daemon (new session, no controlling tty, stdin from
  # /dev/null, disowned) so the orchestrator — and its callers (forge vm.ffi, a
  # CI runner) — can exit cleanly without waiting on a child that never returns.
  # `setsid` is util-linux and does NOT exist on macOS, where it aborted the whole
  # script; `nohup` is POSIX and gives the same practical detachment here (stdin is
  # already </dev/null so there's no controlling tty, SIGHUP is ignored, and the job
  # is disowned so nothing waits on it). Prefer setsid where present — Linux keeps
  # its exact prior behaviour.
  DETACH="$(command -v setsid || command -v nohup)"
  "$DETACH" "$LND" --lnddir="$d" >"$d/lnd.log" 2>&1 </dev/null &
  disown 2>/dev/null || true
  echo -n "  starting $n"
  for _ in $(seq 1 120); do node_synced "$n" && break; echo -n "."; sleep 1; done
  echo
  node_synced "$n" || { echo "  $n failed to sync:" >&2; tail -8 "$d/lnd.log" >&2; exit 1; }
}

echo "starting LND nodes..."
start_node alice
start_node bob

BOB_PUB=$(lncli_node bob getinfo | jq -r .identity_pubkey)
read -r _ BOB_P2P _ <<<"$(ln_ports bob)"

# Fund alice with on-chain BTC if needed.
abal() { lncli_node alice walletbalance | jq -r .confirmed_balance; }
if [ "$(abal)" -lt 2000000 ]; then
  ADDR=$(lncli_node alice newaddress p2wkh | jq -r .address)
  wcli sendtoaddress "$ADDR" 1 >/dev/null
  mine 6
  echo -n "  funding alice"
  for _ in $(seq 1 30); do [ "$(abal)" -ge 2000000 ] && break; echo -n "."; sleep 1; done; echo
fi

# Open alice→bob channel if none active.
nchan() { lncli_node alice listchannels | jq '[.channels[]|select(.active)]|length'; }
if [ "$(nchan)" -eq 0 ]; then
  lncli_node alice connect "$BOB_PUB@127.0.0.1:$BOB_P2P" >/dev/null 2>&1 || true
  lncli_node alice openchannel --node_key="$BOB_PUB" --local_amt=500000 >/dev/null
  echo -n "  opening channel"
  for _ in $(seq 1 60); do [ "$(nchan)" -ge 1 ] && break; mine 1; echo -n "."; sleep 1; done; echo
fi

[ "$(nchan)" -ge 1 ] || { echo "channel did not activate" >&2; exit 1; }
echo "LN up — alice→bob channel active (cap $(lncli_node alice listchannels | jq -r '.channels[0].capacity') sat)"

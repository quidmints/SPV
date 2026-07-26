#!/usr/bin/env bash
# Start a local anvil EVM and deploy the hop-daemon demo stack (MockSPV +
# MockHopAux + a real BTCChannels). Writes evm/test/btc/hopdemo.addrs.json.
# anvil account[0] is the hop key the daemon signs with.
set -euo pipefail
source "$(dirname "$0")/env.sh"

ANVIL_PORT=8545
# Well-known anvil account[0] (deterministic dev key — regtest/anvil only).
export PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RPC="http://127.0.0.1:$ANVIL_PORT"

if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "anvil already running on $ANVIL_PORT"
else
  nohup anvil --port "$ANVIL_PORT" --silent >"$HARNESS_DIR/.anvil.log" 2>&1 &
  echo -n "waiting for anvil"
  for _ in $(seq 1 30); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; echo -n "."; sleep 1; done
  echo
fi

echo "deploying demo stack ..."
export ETHERSCAN_L1="${ETHERSCAN_L1:-unused}"   # foundry.toml [etherscan] interpolates it; no verification here
( cd "$SPV_DIR/evm" && forge script script/HopDemo.s.sol --tc HopDemo --rpc-url "$RPC" \
    --broadcast --private-key "$PRIVATE_KEY" >/tmp/quid-hopdemo-deploy.log 2>&1 ) \
  || { echo "deploy failed — see /tmp/quid-hopdemo-deploy.log" >&2; tail -20 /tmp/quid-hopdemo-deploy.log >&2; exit 1; }

echo "EVM up — $RPC  addrs → evm/test/btc/hopdemo.addrs.json"
cat "$SPV_DIR/evm/test/btc/hopdemo.addrs.json"

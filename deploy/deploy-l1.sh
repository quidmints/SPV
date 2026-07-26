#!/usr/bin/env bash
# Deploy the QU!D L1 contracts (evm/src/DeployL1_s.sol:Deploy) — the full
# topology incl. SPVGateway + BTCChannels. Dry-run by default; set BROADCAST=1
# to actually send. Usage: [BROADCAST=1] deploy/deploy-l1.sh [env-file]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$REPO/deploy/deploy.env}"

[ -f "$ENV_FILE" ] || { echo "env file not found: $ENV_FILE (copy deploy/deploy.env.example)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

command -v forge >/dev/null || { echo "foundry not installed — curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2; exit 1; }

: "${RPC_URL:?set RPC_URL}" "${PRIVATE_KEY:?set PRIVATE_KEY}" \
  "${BTC_CHECKPOINT_HEADER:?}" "${BTC_CHECKPOINT_HEIGHT:?}" "${BTC_CHECKPOINT_WORK:?}"

ARGS=(script src/DeployL1_s.sol:Deploy --rpc-url "$RPC_URL")
[ "${BROADCAST:-0}" = "1" ] && ARGS+=(--broadcast) || echo "[deploy-l1] DRY RUN (set BROADCAST=1 to send)" >&2
[ -n "${VERIFY:-}" ] && ARGS+=(--verify)
# foundry.toml's [etherscan] interpolates ${ETHERSCAN_L1} at config load (even
# without --verify). Use the real key if verifying; a dummy otherwise.
export ETHERSCAN_L1="${ETHERSCAN_L1:-dummy}"

# ── Local-anvil ANGEL seed grant ──────────────────────────────────────────────
# DeployL1_s requires the deployer to own the Foundation ANGEL NFT (DeployLib
# approves Aux for it; Basket's ctor requires that approval; Aux.finalize burns
# it). On a REAL deploy the Safe owns ANGEL. On a LOCAL ANVIL fork the deployer
# doesn't, so impersonate ANGEL's live owner and transfer it in — mirrors
# spa/e2e-faucet.sh's storage overrides. Gated on the RPC actually being anvil
# (anvil_nodeInfo only responds there), so a real mainnet deploy is untouched.
F8N=0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405; ANGEL=16508
if cast rpc anvil_nodeInfo --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
  AO=$(cast call "$F8N" 'ownerOf(uint256)(address)' "$ANGEL" --rpc-url "$RPC_URL")
  if [ "${AO,,}" != "${DEPLOYER,,}" ]; then
    echo "[deploy-l1] anvil: granting ANGEL #$ANGEL to deployer $DEPLOYER (impersonating $AO)" >&2
    cast rpc anvil_impersonateAccount "$AO" --rpc-url "$RPC_URL" >/dev/null
    cast rpc anvil_setBalance "$AO" 0xde0b6b3a7640000 --rpc-url "$RPC_URL" >/dev/null   # 1 ETH gas
    cast send "$F8N" 'transferFrom(address,address,uint256)' "$AO" "$DEPLOYER" "$ANGEL" \
      --from "$AO" --unlocked --rpc-url "$RPC_URL" >/dev/null
    cast rpc anvil_stopImpersonatingAccount "$AO" --rpc-url "$RPC_URL" >/dev/null
  fi
fi

cd "$REPO/evm"
exec forge "${ARGS[@]}"

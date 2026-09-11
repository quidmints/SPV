#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Channel-DRIVER e2e against a REAL anvil EVM (no mock RPC).
#
# Bootstraps every binary it needs (installs if missing), deploys the REAL FULL
# QU!D stack (Vogue/Core/Aux/Basket/Vault + SPVGateway + BTCChannels, via the
# shared DeployLib) onto a fresh anvil MAINNET FORK — no StubVault — and runs
# quid-bridge's driver_e2e test, which drives REAL openChannel / recordClose /
# requestSwapOutOnchain / deliverSwapOutOnchain from the Rust driver against those
# contracts while the SPV relayer feeds the live regtest header chain.
#
# The real Vault needs mainnet state (PoolManager, tokens, Morpho vaults, feeds),
# so this MUST fork mainnet. Acct #0 is pre-funded with USDC (impersonating a
# mainnet whale) so DriverE2E can seed basket TVL and the swap-out swapper can pay.
#
# Anyone cloning the repo can run:   regtest/driver-e2e.sh
#
# Env overrides:
#   QUID_FORK_RPC   mainnet RPC to fork (default: foundry.toml `mainnet`).
#   ANVIL_PORT      default 8545.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"
# env.sh owns the pinned bitcoin-core/LND versions + the platform table. Source it
# so BITCOIND comes from the ONE pin (BITCOIN_VERSION) instead of a copy-pasted
# path literal that silently desyncs the moment the pin moves.
source "$HARNESS_DIR/env.sh"
EVM_DIR="$REPO/evm"
# NB: the cargo workspace, NOT env.sh's `LN_DIR` (which is the LND *data* dir,
# $HARNESS_DIR/.lnd). Deliberately a different name — the two were colliding.
RUST_WS="$REPO/quid-ln"
ANVIL_PORT="${ANVIL_PORT:-8545}"
ANVIL_RPC="http://127.0.0.1:$ANVIL_PORT"
# The fork RPC: QUID_FORK_RPC, else the keyed ETH_RPC_URL from evm/.env (the same one every
# forge fork suite uses), else the public endpoint. ⚠️ THE PUBLIC ENDPOINT CANNOT FINISH THE
# DEPLOY: a fresh full-stack deploy simulates thousands of lazily-fetched storage reads, and
# measured 2026-09-11 it sat 24 minutes on publicnode without landing one contract. With a key
# the run also passes `--no-rate-limit`, because anvil otherwise throttles ITSELF to 330
# compute-units/s against any fork provider — the key buys nothing until that is off.
if [ -z "${QUID_FORK_RPC:-}" ] && [ -f "$EVM_DIR/.env" ]; then
  # The .env line carries an inline `# comment`; take the URL token only.
  QUID_FORK_RPC="$(sed -n 's/^ETH_RPC_URL=//p' "$EVM_DIR/.env" | head -1 | awk '{print $1}')"
fi
FORK_RPC="${QUID_FORK_RPC:-https://ethereum-rpc.publicnode.com}"
FORK_RPC_HOST="${FORK_RPC#*://}"; FORK_RPC_HOST="${FORK_RPC_HOST%%/*}"
RATE_LIMIT_FLAG=()
[ "$FORK_RPC_HOST" != "ethereum-rpc.publicnode.com" ] && RATE_LIMIT_FLAG=(--no-rate-limit)

# Anvil's deterministic account #0 — also the hopNode (DriverE2E sets
# hopNode = deployer) and the driver's hot key, so the onlyHop gate passes.
ACCT0_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

log() { echo "[driver-e2e] $*" >&2; }

# ── 1. ensure binaries (install if missing) ──────────────────────────────────
if ! command -v anvil >/dev/null || ! command -v forge >/dev/null; then
  log "foundry (anvil/forge) not found — installing via foundryup"
  curl -fsSL https://foundry.paradigm.xyz | bash
  export PATH="$HOME/.foundry/bin:$PATH"
  foundryup
fi

# bitcoin-core (bitcoind) — reuse the pinned, checksum-verified downloader.
# $BITCOIND comes from env.sh (sourced above), so it always tracks BITCOIN_VERSION.
if [ ! -x "$BITCOIND" ]; then
  log "bitcoind not found — running setup.sh (downloads + verifies bitcoin-core)"
  "$HARNESS_DIR/setup.sh"
fi
export BITCOIND_EXE="$BITCOIND"

# electrs: the quid-hop harness auto-downloads a pinned electrs at build time
# (the `harness`/`esplora_*` cargo feature). Honor ELECTRS_EXE if the operator
# set one; otherwise electrsd::downloaded_exe_path() resolves it.
[ -n "${ELECTRS_EXE:-}" ] && export ELECTRS_EXE

# ── 2. start anvil (mainnet fork — the real Vault needs mainnet state) ────────
# --disable-code-size-limit: the real QU!D stack includes contracts that exceed
# the EIP-170 24576-byte runtime limit (Vogue ~26.3KB, Vault ~25.1KB — a
# PRE-EXISTING condition of the codebase, independent of this harness), so anvil
# must not enforce the limit for the deploy to land.
# Never echo the URL — a keyed one carries the key in its path.
log "starting anvil forking $FORK_RPC_HOST${RATE_LIMIT_FLAG:+ (keyed, anvil rate limit off)}"
# Pin the fork block: QUID_FORK_BLOCK if set, else the CURRENT head when the RPC is keyed (a
# pin is what lets anvil cache fetched state on disk instead of re-fetching it; a historical
# pin needs an ARCHIVE RPC, which the public endpoint is not — so unpinned there ⇒ `latest`).
FORK_BLOCK_FLAG=()
if [ -n "${QUID_FORK_BLOCK:-}" ]; then
  FORK_BLOCK_FLAG=(--fork-block-number "$QUID_FORK_BLOCK")
elif [ ${#RATE_LIMIT_FLAG[@]} -gt 0 ]; then
  FORK_BLOCK_FLAG=(--fork-block-number "$(cast block-number --rpc-url "$FORK_RPC")")
fi
[ ${#FORK_BLOCK_FLAG[@]} -gt 0 ] && log "fork pinned at block ${FORK_BLOCK_FLAG[1]}"
anvil --port "$ANVIL_PORT" --chain-id 31337 --silent --disable-code-size-limit "${RATE_LIMIT_FLAG[@]}" --fork-url "$FORK_RPC" "${FORK_BLOCK_FLAG[@]}" &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
# wait for the RPC to come up
for _ in $(seq 1 60); do
  if cast block-number --rpc-url "$ANVIL_RPC" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

# ── 2b. fund acct #0 with USDC (impersonate a mainnet whale on the fork) so the
#        DriverE2E script can seed basket TVL (mint QU!D) and the swap-out swapper
#        (acct #0 = the hot key) can pay its committed USD on the real vault. ─────
USDC_ADDR="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
USDC_WHALE="0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341"   # large USDC holder (same one Alles.t.sol funds from)
ACCT0_ADDR="$(cast wallet address "$ACCT0_KEY")"
log "funding $ACCT0_ADDR with 1,000,000 USDC from whale $USDC_WHALE (fork impersonation)"
cast rpc --rpc-url "$ANVIL_RPC" anvil_impersonateAccount "$USDC_WHALE" >/dev/null
cast rpc --rpc-url "$ANVIL_RPC" anvil_setBalance "$USDC_WHALE" 0xde0b6b3a7640000 >/dev/null  # 1 ETH for gas
cast send --rpc-url "$ANVIL_RPC" --from "$USDC_WHALE" --unlocked "$USDC_ADDR" \
  "transfer(address,uint256)" "$ACCT0_ADDR" 1000000000000 >/dev/null                          # 1,000,000 USDC (6-dec)
cast rpc --rpc-url "$ANVIL_RPC" anvil_stopImpersonatingAccount "$USDC_WHALE" >/dev/null

# ANGEL seed NFT: `DeployLib` approves Aux for Foundation tokenId `Basket.ANGEL` (16508) mid-deploy
# and Basket's constructor REQUIRES that approval — so the deployer must OWN it, exactly as the
# production msig does. `Alles.t.sol:775` prank-transfers it from whoever holds it at the fork
# head; do the same here, or the deploy dies at `approve` with
# "ERC721: approve caller is not owner nor approved for all" (measured 2026-09-11).
F8N_COLLECTION="0x3B3ee1931Dc30C1957379FAc9aba94D1C48a5405"
ANGEL_ID=16508
ANGEL_OWNER="$(cast call --rpc-url "$ANVIL_RPC" "$F8N_COLLECTION" "ownerOf(uint256)(address)" "$ANGEL_ID")"
log "handing ANGEL #$ANGEL_ID to $ACCT0_ADDR from its holder $ANGEL_OWNER (fork impersonation)"
cast rpc --rpc-url "$ANVIL_RPC" anvil_impersonateAccount "$ANGEL_OWNER" >/dev/null
cast rpc --rpc-url "$ANVIL_RPC" anvil_setBalance "$ANGEL_OWNER" 0xde0b6b3a7640000 >/dev/null
cast send --rpc-url "$ANVIL_RPC" --from "$ANGEL_OWNER" --unlocked "$F8N_COLLECTION" \
  "transferFrom(address,address,uint256)" "$ANGEL_OWNER" "$ACCT0_ADDR" "$ANGEL_ID" >/dev/null
cast rpc --rpc-url "$ANVIL_RPC" anvil_stopImpersonatingAccount "$ANGEL_OWNER" >/dev/null

# ── 3+4. deploy FRESH contracts per test, then run that ONE test ─────────────
# Each test drives its OWN regtest chain into the SPVGateway, so the tests MUST
# NOT share a gateway: the first test advances the gateway to its chain's headers,
# and a second test's divergent funding block (same regtest genesis, different
# blocks) would then fail SPV verification (BadSPV). We therefore redeploy the
# full stack (SPVGateway+BTCChannels+Vault, via DeployLib) before each test —
# anvil persists (incl. acct #0's USDC), and each Deploy lands at a fresh
# nonce-derived address, giving full per-test isolation.
deploy_and_run() {
  local test_name="$1"
  log "deploying DriverE2E (fresh full QU!D stack @ regtest-genesis SPVGateway) for $test_name"
  # foundry.toml's [etherscan] interpolates ${ETHERSCAN_L1} at config-load even
  # without --verify; give it a dummy. (Full compile incl. tests — no shortcuts.)
  local deploy_out gw ch
  # `|| true`: under `set -e` a failing command substitution in an assignment kills the script
  # BEFORE the echo below, losing the only copy of forge's error (measured 2026-09-11 — the log
  # ended at "deploying …" with nothing after it). Let the address check below report it.
  deploy_out="$(cd "$EVM_DIR" && ETHERSCAN_L1="${ETHERSCAN_L1:-dummy}" PRIVATE_KEY="$ACCT0_KEY" \
    forge script script/DriverE2E.s.sol:Deploy --rpc-url "$ANVIL_RPC" --broadcast --skip '*.t.sol' \
      --disable-code-size-limit --non-interactive 2>&1 || true)"
  echo "$deploy_out" >&2
  gw="$(echo "$deploy_out" | grep -E "^\s*QUID_SPV_GATEWAY " | tail -1 | awk '{print $2}')"
  ch="$(echo "$deploy_out" | grep -E "^\s*QUID_BTC_CHANNELS " | tail -1 | awk '{print $2}')"
  [ -n "$gw" ] && [ -n "$ch" ] || { log "deploy did not yield addresses"; exit 1; }
  log "SPVGateway=$gw BTCChannels=$ch  → running $test_name"
  ( cd "$RUST_WS" && \
    QUID_RPC_URL="$ANVIL_RPC" \
    QUID_CHAIN_ID="31337" \
    QUID_BTC_CHANNELS="$ch" \
    QUID_SPV_GATEWAY="$gw" \
    QUID_HOT_KEY="${ACCT0_KEY#0x}" \
    BITCOIND_EXE="$BITCOIND_EXE" \
      cargo test -p quid-bridge --features harness --test driver_e2e "$test_name" -- --nocapture --test-threads=1 )
}

[ -z "${DRIVER_E2E_ONLY:-}" ] && deploy_and_run channel_lifecycle_open_then_close_on_real_evm
[ -z "${DRIVER_E2E_ONLY:-}" ] && deploy_and_run swap_out_onchain_delivery_on_real_evm
deploy_and_run "${DRIVER_E2E_ONLY:-lp_raw_btc_withdrawal_on_real_evm}"

log "done"

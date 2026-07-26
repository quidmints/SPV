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
FORK_RPC="${QUID_FORK_RPC:-https://ethereum-rpc.publicnode.com}"

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
log "starting anvil forking $FORK_RPC"
# Pin the fork block ONLY when QUID_FORK_BLOCK is set (needs an ARCHIVE RPC — the public
# RPC rejects historical state). Unset ⇒ fork `latest` (works on the public RPC, slower).
FORK_BLOCK_FLAG=()
[ -n "${QUID_FORK_BLOCK:-}" ] && FORK_BLOCK_FLAG=(--fork-block-number "$QUID_FORK_BLOCK")
anvil --port "$ANVIL_PORT" --chain-id 31337 --silent --disable-code-size-limit --fork-url "$FORK_RPC" "${FORK_BLOCK_FLAG[@]}" &
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
  deploy_out="$(cd "$EVM_DIR" && ETHERSCAN_L1="${ETHERSCAN_L1:-dummy}" PRIVATE_KEY="$ACCT0_KEY" \
    forge script script/DriverE2E.s.sol:Deploy --rpc-url "$ANVIL_RPC" --broadcast --skip '*.t.sol' \
      --disable-code-size-limit --non-interactive 2>&1)"
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

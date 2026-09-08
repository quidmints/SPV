#!/usr/bin/env bash
# ⭐ §SESS-118 — RUN THE SUITE AGAINST A *SHARED* FORK BLOCK SO FOUNDRY'S CACHE IS ACTUALLY REUSED.
#
# 🔴 THE MEASURED PROBLEM. `ForkPin` defaults to LATEST (deliberately — §A.22 wants live state), and
#    **Foundry caches fork storage PER BLOCK NUMBER**. Two runs minutes apart fork at two different
#    heads, so the second run shares nothing with the first: measured 2026-09-08,
#    `~/.foundry/cache/rpc/mainnet/` held **771 block directories, ~1 MB each, 182 MB total** — a
#    write-once cache that was never read. Every run therefore paid FULL RPC cost, which is what
#    exhausted the key (64 × HTTP 429 in one run, retry windows of 10 minutes).
#
# ⇒ THE FIX IS NOT "PIN A HISTORICAL BLOCK" — that is what §A.18 rejected, because the suite would
#   stop exercising real current state. It is to pin the CURRENT head and REUSE that pin for a short
#   window, so a burst of runs (a baseline, a change, a re-check) shares one cache entry while the
#   state stays recent. Freshness is a knob, not a constant: FORK_TTL seconds, default 2h.
#
# USAGE:  tools/forge-test.sh [any forge test args]
#         FORK_TTL=600 tools/forge-test.sh          # tighter freshness
#         FORK_BLOCK=25934235 tools/forge-test.sh   # explicit pin wins, unchanged
#
# ⛔ LIVE-ROUTE SUITES ARE UNAFFECTED AND MUST STAY THAT WAY. `ConvertToRouted`, `OneInchRealFill`,
#    `OneInchGasProbe`, `OneInchObserverIsIndependent` and `CurveObserverIsCheapAndSane` call
#    `vm.createSelectFork(vm.envString("ETH_RPC_URL"))` DIRECTLY — they bypass `ForkPin` and are
#    unpinned by construction. That is required: their route is built against current mainnet by
#    `fetch_1inch_route.py`, and `ConvertToRouted`'s own header measures the failure — *"pinned 20
#    blocks behind head → got == 0; the identical test at head → 100.84 WETH."*
set -euo pipefail
cd "$(dirname "$0")/../evm"
set -a; . .env 2>/dev/null || true; set +a
: "${FORK_TTL:=7200}"
STAMP=".fork-block"          # gitignored; block number + unix seconds
if [ -z "${FORK_BLOCK:-}" ]; then
  now=$(date +%s)
  if [ -f "$STAMP" ] && read -r blk at < "$STAMP" 2>/dev/null && [ -n "${blk:-}" ] \
     && [ $((now - at)) -lt "$FORK_TTL" ]; then
    FORK_BLOCK="$blk"
    echo "fork: reusing pinned block $blk ($(( (now-at)/60 ))m old, TTL $((FORK_TTL/60))m) -- cache hits"
  else
    FORK_BLOCK=$(cast block-number --rpc-url "$ETH_RPC_URL")
    printf '%s %s\n' "$FORK_BLOCK" "$now" > "$STAMP"
    echo "fork: pinned fresh head $FORK_BLOCK (cache will be reused for $((FORK_TTL/60))m)"
  fi
  export FORK_BLOCK
fi
exec forge test "$@"

#!/usr/bin/env bash
# One-shot orchestrator for the Foundry `vm.ffi` swap-in test. Ensures regtest +
# both LND nodes + the alice→bob channel are up, performs a REAL HTLC swap, and
# leaves swapin_fixture.json for the test. Prints:
#   READY  — fixture written
#   SKIP   — harness binaries NOT INSTALLED. This is the ONLY thing that skips the test.
#   BROKEN — binaries ARE installed but orchestration failed. The test FAILS on this, loudly.
#
# The SKIP/BROKEN split is load-bearing, not cosmetic. Both cases used to print SKIP, so an
# installed-but-broken harness was indistinguishable from an absent one — and that is exactly how
# this test stayed invisible: LND reports `synced_to_chain: false` on a stale regtest tip, every
# run emitted SKIP, and a genuine breakage read as a clean skip in a green suite. Never collapse
# "cannot run" and "ran and failed" into one token.
set -uo pipefail
source "$(dirname "$0")/env.sh"
LOG=/tmp/quid-swapin-e2e.log

if [ ! -x "$BITCOIND" ] || [ ! -x "$LND" ]; then echo -n SKIP; exit 0; fi

# Bring the live harness up + perform the real HTLC swap. If ANY step fails (a
# flaky / partially-available bitcoind/LND environment), emit SKIP on stdout so
# the Foundry test skips cleanly (the suite stays green) rather than hard-failing
# on a non-READY token. The detailed failure is preserved in $LOG for whoever is
# actually trying to run the live harness; the diagnostic also goes to stderr.
# Chain with && so a failure SHORT-CIRCUITS at its true source: if start-ln.sh
# can't bring a node up, swap.sh must NOT run on top of a half-up harness (that
# only buries the real error under a downstream "[lncli] FAILED"). The last line
# of $LOG then points straight at the step that actually failed.
{
  "$HARNESS_DIR/start.sh" \
    && "$HARNESS_DIR/start-ln.sh" \
    && "$HARNESS_DIR/swap.sh" "${1:-50000}"
} >"$LOG" 2>&1 || { echo "live harness orchestration FAILED — see $LOG" >&2; echo -n BROKEN; exit 0; }

echo -n READY

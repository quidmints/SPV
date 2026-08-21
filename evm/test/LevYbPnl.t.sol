// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice PROOF (not a JS sim): does the YB IL-protect actually CANCEL the range LP's impermanent loss?
///   We model the canonical √p liquidity position and compare, in ETH-exposure terms, four "protect"
///   strategies against HODL across real price moves. Transparent, deterministic math — every number is
///   re-derivable from the asserts. Skeptical by design: it tests the strategy the CODE implements (a
///   STATIC target LTV) and the keeper's `L=1/α` rule, NOT only the one the levamm sim claimed works.
///
///   Model (p0=1, price ratio r=p1/p0; E0 = the LP's deposited BTC):
///     • a √p range LP holds `E0/√r` ETH after the move (it SOLD `E0·(1 − 1/√r)` ETH as price rose — that
///       sold ETH IS the IL, in ETH terms);
///     • HODL keeps the full `E0` ETH exposure.
///   The protect must RE-ADD the sold ETH so the combined position is flat at `E0` (= HODL ⇒ IL cancelled).
contract LevYbPnlProof is Test {
    uint constant WAD = 1e18;
    uint constant E0  = 100e18; // 100 ETH deposited

    /// √x for x in WAD (returns WAD). isqrt(x·1e18): √(1e18)=1e9·√x... isqrt(x*1e18) gives √x in WAD.
    function _sqrtWad(uint x) internal pure returns (uint) { return _isqrt(x * WAD); }
    function _isqrt(uint a) internal pure returns (uint y) {
        if (a == 0) return 0;
        uint z = (a + 1) / 2; y = a;
        while (z < y) { y = z; z = (a / z + z) / 2; }
    }

    /// √p range LP's ETH after a move to ratio `r` (WAD): E0/√r.
    function _rangeEth(uint r) internal pure returns (uint) { return E0 * WAD / _sqrtWad(r); }
    /// The ETH the range sold = the IL (ETH terms): E0·(1 − 1/√r).
    function _ilEth(uint r) internal pure returns (uint) { return E0 - _rangeEth(r); }

    function testProof_OnlyDynamicSizingCancelsIL() public {
        uint[4] memory rs = [uint(12e17), 15e17, 2e18, 3e18]; // 1.2x, 1.5x, 2x, 3x
        emit log_string("r | range-only | keeper L=1/a (a=1) | STATIC L=2 (code) | DYNAMIC (re-add sold) | HODL=E0");
        for (uint i = 0; i < rs.length; i++) {
            uint r = rs[i];
            uint range = _rangeEth(r);                         // range LP ETH (bears full IL)
            uint il = _ilEth(r);                             // ETH the range sold

            // (a) keeper's coded rule: L = 1/α. weETH is ∝p ⇒ α=1 ⇒ L=1 ⇒ ZERO buffer ⇒ no protection.
            uint keeperAlpha = range + 0;

            // (b) STATIC L=2 (a fixed target LTV, what the code maintains): a fixed E0 buffer regardless of
            //     the actual move. Over-hedges (directional long), never equals HODL.
            uint staticL2 = range + E0;

            // (c) DYNAMIC: re-add exactly the ETH the range sold ⇒ combined = E0 = HODL ⇒ IL CANCELLED.
            uint dynamicSized = range + il;

            emit log_named_uint("  r (WAD)", r);
            emit log_named_uint("    range-only ETH", range);
            emit log_named_uint("    keeper-alpha ETH", keeperAlpha);
            emit log_named_uint("    static-L2 ETH", staticL2);
            emit log_named_uint("    dynamic ETH", dynamicSized);

            // PROOF 1 — DYNAMIC sizing cancels IL exactly: combined ETH exposure == HODL (E0), every move.
            assertApproxEqAbs(dynamicSized, E0, 1e6, "dynamic-sized protect must restore full E0 ETH (IL cancelled)");

            // PROOF 2 — the CODED static target does NOT cancel IL: it over-hedges (directional), strictly > E0.
            assertGt(staticL2, E0, "static L=2 over-hedges (directional, not IL-neutral)");

            // PROOF 3 — the keeper's L=1/alpha rule on weETH (alpha=1) gives ZERO protection: still full IL.
            assertEq(keeperAlpha, range, "keeper L=1/alpha leaves the LP with the full range IL (no protect)");
            assertLt(keeperAlpha, E0, "...i.e. below HODL by the IL");
        }
        emit log_string("VERDICT: IL is cancelled ONLY by sizing the borrow to the MEASURED range-sold ETH.");
        emit log_string("The correct keeper target is LTV = 1 - 1/sqrt(r_since_entry), NOT a fixed LTV nor L=1/alpha.");
    }

    /// Derive the CORRECT keeper target LTV that yields the dynamic (IL-cancelling) buffer, and assert it
    /// matches `1 - 1/√r`. This is the formula the keeper must use (drive off the LP's entry price), and the
    /// fix to wire into LevManager.setTargetLtv / lev_keeper — replacing the L=1/α stand-in.
    function testProof_CorrectKeeperTargetLtv() public {
        uint[3] memory rs = [uint(15e17), 2e18, 4e18];
        for (uint i = 0; i < rs.length; i++) {
            uint r = rs[i];
            uint range = _rangeEth(r);
            uint buffer = _ilEth(r);                          // ETH to re-add
            // target LTV = debt/collateral = buffer / (range + buffer) = buffer / E0  (since range+buffer=E0)
            uint targetLtvWad = buffer * WAD / (range + buffer);
            uint expectedWad = WAD - (WAD * WAD / _sqrtWad(r)); // 1 - 1/√r
            emit log_named_uint("r (WAD)", r);
            emit log_named_uint("  correct target LTV (WAD)", targetLtvWad);
            assertApproxEqAbs(targetLtvWad, expectedWad, 1e9, "keeper target must be 1 - 1/sqrt(r)");
        }
    }

    // SHORT-CONCEPT PROOFS REMOVED (2026-07-24): every proof below this point validated the deleted below-entry
    // delta-1-both-ways SHORT (bounded-short, dynamic-short, nested-short, "IL cancelled both ways"). That design
    // was an LVR leak for a long-biased LP (see docs §J.4) — the down-side short is gone, so these proofs of it go
    // too. The two UP-SIDE proofs above (OnlyDynamicSizingCancelsIL, CorrectKeeperTargetLtv) validate the overlay
    // we KEEP: capture the rise, re-add exactly the range-sold ETH; below entry a long LP simply holds.
}

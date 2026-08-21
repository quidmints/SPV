// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §E286 — did `MAX_WELL_SKEW` neutralise §E68's integral, and did it reopen an atomicity arb?
/// @notice §E68 replaced "bill the whole drain at the STARTING rate" with the average along the swap's
///         own displacement, `qBar = [ln((1−q0)/(1−q1)) − Δ]/Δ`, because otherwise *"the last units of
///         a big drain belong near the pole and were billed at the cheap starting rate ⇒ THE LARGEST
///         IMBALANCER WAS UNDERCHARGED, and one large drain was strictly cheaper than the same volume
///         split across txs"*. The integral makes one drain cost the same as N slices — path
///         independence.
///
/// §E274 then MEASURED that the live (capped) skew sat at exactly 3e16 from q₁=0.6 through 0.95 while
/// the uncapped kernel ran 3.69e16 → 12.35e16. **A cap is a function of the ENDPOINT, not of the path**,
/// so clamping the integral's output can only preserve path-independence where it does not bind.
/// This measures the gap directly, on `skewWad` (public pure) — no fixture, no fork.
contract IntegralVsCapTest is Test {
    uint constant TARGET = 2_000_000e6;
    uint constant POOL   = 1_000_000e6;   // band starts short ⇒ scarcity is real
    uint constant SIGMA  = 1e18;
    uint constant CAP    = 3e16;          // the deleted MAX_WELL_SKEW

    /// total premium for draining `total` in `n` equal slices, each priced at the inventory it sees.
    function _cost(uint total, uint n, bool capped) internal pure returns (uint paid) {
        uint inv = POOL;
        uint slice = total / n;
        for (uint i; i < n; ++i) {
            uint r = SwapLib.skewWad(inv, TARGET, SIGMA, SwapLib.ethRisk(), slice);
            if (capped && r > CAP) r = CAP;
            paid += r * slice / 1e18;
            inv -= slice;
        }
    }

    function test_E286_CapBreaksPathIndependence() public pure {
        uint total = POOL * 60 / 100;                  // drain 60% of the band
        uint one   = _cost(total, 1, false);
        uint many  = _cost(total, 20, false);
        uint oneC  = _cost(total, 1, true);
        uint manyC = _cost(total, 20, true);
        console2.log("UNCAPPED  1 slice:", one);
        console2.log("UNCAPPED 20 slices:", many);
        console2.log("CAPPED    1 slice:", oneC);
        console2.log("CAPPED   20 slices:", manyC);
        // §E68's property: slicing must not be cheaper than one shot.
        if (many < one)  console2.log("uncapped: slicing is CHEAPER by", one - many);
        if (manyC < oneC) console2.log("CAPPED:   slicing is CHEAPER by", oneC - manyC);
        if (manyC > oneC) console2.log("CAPPED:   slicing is DEARER by", manyC - oneC);
        console2.log("cap suppressed the one-shot premium by:", one > oneC ? one - oneC : 0);
    }
}

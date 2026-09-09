// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Test, console2 as console} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

/// @title §BASE-VS-KERNEL — is the measured refill premium the A-S KERNEL, or the size-blind BASE?
/// @notice A peer thread's challenge, and it is decisive against my own conclusion if true:
///   "premium 4.2 bps FLAT across 100x of drain size" cannot be a `q/(k-q)` kernel, because q rises
///   with the drain so the kernel must rise CONVEXLY. Flat in bps is the signature of a term with no
///   `q` in it -- `_maxWellSkew` = sigma^2 * confFrac / 8, which since §E79 ADDS as a floor.
/// ⇒ SPLIT THEM. `skewWad(T,T,...,0)` at flush charges the BASE ALONE (pinned by Alles:1940), so
///   base = flush read, kernel = total - base, at every size. No modelling; two live reads.
contract BaseVsKernelTest is Test {
    uint constant TARGET = 1_000_000e6;      // 6-dec USD, the flow-EWMA target
    uint constant INV    = 1_000_000e6;      // start FLUSH, so the drain creates the scarcity
    function _row(uint sigma, uint drainUsd6) internal pure
        returns (uint total, uint base, uint kernel, uint totBps, uint kerBps) {
        base   = SwapLib.skewWad(TARGET, TARGET, sigma, SwapLib.ethRisk(), 0);   // flush = base alone
        total  = SwapLib.skewWad(INV, TARGET, sigma, SwapLib.ethRisk(), drainUsd6);
        kernel = total > base ? total - base : 0;
        totBps = total  / 1e14;      // wad -> bps
        kerBps = kernel / 1e14;
    }
    function test_BaseVsKernel_AcrossSize() public pure {
        uint[7] memory sizes = [uint(2_000e6), 10_000e6, 50_000e6, 200_000e6, 400_000e6, 700_000e6, 950_000e6];
        uint[3] memory sigmas = [uint(1e17), 5e17, 16e18];   // 32%, 71%, 400% annualised
        for (uint s; s < sigmas.length; s++) {
            console.log("=================== sigma^2 (wad) ==================="); console.log(sigmas[s]);
            for (uint i; i < sizes.length; i++) {
                (uint total, uint base, uint kernel, uint tb, uint kb) = _row(sigmas[s], sizes[i]);
                console.log("  drain usd6 / q% of target:", sizes[i], sizes[i] * 100 / TARGET);
                console.log("     total wad / base wad   :", total, base);
                console.log("     KERNEL wad             :", kernel);
                console.log("     total bps / KERNEL bps :", tb, kb);
                console.log("     kernel share of total %:", total == 0 ? 0 : kernel * 100 / total);
            }
        }
    }
}

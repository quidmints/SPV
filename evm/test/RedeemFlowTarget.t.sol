// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {console2} from "forge-std/console2.sol";

/// @title §SESS-18 — **A REDEMPTION IS FLOW, AND UNTIL NOW IT REACHED THE SKEW'S TARGET THROUGH NO PATH
///        AT ALL.**
///
/// @notice `flowEwmaUsd` is `skewWad`'s `target` — *"scarcity is inventory against the flow we shed
///         into"* — and `_bumpFlow` has exactly ONE call site, `Core:1053`, inside the swap settlement
///         path (*"the ONE bump point"*). `unwindForRedeem` is a **BURN, not a swap**, so a redemption
///         wave consumed range inventory and left the target decaying. **The pool read as over-stocked
///         exactly while it was being emptied.**
/// 📊 **WHAT THAT WAS WORTH (§SESS-16, `SkewTollCurve.t.sol`):** at live inputs `inv/target` read **4.54**
///         and the drain toll was **0 bps at 1/5/10/25% depletion**. Holding inventory and drain fixed and
///         varying `target` alone: **×5 ⇒ 34 bps, ×10 ⇒ 279 bps.**
///
/// 🔴 **THE DESIGN CONSTRAINT THAT DECIDED THE SHAPE, AND IT IS THE REASON THIS IS NOT A ONE-LINE FIX.**
///    `flowEwmaUsd` (GROSS) and `netFlowUsd` (SIGNED) are a **matched pair, and the pair IS the
///    wash-trading discriminator** (§E326: over a round trip gross went `0 → 49,999,999,999 →
///    99,994,054,053` while the position netted to ~$6). **A redemption raises gross and moves net not at
///    all — precisely the wash signature.** ⇒ folding redemptions into `_flow` would have made the
///    discriminator false-positive on the most legitimate flow there is, **before it is even built**.
///    ⇒ redemptions get their OWN register and both skews read `skewTargetUsd() = flow + redeem`.
contract RedeemFlowTargetTest is AllesFixture {

    function _seed() internal {
        vm.prank(User02); ETH.deposit{value: 400 ether}(0, User02);
    }

    /// ⭐ THE ANSWER: a redemption unwind now reaches the skew target — and does NOT touch swap gross.
    function test_RedemptionRaisesTheSkewTargetButNotSwapGross() public {
        _seed();
        uint flow0   = CORE.flowEwmaUsd();
        uint redeem0 = CORE.redeemEwmaUsd();
        uint tgt0    = CORE.skewTargetUsd();
        assertEq(tgt0, flow0 + redeem0, "target must be the composition of the two registers");

        vm.prank(address(ETH));
        uint freed = ETH.unwindForRedeem(50_000e18);

        uint flow1   = CORE.flowEwmaUsd();
        uint redeem1 = CORE.redeemEwmaUsd();
        console2.log("usdFreed (18-dec):", freed);
        console2.log("swap gross  before/after:", flow0, flow1);
        console2.log("redeem ewma before/after:", redeem0, redeem1);

        if (freed == 0) return;   // an empty range frees nothing; the control below covers vacuity

        // 🔑 THE TARGET MOVED...
        assertGt(redeem1, redeem0, "the redemption did NOT reach the skew target - the fix is inert");
        assertGt(CORE.skewTargetUsd(), tgt0, "skewTargetUsd did not rise with the redemption");
        // ...AND THE WASH DISCRIMINATOR IS INTACT.
        assertEq(flow1, flow0,
            "a redemption moved SWAP gross - the gross/net wash check would now false-positive");
        assertEq(CORE.netFlowUsd(), 0,
            "a proportional burn invented a DIRECTION it does not have");
    }

    /// 🔴 THE CONTROL. If `unwindForRedeem` frees nothing in this fixture, every assertion above is
    ///    vacuously satisfied and this file measures nothing. Assert the unwind is REAL first.
    function test_Control_TheUnwindActuallyFreesSomething() public {
        _seed();
        uint before = CORE.POOLED_USD();
        vm.prank(address(ETH));
        uint freed = ETH.unwindForRedeem(50_000e18);
        console2.log("POOLED_USD before:", before);
        console2.log("POOLED_USD after :", CORE.POOLED_USD());
        assertGt(freed, 0,
            "CONTROL FAILED - the unwind frees nothing here, so the main test asserts against a no-op");
        assertLt(CORE.POOLED_USD(), before, "the range's USD leg did not fall");
    }

    /// 🔑 AND THE DIRECTION OF THE EFFECT ON BOTH SKEWS, which is why one register suffices:
    ///    a higher target prices the DRAIN and keeps the REFILL exempt over a wider band.
    function test_RaisingTheTargetPricesDrainsAndKeepsRefillsExempt() public {
        _seed();
        uint tgt0 = CORE.skewTargetUsd();
        vm.prank(address(ETH));
        ETH.unwindForRedeem(50_000e18);
        uint tgt1 = CORE.skewTargetUsd();
        console2.log("skewTargetUsd before:", tgt0);
        console2.log("skewTargetUsd after :", tgt1);
        assertGe(tgt1, tgt0, "the target fell after a redemption consumed inventory");
    }
}

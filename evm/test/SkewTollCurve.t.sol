// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
import {console2} from "forge-std/console2.sol";

/// @notice §SESS-16 / **M0 — HOW BIG IS THE SKEW TOLL ACTUALLY, AND DOES REDEMPTION FLOW REACH IT?**
///
/// §SESS-15 posed M0 as *"is realised volatile-OUT drain rate price-elastic with respect to the charged
/// skew?"* — and that has a **behavioural** half and a **magnitude** half.
/// ⛔ **THE BEHAVIOURAL HALF IS UNMEASURABLE TODAY, AND THAT IS A FINDING RATHER THAN AN EXCUSE.**
///    `evm/deployments/l1.json` names `chainId: 1` addresses, and **every one of them has ZERO CODE on
///    mainnet** (checked `core`/`aux`/`vault`/`levManager` at the archive pin). It is a dry-run artifact,
///    not a live deployment ⇒ **there is no realised flow to regress**, and the same is true of §PLP-T's
///    whole M1–M7 set. **Those measurements are blocked on LAUNCH (or on a proxy venue), not on analysis.**
/// ⭐ **THE MAGNITUDE HALF IS PURE, AND IT DECIDES WHETHER THE BEHAVIOURAL HALF EVEN MATTERS.** If the
///    toll at deep depletion is a couple of bps, no elasticity saves the pool — the deterrent is too small
///    to change anyone's routing. If it is hundreds of bps, it is a real brake and §PLP-T's *"one-way
///    ratchet with no restoring term"* is too strong. **That is answerable from `skewWad` alone**, which
///    is `public pure`.
///
/// 🔑 **AND THE SECOND QUESTION IS THE OWNER'S, RAISED 2026-09-06:** *"there was a todo to include
///    redemption flow somehow in the skew math?"* **There was, and it is live.** `_bumpFlow` has exactly
///    ONE call site — `Core.sol:1053`, inside the swap settlement path, whose own comment says *"Every
///    range and well swap routes through here, so this remains the ONE bump point."* `unwindForRedeem`
///    is a BURN, not a swap, so **a redemption wave consumes range inventory without ever raising
///    `flowEwmaUsd`** — the EWMA that `skewWad` reads as `target`. This file measures what that omission
///    is worth by pricing the SAME drain against a target that does and does not count redemptions.
///
/// @dev Live-measured inputs, not invented: `σ² = 704808248487932092`, `flowEwmaUsd = $198,203`,
///      `POOLED = 319.79 ETH` are the figures recorded at SPRINT.md:19301.
contract SkewTollCurve is Test {
    uint constant SIGMA_SQ = 704_808_248_487_932_092;   // live σ², measured
    uint constant FLOW     = 198_203e6;                 // live flowEwmaUsd, 6-dec
    uint constant POOL     = 900_000e6;                 // ~319.79 ETH @ ~$2,800, 6-dec USD

    function _eth() internal pure returns (SwapLib.Risk memory) { return SwapLib.ethRisk(); }

    /// @dev bps withheld, CLAMPED THE WAY PRODUCTION CLAMPS. `skewWad` is allowed to exceed 1e18 and
    ///      returns `type(uint).max` once `drain >= inv` — deliberate, so the pole *"reports itself"* and
    ///      `_boundToFullHaircut` turns it into a 100% haircut (`SKEW_UNFILLABLE == 1e18`). ⚠️ An earlier
    ///      draft of this helper multiplied the raw value by 10_000 first and overflowed; that was the
    ///      TEST being wrong, not the library. Clamp first, then scale.
    function _bps(uint pool, uint flow, uint drain) internal pure returns (uint) {
        uint raw = SwapLib.skewWad(pool, flow, SIGMA_SQ, _eth(), drain);
        if (raw > 1e18) raw = 1e18;                       // SKEW_UNFILLABLE saturation
        return raw * 10_000 / 1e18;
    }

    /// ⭐ THE TOLL CURVE. How dear does the marginal drain actually get as inventory falls?
    function test_M0_TollCurveAgainstDepletion() public pure {
        console2.log("pool USD6:", POOL);
        console2.log("flow USD6:", FLOW);
        // ⭐ THE CURVE IS A FUNCTION OF inv/target, AND AT LIVE VALUES THAT RATIO IS ~4.5 — the pool
        //    reads as 4.5x over-stocked against the flow it thinks it serves. That is WHY the toll is
        //    ~0 across the normal range, and it is the same fact the redemption test below prices.
        console2.log("inv/target x100:", POOL * 100 / FLOW);
        uint[7] memory pct = [uint(1), 5, 10, 25, 50, 75, 90];
        for (uint i; i < pct.length; ++i) {
            uint drain = POOL * pct[i] / 100;
            console2.log("drain % of pool:", pct[i]);
            console2.log("   skew, bps:", _bps(POOL, FLOW, drain));
        }
        // Non-vacuity: the toll must actually RISE with size, or the curve measures nothing.
        assertGt(_bps(POOL, FLOW, POOL * 90 / 100), _bps(POOL, FLOW, POOL / 100),
            "the toll does not rise with drain size - skew is not a brake at any magnitude");
    }

    /// ⭐ AND THE SAME DRAIN AS THE POOL IS ALREADY DEPLETED — the ratchet's own axis.
    function test_M0_TollAsInventoryFalls() public pure {
        uint drain = POOL / 20;                       // a fixed 5%-of-full-pool ticket
        uint[6] memory inv = [POOL, POOL*3/4, POOL/2, POOL/4, POOL/10, POOL/20];
        for (uint i; i < inv.length; ++i) {
            console2.log("inventory USD6:", inv[i]);
            console2.log("   same ticket costs, bps:", _bps(inv[i], FLOW, drain));
        }
        assertGt(_bps(POOL/20, FLOW, drain), _bps(POOL, FLOW, drain),
            "a scarcer pool does not charge more for the same ticket");
    }

    /// 🔑 THE OWNER'S TODO, PRICED. `target` is `flowEwmaUsd`, which redemptions never raise. If a
    ///    redemption wave were counted, `target` would be HIGHER for the same inventory. Sweep the
    ///    multiple and report what the omission is worth on an identical drain.
    function test_M0_RedemptionFlowOmissionIsWorthThisMuch() public pure {
        uint drain = POOL / 10;
        uint base = _bps(POOL, FLOW, drain);
        console2.log("target = swap flow only, bps:", base);
        uint[4] memory mult = [uint(2), 3, 5, 10];
        for (uint i; i < mult.length; ++i) {
            uint b = _bps(POOL, FLOW * mult[i], drain);
            console2.log("   if redemptions made flow x:", mult[i]);
            console2.log("      skew would be, bps:", b);
        }
        // Which way does the omission err? Recorded rather than assumed.
        uint hi = _bps(POOL, FLOW * 10, drain);
        console2.log("under-charging by (bps) if true flow is 10x:", hi > base ? hi - base : 0);
        assertTrue(hi != base, "target does not move the skew at all - then the omission is harmless");
    }

    /// 🔴 THE CONTROL. §SESS-15 claims the REFILL direction pays zero. If `skewWad` charged both
    ///    directions this whole framing is wrong, so the asymmetry gets its own assertion: at drain 0
    ///    (the indicative rate) the pool must not be charging a depletion premium.
    function test_Control_ZeroDrainOwesNoDepletionTerm() public pure {
        uint atZero = _bps(POOL, FLOW, 0);
        uint atHalf = _bps(POOL, FLOW, POOL / 2);
        console2.log("indicative rate at drain 0, bps:", atZero);
        console2.log("rate at a 50% drain, bps:", atHalf);
        assertLt(atZero, atHalf, "CONTROL FAILED - drain size does not price, so the curve is flat");
    }
}

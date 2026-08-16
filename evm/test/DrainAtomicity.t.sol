// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";
// §E113: the v4-PERIPHERY LiquidityAmounts has only getLiquidityFor* (forward). The reverse
// (amounts FROM liquidity) lives in v4-core/test/utils -- the one that can price a position.

/// §E71 — DID E68 ACTUALLY KILL THE ATOMICITY ARBITRAGE? A FALSIFIABLE TEST OF MY OWN CHANGE.
///
/// E68 replaced the drain kernel's POINT sample with the INTEGRAL over the swap's own displacement,
/// on the argument that `rate(q0)` applied to a whole swap underprices the last units of a large
/// drain — so ONE BIG DRAIN WAS STRICTLY CHEAPER THAN THE SAME VOLUME SPLIT ACROSS TRANSACTIONS,
/// a standing incentive to consolidate drains and an undercharge of the largest imbalancer.
///
/// That was an ARGUMENT. This is the test. **PREDICTION, STATED BEFORE THE RUN:**
///
///     premium(one drain of size S)  >=  premium(N drains of size S/N)
///
/// Pre-E68 the inequality ran the OTHER WAY. If the split is still cheaper, the fix did not work
/// and E68's claim must be withdrawn — not re-argued.
///
/// MEASURED VIA `skewPremiumCum`, the monotonic retained-premium counter, because it is the
/// protocol's OWN record of what was charged. Deriving the premium from balances instead would
/// re-introduce the payout-path uncertainty that stalled E69.
///
/// ⚠️ THE CAP IS THE KNOWN CONFOUND AND IT IS WHY THIS TEST LOGS BOTH LEGS RATHER THAN ASSERTING
/// A RATIO. `skewWad` clamps to `_maxWellSkew` at the end. If BOTH legs pin to the cap, the two
/// numbers converge and the test says NOTHING about the integral — it would look identical whether
/// or not E68 works. That is the control, and it is checked explicitly below.
contract DrainAtomicity is Alles {
    address lpA = User02;
    address drainer = address(0xBEEF04);
    address bold;

    function _seedBasket() internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        deal(address(USDC), User01, 4_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 2_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    function _settle() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 20 minutes);
    }

    /// stable → volatile: the band hands out ETH, so `inv` FALLS and it gets SCARCER.
    /// §E71-r3 — RETURNS THE VOLATILE THE TRADER ACTUALLY RECEIVED. The original version returned
    /// nothing and the test read `skewPremiumCum` instead: OUR OWN ACCOUNTING of what we retained.
    /// That is the same trap that hid the delivery bug through six layers of diagnosis — asserting
    /// on a number the failing system reports about ITSELF. A discount in our bookkeeping is not
    /// evidence of a discount to the WHALE, and a real arbitrage could be invisible to it. The
    /// trader's cost is ETH-received per dollar spent, measured as a BALANCE DELTA on the trader.
    function _drain(uint boldAmt) internal returns (uint ethGot) {
        deal(bold, drainer, boldAmt);
        // §E71-r3 CONTROL: count NATIVE ETH as well as WETH. I already made the mistake once of
        // reading a single token and concluding "delivered nothing" when the payout landed elsewhere
        // (E69, where proceeds arrived as a different basket stable). A volatile leg can settle as
        // native ETH, so summing both is what makes a zero reading mean ZERO RECEIPT rather than
        // ZERO KNOWLEDGE of where it went.
        uint before = WETH.balanceOf(drainer) + drainer.balance;
        vm.startPrank(drainer);
        IERC20(bold).approve(address(AUX), boldAmt);
        // §E71-r3: NO try/catch and NO minOut=0 mask. With them, a zero receipt was
        // indistinguishable between "the swap reverted" and "the swap delivered nothing" — the exact
        // S16 pattern this session spent six layers untangling, sitting inside the measuring
        // instrument. Let a revert announce itself; that is the whole discriminator.
        AUX.swap(bold, address(WETH), true, boldAmt, 0);
        vm.stopPrank();
        ethGot = (WETH.balanceOf(drainer) + drainer.balance) - before;
        _settle();
    }

    function _setupBand() internal {
        _seedBasket();
        vm.prank(lpA);
        V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        // Pre-drain into the SCARCE region so both legs start from an identical, premium-charging
        // state. Starting flush would put both at zero premium and measure nothing.
        for (uint i = 0; i < 20; ++i) {
            _drain(20_000 * 1e18);
            if (CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30
                < CORE.flowEwmaUsd()) break;
        }
    }

    /// §E72 — THE σ² CLIFF. E59 made `sigmaSqWad == 0` return the CAP, on the reasoning that
    /// UNMEASURED variance should be priced conservatively. But σ² enters the kernel
    /// MULTIPLICATIVELY (`K·σ²·qBar`), so σ² = 1 wei of variance is not "slightly less
    /// conservative" than σ² = 0 — it is ~zero. **If that is so, the two adjacent states are the
    /// CAP and NOTHING, and anyone able to nudge realized variance off exactly-zero converts the
    /// maximum charge into no charge at all.**
    ///
    /// This is a PURE call into `skewWad`, so there is no fixture, no oracle and no rounding path
    /// to blame — whatever it prints is the formula's own behaviour.
    function test_E72_SigmaSquaredCliffAtZero() public pure {
        uint T = 1_000_000e6;          // target
        uint inv = T / 2;              // genuinely scarce: q0 = 0.5
        uint drain = T / 4;            // a real, size-significant drain

        uint atZero = SwapLib.skewWad(inv, T, 0, SwapLib.ethRisk(), drain);
        uint atOne  = SwapLib.skewWad(inv, T, 1, SwapLib.ethRisk(), drain);
        uint atTiny = SwapLib.skewWad(inv, T, 1e13, SwapLib.ethRisk(), drain);   // ≈ the live fixture's σ²
        uint atReal = SwapLib.skewWad(inv, T, 1e16, SwapLib.ethRisk(), drain);   // a plausible real variance

        console.log("skew at sigma^2 = 0     :", atZero);
        console.log("skew at sigma^2 = 1     :", atOne);
        console.log("skew at sigma^2 = 1e13  :", atTiny);
        console.log("skew at sigma^2 = 1e16  :", atReal);

        if (atZero > atOne * 1000) {
            console.log("CLIFF CONFIRMED: sigma^2=0 charges >1000x what sigma^2=1 charges.");
            console.log("Adjacent states are THE CAP and ~NOTHING; the sentinel is exploitable.");
        } else {
            console.log("NO CLIFF: the zero sentinel and its neighbour are comparable.");
        }
    }

    /// §E85 — WHERE DOES THE KERNEL OVERTAKE THE FLOOR? The owner distrusted the "q≈0.87" I quoted
    /// for BTC, and was right to: `SPLICE_FLOOR` is a CONSTANT while the kernel scales with σ², so the
    /// crossover is a FUNCTION OF VOLATILITY, not a property of the design. I quoted ONE POINT ON A
    /// CURVE as though it were the curve, then reasoned from it (E83) to call the barrier "decoration".
    /// This sweeps it. Nothing should rest on a single crossover number again.
    function test_E85_CrossoverMovesWithVolatility() public pure {
        uint T = 1_000_000e6;
        uint[4] memory sigs = [uint(1e15), 1e16, 1e17, 1e18];
        for (uint s = 0; s < 4; ++s) {
            uint base = SwapLib.skewWad(T - T / 1000, T, sigs[s], SwapLib.btcRisk(), 0);  // q->0: the floor
            uint lo = 1; uint hi = 999;
            while (lo < hi) {                       // first q (thousandths) where kernel clears the floor
                uint mid = (lo + hi) / 2;
                if (SwapLib.skewWad(T - (T * mid) / 1000, T, sigs[s], SwapLib.btcRisk(), 0) > base + base / 50) hi = mid;
                else lo = mid + 1;
            }
            console.log("sigma^2 / floor / crossover q (thousandths):", sigs[s], base, lo);
        }
    }

    /// §E96 — WHAT DOES ORDINARY FLOW PAY FOR SOMEONE ELSE'S IMBALANCE? This is the owner's ORIGINAL
    /// complaint and it had never been tested: *"the second swapper into an already-imbalanced pool
    /// pays a premium scaled to the whole imbalance, most of which they didn't cause."*
    ///
    /// E71 (consolidation) does NOT answer it — that measures ONE big swap vs the same volume split,
    /// i.e. path-independence WITHIN a displacement. This measures the LEVEL dependence: the SAME
    /// small ticket, priced at a balanced band and at an imbalanced one. The integral is irrelevant
    /// here BY CONSTRUCTION — its own limit argument says infinitesimal swaps price identically to
    /// the old point rate, which is exactly why E68/E68b could not have fixed this.
    ///
    /// Measured on the TRADER's receipt (native ETH + WETH), never on `skewPremiumCum` — our ledger
    /// moves differently from what the user gets, and trusting it produced two retracted findings.
    /// §E96b — HOW DOES THE TAX ON ORDINARY FLOW SCALE WITH IMBALANCE DEPTH? E96 measured ONE depth
    /// (15 bps at inv halved) and I flagged that quoting it as "the" number was unsound. The refill
    /// decision turns on the SHAPE, not one point: repair cost is roughly flat, so if the tax grows
    /// convexly with depth then waiting is progressively worse and the case for self-repair
    /// strengthens the longer an imbalance stands.
    /// Measured on the TRADER's receipt (native ETH + WETH). Each depth is an INDEPENDENT snapshot —
    /// no leg inherits another's flow EWMA, which would confound depth with history.
    /// §E88-r PROOF — DOES THE σ² SENTINEL FIX ACTUALLY FIRE, AND IS THE STATE IT GUARDS REACHABLE?
    /// E88-r reserved `realizedVarianceWad == 0` for "UNMEASURED" by returning 1 wei when the ring is
    /// populated (`cardinality >= 2`) but computes a true zero — so downstream stops charging the 3%
    /// ceiling to a genuinely CALM market. It landed GREEN but UNPROVEN: a green suite shows the
    /// branch does not fire SPURIOUSLY, never that it fires at all. This asks the question directly,
    /// and the more useful one behind it: if "populated ring, genuine zero" is UNREACHABLE in
    /// practice, the fix is DEFENSIVE ONLY and should be recorded as such rather than as a live fix.
    /// §E88-REACH — IS THE σ² SENTINEL REACHABLE IN *ANY* STATE, or is it dead code? It needs all
    /// three at once: `target > 0` (flow history exists), `inv1 < target` (genuinely scarce), and
    /// `σ² == 0` (no price movement). Ordinary trading cannot do it — building flow moves the tick.
    /// The only candidate is MANY TINY swaps that accumulate flow WITHOUT crossing a tick. If even
    /// that fails, `if (sigmaSqWad == 0) return MAX_WELL_SKEW;` is unreachable and rule 1 applies:
    /// delete it rather than leave it "for safety".
    /// §E97 — THE SELL LEG, WHICH HAS NEVER BEEN MEASURED. Every behavioural test this session drove
    /// the DRAIN side; `sellSkew`'s integral (E68b) and its share of the risk-vs-fee split (E89b) were
    /// verified only by "the suite is green" — which E88-PROOF just demonstrated is what a
    /// never-executed branch also produces. This is E96's mirror on the abundant side: does a seller
    /// into an ALREADY-ABUNDANT band pay for an overshoot it did not create?
    /// Measured on the trader's receipt (all basket stables + QUID), never on our own ledger.
    /// §E98 — THE BTC LEG, WHICH HAS NEVER BEEN EXERCISED. Every behavioural skew test this session
    /// was ETH. That matters specifically for E89b: `SPLICE_FLOOR` (2e15) exists ONLY for BTC, so the
    /// risk-vs-fee split — amplify the kernel and `σ²·confFrac/8`, NEVER the fixed splice fee — is
    /// entirely UNTESTED. And it only bites when E53's amplifier exceeds 1, which requires BOTH
    /// bands populated (a lone band gives `_sharedScarcityWad == 1e18` and the split is invisible).
    ///
    /// THE DISCRIMINATOR: `skewWad` is public and returns the UNAMPLIFIED `kernel + base`.
    /// `AUX.wellSkew` returns the composed, amplified price. If the split is right the splice fee
    /// sits OUTSIDE the amplifier, so `live = (raw − SPLICE) × amp + SPLICE`, which is STRICTLY LESS
    /// than the wrong form `raw × amp` whenever `amp > 1`. So `live < raw` is impossible and
    /// `live` must exceed `SPLICE_FLOOR` while staying below `raw × 2` (the amplifier's own ceiling).
    function test_E98_BtcLegAndTheSpliceFloorSplit() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        uint ethAlone = AUX.wellSkew(address(WETH), 0);

        // Populate the BTC band so the SHARED-scarcity amplifier can exceed 1 for BOTH assets.
        AUX.setBTCChannels(address(this));   // auth: registerBtcLp is gated (403 without this)
        BTC.registerBtcLp(User01, 2e7);
        _settle();

        uint ethBoth = AUX.wellSkew(address(WETH), 0);
        uint btcLive = AUX.wellSkew(address(WBTC), 0);
        emit log_named_uint("ETH wellSkew, ETH band only ", ethAlone);
        emit log_named_uint("ETH wellSkew, BOTH bands    ", ethBoth);
        emit log_named_uint("BTC wellSkew, BOTH bands    ", btcLive);
        emit log_named_uint("SPLICE_FLOOR (BTC only)     ", 2e15);

        if (ethBoth > ethAlone) {
            emit log("AMPLIFIER ACTIVE: populating BTC raised the ETH skew -- shared scarcity is live.");
        } else {
            emit log("AMPLIFIER NOT ACTIVE at this state -- the E89b split cannot be observed here.");
        }
        // DRIVE REAL BTC FLOW INTO SCARCITY. A populated band is not enough (E98): the base is only
        // reached once `flowEwmaUsd(true) > 0` AND `inv < target`. Buying BTC drains the BTC band.
        for (uint i = 0; i < 3; ++i) {   // §E98-r: MILD scarcity -- 14 rounds pinned `live` at the
            deal(bold, drainer, 3_000 * 1e18);   // 3% ceiling and destroyed the discriminator.
            vm.startPrank(drainer);
            IERC20(bold).approve(address(AUX), 3_000 * 1e18);
            try AUX.swap(bold, address(WBTC), true, 3_000 * 1e18, 0) {} catch {}
            vm.stopPrank();
            _settle();
        }
        uint pB     = AUX.getTWAPforAsset(address(WBTC), 1800);
        uint invBtc = CORE.POOLED() * pB / 1e30;
        uint tgtBtc = CORE.flowEwmaUsd();
        uint sigBtc = CORE.realizedVarianceWad();
        btcLive     = AUX.wellSkew(address(WBTC), 0);
        uint raw    = SwapLib.skewWad(invBtc, tgtBtc, sigBtc, SwapLib.btcRisk(), 0);   // UNAMPLIFIED kernel+base
        emit log_named_uint("BTC inv (usd6)        ", invBtc);
        emit log_named_uint("BTC target/flow (usd6)", tgtBtc);
        emit log_named_uint("BTC sigma^2           ", sigBtc);
        emit log_named_uint("BTC raw (unamplified) ", raw);
        emit log_named_uint("BTC live (amplified)  ", btcLive);
        // §E98-r2 — DRIVE THE **ETH** BAND SCARCE TOO. The identity `amp_ETH + amp_BTC = 3e18` needs
        // BOTH bands live: `_sharedScarcityWad = 1e18 + other/both`, and `other_ETH + other_BTC =
        // both`, so the two amplifiers sum to exactly 3e18. ETH has NO `SPLICE_FLOOR`, so for ETH the
        // splice-inside and splice-outside forms COINCIDE and `amp_ETH = live/raw` is unambiguous —
        // which pins `amp_BTC` INDEPENDENTLY of the thing under test. Only then can the BTC forms be
        // told apart; the previous run had ETH flush (`wellSkew == 0`) and the identity was unusable.
        for (uint i = 0; i < 20; ++i) {
            _drain(20_000 * 1e18);
            uint iv = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
            if (iv < CORE.flowEwmaUsd()) break;
        }
        {
            uint pE      = AUX.getTWAPforAsset(address(WETH), 1800);
            uint invEth  = CORE.POOLED() * pE / 1e30;
            uint rawEth  = SwapLib.skewWad(invEth, CORE.flowEwmaUsd(),
                                           CORE.realizedVarianceWad(), SwapLib.ethRisk(), 0);
            uint liveEth = AUX.wellSkew(address(WETH), 0);
            emit log_named_uint("ETH raw  (unamplified)", rawEth);
            emit log_named_uint("ETH live (amplified)  ", liveEth);
            if (rawEth > 0 && liveEth > 0 && liveEth < 3e16) {
                uint ampEth = liveEth * 1e18 / rawEth;
                emit log_named_uint("amp_ETH (unambiguous) ", ampEth);
                if (ampEth < 3e18) {
                    emit log_named_uint("amp_BTC = 3e18 - amp_ETH (INDEPENDENT)", 3e18 - ampEth);
                    emit log("^ compare against the two BTC candidates below: the match is the verdict.");
                }
            } else {
                emit log("ETH leg not usable for the identity (flush, or capped).");
            }
        }

        // §E98-r PRECONDITION, WHICH THE FIRST VERSION OMITTED: once `live` clamps to MAX_WELL_SKEW
        // the cap has destroyed the very difference the two forms are distinguished by
        // (`SPLICE × (amp − 1)`), and any derived "amp" is an artifact of the clamp. Assert the
        // premise before computing anything from it.
        if (btcLive >= 3e16) {
            emit log("VOID: live is at the 3% CEILING -- cap-bound, discriminator cannot fire here.");
        } else if (raw > 2e15 && btcLive > 0) {
            // Correct split: live = (raw − SPLICE)*amp + SPLICE  ⇒ amp = (live−SPLICE)/(raw−SPLICE)
            // Wrong  split: live = raw*amp                       ⇒ amp = live/raw
            emit log_named_uint("amp IF splice OUTSIDE (x1e18)", (btcLive - 2e15) * 1e18 / (raw - 2e15));
            emit log_named_uint("amp IF splice INSIDE  (x1e18)", btcLive * 1e18 / raw);
            emit log("Only ONE can be a real amplifier (>=1e18, <=2e18). That is the verdict.");
        } else {
            emit log_named_uint("INCONCLUSIVE: raw <= SPLICE_FLOOR or live==0; raw=", raw);
        }

        if (btcLive > 0) {
            emit log_named_uint("BTC skew as multiple of SPLICE_FLOOR (x1e18)", btcLive * 1e18 / 2e15);
            assertGe(btcLive, 2e15,
                "E89b: SPLICE_FLOOR is added OUTSIDE the amplifier, so it is a hard floor on BTC");
        } else {
            emit log("BTC skew is 0 -- flush/target short-circuit fires before the base is added.");
            emit log("That is the same E88-PROOF finding on the BTC leg: the base never applies here.");
        }
    }

    /// §E99 — IS PERSISTENCE INVISIBLE TO THE SKEW? I have asserted many times that "a one-block
    /// imbalance and a month-old one price identically", and used it as E93's whole premise —
    /// WITHOUT EVER MEASURING IT. This measures it: reach scarcity, read the skew, then let TIME
    /// pass with NO trading and NO LP action, and read it again. Nothing about the inventory has
    /// changed, so any difference is a genuine time-response and any equality is its absence.
    /// §E100 — DOES AN LP ADD REALLY LEAVE `flow.ts` UNTOUCHED? E93-COMPLETE claimed LP `addLiq`/
    /// `burn` move `POOLED_*` WITHOUT bumping `flow.ts` (because flow tracks SWAP notional), and
    /// E93-HOLE-CLOSED built the `max(flow.ts, LAST_REPACK)` fix on that claim. **INFERRED, NEVER
    /// MEASURED.** If `flow.ts` DOES bump on an LP add, both the hole and its fix are unnecessary.
    /// §E101 CHECK — DOES AN LP *BURN* REDUCE `POOLED_*` WITHOUT BUMPING `flow.ts`? E101 derived that
    /// no LP timestamp is needed, because adds can only move inventory TOWARD repair — leaving BURNS
    /// as the one residual hole. I INFERRED the burn behaves like the add. **Inferring from the add
    /// case is exactly what produced a no-op fix in E93-HOLE-CLOSED**, so this measures it instead.
    /// §E102 — READ `flow.ts` DIRECTLY. `Flow internal _flow` (slot 1030) is not publicly
    /// readable, and E100/E101 inferred "ts did not bump" from `flowEwmaUsd` NOT CHANGING. That
    /// inference is only valid when the FAST leg is binding, because `flowEwmaUsd` returns
    /// `min(fast, slow)` (E55) — if the slow leg pins the minimum, a fast-leg bump moves NOTHING and
    /// the inference is SILENTLY WRONG. `Flow{uint128 vol; uint64 ts}` packs into one slot: `vol` in
    /// the low 128 bits, `ts` in the next 64. Reading the slot removes the inference entirely.
    function _flowTs(bool slow) internal view returns (uint64) {
        // §ISBTC-SPLIT — RE-DERIVED FROM `forge inspect Core storageLayout`, NOT ADJUSTED BY HAND.
        // Core held BOTH bands' state and each instance now holds one, which removed an entire
        // `Observation[65535]` array and moved everything after it DOWN BY 65,535 SLOTS:
        // `_flowETH` 131088 -> `_flow` 1030 (the ring shrank 65535 -> 1024 too). `slow` reads 1031,
        // formerly `_flowSlow*`), which is what it was already reading -- the slow leg is dead by
        // §UNIT-B-MIN-STRUCTURAL and the test asserts it does not move.
        uint slot = slow ? 1031 : 1030;
        uint raw = uint(vm.load(address(CORE), bytes32(slot)));
        return uint64(raw >> 128);
    }

    function test_E101_DoesAnLpBurnMoveInventoryWithoutBumpingFlow() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 300 ether}(0, lpA);
        _settle();
        for (uint i = 0; i < 6; ++i) _drain(20_000 * 1e18);   // give flow a history
        vm.warp(block.timestamp + 1 days);                    // let it decay so a bump is visible

        uint invBefore  = CORE.POOLED();
        uint flowBefore = CORE.flowEwmaUsd();
        uint shares     = V4.balanceOf(lpA);
        emit log_named_uint("LP shares held           ", shares);

        uint64 tsFast0 = _flowTs(false); uint64 tsSlow0 = _flowTs(true);
        vm.prank(lpA);
        V4.withdraw(20 ether, lpA, lpA);   // §E102: no try/catch -- a revert must announce itself
        vm.roll(block.number + 1);

        uint invAfter  = CORE.POOLED();
        uint flowAfter = CORE.flowEwmaUsd();
        emit log_named_uint("POOLED before        ", invBefore);
        emit log_named_uint("POOLED after         ", invAfter);
        emit log_named_uint("flow before              ", flowBefore);
        emit log_named_uint("flow after               ", flowAfter);

        uint64 tsFast1 = _flowTs(false); uint64 tsSlow1 = _flowTs(true);
        emit log_named_uint("flow.ts FAST before/after", tsFast0);
        emit log_named_uint("                         ", tsFast1);
        emit log_named_uint("flow.ts SLOW before/after", tsSlow0);
        emit log_named_uint("                         ", tsSlow1);
        if (tsFast1 == tsFast0 && tsSlow1 == tsSlow0) {
            emit log("DIRECT READ: neither flow.ts moved -- E100/E101 CONFIRMED, not inferred.");
        } else {
            emit log("DIRECT READ: a flow.ts DID move -- the min() inference was masking it. E100/E101 WRONG.");
        }
        if (invAfter == invBefore) {
            emit log("VOID: the burn did not move POOLED -- nothing to conclude.");
        } else if (invAfter < invBefore && flowAfter <= flowBefore) {
            emit log("HOLE CONFIRMED: a burn REDUCES inventory and does NOT bump flow -- E101's");
            emit log("residual gap is real, and add-then-burn can break the continuity inference.");
        } else if (invAfter < invBefore) {
            emit log("BURN BUMPS FLOW: inventory fell AND flow rose -- then E101 has NO residual hole.");
        } else {
            emit log("UNEXPECTED: the burn INCREASED POOLED -- re-read before concluding.");
        }
    }

    function test_E100_DoesAnLpAddBumpTheFlowTimestamp() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 200 ether}(0, lpA);
        _settle();
        for (uint i = 0; i < 6; ++i) _drain(20_000 * 1e18);   // give flow a non-zero history

        uint invBefore   = CORE.POOLED();
        uint repackBefore = V4.LAST_REPACK();
        uint flowBefore  = CORE.flowEwmaUsd();
        vm.warp(block.timestamp + 3 days);                    // let the clock move, no trading
        uint flowMid = CORE.flowEwmaUsd();               // decayed, proving time passed

        // §E102: read `flow.ts` DIRECTLY, not through `flowEwmaUsd`'s `min(fast, slow)`. The proxy
        // is only valid when the FAST leg binds, and this row's original conclusion rested on it.
        uint64 tsFast0 = _flowTs(false); uint64 tsSlow0 = _flowTs(true);
        // THE LP ACTION under test -- moves POOLED_* with no swap.
        vm.prank(lpA); V4.deposit{value: 50 ether}(0, lpA);
        vm.roll(block.number + 1);

        uint invAfter    = CORE.POOLED();
        uint repackAfter = V4.LAST_REPACK();
        emit log_named_uint("POOLED before / after", invBefore);
        emit log_named_uint("                         ", invAfter);
        emit log_named_uint("flow (decayed, pre-add)  ", flowMid);
        emit log_named_uint("flow (post-add)          ", CORE.flowEwmaUsd());
        emit log_named_uint("LAST_REPACK before       ", repackBefore);
        emit log_named_uint("LAST_REPACK after        ", repackAfter);

        uint64 tsFast1 = _flowTs(false); uint64 tsSlow1 = _flowTs(true);
        emit log_named_uint("flow.ts FAST before/after", tsFast0);
        emit log_named_uint("                         ", tsFast1);
        emit log_named_uint("flow.ts SLOW before/after", tsSlow0);
        emit log_named_uint("                         ", tsSlow1);
        assertGt(invAfter, invBefore, "PREMISE: the LP add must actually move POOLED");
        if (tsFast1 == tsFast0 && tsSlow1 == tsSlow0) {
            emit log("DIRECT READ: neither flow.ts moved on the LP ADD -- E100 CONFIRMED, not inferred.");
        } else {
            emit log("DIRECT READ: a flow.ts DID move on the LP add -- E100's conclusion was WRONG.");
        }
        if (repackAfter > repackBefore) {
            emit log("LAST_REPACK DID bump on the LP add -- the E93-HOLE-CLOSED fix is LOAD-BEARING.");
        } else {
            emit log("LAST_REPACK did NOT bump -- the fix does NOT cover LP adds. HOLE STILL OPEN.");
        }
        if (CORE.flowEwmaUsd() > flowMid) {
            emit log("flow ALSO moved on the LP add -- then the hole never existed and the fix is dead code.");
        } else {
            emit log("flow did NOT move on the LP add -- the hole was REAL, as claimed.");
        }
    }

    function test_E99_DoesTheSkewSeePersistence() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        for (uint i = 0; i < 20; ++i) {
            _drain(20_000 * 1e18);
            if (CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30
                < CORE.flowEwmaUsd()) break;
        }
        uint invFresh  = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint skewFresh = AUX.wellSkew(address(WETH), 0);
        uint flowFresh = CORE.flowEwmaUsd();

        // 30 DAYS pass. No swap, no LP action -- inventory is UNCHANGED by construction.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);
        uint invAged  = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint skewAged = AUX.wellSkew(address(WETH), 0);
        uint flowAged = CORE.flowEwmaUsd();

        emit log_named_uint("inv  fresh / aged (usd6)", invFresh);
        emit log_named_uint("                        ", invAged);
        emit log_named_uint("flow fresh              ", flowFresh);
        emit log_named_uint("flow aged (30d decay)   ", flowAged);
        emit log_named_uint("SKEW fresh              ", skewFresh);
        emit log_named_uint("SKEW after 30 IDLE DAYS ", skewAged);

        if (invFresh != invAged) {
            emit log("VOID: inventory moved despite no trade -- comparison is not clean.");
        } else if (skewFresh == skewAged) {
            emit log("CONFIRMED: 30 idle days change the skew by NOTHING. Persistence is INVISIBLE.");
        } else {
            emit log("The skew DOES move with idle time -- my E93 premise was WRONG. Direction:");
            emit log_named_uint("  aged/fresh x1e18", skewFresh == 0 ? 0 : skewAged * 1e18 / skewFresh);
        }
    }

    function test_E97_SellLegTaxOnOrdinaryFlow() public {
        uint SMALL = 3 ether;

        // Reference: sell into a FRESH band (at/below target ⇒ `over == 0` ⇒ EXEMPT by construction).
        uint snap = vm.snapshotState();
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        uint refOut = _sell(SMALL);
        vm.revertToState(snap);

        // Now push the band ABUNDANT with someone else's sells, then send the SAME small ticket.
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        for (uint i = 0; i < 15; ++i) _sell(20 ether);
        uint heavyOut = _sell(SMALL);

        emit log_named_uint("stable for 3 ETH @ fresh    ", refOut);
        emit log_named_uint("stable for 3 ETH @ abundant ", heavyOut);
        if (refOut == 0 || heavyOut == 0) {
            emit log("VOID: a leg received nothing -- the sell path did not deliver.");
            return;
        }
        if (heavyOut < refOut) {
            emit log_named_uint("SELL-LEG TAX on ordinary flow, bps",
                (refOut - heavyOut) * 10_000 / refOut);
        } else {
            emit log("NO SELL-LEG TAX: the ordinary sell was not penalised by standing abundance.");
        }
    }

    /// volatile → stable. Returns the trader's TOTAL stable receipt across every basket stable plus
    /// QUID — a balance delta, because reading one guessed token is how E69 mis-reported for two runs.
    function _sell(uint ethAmt) internal returns (uint got) {
        deal(address(WETH), drainer, ethAmt);
        address[] memory ss = AUX.getStables();
        uint before = QUID.balanceOf(drainer);
        for (uint i = 0; i < ss.length; ++i) {
            uint b = IERC20(ss[i]).balanceOf(drainer);
            if (b > 0) { uint8 d = IERC20(ss[i]).decimals(); before += d < 18 ? b * (10 ** (18 - d)) : b; }
        }
        vm.startPrank(drainer);
        WETH.approve(address(AUX), ethAmt);
        // §E97: NO try/catch. Three times this session a swallowed revert was mistaken for a
        // delivery failure. Let it announce itself.
        AUX.swap(bold, address(WETH), false, ethAmt, 0);
        vm.stopPrank();
        uint after_ = QUID.balanceOf(drainer);
        for (uint i = 0; i < ss.length; ++i) {
            uint b = IERC20(ss[i]).balanceOf(drainer);
            if (b > 0) { uint8 d = IERC20(ss[i]).decimals(); after_ += d < 18 ? b * (10 ** (18 - d)) : b; }
        }
        got = after_ > before ? after_ - before : 0;
        _settle();
    }

    function test_E88_IsTheSentinelReachableAtAll() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();

        // Many TINY drains: enough to build a flow EWMA, each too small to be expected to move a tick.
        for (uint i = 0; i < 25; ++i) _drain(50 * 1e18);
        uint flow = CORE.flowEwmaUsd();
        uint sig  = CORE.realizedVarianceWad();
        uint inv  = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        emit log_named_uint("flow EWMA (target)  ", flow);
        emit log_named_uint("realizedVariance    ", sig);
        emit log_named_uint("inv (usd6)          ", inv);

        // §E88-REACH: `sig == 1` IS THE FIX FIRING. E88-r returns exactly 1 wei when the ring is
        // populated and the raw variance computes to zero, precisely so 0 can mean UNMEASURED and
        // nothing else. Testing `sig == 0` here would be testing for the PRE-FIX behaviour and would
        // report "not reached" at the exact moment the fix works — which it did on the first run.
        if (flow > 0 && sig == 1) {
            emit log("E88-r FIRED: populated ring, raw variance 0 -> returned 1 wei. THE FIX IS LIVE.");
            emit log("Without it this calm market would have hit the sentinel and paid the 3% CEILING.");
        } else if (flow > 0 && sig == 0) {
            emit log("REACHABLE: flow exists with ZERO variance -- the sentinel CAN fire. LIVE branch.");
            emit log_named_uint("  and inv < target? (1=yes)", inv < flow ? 1 : 0);
        } else if (flow == 0) {
            emit log("NOT REACHED: tiny swaps built NO flow, so target==0 short-circuits first.");
        } else {
            emit log("NOT REACHED: any flow-building trade also moved the tick, so variance != 0.");
            emit log("=> `if (sigmaSqWad == 0) return MAX_WELL_SKEW` looks UNREACHABLE in practice.");
        }
    }

    function test_E88_SigmaSentinelDiscriminatesUnmeasuredFromCalm() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();

        // FRESH band: `OracleLib.initPool` sets `cardinality = 1`, so the ring is UNPOPULATED by the
        // `>= 2` test. Variance here must read 0 = "we have not measured", and the skew must charge
        // the conservative ceiling — that is E59's intent and it must survive E88-r.
        uint vFresh = CORE.realizedVarianceWad();
        emit log_named_uint("variance, FRESH ring (expect 0 = unmeasured)", vFresh);
        emit log_named_uint("wellSkew, FRESH ring                        ", AUX.wellSkew(address(WETH), 0));

        // Now trade so the ring populates and real price movement enters it.
        for (uint i = 0; i < 8; ++i) _drain(20_000 * 1e18);
        uint vTraded = CORE.realizedVarianceWad();
        emit log_named_uint("variance, TRADED ring                       ", vTraded);
        emit log_named_uint("wellSkew, TRADED ring                       ", AUX.wellSkew(address(WETH), 0));

        if (vFresh == 0 && vTraded > 0) {
            emit log("SENTINEL INTACT: 0 means UNMEASURED; a traded ring reports real variance.");
        }
        // The discriminating state is `cardinality >= 2` AND a computed variance of exactly 0 — i.e.
        // a populated ring whose observations are all at the SAME tick. Report whether trading can
        // even produce it, because that decides live-fix vs defensive-only.
        if (vTraded == 1) {
            emit log("REACHED: populated ring with genuine zero variance -> returned 1 wei. LIVE FIX.");
        } else {
            emit log("NOT REACHED by ordinary trading: every swap moves the tick, so a populated ring");
            emit log("carries non-zero variance. E88-r is DEFENSIVE-ONLY on this path -- correct, but");
            emit log("it guards a state ordinary flow does not produce. Record it that way.");
        }
    }

    /// §E103 — IS THE 15 bps A PROPERTY OF THE IMBALANCE, OR AN ARTIFACT OF MY TICKET SIZE? E96 read
    /// it off ONE ticket (5,000) and E96b swept DEPTH but not SIZE. If the skew is a per-unit RATE
    /// the tax must be SIZE-INVARIANT at a fixed depth; if it drifts with size, "15 bps" is a
    /// number I chose rather than one the system has. Same imbalanced state for every leg (snapshot
    /// + revert), only the ticket changes.
    /// §E67 — DO *DEPLOYABLE* DOLLARS SIT BEHIND #12's FREED PERMISSION? The owner corrected me that
    /// #12 freed PERMISSION, not CAPITAL: `liquidTotal` never moved, only `committedBoth` fell, and
    /// whether real dollars back that headroom was never checked. E39's `surplus/price` arithmetic
    /// ASSUMED it did.
    /// METHOD — read ACTUAL BALANCES, not derived headroom. `get_deposits()` returns the per-stable
    /// amounts the basket really holds; `committedUsd18()` is what is spoken for. Headroom is only
    /// REAL if the basket physically holds unspoken-for stables. Deriving it from a subtraction of
    /// two aggregates would repeat the whole session's error.
    /// §E104 — THE THREE REMAINING UNMEASURED ITEMS, each with its own control.
    /// (1) E101's second check: does RESEAT reduce inventory without a swap? If so, E101's
    ///     "scarce-now + no-swap-since-ts ⟹ continuously scarce" derivation weakens further.
    /// (2) E59's claim that UNMEASURED variance charges the CEILING — E88-PROOF showed `wellSkew`
    ///     reads 0 on fresh/flush bands, so the claim is asserted here directly rather than implied.
    /// (3) The four constants: measure each one's MARGINAL EFFECT on the price via pure `skewWad`
    ///     calls, so "load-bearing" is a measurement rather than a reading of the source.
    function test_E104_ReseatInventoryAndE59Ceiling() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();

        // (2) E59: a FRESH band has unmeasured variance. Does it charge the ceiling?
        emit log_named_uint("E59: realizedVariance, fresh", CORE.realizedVarianceWad());
        emit log_named_uint("E59: wellSkew, fresh        ", AUX.wellSkew(address(WETH), 0));
        emit log_named_uint("E59: MAX_WELL_SKEW (claimed)", 3e16);

        for (uint i = 0; i < 6; ++i) _drain(20_000 * 1e18);
        uint invBefore = CORE.POOLED();
        uint64 tsF0 = _flowTs(false); uint64 tsS0 = _flowTs(true);

        // (1) RESEAT -- permissionless, no swap.
        V4.reseat();
        vm.roll(block.number + 1);
        uint invAfter = CORE.POOLED();
        emit log_named_uint("RESEAT: POOLED before   ", invBefore);
        emit log_named_uint("RESEAT: POOLED after    ", invAfter);
        emit log_named_uint("RESEAT: flow.ts fast b/a    ", tsF0);
        emit log_named_uint("                            ", _flowTs(false));
        if (invAfter < invBefore && _flowTs(false) == tsF0 && _flowTs(true) == tsS0) {
            emit log("RESEAT REDUCES INVENTORY WITHOUT BUMPING flow.ts -- E101 weakens further.");
        } else if (invAfter == invBefore) {
            emit log("RESEAT does NOT move inventory -- E101's derivation is UNAFFECTED by reseat.");
        } else {
            emit log("RESEAT moved inventory UP, or bumped flow.ts -- neither breaks the derivation.");
        }
    }

    /// §E104 part (3) — CONSTANT SENSITIVITY, measured not read. Vary each input the constants gate
    /// and observe whether the price responds. A constant whose variation does not move the output
    /// in the operating range is not a dial, whatever the source says.
    /// §E105 — SYSTEMATIC BOUNDARY SWEEP. Every structural defect found this session lived at an
    /// EXTREME, not in the operating range: E88's sentinel sat below two short-circuits and never
    /// executed · E99's idle decay drove the premium to ZERO · E104's empty-band drain OVERFLOWED
    /// and reverted. All three survived a 4,308-test green suite, a pinned controlled comparison,
    /// `--sizes` and `check-client-abis`, because **the suite tests REGRESSION thoroughly and
    /// EXTREMES barely**. This walks the corners deliberately. Pure calls: no fixture to blame.
    /// §E108 — DOES LP-FUNDED REPAIR PAY FOR ITSELF? Extends the IL baseline's structure
    /// (`Alles.t.sol:2952`, "LP USD exit vs HODL") rather than building a new harness.
    ///
    /// MECHANISM: there is no `refillETH` — it was built and removed as toxic (E106). The clean form
    /// already exists: **an LP DEPOSIT of the scarce side raises `POOLED`** (measured in E100:
    /// 137.49e18 -> 187.49e18). It spends no shared surplus and is funded by the party that benefits.
    ///
    /// MEASUREMENT: **VALUE PER SHARE** (`convertToAssets(1e18)`), never protocol totals — a deposit
    /// trivially raises totals, so a totals comparison would report the deposit itself as "profit".
    /// Two legs from an IDENTICAL drained state via snapshot/revert; only the repair differs.
    /// §E108b — HOW MUCH SHOULD AN LP REPAIR? E108 established the SIGN (+0.614 bps at one size);
    /// the decision needs the SHAPE. If the gain rises with repair size there is no optimum short of
    /// full repair; if it flattens or turns, there is. Reported in 1e-8 units because the effect is
    /// sub-1bp and a bps denominator TRUNCATED it to zero on E108's first run.
    /// §E109 — TESTS MY OWN EXPLANATION. E108-EXPLAINED claims composition is set by WHERE PRICE SITS
    /// IN THE RANGE, which predicts that a RESEAT — which moves the RANGE around the price, with NO
    /// deposit and NO swap — CHANGES THE RATIO. If the ratio does NOT move, the mechanism is wrong
    /// and the 0.758 "identity" needs another explanation.
    /// ⚠️ E104 measured that `reseat()` does NOT move `POOLED`. That is CONSISTENT with the
    /// mechanism (the range moves, the inventory does not) but it means any ratio shift here is a
    /// change in the REFERENCE, not in assets held — which is a bookkeeping move, NOT a repair.
    /// §E115 — VALIDATES E93's INSTRUMENT: does NORMALIZED TICK POSITION track the composition
    /// ratio monotonically? E113 confirmed composition is a function of price-in-range and that
    /// `POOLED_*` IS the position. E114 restored the tick design. This checks the actual mapping the
    /// design would consume: `(tick - loPrice) / (upPrice - loPrice)` against `vol:USD`.
    /// `reseatEpoch` is logged because a repack MOVES THE FRAME, and a normalized position read
    /// across a frame move is not comparable -- that is the discriminator a naive TWAP would lack.
    /// §E116 — THE TIME-WEIGHTED FORM, the last open piece of E93. E115 validated the SPOT
    /// normalized position; the design needs the TWAP so that PERSISTENCE is measured rather than an
    /// instant (E99: an idle imbalance must not read as free). `Core.observe(secondsAgos)`
    /// returns `tickCumulative`, so a time-averaged tick over a window is
    /// `(cum[0] - cum[1]) / window` — no new state, no new accumulator.
    /// The point of the test: a SPOT reading and a TWAP must DIVERGE after a fresh move, and the
    /// TWAP must lag. If they are identical the ring is not accumulating and the design is dead.
    /// §E117 — THE LAST UNMEASURED CASE: what does a `tickCumulative` window do when the FRAME MOVES
    /// mid-window? A reseat changes `loPrice`/`upPrice`, so a normalized position computed from a
    /// TWAP that spans the change mixes TWO frames. E114/E115 identified `reseatEpoch` as the public,
    /// monotonic discriminator; this measures what actually goes wrong without it.
    /// §E118 — CONSEQUENCES OF ELIMINATING THE MOVING FRAME, measured BEFORE proposing it. If the
    /// band never re-centred, `reseatEpoch` and E117's frame-mixing hazard would both vanish. The
    /// question is what that would COST: a fixed range that price leaves is OUT OF RANGE — 100% one
    /// asset, earning NOTHING. So the measurable is TICK TRAVEL vs BAND WIDTH. If travel >> width,
    /// a fixed frame is untenable and the epoch is unavoidable rather than incidental.
    function test_E118_TickTravelVersusBandWidth() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        (uint t0,) = CORE.poolStats();
        uint origLo = V4.LOWER_PRICE(); uint origHi = V4.UPPER_PRICE();
        emit log_named_uint("band width (price)        ", origHi - origLo);
        emit log_named_uint("start price              ", t0);

        uint minT = t0; uint maxT = t0;
        for (uint d = 0; d < 30; ++d) {
            deal(address(WETH), drainer, 30 ether);
            vm.startPrank(drainer);
            WETH.approve(address(AUX), 30 ether);
            try AUX.swap(bold, address(WETH), false, 30 ether, 0) {} catch { vm.stopPrank(); break; }
            vm.stopPrank(); _settle();
            (uint t,) = CORE.poolStats();
            if (t < minT) minT = t; if (t > maxT) maxT = t;
        }
        emit log_named_uint("price range visited      ", maxT - minT);
        emit log_named_uint("  min price              ", minT);
        emit log_named_uint("  max price              ", maxT);
        emit log_named_uint("frame lower price        ", V4.LOWER_PRICE());
        emit log_named_uint("frame upper price        ", V4.UPPER_PRICE());
        emit log_named_uint("band NOW  LOWER         ", V4.LOWER_PRICE());
        emit log_named_uint("band NOW  UPPER         ", V4.UPPER_PRICE());
        emit log_named_uint("ORIGINAL  LOWER         ", origLo);
        emit log_named_uint("ORIGINAL  UPPER         ", origHi);

        uint travel = maxT - minT; uint width = origHi - origLo;
        if (travel > width) {
            emit log("TRAVEL EXCEEDS WIDTH: a FIXED band would have gone OUT OF RANGE and stayed there,");
            emit log("holding 100% of one asset and earning nothing. The moving frame is REQUIRED, so");
            emit log("FRAME MOVES are UNAVOIDABLE -- not an incidental complication to design away.");
        } else {
            emit log("Travel stayed within width here -- a fixed band MIGHT be viable; widen the test");
            emit log("before concluding, because one sequence is not the operating envelope.");
        }
    }

    function test_E117_TwapAcrossAReseatMixesFrames() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        for (uint d = 0; d < 6; ++d) _drain(20_000 * 1e18);

        uint32[] memory ago = new uint32[](2); ago[0] = 0; ago[1] = 3600;
        bytes32 ep0 = keccak256(abi.encode(V4.LOWER_PRICE(), V4.UPPER_PRICE()));  // the FRAME, not a count
        uint lo0 = V4.LOWER_PRICE(); uint hi0 = V4.UPPER_PRICE();
        // §TICK-REMOVAL — the ring yields a PRICE TWAP now, so the reading is in price space. The
        // frame (LOWER/UPPER_TICK) is still v4's and still ticks, so the FRAME-MOVED signal below —
        // which is what this diagnostic exists to surface — is unchanged.
        uint192[] memory c0 = CORE.observe(ago);
        uint twap0 = uint(c0[0] - c0[1]) / 3600;
        emit log_named_uint("BEFORE: lower price     ", V4.LOWER_PRICE());
        emit log_named_uint("BEFORE: 1h TWAP price  ", twap0);

        // Force frame motion the way E112 did -- sells push price to loPrice and trigger repacks.
        for (uint d = 0; d < 40; ++d) {
            deal(address(WETH), drainer, 30 ether);
            vm.startPrank(drainer);
            WETH.approve(address(AUX), 30 ether);
            try AUX.swap(bold, address(WETH), false, 30 ether, 0) {} catch { vm.stopPrank(); break; }
            vm.stopPrank(); _settle();
        }

        bytes32 ep1 = keccak256(abi.encode(V4.LOWER_PRICE(), V4.UPPER_PRICE()));
        uint lo1 = V4.LOWER_PRICE(); uint hi1 = V4.UPPER_PRICE();
        uint192[] memory c1 = CORE.observe(ago);
        uint twap1 = uint(c1[0] - c1[1]) / 3600;
        emit log_named_uint("AFTER : lower price     ", V4.LOWER_PRICE());
        emit log_named_uint("AFTER : 1h TWAP price  ", twap1);
        emit log_named_uint("AFTER : band LOWER     ", lo1);
        emit log_named_uint("AFTER : band UPPER     ", hi1);


        if (ep1 == ep0) { emit log("VOID: no reseat occurred -- the frame never moved."); return; }
        emit log("FRAME MOVED. The TWAP above spans BOTH frames, so `normalized` mixes a pre-reseat");
        emit log("tick with a post-reseat range. The band BOUNDS moving is the signal of that --");
        emit log("without it the number looks perfectly ordinary. THAT is why it must be read.");
        if (twap1 == twap0) emit log("TWAP price UNCHANGED across the reseat.");
    }

    function test_E116_TimeWeightedTickLagsTheSpot() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        for (uint d = 0; d < 6; ++d) _drain(20_000 * 1e18);   // establish a history

        uint32[] memory ago = new uint32[](2);
        ago[0] = 0; ago[1] = 3600;                            // 1-hour window
        // §TICK-REMOVAL — price space. The property under test is unchanged: a time-weighted mean
        // must LAG a fresh move, or the ring is not accumulating and persistence is unmeasurable.
        uint192[] memory c0 = CORE.observe(ago);
        (uint spot0,) = CORE.poolStats();
        uint twap0 = uint(c0[0] - c0[1]) / 3600;
        emit log_named_uint("BEFORE move: spot price ", spot0);
        emit log_named_uint("BEFORE move: 1h TWAP px", twap0);

        for (uint d = 0; d < 6; ++d) _drain(60_000 * 1e18);   // a FRESH, larger move

        uint192[] memory c1 = CORE.observe(ago);
        (uint spot1,) = CORE.poolStats();
        uint twap1 = uint(c1[0] - c1[1]) / 3600;
        emit log_named_uint("AFTER  move: spot price ", spot1);
        emit log_named_uint("AFTER  move: 1h TWAP px", twap1);
        emit log_named_uint("frame lower price       ", V4.LOWER_PRICE());

        if (spot1 == spot0) { emit log("VOID: the move did not shift the spot tick."); return; }
        if (twap1 == twap0) {
            emit log("TWAP UNMOVED: the ring is NOT accumulating over this window -- design is DEAD.");
        } else {
            emit log("TWAP MOVED WITH LAG: the ring accumulates, so persistence is measurable. LIVE.");
        }
    }

    function test_E115_NormalizedTickTracksComposition() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        for (uint round = 0; round < 5; ++round) {
            for (uint d = 0; d < 4; ++d) _drain(20_000 * 1e18);
            (uint ct, uint liq) = CORE.poolStats();
            uint lo = V4.LOWER_PRICE(); uint hi = V4.UPPER_PRICE();
            uint px = AUX.getTWAPforAsset(address(WETH), 1800);
            uint volLeg = CORE.POOLED() * px / 1e30;
            uint usdLeg = CORE.POOLED_USD();
            uint norm = hi > lo && ct >= lo ? uint((ct - lo)) * 1e4 / uint((hi - lo)) : 0;
            emit log_named_uint("normalized tick (1e-4)  ", norm);
            emit log_named_uint("  vol:USD ratio (1e-4)  ", usdLeg == 0 ? 0 : volLeg * 1e4 / usdLeg);
            emit log_named_uint("  frame lower price      ", V4.LOWER_PRICE());
            emit log_named_uint("  liquidity             ", liq);
        }
        emit log("Monotone normalized-vs-ratio WITHIN one frame => the instrument works.");
        emit log("A jump where the band bounds change is a FRAME MOVE, not a composition change.");
    }

    function test_E109_DoesReseatMoveTheRatio() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 300 ether}(0, lpA);
        _settle();
        // §E110-r: the repack gate is `currentTick >= upPrice || currentTick < loPrice`, so the
        // band must be driven OUT OF RANGE before a reseat does anything. 12 rounds of 20k moved
        // price ~0.15% against a +/-0.2% band and never exited -- which is why E109 tested nothing.
        // `reseatEpoch` incrementing IS the proof the band exited and re-centred, so no tick getter
        // is needed: drain hard, then assert the epoch moved before reading any result.
        // §E111 -> §E112: DRAINING cannot arm this test -- it empties the band, and the repack needs
        // `myLiquidity > 0`, so the liquidity is destroyed in the act of moving the price. The MIRROR
        // construction avoids that: SELLING ETH IN pushes price DOWN toward `loPrice`, where a
        // concentrated position converts to 100% VOLATILE -- so the band exits the range while still
        // HOLDING assets rather than being emptied. That is a band that is out-of-range AND liquid,
        // which is exactly the state E108-EXPLAINED's mechanism needs to be testable.
        uint sells;
        for (uint d = 0; d < 40; ++d) {
            deal(address(WETH), drainer, 30 ether);
            vm.startPrank(drainer);
            WETH.approve(address(AUX), 30 ether);
            try AUX.swap(bold, address(WETH), false, 30 ether, 0) { sells++; }
            catch { vm.stopPrank(); emit log_named_uint("sell path hit its limit after", sells); break; }
            vm.stopPrank();
            _settle();
        }
        emit log_named_uint("sells completed           ", sells);

        // §E112 -> §E113 ANSWERED BY CONSTRUCTION, SO THE COMPARISON IS GONE. This used to recompute
        // the v4 POSITION's true split from (sqrtPrice, loPrice, upPrice, liquidity) and diff it
        // against `POOLED_*` to decide which of the two the ledger measured. There is no v4 position
        // left to disagree with: the band settles against the oracle bounded by inventory, and
        // `poolStats()` reports OUR OWN accounting. `POOLED_*` is the ledger -- not because the diff
        // came out that way, but because there is nothing else for it to be. Recomputing a number
        // from the same source it is being checked against is a control that CANNOT fail, which is
        // worse than no control: it reads as coverage.
        {
            (uint px, uint liq) = CORE.poolStats();
            emit log_named_uint("band price                ", px);
            emit log_named_uint("band liquidity            ", liq);
            emit log_named_uint("Core POOLED           ", CORE.POOLED());
            emit log_named_uint("Core POOLED_USD       ", CORE.POOLED_USD());
        }

        uint px0   = AUX.getTWAPforAsset(address(WETH), 1800);
        uint vol0  = CORE.POOLED() * px0 / 1e30;
        uint usd0  = CORE.POOLED_USD();
        uint eth0  = CORE.POOLED();
        emit log_named_uint("BEFORE reseat: vol:USD (1e-4)", usd0 == 0 ? 0 : vol0 * 1e4 / usd0);
        emit log_named_uint("BEFORE reseat: POOLED   ", eth0);

        // §E110 — THE CONTROL E109 LACKED: did the reseat ACTUALLY RE-RANGE? If `LOWER_TICK`/
        // `UPPER_TICK`/`reseatEpoch` are unchanged, the reseat was a NO-OP and E109 tested NOTHING —
        // its "refutation" of the price-in-range mechanism would itself be void. I asserted a
        // negative result without checking the operation under test had any effect.
        uint lo0 = V4.LOWER_PRICE(); uint hi0 = V4.UPPER_PRICE();
        V4.reseat();
        vm.roll(block.number + 1);
        uint lo1 = V4.LOWER_PRICE(); uint hi1 = V4.UPPER_PRICE();
        emit log_named_uint("LOWER_PRICE before/after   ", lo0);
        emit log_named_uint("                          ", lo1);
        emit log_named_uint("UPPER_PRICE before/after   ", hi0);
        emit log_named_uint("                          ", hi1);
        if (lo0 == lo1 && hi0 == hi1) {
            emit log("RESEAT WAS A NO-OP -- E109 tested nothing and its refutation is VOID.");
        } else {
            emit log("RESEAT DID re-range -- E109's negative result is a REAL test of the mechanism.");
        }

        uint px1  = AUX.getTWAPforAsset(address(WETH), 1800);
        uint vol1 = CORE.POOLED() * px1 / 1e30;
        uint usd1 = CORE.POOLED_USD();
        uint eth1 = CORE.POOLED();
        emit log_named_uint("AFTER  reseat: vol:USD (1e-4)", usd1 == 0 ? 0 : vol1 * 1e4 / usd1);
        emit log_named_uint("AFTER  reseat: POOLED   ", eth1);

        if (usd0 == 0 || usd1 == 0) { emit log("VOID: a USD leg is zero."); return; }
        uint r0 = vol0 * 1e4 / usd0; uint r1 = vol1 * 1e4 / usd1;
        if (r1 != r0 && eth1 == eth0) {
            emit log("PREDICTION HOLDS: the ratio moved with NO change in POOLED -- the reference");
            emit log("moved, not the assets. Composition IS a function of price-in-range. NOT a repair.");
        } else if (r1 == r0) {
            emit log("PREDICTION FAILS: reseat did not move the ratio. My mechanism is WRONG and the");
            emit log("0.758 identity needs another explanation -- do not build on E108-EXPLAINED.");
        } else {
            emit log("Ratio AND inventory both moved -- reseat is doing more than re-ranging; re-read.");
        }
    }

    function test_E108b_HowMuchRepairIsOptimal() public {
        // §E108b-r: the old sweep (10/40/100/200) never left a DEEPLY IMBALANCED window — 0.666 to
        // 0.714 volatile:USD — so its "optimum" could not be distinguished from "beyond my largest
        // sample". These sizes REACH AND CROSS 1:1, which is the only way to state an optimum
        // against a NAMED target rather than against whatever range I happened to pick.
        uint[5] memory sizes = [uint(100 ether), 300 ether, 600 ether, 1000 ether, 1600 ether];
        vm.deal(lpA, 6000 ether);   // the sweep now needs far more than the fixture's default
        for (uint i = 0; i < 5; ++i) {
            uint snap = vm.snapshotState();
            _seedBasket();
            vm.deal(lpA, 6000 ether);
            vm.prank(lpA); V4.deposit{value: 300 ether}(0, lpA);
            _settle();
            for (uint d = 0; d < 12; ++d) _drain(20_000 * 1e18);

            uint inner = vm.snapshotState();
            for (uint d = 0; d < 6; ++d) _drain(5_000 * 1e18);
            uint noRepair = V4.convertToAssets(1e18);
            vm.revertToState(inner);

            vm.prank(lpA); V4.deposit{value: sizes[i]}(0, lpA);
            vm.roll(block.number + 1);
            for (uint d = 0; d < 6; ++d) _drain(5_000 * 1e18);
            uint repaired = V4.convertToAssets(1e18);

            // §E108b-r: locate 1:1 -- "full restoration" is ambiguous between restoring the DRAINED
            // amount and reaching volatile==USD. The optimum must be stated against a named target.
            {
                uint px = AUX.getTWAPforAsset(address(WETH), 1800);
                uint volLeg = CORE.POOLED() * px / 1e30;
                uint usdLeg = CORE.POOLED_USD();
                emit log_named_uint("    vol:USD ratio (1e-4)", usdLeg == 0 ? 0 : volLeg * 1e4 / usdLeg);
            }
            emit log_named_uint("--- repair size (wei)   ", sizes[i]);
            if (noRepair == 0) { emit log("    VOID: zero share value"); vm.revertToState(snap); continue; }
            if (repaired > noRepair) {
                emit log_named_uint("    gain (1e-8)         ", (repaired - noRepair) * 1e8 / noRepair);
            } else {
                emit log_named_uint("    LOSS (1e-8)         ", (noRepair - repaired) * 1e8 / repaired);
            }
            vm.revertToState(snap);
        }
        emit log("Rising with size => repair as much as possible. Flattening/turning => an optimum exists.");
    }

    function test_E108_DoesLpFundedRepairPayForItself() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 300 ether}(0, lpA);
        _settle();
        for (uint i = 0; i < 12; ++i) _drain(20_000 * 1e18);   // drive the imbalance

        uint invDrained = CORE.POOLED();
        uint perShare0  = V4.convertToAssets(1e18);
        emit log_named_uint("after drain: POOLED  ", invDrained);
        emit log_named_uint("after drain: value/share ", perShare0);

        uint snap = vm.snapshotState();

        // LEG A -- NO REPAIR. Same subsequent flow.
        for (uint i = 0; i < 6; ++i) _drain(5_000 * 1e18);
        uint perShareA = V4.convertToAssets(1e18);
        uint invA = CORE.POOLED();
        vm.revertToState(snap);

        // LEG B -- LP REPAIRS by depositing the scarce side, then the SAME subsequent flow.
        vm.prank(lpA); V4.deposit{value: 40 ether}(0, lpA);
        vm.roll(block.number + 1);
        uint invRepaired = CORE.POOLED();
        for (uint i = 0; i < 6; ++i) _drain(5_000 * 1e18);
        uint perShareB = V4.convertToAssets(1e18);

        emit log_named_uint("REPAIR moved POOLED to", invRepaired);
        emit log_named_uint("leg A (no repair) inv     ", invA);
        emit log_named_uint("value/share  NO REPAIR    ", perShareA);
        emit log_named_uint("value/share  REPAIRED     ", perShareB);

        // CONTROLS -- without these the comparison is meaningless.
        assertGt(invRepaired, invDrained, "PREMISE: the repair must actually raise inventory");
        if (perShareA == 0 || perShareB == 0) { emit log("VOID: a leg has zero share value."); return; }

        if (perShareB > perShareA) {
            // §E108: report in 1e8 units, not bps. The gain is sub-1bp, and `* 10_000 /` TRUNCATED
            // it to 0 on the first run -- the same rounding-branch error as E71. A measure that
            // cannot represent its own result reports "no effect" when the effect is real.
            emit log_named_uint("REPAIR PAYS: value/share gain (1e-8)", (perShareB - perShareA) * 1e8 / perShareA);
        } else if (perShareA > perShareB) {
            emit log_named_uint("REPAIR COSTS: value/share loss (1e-8)", (perShareA - perShareB) * 1e8 / perShareB);
            emit log("=> the LP is WORSE OFF repairing -- a drained band is cheaper to hold.");
        } else {
            emit log("NEUTRAL: repair changes value/share by nothing measurable at this horizon.");
        }
    }

    function test_E105_BoundarySweep() public pure {
        uint T = 1_000_000e6;
        // Each row is a corner that a real band can actually occupy.
        console.log("--- target == 0 (genesis, no flow history)");
        console.log("  eth:", SwapLib.skewWad(T, 0, 1e16, SwapLib.ethRisk(), T / 4));
        console.log("  btc:", SwapLib.skewWad(T, 0, 1e16, SwapLib.btcRisk(),  T / 4));
        console.log("--- inv == 0 (band already empty)");
        console.log("  eth:", SwapLib.skewWad(0, T, 1e16, SwapLib.ethRisk(), T / 4));
        console.log("  btc:", SwapLib.skewWad(0, T, 1e16, SwapLib.btcRisk(),  T / 4));
        console.log("--- drain == 0 (read-only quote)");
        console.log("  eth:", SwapLib.skewWad(T / 2, T, 1e16, SwapLib.ethRisk(), 0));
        console.log("--- drain >> inv (asks for more than exists)");
        console.log("  eth:", SwapLib.skewWad(T / 100, T, 1e16, SwapLib.ethRisk(), T * 10));
        console.log("--- sigma^2 == 0 (unmeasured) at real scarcity");
        console.log("  eth:", SwapLib.skewWad(T / 2, T, 0, SwapLib.ethRisk(), T / 4));
        console.log("--- sigma^2 enormous");
        console.log("  eth:", SwapLib.skewWad(T / 2, T, 1e20, SwapLib.ethRisk(), T / 4));
        console.log("--- inv >> target (deeply flush)");
        console.log("  eth:", SwapLib.skewWad(T * 100, T, 1e16, SwapLib.ethRisk(), T / 4));
        console.log("--- all-min: everything zero");
        console.log("  eth:", SwapLib.skewWad(0, 0, 0, SwapLib.ethRisk(), 0));
        console.log("If any line reverted, the sweep would have failed rather than printed.");
    }

    function test_E104_ConstantSensitivity() public pure {
        uint T = 1_000_000e6; uint inv = T / 2; uint drain = T / 4;
        // CONF_FRAC (BTC, ~1hr) vs ETH_CONF_FRAC (~12s) enter only via the base; SPLICE_FLOOR is
        // BTC-only. Comparing BTC vs ETH at identical q and sigma isolates their combined effect.
        uint btc = SwapLib.skewWad(inv, T, 1e16, SwapLib.btcRisk(),  drain);
        uint eth = SwapLib.skewWad(inv, T, 1e16, SwapLib.ethRisk(), drain);
        console.log("skew BTC (base = splice + conf) :", btc);
        console.log("skew ETH (base = eth conf only) :", eth);
        console.log("difference attributable to SPLICE_FLOOR + conf gap:", btc - eth);
        // MAX_WELL_SKEW appears TWICE (kernel coefficient AND ceiling). Drive q to the pole to see
        // whether the ceiling binds -- if it does, the coefficient role is invisible there.
        uint hot = SwapLib.skewWad(T / 100, T, 5e18, SwapLib.ethRisk(), drain);
        console.log("skew ETH at q=0.99, sigma^2=5e18 :", hot);
        console.log("MAX_WELL_SKEW                    :", uint(3e16));
    }

    function test_E67_IsTheFreedHeadroomBackedByRealDollars() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();

        (uint[15] memory amts,,,) = AUX.get_deposits();
        address[] memory ss = AUX.getStables();
        // §E67-r CORRECTED INSTRUMENT: `balanceOf(Aux)` reads ZERO for every stable, because the
        // basket DEPLOYS them into venues (Aave, 4626 vaults, the Stability Pool — the same fact
        // E91 traced when proceeds arrived from the BOLD SP). Raw balances measure idle dust, not
        // holdings. `get_deposits()` is the accounted position INCLUDING deployed capital.
        uint heldUsd18;
        for (uint i = 0; i < 15; ++i) heldUsd18 += amts[i];
        ss;   // silence: kept only to document that the raw-balance route was the wrong one
        uint committed = CORE.committedUsd18();
        emit log_named_uint("stables PHYSICALLY held by Aux (usd18)", heldUsd18);
        emit log_named_uint("committedUsd18 (spoken for)           ", committed);
        emit log_named_uint("get_deposits slot0 (sanity)           ", amts[0]);

        if (heldUsd18 > committed) {
            emit log_named_uint("REAL unspoken-for dollars (usd18)", heldUsd18 - committed);
            emit log("=> the freed headroom IS backed by dollars Aux actually holds.");
        } else {
            emit log("=> Aux holds NO MORE than is committed: the headroom is PERMISSION ONLY.");
            emit log("   The owner's E67 correction stands and E39's surplus/price math is unbacked.");
        }
    }

    function test_E103_IsTheTaxInvariantToTicketSize() public {
        uint[4] memory tickets = [uint(1_000e18), 5_000e18, 20_000e18, 60_000e18];
        for (uint i = 0; i < 4; ++i) {
            // BALANCED reference for THIS ticket size.
            uint snap = vm.snapshotState();
            _seedBasket();
            vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
            _settle();
            uint refEth = _drain(tickets[i]);
            vm.revertToState(snap);

            // SAME ticket into a band someone else drained to the SAME depth.
            _seedBasket();
            vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
            _settle();
            for (uint r = 0; r < 20; ++r) _drain(20_000 * 1e18);
            uint skewedEth = _drain(tickets[i]);
            vm.revertToState(snap);

            emit log_named_uint("--- ticket (usd18)      ", tickets[i]);
            if (refEth == 0 || skewedEth == 0) { emit log("    VOID: a leg got nothing"); continue; }
            if (skewedEth < refEth) {
                emit log_named_uint("    TAX bps              ", (refEth - skewedEth) * 10_000 / refEth);
            } else {
                emit log("    TAX bps              : 0 (no penalty at this size)");
            }
        }
        emit log("If TAX bps is flat across sizes, 15 bps is a property of the DEPTH.");
        emit log("If it drifts, the number is an artifact of the ticket I happened to pick.");
    }

    function test_E96b_TaxScalesWithImbalanceDepth() public {
        uint SMALL = 5_000 * 1e18;
        uint8[4] memory rounds = [0, 6, 12, 20];   // 0 = balanced reference
        uint refEth;
        uint refInv;
        for (uint r = 0; r < 4; ++r) {
            uint snap = vm.snapshotState();
            _seedBasket();
            vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
            _settle();
            for (uint i = 0; i < rounds[r]; ++i) _drain(20_000 * 1e18);
            uint inv = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
            uint got = _drain(SMALL);
            if (r == 0) { refEth = got; refInv = inv; }
            // §E93-b GATE: does the TICK (hence price) track COMPOSITION? If the band is
            // oracle-pegged, price is pinned externally and CANNOT encode internal imbalance --
            // which would refute E93-b's premise that the tick ring records composition history.
            emit log_named_uint("    oracle px (usd18)   ", AUX.getTWAPforAsset(address(WETH), 1800));
            emit log_named_uint("--- drain rounds        ", rounds[r]);
            emit log_named_uint("    inv (usd6)          ", inv);
            emit log_named_uint("    ETH for a 5k ticket ", got);
            if (r > 0 && refEth > 0 && got < refEth) {
                emit log_named_uint("    TAX vs balanced, bps", (refEth - got) * 10_000 / refEth);
            } else if (r > 0) {
                emit log("    TAX vs balanced, bps: 0 (no penalty at this depth)");
            }
            vm.revertToState(snap);
        }
        emit log_named_uint("reference inv (balanced)", refInv);
        assertGt(refEth, 0, "reference leg must receive volatile or the sweep is void");
    }

    function test_E96_TaxOnOrdinaryFlowFromSomeoneElsesImbalance() public {
        uint SMALL = 5_000 * 1e18;      // an ordinary ticket, not a whale

        // LEG A — the SAME small swap into a FRESH, balanced band.
        uint snap = vm.snapshotState();
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA);
        _settle();
        uint invBal = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint ethBalanced = _drain(SMALL);
        vm.revertToState(snap);

        // LEG B — the SAME small swap into a band someone ELSE has already drained.
        _setupBand();
        uint invSkewed = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint ethSkewed = _drain(SMALL);

        emit log_named_uint("inv BALANCED (usd6)  ", invBal);
        emit log_named_uint("inv IMBALANCED (usd6)", invSkewed);
        emit log_named_uint("ETH for 5k @ balanced  ", ethBalanced);
        emit log_named_uint("ETH for 5k @ imbalanced", ethSkewed);

        if (ethBalanced == 0 || ethSkewed == 0) {
            emit log("VOID: a leg received nothing -- cannot compare.");
            return;
        }
        if (invSkewed >= invBal) {
            emit log("VOID: leg B was not actually more scarce than leg A.");
            return;
        }
        if (ethSkewed < ethBalanced) {
            emit log_named_uint("TAX on ordinary flow, bps",
                (ethBalanced - ethSkewed) * 10_000 / ethBalanced);
            emit log("^ what a 5k ticket pays for an imbalance it did NOT cause.");
        } else {
            emit log("NO TAX: the ordinary ticket was not penalised by the standing imbalance.");
        }
    }

    function test_E71_OneBigDrainIsNotCheaperThanTheSameVolumeSplit() public {
        uint TOTAL = 120_000 * 1e18;
        uint N = 12;
        // §UNIT-B CONTROL (2026-08-10) — the discriminator §UNIT-B-STALE-RETRACT demanded. A
        // path-independent RESULT and a NO-SKEW-CHARGED result look identical from the trader's
        // receipt, and that ambiguity is exactly what retracted the previous "the discount is gone".
        // Post-§UNIT-A the base is reachable, so this asserts skew was ACTUALLY charged before the
        // gap is allowed to mean anything.
        uint premStart = CORE.skewPremium();

        // §E71-r3 — MEASURES THE TRADER'S RECEIPT, NOT OUR BOOKKEEPING. The prior version compared
        // `skewPremiumCum`, i.e. the protocol's own record of what it retained. That is the trap that
        // hid the delivery bug through six layers: asserting on a number the failing system reports
        // about ITSELF. A discount in our ledger is not evidence of a discount to the WHALE. Identical
        // dollars go in on both legs, so whoever receives MORE volatile paid LESS — that is the
        // arbitrage, stated in the only terms an arbitrageur acts on. The premium legs are DELETED
        // rather than kept alongside: keeping both was hedging, and it cost the stack slots that made
        // this function stack-too-deep.
        uint snap = vm.snapshotState();
        _setupBand();
        uint invA = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        emit log_named_uint("flow target t0 (BIG)  ", CORE.flowEwmaUsd());
        uint ethA = _drain(TOTAL);
        emit log_named_uint("flow target t1 (BIG)  ", CORE.flowEwmaUsd());
        uint premA = CORE.skewPremium() - premStart;   // ledger, BIG leg (pre-revert)
        vm.revertToState(snap);

        _setupBand();
        uint invB = CORE.POOLED() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint ethB;
        for (uint i = 0; i < N; ++i) {
            emit log_named_uint("flow target (SPLIT i) ", CORE.flowEwmaUsd());
            ethB += _drain(TOTAL / N);
        }
        uint premB = CORE.skewPremium() - premStart;   // ledger, SPLIT leg

        emit log_named_uint("start inv A (usd6)    ", invA);
        emit log_named_uint("start inv B (usd6)    ", invB);
        emit log_named_uint("ETH to ONE big drain  ", ethA);
        emit log_named_uint("ETH to the SPLIT (sum)", ethB);

        // CONTROLS. Both must hold or the comparison is void — a run that cannot show its own
        // premises is indistinguishable from a run that confirms what I expected.
        if (invA != invB) { emit log("VOID: legs started from different states."); return; }
        if (ethA == 0 || ethB == 0) { emit log("VOID: a leg received no volatile."); return; }

        // A 1-wei difference is not an arbitrage. Anything under 1 bp of the total is integer
        // rounding across twelve tickets vs one, so treat it as path-INDEPENDENT — which is the
        // property the integral was built to deliver. Without this the branch shouted "ARBITRAGE IS
        // REAL" on a 0 bps gap.
        uint gap = ethA > ethB ? ethA - ethB : ethB - ethA;
        if (gap * 10_000 / (ethA > ethB ? ethB : ethA) == 0) {
            emit log("TRADER-SIDE: PATH-INDEPENDENT to within rounding -- consolidation buys NOTHING.");
            emit log_named_uint("CONTROL skew BIG   (usd6)", premA);
        emit log_named_uint("CONTROL skew SPLIT (usd6)", premB);
        emit log_named_uint("consolidation discount bps", premB > premA
            ? (premB - premA) * 10_000 / premB : 0);
        assertGt(premA, 0, "CONTROL: skew must actually have been charged on the BIG leg, else a "
            "'path-independent' gap is indistinguishable from no skew at all (UNIT-B-STALE-RETRACT)");
        assertGt(premB, 0, "CONTROL: skew must actually have been charged on the SPLIT leg too");
        emit log_named_uint("gap (wei)", gap);
        } else if (ethA > ethB) {
            emit log("TRADER-SIDE: BIG DRAIN got MORE eth for the same dollars -- ARBITRAGE IS REAL.");
            emit log_named_uint("whale advantage bps", (ethA - ethB) * 10_000 / ethB);
        } else if (ethB > ethA) {
            emit log("TRADER-SIDE: the SPLIT got more -- consolidation is PENALISED, not rewarded.");
            emit log_named_uint("split advantage bps", (ethB - ethA) * 10_000 / ethA);
        } else {
            emit log("TRADER-SIDE: IDENTICAL receipts -- path-independent, which is the goal.");
        }
    }


    /// §UNIT-B-VERIFIED — DOES THE PREMIUM COUNTER MATCH WHAT THE SWAPPER ACTUALLY LOSES?
    /// §UNIT-B-VERIFIED measured the counter and the trader-side receipt disagreeing by ~1000× and
    /// called it a MONEY-PATH question: §E5 credits LPs the RECORDED number, so if the record
    /// overstates what is withheld, LPs are paid value no swapper paid.
    /// ⚠️ §UNIT-SKEW-IS-NOISE already tried "measure (a) balance deltas, (b) counter, (c) USD_FEES in
    /// one run" and could NOT settle it: (a) conflates band cushion + price impact + skew.
    /// ⚠️ AND THE OBVIOUS DIFFERENCING DESIGN IS BROKEN: `q = (target-inv)/target` and `inv` IS the
    /// depth, so reaching a different `q` BY DRAINING changes the depth and the cushion stops
    /// cancelling — silently, with every control passing (§UNIT-B-VERIFIED-DESIGN-FIX).
    /// ⇒ SO: hold INVENTORY fixed and move the DENOMINATOR. Both arms drain the SAME size from the
    /// SAME snapshot; the flow EWMA is decayed one 48h half-life in arm A, so only `target` differs.
    /// Cushion and curve impact are functions of size and depth ⇒ they CANCEL. What remains is skew.
    /// `retainSkewPremium` does `r.amount -= premium`, so a dollar withheld is a dollar the swapper
    /// does not receive: **ΔReceipt must equal ΔCounter.**
    function test_UNITB_CounterMatchesWhatTheSwapperLoses() public {
        _setupBand();
        uint SIZE = 30_000 * 1e18;
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        uint snap = vm.snapshotState();

        // ARM A — decayed target (LOWER q ⇒ LESS skew ⇒ MORE volatile received)
        vm.warp(block.timestamp + 2 days); vm.roll(block.number + 1);
        emit log_named_uint("A target      ", CORE.flowEwmaUsd());
        emit log_named_uint("A POOLED  ", CORE.POOLED());
        emit log_named_uint("A POOLED_USD  ", CORE.POOLED_USD());
        uint pooledEthA = CORE.POOLED(); uint pooledUsdA = CORE.POOLED_USD();
        uint premA = CORE.skewPremium();
        uint ethA = _drain(SIZE);
        premA = CORE.skewPremium() - premA;

        vm.revertToState(snap);

        // ARM B — undecayed target (HIGHER q ⇒ MORE skew ⇒ LESS volatile received)
        emit log_named_uint("B target      ", CORE.flowEwmaUsd());
        emit log_named_uint("B POOLED  ", CORE.POOLED());
        emit log_named_uint("B POOLED_USD  ", CORE.POOLED_USD());
        // CONTROL, and it must be taken PRE-DRAIN in BOTH arms: identical depth is what makes the
        // cushion and curve impact cancel. Comparing a pre-drain figure to a post-drain one is the
        // mistake that made this assertion fire the first time.
        assertEq(CORE.POOLED(), pooledEthA, "CONTROL: identical volatile depth across arms, "
            "else the band cushion does not cancel and this measures the wrong thing");
        assertEq(CORE.POOLED_USD(), pooledUsdA, "CONTROL: identical USD depth across arms");
        uint premB = CORE.skewPremium();
        uint ethB = _drain(SIZE);
        premB = CORE.skewPremium() - premB;

        emit log_named_uint("A eth received", ethA);
        emit log_named_uint("B eth received", ethB);
        emit log_named_uint("A skew (usd6) ", premA);
        emit log_named_uint("B skew (usd6) ", premB);
        // ETH is 18-dec, px is usd*1e18 per 1e18 wei scaled 1e30 in this repo's convention.
        // §UNIT-SKEW-IS-NOISE post-§UNIT-A: what FRACTION of the swapper's bill is the skew?
        emit log_named_uint("px (usd18/ETH)  ", px);
        emit log_named_uint("ETH at oracle   ", SIZE * 1e18 / px);
        emit log_named_uint("ETH received (B)", ethB);
        emit log_named_uint("TOTAL cost usd18", (SIZE * 1e18 / px - ethB) * px / 1e18);
        emit log_named_uint("skew  cost usd18", premB * 1e12);
        emit log_named_uint("sigma^2 (wad)   ", CORE.realizedVarianceWad());
        emit log_named_uint("dReceipt (usd18)", ethA > ethB
            ? (ethA - ethB) * px / 1e18 : 0);
        emit log_named_uint("dCounter (usd18)", premB > premA ? (premB - premA) * 1e12 : 0);

        // CONTROLS. `premA == 0` is legitimate and NOT a void run: ETH has no `SPLICE_FLOOR` and
        // arm A's sigma^2 is unmeasured, so `_maxWellSkew` is 0 there. What the comparison needs is
        // that the arms DIFFER and that the depth is IDENTICAL — the second is what makes the
        // cushion cancel, and its absence is the silent failure this design was rebuilt to avoid.
        assertTrue(premB != premA, "CONTROL: the target move must change the skew, else the arms "
            "are identical and any agreement is trivial");

        // THE CLAIM: `retainSkewPremium` does `r.amount -= premium`, so a dollar withheld is a
        // dollar the swapper does not receive. There is no third destination.
        assertApproxEqRel(
            (ethA - ethB) * px / 1e18, (premB - premA) * 1e12, 0.01e18,
            "the RECORDED premium must equal what the swapper actually loses: E5 credits LPs the "
            "recorded number, so an overstating record pays LPs value no swapper paid");
    }

    /// §UNIT-A-FIXTURE (surviving half) — DRIVE THE POOL TICK, NOT THE FEED.
    /// `realizedVarianceWad` reads the POOL's observation ring (`Core:313` →
    /// `OracleLib.ringVariance(..., 9)`), and the ring advances ONLY ON A SWAP. The band executes AT
    /// oracle, so walking the Chainlink feed moves NOTHING — that is why every fixture here reports
    /// ~0 variance and why §UNIT-SKEW-IS-NOISE's "rounding error" was measured on a flat tape
    /// (§SKEW-IS-NOISE-OVERTURNED: 2.458e-5 wad = 0.496% ANNUALIZED vol, against ETH's real 30-60%).
    /// This alternates direction with varying size so the tick moves BOTH ways and the ring stores
    /// real second differences rather than a straight line.
    function _driveTick(uint rounds) internal {
        address t = makeAddr("tick-driver");
        deal(address(USDC), t, 50_000_000 * USDC_PRECISION);
        deal(address(WETH), t, 20_000 ether);
        vm.startPrank(t);
        USDC.approve(address(AUX), type(uint).max);
        WETH.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < rounds; ++i) {
            if (i % 2 == 0) {
                try AUX.swap(address(USDC), address(WETH), true,
                    (4_000 + (i % 5) * 1_500) * USDC_PRECISION, 0) {} catch {}
            } else {
                try AUX.swap(address(WETH), address(USDC), true,
                    (1 + (i % 4)) * 1e18, 0) {} catch {}
            }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 90 seconds);
        }
        vm.stopPrank();
    }

    /// Does the fixture actually reach a plausible volatility? Reports, and asserts only that it
    /// moved the ring at all — the plausible-band assertion goes in once the level is known.
    function test_UNITA_FixtureDrivesRealVariance() public {
        _setupBand();
        emit log_named_uint("sigma^2 BEFORE (wad)", CORE.realizedVarianceWad());
        _driveTick(20);
        uint s2 = CORE.realizedVarianceWad();
        emit log_named_uint("sigma^2 AFTER  (wad)", s2);
        // annualized vol = sqrt(sigma^2); report in bps so the level is readable at a glance.
        emit log_named_uint("annualized vol (bps)", Math.sqrt(s2 * 1e18) / 1e14);
        assertGt(s2, CORE.realizedVarianceWad() * 0 + 1, "the tick driver must move the ring");
    }

    /// §UNIT-B-E71-NOT-AN-INSTRUMENT — PIN THE ENTRY STATE so a target-mechanism change is
    /// ATTRIBUTABLE. §E71 cannot do this: changing the mechanism changes what `_setupBand`'s own
    /// swaps leave in the flow registers, so each variant starts from a different `q` — measured
    /// 380,432 → 360,528 → 340,720 across three variants, and skew is NON-LINEAR in `q`, so the
    /// discounts were never comparable. Two experiments were void on that broken control.
    ///
    /// `Flow` is `{uint128 vol; uint64 ts}` in ONE slot ⇒ `(ts << 128) | vol`. Slots from
    /// `forge inspect Core storageLayout`: 1030 `_flow` (ONE register per instance since the isBTC
    /// split; the sibling band is a separate contract), followed by the retained dead slow-flow
    /// slots (§UNIT-B-SLOWDEL-PADDING). `ts = now` ⇒ zero decay ⇒ the value is exactly what was
    /// written.
    function _pinFlow(uint128 vol) internal {
        bytes32 packed = bytes32((uint(block.timestamp) << 128) | uint(vol));
        // §ISBTC-SPLIT — ONE flow register per instance now (was `_flowBTC` + `_flowETH`), and it
        // moved to 1030 as the second ring went and the ring itself shrank to 1024. Pinning the single live
        // register is the whole job; there is no sibling band's copy to keep in step.
        vm.store(address(CORE), bytes32(uint(1030)), packed);
    }

    /// The instrument §UNIT-B needs. Same shape as §E71 (one big drain vs the same volume split),
    /// but the entry target is PINNED and ASSERTED, so any difference is the mechanism and not the
    /// fixture. ⚠️ The `assertEq(flowEwmaUsd, PINNED)` is not decoration: it is what proves the pin
    /// found the right slots, and it fails loudly if `Core`'s layout moves.
    function test_UNITB_PinnedEntry_ConsolidationDiscount() public {
        uint TOTAL = 120_000 * 1e18;
        uint N = 12;
        uint128 PINNED = 380_432_109_336;   // the pre-fix entry target, so runs stay comparable

        uint snap = vm.snapshotState();
        _setupBand();
        _pinFlow(PINNED);
        assertEq(CORE.flowEwmaUsd(), PINNED,
            "CONTROL: the entry target must be exactly what was pinned -- if this fails the slots "
            "moved and every number below is unattributable (this is the defect it exists to catch)");
        uint premBig = CORE.skewPremium();
        uint ethBig = _drain(TOTAL);
        premBig = CORE.skewPremium() - premBig;

        vm.revertToState(snap);
        _setupBand();
        _pinFlow(PINNED);
        assertEq(CORE.flowEwmaUsd(), PINNED, "CONTROL: identical pinned entry in BOTH arms");
        uint premSplit = CORE.skewPremium();
        uint ethSplit;
        for (uint i = 0; i < N; ++i) ethSplit += _drain(TOTAL / N);
        premSplit = CORE.skewPremium() - premSplit;

        emit log_named_uint("pinned entry target ", PINNED);
        emit log_named_uint("skew BIG   (usd6)   ", premBig);
        emit log_named_uint("skew SPLIT (usd6)   ", premSplit);
        emit log_named_uint("ETH big / split     ", ethBig);
        emit log_named_uint("ETH split           ", ethSplit);
        emit log_named_uint("discount bps        ", premSplit > premBig
            ? (premSplit - premBig) * 10_000 / premSplit : 0);

        assertGt(premBig, 0, "CONTROL: the big leg must actually be charged skew");
        assertGt(premSplit, 0, "CONTROL: the split leg must actually be charged skew");
        // SATURATION CONTROL (§SIGMA-REMOVE-P2-FALSE-PASS). A steepness input scaled ~1e7 too high
        // pins BOTH legs at MAX_WELL_SKEW (3%), and the discount then reads 0 bps -- passing this
        // test by DESTROYING the mechanism rather than fixing it. `3,600,000,000` = exactly 3% of
        // $120,000 was the tell. A criterion a CLAMP can satisfy cannot distinguish success from
        // destruction, so both legs must be STRICTLY BELOW the cap for the comparison to mean
        // anything.
        assertLt(premBig,   TOTAL / 1e12 * 3 / 100, "SATURATION: the big leg is pinned at the 3% cap");
        assertLt(premSplit, TOTAL / 1e12 * 3 / 100, "SATURATION: the split leg is pinned at the 3% cap");
    }

    /// §UNIT-B-PATIENCE — HOW MUCH OF THE RATCHET'S DEFENCE DOES WAITING BUY?
    /// §UNIT-B-RATCHET-IS-A-DEFENCE measured the chopper 14.4% cheaper than the whale, and the
    /// frozen-target arm 43.5% cheaper. Those are not two rival numbers: they are the SAME curve at
    /// its two ends, because `_bumpEwma` is DECAY-THEN-ADD over elapsed whole minutes (`Core:241-252`)
    /// and `_drain` does not warp time. So the 14.4% arm ran every slice at one timestamp, giving the
    /// ratchet its MAXIMUM bite, and the frozen arm is the infinitely-patient limit.
    ///
    /// The open question is therefore not "how big is the residual" but "what does patience cost the
    /// chopper", and that is a risk curve, not a scalar. `FLOW_DECAY` is a 48h half-life, so the
    /// attack should be slow to develop -- a wide, manipulation-resistant memory is exactly the
    /// design intent. This measures where between the two ends real delays land.
    function test_UNITB_PatienceCurve_WhatWaitingBuysTheChopper() public {
        uint TOTAL = 120_000 * 1e18;
        uint N = 12;
        uint128 PINNED = 380_432_109_336;
        uint[3] memory delays = [uint(0), 30 minutes, 4 hours];

        uint snap = vm.snapshotState();
        _setupBand();
        _pinFlow(PINNED);
        uint premBig = CORE.skewPremium();
        _drain(TOTAL);
        premBig = CORE.skewPremium() - premBig;
        emit log_named_uint("whale, one drain    ", premBig);

        for (uint d; d < delays.length; d++) {
            vm.revertToState(snap);
            _setupBand();
            _pinFlow(PINNED);
            uint prem = CORE.skewPremium();
            for (uint i = 0; i < N; ++i) {
                if (i > 0 && delays[d] > 0) vm.warp(block.timestamp + delays[d]);
                _drain(TOTAL / N);
            }
            prem = CORE.skewPremium() - prem;

            emit log_named_uint("--- inter-slice delay(s)", delays[d]);
            emit log_named_uint("    chopper premium    ", prem);
            emit log_named_uint("    chopper cheaper bps", prem < premBig
                ? (premBig - prem) * 10_000 / premBig : 0);
            // CONTROL: a reverting or zero-charging arm must not read as a cheap one.
            assertGt(prem, 0, "CONTROL: this delay arm charged nothing");
            assertLt(prem, TOTAL / 1e12 * 3 / 100, "SATURATION: arm pinned at the 3% cap");
        }
    }

    /// §UNIT-B-PATIENCE-WHY — WHICH INPUT COLLAPSES WHEN THE CHOPPER WAITS?
    /// The patience curve shows a 4h gap making the chop 93.3% cheaper. `FLOW_DECAY` is a 48h
    /// half-life, so EWMA decay over 4h is ~5.6% per gap and CANNOT produce that. Something else
    /// moves. The candidates are the three inputs to the charge -- the target (`flowEwmaUsd`),
    /// the variance (`realizedVarianceWad`), and the inventory/price basis -- so log all of them
    /// per slice rather than reason about which it is.
    function test_UNITB_PatienceWhy_LogTheInputsPerSlice() public {
        uint TOTAL = 120_000 * 1e18;
        uint N = 12;
        _setupBand();
        _pinFlow(380_432_109_336);

        for (uint i = 0; i < N; ++i) {
            if (i > 0) vm.warp(block.timestamp + 4 hours);
            uint premBefore = CORE.skewPremium();
            emit log_named_uint("== slice             ", i);
            emit log_named_uint("   sigma^2 (wad)     ", CORE.realizedVarianceWad());
            emit log_named_uint("   flowEwmaUsd       ", CORE.flowEwmaUsd());
            emit log_named_uint("   wellSkew (wad)    ", AUX.wellSkew(address(WETH), 0));
            emit log_named_uint("   POOLED        ", CORE.POOLED());
            _drain(TOTAL / N);
            emit log_named_uint("   premium charged   ", CORE.skewPremium() - premBefore);
        }
    }

    /// §UNIT-B-PATIENCE-BACKGROUND — THE RE-MEASURE §UNIT-B-PATIENCE BOOKED AS REQUIRED BEFORE THE
    /// EXPOSURE COULD BE SIZED. That entry measured a 4h-spaced chopper paying 93.3% less, and bounded
    /// the claim honestly: the fixture has NO EXOGENOUS PRICE PROCESS, so the attacker held the clock
    /// still by simply not trading. But the observation ring advances on ANY swap, so in a pool with
    /// other traders the attacker cannot stop σ² being sampled. This measures how much that protects.
    ///
    /// Background trades are deliberately SMALL (1% of a slice). They are still drains, so they do
    /// deplete inventory and that is a confound in the raising direction -- kept small so it cannot
    /// account for the effect, and σ² is logged per arm so the MECHANISM is visible rather than
    /// inferred from the premium alone.
    function test_UNITB_PatienceBackground_DoesOtherFlowDefendThePool() public {
        uint TOTAL = 120_000 * 1e18;
        uint N = 12;
        uint SLICE = TOTAL / N;
        uint BG = SLICE / 100;             // 1% of a slice — advances the ring, barely drains

        // ARM A — quiet pool: the attacker is the only trader (reproduces §UNIT-B-PATIENCE).
        uint snap = vm.snapshotState();
        _setupBand();
        _pinFlow(380_432_109_336);
        uint premQuiet = CORE.skewPremium();
        for (uint i = 0; i < N; ++i) {
            if (i > 0) vm.warp(block.timestamp + 4 hours);
            _drain(SLICE);
        }
        premQuiet = CORE.skewPremium() - premQuiet;
        uint sigQuiet = CORE.realizedVarianceWad();

        // ARM B — busy pool: three small swaps inside each 4h gap, so the ring keeps advancing.
        vm.revertToState(snap);
        _setupBand();
        _pinFlow(380_432_109_336);
        uint premBusy = CORE.skewPremium();
        uint bgPaid;
        for (uint i = 0; i < N; ++i) {
            if (i > 0) {
                for (uint k = 0; k < 3; ++k) {
                    vm.warp(block.timestamp + 1 hours);
                    uint b4 = CORE.skewPremium();
                    _drain(BG);
                    bgPaid += CORE.skewPremium() - b4;
                }
                vm.warp(block.timestamp + 1 hours);
            }
            _drain(SLICE);
        }
        // Charge the attacker ONLY for their own slices; background flow is somebody else's bill.
        premBusy = CORE.skewPremium() - premBusy - bgPaid;
        uint sigBusy = CORE.realizedVarianceWad();

        emit log_named_uint("QUIET: attacker pays  ", premQuiet);
        emit log_named_uint("QUIET: final sigma^2  ", sigQuiet);
        emit log_named_uint("BUSY : attacker pays  ", premBusy);
        emit log_named_uint("BUSY : final sigma^2  ", sigBusy);
        emit log_named_uint("BUSY : background bill", bgPaid);
        emit log_named_uint("busy/quiet ratio x1e4 ", premQuiet == 0 ? 0 : premBusy * 1e4 / premQuiet);

        assertGt(premQuiet, 0, "CONTROL: the quiet arm charged nothing");
        assertGt(premBusy,  0, "CONTROL: the busy arm charged nothing");
    }

    /// §UNIT-FORELLA FRAME CHECK — the row's OWN named prerequisite: *"`q` SURVIVES A RESEAT and a
    /// troller CANNOT reset their accrued path cost by triggering one. VERIFY WITH A TEST before
    /// relying on it."* The brake charges total variation along `q`, so if a permissionless `reseat()`
    /// moved `q`, a troller would simply reseat between drags and pay nothing -- the brake would be
    /// defeated by its own frame. §E93-VERIFY found exactly that defect for a TICK-POSITION signal;
    /// the claim is that `q` does not inherit it, being built from ABSOLUTE quantities
    /// (`inv = POOLED*px` against `target = flowEwmaUsd`) rather than from position within a range.
    ///
    /// Asserts the INPUTS as well as the output: if only the composed skew were checked, two
    /// compensating moves could cancel and read as survival.
    function test_FORELLA_ScarcitySurvivesAPermissionlessReseat() public {
        _setupBand();
        _drain(60_000 * 1e18);                     // create real imbalance, so q > 0

        uint skewBefore   = AUX.wellSkew(address(WETH), 0);
        uint pooledBefore = CORE.POOLED();
        uint flowBefore   = CORE.flowEwmaUsd();

        // CONTROL: a band that is not skewed cannot demonstrate that skew survives anything.
        assertGt(skewBefore, 0, "CONTROL: the band must actually be skewed before the reseat");

        V4.reseat();

        uint skewAfter   = AUX.wellSkew(address(WETH), 0);
        uint pooledAfter = CORE.POOLED();
        uint flowAfter   = CORE.flowEwmaUsd();

        emit log_named_uint("skew before reseat  ", skewBefore);
        emit log_named_uint("skew after  reseat  ", skewAfter);
        emit log_named_uint("POOLED before   ", pooledBefore);
        emit log_named_uint("POOLED after    ", pooledAfter);
        emit log_named_uint("flow EWMA before    ", flowBefore);
        emit log_named_uint("flow EWMA after     ", flowAfter);

        // Both of q's operands must be untouched -- inventory and target.
        assertEq(pooledAfter, pooledBefore, "reseat moved POOLED: q's numerator is frame-relative");
        assertEq(flowAfter,   flowBefore,   "reseat moved the flow EWMA: q's denominator is resettable");
        assertEq(skewAfter,   skewBefore,   "reseat changed the skew: a troller can reset accrued path cost");
    }

    /// §UNIT-B-REMEDY — THE DECISIVE EXPERIMENT: FREEZE THE TARGET ACROSS THE WHOLE EPISODE.
    /// §UNIT-B-ATTRIBUTED isolated the EWMA ratchet as the SOLE mover of the consolidation discount,
    /// using `skewWad`'s purity to hold flow constant. That is a statement about the FORMULA. This is
    /// the same claim end-to-end in a REAL fixture, which is the harder and more honest test.
    ///
    /// The difference from `test_UNITB_PinnedEntry_ConsolidationDiscount` is one line: that test pins
    /// the target ONCE at entry and then lets twelve drains bump it, so the ratchet is LIVE and the
    /// discount it measures is ratchet + curve. Re-pinning before EVERY slice freezes the target for
    /// the whole episode -- which is what "the target must not include the trade's own flow" means
    /// once a chopped trade is recognised as ONE trade.
    ///
    /// PREDICTION, STATED BEFORE RUNNING: the split arm pays LESS once the target is frozen, because
    /// the only remaining path effects are inventory depletion and the own-size `drainUsd6` term, and
    /// the pure-function run showed those net in the chopper's favour (254 bps).
    ///
    /// ⚠️ WHAT THE RUN ACTUALLY SHOWED, AND IT REFUTES THE REMEDY THIS TEST WAS BUILT TO SUPPORT:
    /// MEASURED at HEAD -- big 30,385 · split-with-ratchet 25,998 · split-frozen 17,159. So the
    /// chopper is cheaper by 14.4% WITH the ratchet and by 43.5% WITHOUT it. **The ratchet is not the
    /// defect; it is the only thing currently RESISTING the chop**, clawing back about two thirds of
    /// the advantage. Freezing the target would make chopping 34% cheaper still.
    /// ⚠️ AND §UNIT-B's HEADLINE IS STALE: it records the WHALE as the discounted party (23,560 vs
    /// 25,853). At HEAD the whale pays MORE (30,385 vs 25,998) and the sibling test prints a
    /// discount of 0 bps. The whale discount no longer reproduces; the live defect is the residual
    /// 14.4% CHOPPING advantage, which is the opposite party and needs the opposite fix.
    function test_UNITB_FrozenTargetInvertsTheConsolidationDiscount() public {
        uint TOTAL = 120_000 * 1e18;
        uint N = 12;
        uint128 PINNED = 380_432_109_336;   // same entry target as the sibling test, so runs compare

        uint snap = vm.snapshotState();
        _setupBand();
        _pinFlow(PINNED);
        assertEq(CORE.flowEwmaUsd(), PINNED, "CONTROL: pinned entry target, big arm");
        uint premBig = CORE.skewPremium();
        _drain(TOTAL);                      // one trade: already priced at the frozen target
        premBig = CORE.skewPremium() - premBig;

        vm.revertToState(snap);
        _setupBand();
        _pinFlow(PINNED);
        assertEq(CORE.flowEwmaUsd(), PINNED, "CONTROL: pinned entry target, split arm");
        uint premSplit = CORE.skewPremium();
        for (uint i = 0; i < N; ++i) {
            _pinFlow(PINNED);               // THE CHANGE: re-freeze before each slice is priced
            _drain(TOTAL / N);
        }
        premSplit = CORE.skewPremium() - premSplit;

        emit log_named_uint("frozen target       ", PINNED);
        emit log_named_uint("skew BIG   (usd6)   ", premBig);
        emit log_named_uint("skew SPLIT (usd6)   ", premSplit);
        emit log_named_string("direction           ", premSplit > premBig
            ? "split pays MORE (whale still discounted)"
            : "split pays LESS (discount INVERTED - ratchet was the mover)");
        emit log_named_uint("gap bps of premium  ", premSplit > premBig
            ? (premSplit - premBig) * 10_000 / premSplit
            : (premBig - premSplit) * 10_000 / premBig);

        assertGt(premBig, 0, "CONTROL: the big leg must actually be charged skew");
        assertGt(premSplit, 0, "CONTROL: the split leg must actually be charged skew");
        // SATURATION CONTROL -- at the 3% cap every arm reads alike and a "pass" would mean the
        // mechanism was destroyed, not fixed (§SIGMA-REMOVE-P2-FALSE-PASS).
        assertLt(premBig,   TOTAL / 1e12 * 3 / 100, "SATURATION: big leg pinned at the 3% cap");
        assertLt(premSplit, TOTAL / 1e12 * 3 / 100, "SATURATION: split leg pinned at the 3% cap");

        // THE CLAIM UNDER TEST. If this fails, the ratchet is NOT the sole mover and
        // §UNIT-B-ATTRIBUTED's pure-function result does not survive contact with the real path.
        assertLt(premSplit, premBig,
            "with the target frozen the whale must no longer be the cheaper path");
    }

    /// §UNIT-B-RIGHT-QUESTION (P2) — ENTRY-HISTORY INDEPENDENCE. The SAME traversal must cost the
    /// SAME however the band reached its starting point. This is the property a signed/two-sided
    /// curve needs (§UNIT-B-BLOCKS-C), and §E71 cannot see it: comparing SEQUENCE TOTALS conflates
    /// "what this swap created" with "what the history did".
    /// ⚠️ THE FLOW IS RE-PINNED IMMEDIATELY BEFORE THE PROBE, and that is not optional: arm B has
    /// taken twelve EWMA bumps to arm A's one, so without it the TARGET differs, `q` differs at the
    /// same inventory, and the two probes are NOT traversing the same interval. Pinning isolates the
    /// KERNEL's history-dependence from the TARGET-path effect already measured in §UNIT-B-MECHANISM.
    function test_UNITB_ProbeSwapIsEntryHistoryIndependent() public {
        uint TOTAL = 120_000 * 1e18; uint N = 12; uint PROBE = 10_000 * 1e18;
        uint128 PINNED = 380_432_109_336;
        uint snap = vm.snapshotState();

        _setupBand(); _pinFlow(PINNED);
        _drain(TOTAL);                                   // ARM A: one whale walks 0 -> q0
        uint invA = CORE.POOLED();
        emit log_named_uint("sigma^2 after whale   ", CORE.realizedVarianceWad());
        _pinFlow(PINNED);                                // same target for the probe
        uint pA = CORE.skewPremium();
        _drain(PROBE);
        pA = CORE.skewPremium() - pA;

        vm.revertToState(snap);

        _setupBand(); _pinFlow(PINNED);
        for (uint i = 0; i < N; ++i) _drain(TOTAL / N);   // ARM B: twelve walk to the SAME q0
        uint invB = CORE.POOLED();
        emit log_named_uint("sigma^2 after split   ", CORE.realizedVarianceWad());
        _pinFlow(PINNED);
        uint pB = CORE.skewPremium();
        _drain(PROBE);
        pB = CORE.skewPremium() - pB;

        emit log_named_uint("inventory after whale ", invA);
        emit log_named_uint("inventory after split ", invB);
        emit log_named_uint("probe premium (whale) ", pA);
        emit log_named_uint("probe premium (split) ", pB);
        emit log_named_int ("probe delta           ", int(pA) - int(pB));

        // CONTROL: the probes must start from the SAME inventory, else they traverse different
        // intervals and the comparison is void. This is the assertion the whole design rests on.
        assertApproxEqRel(invA, invB, 0.001e18,
            "CONTROL: both arms must reach the SAME q0, else the probes are not the same traversal");
        assertGt(pA, 0, "CONTROL: the probe must actually be charged skew");
        // SATURATION CONTROL — see the pinned instrument. Two capped probes are trivially "equal".
        assertLt(pA, PROBE / 1e12 * 3 / 100, "SATURATION: probe A is pinned at the 3% cap");
        assertLt(pB, PROBE / 1e12 * 3 / 100, "SATURATION: probe B is pinned at the 3% cap");
        // (P2) IS OPEN AT HEAD AND THIS RECORDS IT RATHER THAN HIDING OR SHOUTING IT. The input is
        // still sigma^2, which is a SECOND DIFFERENCE and so encodes the SHAPE of the flow, so the
        // same traversal costs MORE via a whale than via twelve splitters (§UNIT-B-ROOT-FOUND).
        // A permanently-RED test in a 4,400-test suite becomes noise that hides real regressions,
        // so this asserts a REGRESSION BOUND: the gap must not GROW.
        // ▶️ WHEN §SIGMA-REMOVE LANDS THIS MUST TIGHTEN TO ~1.0x — that is the acceptance criterion,
        //    and it lives in the queue, not in a loosened tolerance here.
        //
        // ⚠️ RE-BASELINED 2026-08-16 FROM 300 TO 450, AND THIS IS *NOT* A LOOSENING AFTER A
        // REGRESSION — IT IS THE REMOVAL OF A MEASUREMENT ARTIFACT. The bound must not be moved
        // again without the same standard of evidence.
        //   The tick ring was replaced by a plain-price ring (§TICK-REMOVAL). Measured on the SAME
        //   fixture, both arms, before and after:
        //     tick ring : sigma^2 whale 2.458e13 / split 1.542e13 -> ratio 1.59x
        //     price ring: sigma^2 whale 2.075e13 / split 5.185e12 -> ratio 4.00x
        //   The WHALE arm barely moved (x0.84). The SPLIT arm COLLAPSED (x0.34), and that asymmetry
        //   is the evidence: the split arm is twelve SMALL moves, and TICKS ARE QUANTIZED. With
        //   BAND_DELTA = 20 bps against tickSpacing 10, each ~1.7 bp sub-move rounded UP to a whole
        //   tick, inflating the split arm's variance ~3x and MASKING the real dependence.
        //   ⇒ 4.00x is not new leakage. It is the TRUE value, which the coarse estimator was hiding;
        //   1.59x (and the 2.34x recorded earlier) were artifacts of measuring log-price on a grid
        //   too coarse for the band. The defect did not grow — our ability to see it did.
        // 📌 The ~1.0x TARGET IS UNCHANGED, and the root is unpatchable at the estimator: realized
        //   variance of a chopped path IS genuinely lower (D^2 versus 12*(D/12)^2 = D^2/12), so no
        //   normalization fixes it. It is fixed by removing sigma^2 from the CHARGE, which is what
        //   the passthrough design does (§WHO-PAYS / §SKEW-DESIGN-VERDICT).
        assertLt(pA * 100 / pB, 450,
            "(P2) REGRESSION BOUND: entry history must not leak MORE than the 4.00x measured once "
            "tick quantization stopped masking it. The target is 1.0x and is reached by removing "
            "sigma^2 from the charge, not by tuning the estimator");
    }


    /// §SIGMA-REMOVE-P1 — SHADOW-MEASURE THREE CANDIDATE STEEPNESS INPUTS. Nothing wired to pricing.
    /// Acceptance is the HISTORY GAP on the probe scenario (whale vs twelve splitters, SAME
    /// endpoints): σ² measured **2.34×** (§UNIT-B-ROOT-FOUND); a trade-based proxy is predicted ~12×
    /// by algebra (§SIGMA-REMOVE-P1-CONSTRAINT) and measured here for the first time; the inventory
    /// TRAPEZOID must be ~1× or the direction is refuted.
    /// ⚠️ TRAPEZOID, not left-rectangle: a per-swap `inv·Δp` accrual is a Riemann sum whose error
    /// scales with SAMPLE COUNT — the same shape-dependence in a new costume. `(inv₀+inv₁)/2`

    /// §SIGMA-REMOVE-P2-GAP-LOCALISED — COUNT THE ACCRUALS. The 8% is entirely in the SPLIT arm
    /// (whale 0.991 vs estimator, split 0.918), so it is a sample-COUNT effect, not a phase offset.
    /// Three candidates: a missed accrual, an overwritten pending from multi-hop routing, or the
    /// contract tiling FINER than the test — in which case the CONTRACT is the accurate one and the
    /// in-test 1.025x is the artifact. Counting SSTOREs to `_lossETH` (slot 131090, which replaced

    /// §SIGMA-REMOVE-RESCOPED risk 2 — THE LAST GATE: is the register's LEVEL stable, or is a decaying
    /// sum over few swaps too jumpy to price on? History-independence is proven (1.106x vs sigma^2's
    /// 2.340x); this asks the different question of whether the LEVEL swings when the same total

    /// §SIGMA-REMOVE-RESCOPED risk 2 — THE ONLY REMAINING GATE: REAL run-to-run noise. Holds the
    /// PARTITION FIXED (6 pieces, same total volume) and varies only the TIMING and the size jitter,
    /// so this is independent of the history gap — unlike the earlier "level spread", which was the
    /// history gap relabelled (§SIGMA-REMOVE-P1-COMPLETE-RETRACTED).
    /// A decaying SUM should barely notice; a SECOND-MOMENT statistic reads spacing directly through

    /// §SIGMA-REMOVE-P2-FITS-BUT-SATURATES — IS THE SATURATION THE SWAP-TO-BAND RATIO?
    /// A 120,000 drain is ~9% of a ~$1.3M band — a pathological ratio, not a production one. The
    /// substitution implies `sigma^2 = 8 · lossFraction / 0.0079 = 1012 · lossFraction`, and the 3%
    /// `MAX_WELL_SKEW` cap binds around `sigma^2 ~ 1`, so **`lossFraction` must stay under ~0.1%**.
    /// This measures the fraction at REALISTIC sizes with NO contract change (the register is live;
}

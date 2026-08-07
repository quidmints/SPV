// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {SwapLib} from "../src/imports/SwapLib.sol";

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
        V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();
        // Pre-drain into the SCARCE region so both legs start from an identical, premium-charging
        // state. Starting flush would put both at zero premium and measure nothing.
        for (uint i = 0; i < 20; ++i) {
            _drain(20_000 * 1e18);
            if (CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30
                < CORE.flowEwmaUsd(false)) break;
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

        uint atZero = SwapLib.skewWad(inv, T, 0, false, drain);
        uint atOne  = SwapLib.skewWad(inv, T, 1, false, drain);
        uint atTiny = SwapLib.skewWad(inv, T, 1e13, false, drain);   // ≈ the live fixture's σ²
        uint atReal = SwapLib.skewWad(inv, T, 1e16, false, drain);   // a plausible real variance

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
            uint base = SwapLib.skewWad(T - T / 1000, T, sigs[s], true, 0);  // q->0: the floor
            uint lo = 1; uint hi = 999;
            while (lo < hi) {                       // first q (thousandths) where kernel clears the floor
                uint mid = (lo + hi) / 2;
                if (SwapLib.skewWad(T - (T * mid) / 1000, T, sigs[s], true, 0) > base + base / 50) hi = mid;
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
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();
        uint ethAlone = AUX.wellSkew(address(WETH));

        // Populate the BTC band so the SHARED-scarcity amplifier can exceed 1 for BOTH assets.
        AUX.setBTCChannels(address(this));   // auth: registerBtcLp is gated (403 without this)
        BTC.registerBtcLp(User01, 2e7);
        _settle();

        uint ethBoth = AUX.wellSkew(address(WETH));
        uint btcLive = AUX.wellSkew(address(WBTC));
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
        uint invBtc = CORE.POOLED_BTC() * pB / 1e30;
        uint tgtBtc = CORE.flowEwmaUsd(true);
        uint sigBtc = CORE.realizedVarianceWad(true);
        btcLive     = AUX.wellSkew(address(WBTC));
        uint raw    = SwapLib.skewWad(invBtc, tgtBtc, sigBtc, true, 0);   // UNAMPLIFIED kernel+base
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
            uint iv = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
            if (iv < CORE.flowEwmaUsd(false)) break;
        }
        {
            uint pE      = AUX.getTWAPforAsset(address(WETH), 1800);
            uint invEth  = CORE.POOLED_ETH() * pE / 1e30;
            uint rawEth  = SwapLib.skewWad(invEth, CORE.flowEwmaUsd(false),
                                           CORE.realizedVarianceWad(false), false, 0);
            uint liveEth = AUX.wellSkew(address(WETH));
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
    function test_E100_DoesAnLpAddBumpTheFlowTimestamp() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 200 ether}(0, lpA, 3);
        _settle();
        for (uint i = 0; i < 6; ++i) _drain(20_000 * 1e18);   // give flow a non-zero history

        uint invBefore   = CORE.POOLED_ETH();
        uint repackBefore = V4.LAST_REPACK();
        uint flowBefore  = CORE.flowEwmaUsd(false);
        vm.warp(block.timestamp + 3 days);                    // let the clock move, no trading
        uint flowMid = CORE.flowEwmaUsd(false);               // decayed, proving time passed

        // THE LP ACTION under test -- moves POOLED_* with no swap.
        vm.prank(lpA); V4.deposit{value: 50 ether}(0, lpA, 3);
        vm.roll(block.number + 1);

        uint invAfter    = CORE.POOLED_ETH();
        uint repackAfter = V4.LAST_REPACK();
        emit log_named_uint("POOLED_ETH before / after", invBefore);
        emit log_named_uint("                         ", invAfter);
        emit log_named_uint("flow (decayed, pre-add)  ", flowMid);
        emit log_named_uint("flow (post-add)          ", CORE.flowEwmaUsd(false));
        emit log_named_uint("LAST_REPACK before       ", repackBefore);
        emit log_named_uint("LAST_REPACK after        ", repackAfter);

        assertGt(invAfter, invBefore, "PREMISE: the LP add must actually move POOLED_ETH");
        if (repackAfter > repackBefore) {
            emit log("LAST_REPACK DID bump on the LP add -- the E93-HOLE-CLOSED fix is LOAD-BEARING.");
        } else {
            emit log("LAST_REPACK did NOT bump -- the fix does NOT cover LP adds. HOLE STILL OPEN.");
        }
        if (CORE.flowEwmaUsd(false) > flowMid) {
            emit log("flow ALSO moved on the LP add -- then the hole never existed and the fix is dead code.");
        } else {
            emit log("flow did NOT move on the LP add -- the hole was REAL, as claimed.");
        }
    }

    function test_E99_DoesTheSkewSeePersistence() public {
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();
        for (uint i = 0; i < 20; ++i) {
            _drain(20_000 * 1e18);
            if (CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30
                < CORE.flowEwmaUsd(false)) break;
        }
        uint invFresh  = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint skewFresh = AUX.wellSkew(address(WETH));
        uint flowFresh = CORE.flowEwmaUsd(false);

        // 30 DAYS pass. No swap, no LP action -- inventory is UNCHANGED by construction.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);
        uint invAged  = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint skewAged = AUX.wellSkew(address(WETH));
        uint flowAged = CORE.flowEwmaUsd(false);

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
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();
        uint refOut = _sell(SMALL);
        vm.revertToState(snap);

        // Now push the band ABUNDANT with someone else's sells, then send the SAME small ticket.
        _seedBasket();
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
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
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();

        // Many TINY drains: enough to build a flow EWMA, each too small to be expected to move a tick.
        for (uint i = 0; i < 25; ++i) _drain(50 * 1e18);
        uint flow = CORE.flowEwmaUsd(false);
        uint sig  = CORE.realizedVarianceWad(false);
        uint inv  = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
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
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();

        // FRESH band: `OracleLib.initPool` sets `cardinality = 1`, so the ring is UNPOPULATED by the
        // `>= 2` test. Variance here must read 0 = "we have not measured", and the skew must charge
        // the conservative ceiling — that is E59's intent and it must survive E88-r.
        uint vFresh = CORE.realizedVarianceWad(false);
        emit log_named_uint("variance, FRESH ring (expect 0 = unmeasured)", vFresh);
        emit log_named_uint("wellSkew, FRESH ring                        ", AUX.wellSkew(address(WETH)));

        // Now trade so the ring populates and real price movement enters it.
        for (uint i = 0; i < 8; ++i) _drain(20_000 * 1e18);
        uint vTraded = CORE.realizedVarianceWad(false);
        emit log_named_uint("variance, TRADED ring                       ", vTraded);
        emit log_named_uint("wellSkew, TRADED ring                       ", AUX.wellSkew(address(WETH)));

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

    function test_E96b_TaxScalesWithImbalanceDepth() public {
        uint SMALL = 5_000 * 1e18;
        uint8[4] memory rounds = [0, 6, 12, 20];   // 0 = balanced reference
        uint refEth;
        uint refInv;
        for (uint r = 0; r < 4; ++r) {
            uint snap = vm.snapshotState();
            _seedBasket();
            vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
            _settle();
            for (uint i = 0; i < rounds[r]; ++i) _drain(20_000 * 1e18);
            uint inv = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
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
        vm.prank(lpA); V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();
        uint invBal = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint ethBalanced = _drain(SMALL);
        vm.revertToState(snap);

        // LEG B — the SAME small swap into a band someone ELSE has already drained.
        _setupBand();
        uint invSkewed = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
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
        uint invA = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint ethA = _drain(TOTAL);
        vm.revertToState(snap);

        _setupBand();
        uint invB = CORE.POOLED_ETH() * AUX.getTWAPforAsset(address(WETH), 1800) / 1e30;
        uint ethB;
        for (uint i = 0; i < N; ++i) ethB += _drain(TOTAL / N);

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
}

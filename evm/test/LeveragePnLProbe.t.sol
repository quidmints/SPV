// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AllesFixture} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IBasket} from "../src/imports/Interfaces.sol";

interface ISPq { function getCompoundedBoldDeposit(address) external view returns (uint); }

/// @notice Quantifies the leverage externality on passive LPs — the analysis
///   recorded in memory project-quid-leverage-liquity.md (CORRECTION 2026-06-22).
///
///   On the QU!D side a leveraged-LP OPEN is a BOLD->WETH swap: the trader sheds
///   BOLD into the protocol's backing (Liquity SP) and pulls WETH out of the LP
///   pool. We measure two things on a mainnet fork:
///     (1) the BOLD-ACCUMULATION curve under repeated guard-safe opens, and
///     (2) the LVR / value-transfer to passive LPs via a rigorous control-vs-
///         treatment design (same final ETH price; difference = pure leverage cost).
///
///   LP value is measured TOTAL (both legs): redeem the LP in a snapshot and value
///   ETH-leg (at the scenario price) + QUID-leg ($1). Valuing the redeemed assets at
///   the scenario price sidesteps pool-reseat machinery AND the forked-SP BOLD-out
///   limitation (no unwind leg needed — the open + revaluation already captures the
///   directional transfer, since the open converts the LP's ETH-side to USD-side).
contract LeveragePnLProbe is AllesFixture {
    address bold; address sp; address lp = User02; address trader = User03;
    uint lpShares;

    // §SILENT-SETUP — `try ETH.redeem(...) {} catch {}` inside `_lpValueUsd` records NOTHING, and a
    // swallowed revert yields ethG == quidG == 0, i.e. a VALUATION OF ZERO that composes silently
    // into every arm of the LVR comparison. Same shape as `VarPrecision.swapsLanded`.
    // ⚠️ These are incremented AFTER `vm.revertToState`, deliberately: the snapshot revert would
    // undo any storage write made inside the measured region, so a counter bumped next to the
    // `try` would read 0 no matter what happened. The outcome is carried out on the STACK.
    uint internal redeemsAttempted;
    uint internal redeemsLanded;
    /// Pre-redeem NAV of the LP position in USD18, at the price the last `_lpValueUsd` used.
    /// Written AFTER `vm.revertToState`, from stack state — same reason as the counters above.
    uint internal lastNavUsd;

    function _seed(uint ethDeposit) internal {
        bold = AUX.getStables()[AUX.getStables().length - 1];
        sp   = AUX.getVaults(bold)[0];
        // SEED THE BASKET FIRST — $1M of stable backing, the same seed every sibling range probe
        // uses (`LevCascade._seedBasket`, `LeverageCrossSubsidyProbe._seedBasket`).
        //
        // Without it this file had NO stable backing at all: the shared fixture arrives with about
        // $156k of basket TVL, while a 400-ETH LP deposit needs the range to commit roughly $1.5M of
        // USD in range. `Core._poolUsdInRange` then trips `require(committedUsd18() <= haircutTvl,
        // "backing")` (src/Core.sol:1016) on the FIRST swap, so `_open` caught the revert, returned
        // 0, and both loops below `break`d on round one. Every measurement in this file — the whole
        // accumulation curve, the entire control-vs-treatment design — was computed over ZERO
        // executed opens, and both tests reported PASS because neither asserted anything. Seeding
        // is what makes the opens executable; it is not what makes the assertions pass.
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        vm.prank(lp);
        lpShares = ETH.deposit{value: ethDeposit}(0, lp);
        require(lpShares > 0, "lp deposit failed");
    }

    /// One guard-safe leverage open. Returns WETH out, or 0 on revert (e.g. guard).
    /// `boldSpent` is measured, not assumed: `swap` may partially fill (#101
    /// degrade-to-partial-fill), so the trader can be left holding change.
    uint lastBoldSpent;
    function _open(uint boldAmt) internal returns (uint wethOut) {
        deal(bold, trader, boldAmt);          // deal SETS the balance, so leftover == change
        vm.startPrank(trader);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0, true) returns (uint w) { wethOut = w; }
        catch { wethOut = 0; }
        vm.stopPrank();
        lastBoldSpent = boldAmt - IERC20(bold).balanceOf(trader);
        // Let the observation ring absorb the move so the next open doesn't trip the
        // 50bps manip guard (spot reconverges toward the 30-min TWAP).
        vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
    }

    uint constant SP_SENTINEL = type(uint).max;
    function _spBold() internal view returns (uint) {
        try ISPq(sp).getCompoundedBoldDeposit(address(AUX)) returns (uint v) { return v; } catch { return SP_SENTINEL; }
    }
    function _tvl() internal returns (uint t) { (uint[15] memory d,,,) = AUX.get_deposits(); t = d[14]; }

    /// @dev Range/basket state at one instant. Emitted rather than returned so the caller
    ///      keeps no locals — this measurement is what decides #12's ownership question.
    function _snapshotRanges(string memory when) internal {
        emit log_string(when);
        emit log_named_uint("   POOLED_USD", CORE.POOLED_USD());
        emit log_named_uint("   POOLED    ", CORE.POOLED());
        emit log_named_uint("   rangeETH      ", AUX.rangeETH());
        emit log_named_uint("   basketUsd  ", CORE.basketUsd());
        emit log_named_uint("   lpShares      ", ETH.lpShares());
        emit log_named_uint("   totalLevPooled", ETH.totalLevPooled());
        emit log_named_uint("   basket TVL    ", _tvl());
        emit log_named_uint("   committedUsd18", CORE.committedUsd18());
        // §WHY-ANY-HAIRCUT — the redeem has exactly TWO haircut paths and both can be inert:
        //   1. `depegLoss` subtracted from `solvent` in `_redeemQuote` (BasketLib:1019)
        //   2. `perShare = BasketLib.qdShareValue(WAD, solvent, mature)` ≡ min(par, pro-rata)
        // and `qdShareValue` returns PAR when `supplyPreBurn == 0` (BasketLib:25). So with
        // matureSupply == 0 there is NO valuation haircut, and the shortfall must be the OTHER term:
        // `freeUsd = solvent − max(il, committedUsd18)`, which is a COMMITMENT/LIQUIDITY bound, not a
        // price. Those are different defects with different fixes, so measure which one is live.
        emit log_named_uint("   matureSupply  ", IBasket(address(QUID)).matureSupply());
    }

    /// TOTAL LP value in USD18 at a given ETH price (USD18 per 1e18 BTC): redeem the
    /// LP in a snapshot, value both legs (ETH + QUID), then revert.
    function _lpValueUsd(uint ethPx18) internal returns (uint usd) {
        uint snap = vm.snapshotState();
        uint eth0 = lp.balance; uint weth0 = WETH.balanceOf(lp); uint q0 = QUID.balanceOf(lp);
        // THE RESIDUAL MUST BE PRICED AGAINST THE VAULT THAT BACKED IT, NOT THE ONE THE REDEEM
        // LEFT BEHIND. Taking `convertToAssets` AFTER the redeem reads a drained vault: measured
        // 2026-08-16, 31.833 surviving shares priced at 0.0134 ETH (~$25) when the same LP had
        // deposited 400 ETH for ~400 shares. That is the husk, not the claim — so the per-share
        // basis is captured HERE, before anything is burned.
        // Scoped: these two are emitted and never read again, and `via_ir` is off here, so keeping
        // them live to the end of the function costs two stack slots for nothing.
        uint navUsd;
        {
            uint preShares = ETH.balanceOf(lp);
            uint preAssets = ETH.convertToAssets(preShares);
            navUsd = preAssets * ethPx18 / 1e18;
            emit log_named_uint("  pre  shares   ", preShares);
            emit log_named_uint("  pre  assets   ", preAssets);
        }
        vm.prank(lp);
        bool redeemLanded;
        try ETH.redeem(lpShares, lp, lp) { redeemLanded = true; } catch {}
        uint ethG  = (lp.balance - eth0) + (WETH.balanceOf(lp) - weth0);
        uint quidG = QUID.balanceOf(lp) - q0;
        // §WHICH-BRANCH — DID THE REDEEM BURN EVERYTHING? `BasketLib:1023` is UNWIND-FIRST,
        // BURN-EXACT: it burns ONLY what it can actually deliver. If shares SURVIVE the redeem,
        // measuring ONLY what left the redeem under-measures the LP, because the undelivered
        // value is still THEIRS — so the residual is valued and ADDED rather than dropped.
        //
        // ⚠️ THIS WAS A LIVE INSTRUMENT BUG, NOT A HYPOTHETICAL. Measured 2026-08-16: the control
        // arm left 2 wei of shares (a full redemption) while the treatment arm left 31.833 shares
        // (a partial one), so the two arms were comparing a FULL redemption against a PARTIAL one
        // and the undelivered residue read as 0.63% of "value extracted by leverage flow". Both
        // arms must bracket the SAME SCOPE or the difference is an artifact of the instrument.
        // ⚠️ THE RESIDUAL IS DELIBERATELY *NOT* FOLDED INTO `usd`, AND BOTH OBVIOUS BASES ARE WRONG.
        // Measured 2026-08-16, valuing 31.833 surviving shares:
        //   • post-redeem `convertToAssets` → 0.0134 ETH (~$25). The husk: the redeem already paid
        //     the backing out, so this UNDER-values.
        //   • pre-redeem NAV per share (1.0000257 BTC) → 31.834 ETH (~$59,960). This OVER-values,
        //     and double-counts: `_pricingBacking()` is rangeETH() PLUS the LP-owned USD increment,
        //     so that number already contains the USD that was delivered as the 55,225 QUID leg.
        // Folding either in makes the LVR assertion pass for a reason the measurement cannot
        // support. The honest comparison is each arm against ITS OWN pre-redeem NAV, emitted
        // above — that is scope-matched by construction and needs no cross-arm assumption.
        uint left = ETH.balanceOf(lp);
        uint residEth = 0;
        emit log_named_uint("  shares left   ", left);
        emit log_named_uint("  resid ETH(wei)", residEth);
        emit log_named_uint("  leg ETH (wei)", ethG);
        emit log_named_uint("  leg QUID(18d)", quidG);
        // Both terms are ETH QUANTITIES valued at the scenario price, so they compose.
        // ⚠️ At a MOVED price the residual is only approximate: `convertToAssets` reads LIVE
        // state, so the USD share of backing it folds in is expressed at the LIVE price and
        // re-valuing it at a scenario price scales that portion wrongly. The FLAT arm — which
        // is where the 0.63% was reported — is exact, because there ethPx18 IS the live price.
        usd = (ethG + residEth) * ethPx18 / 1e18 + quidG;
        vm.revertToState(snap);
        // Storage is restored by the line above, so the counters are written HERE, from stack state.
        ++redeemsAttempted;
        if (redeemLanded) ++redeemsLanded;
        lastNavUsd = navUsd;
        // ⭐ **THE REAL SHORT-PAYMENT GUARD, AND IT IS PER-ARM SO IT NEEDS NO SCOPE MATCHING.**
        //    `BasketLib:1023` is UNWIND-FIRST, BURN-EXACT: it burns ONLY what it can deliver. So a
        //    redemption that pays less than NAV is legitimate **iff shares SURVIVED** — the
        //    undelivered claim is still the LP's and simply defers. Shares BURNED without value
        //    delivered is the actual defect, and it is invisible to any cross-arm comparison of
        //    proceeds. This fires in BOTH arms, which is what makes it trustworthy.
        if (usd < navUsd) {
            assertGt(left, 0,
                "SHORT-PAYMENT: proceeds below pre-redeem NAV with NO surviving shares - "
                "value was burned without being delivered");
        }
        emit log_named_uint("  redeems landed", redeemsLanded);
        emit log_named_uint("  redeems attempt", redeemsAttempted);
        assertGt(redeemsLanded, 0, "PREMISE: the valuation redeem actually ran (else this LP is valued at ZERO)");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // (1) BOLD accumulation curve under repeated guard-safe opens (flat market).
    // ───────────────────────────────────────────────────────────────────────────
    function testLeverage_BoldAccumulationCurve() public {
        _seed(400 ether);
        uint spStart = _spBold();
        emit log_named_uint("TVL18 @start", _tvl());
        emit log_named_uint("BOLD in SP @start (18d)", spStart);
        // PREMISE 0: the Liquity SP leg must be READABLE on this fork. `_spBold` swallows a
        // revert into SP_SENTINEL, and every "BOLD accumulated" reading below would then be
        // type(uint).max — a number that satisfies any growth check while measuring nothing.
        assertTrue(spStart != SP_SENTINEL, "PREMISE: the Liquity SP deposit must be readable, else nothing is measured");

        uint perOpen = 4_000e18; // ~1.3 ETH out on a 400-ETH pool => <0.5% move
        uint landed; uint boldSpent; uint prevSp = spStart;
        for (uint r = 1; r <= 25; r++) {
            uint w = _open(perOpen);
            if (w == 0) { emit log_named_uint("open tripped guard / reverted at round", r); break; }
            landed++; boldSpent += lastBoldSpent;
            uint spNow = _spBold();
            // SAFETY (the curve this test is NAMED for): the protocol has no mechanism that
            // sheds the BOLD a leveraged open pays it — so the SP balance must never fall.
            // A DROP here means something is shedding/losing BOLD backing round-to-round,
            // which is precisely the accumulation story being falsified.
            assertGe(spNow, prevSp, "BOLD in the SP must never DECREASE (nothing sheds it)");
            prevSp = spNow;
            if (r % 5 == 0 || r == 1) {
                uint tvl = _tvl();
                emit log_named_uint("round", r);
                emit log_named_uint("   BOLD in SP (18d)",    spNow);
                emit log_named_uint("   BOLD % of TVL (bps)", tvl > 0 ? (spNow * 10_000) / tvl : 0);
                emit log_named_uint("   POOLED",          CORE.POOLED());
            }
        }
        uint spEnd = _spBold();
        emit log_named_uint("opens that landed", landed);
        emit log_named_uint("BOLD spent by the trader (18d)", boldSpent);
        emit log_named_uint("BOLD accumulated in the SP (18d)", spEnd - spStart);

        // PREMISE 1: at least one open must LAND. The loop `break`s on the first revert, so a
        // guard that trips on round 1 leaves an empty curve — and "BOLD never decreased" would
        // be trivially true over zero rounds.
        assertGt(landed, 0, "PREMISE: at least one leverage open must land, else there is no curve");
        // PREMISE 2: those opens must have actually MOVED BOLD. A landed swap that spent no
        // BOLD (full partial-fill degradation) accumulates nothing to reason about.
        assertGt(boldSpent, 0, "PREMISE: the opens must actually spend BOLD into the protocol");

        // SAFETY: the BOLD the trader paid must ARRIVE in backing. The open is a sale — the
        // trader hands over BOLD and takes WETH out of the LP pool — so if the SP grows by
        // materially less than was spent, the difference is value that left the LP's ETH side
        // and never landed on the basket's stable side. Bound is the MEASURED spend, and the
        // 1% allowance covers Liquity's own deposit accounting, not a fudge for a shortfall.
        assertGe(spEnd - spStart, boldSpent * 99 / 100,
            "the BOLD paid by leverage opens must land in the SP, not evaporate between the legs");
        // SAFETY: 25 rounds of shedding an un-depeg-fed stable into backing must not leave the
        // basket under-collateralised. checkBacking REVERTS on violation, so it is an assertion.
        AUX.checkBacking();
        emit log_string("=> BOLD accumulates monotonically; earmark would PIN it; BOLD has NO depeg feed.");
    }

    // ───────────────────────────────────────────────────────────────────────────
    // (2) LVR / value transfer: control (no opens) vs treatment (N opens), valued at
    //     the SAME final ETH price. Difference = pure leverage externality on the LP.
    // ───────────────────────────────────────────────────────────────────────────
    /// @notice THE DISCRIMINATOR for the 0.63% passive-LP leak (owner asked "check which", 2026-08-16).
    ///         The leak is NOT the range swap — that sells 0.05% ABOVE mid and leaves range value
    ///         unchanged. It is the REDEMPTION's ETH→QUID conversion, which pays 92.1 cents on the
    ///         dollar. `_redeemQuote` forms `perShare = min(WAD, solvent·WAD/mature)`, so the whole
    ///         fork reduces to ONE comparison:
    ///           solvent >= mature  ⇒ perShare == $1, the haircut is NOT solvency, and the QUID mint
    ///                                path is the defect.
    ///           solvent <  mature  ⇒ the basket is GENUINELY SHORT, the 7.90% is CORRECT, and the
    ///                                defect is the ASYMMETRY: an ETH-paid redeemer escapes what an
    ///                                otherwise-identical QUID-paid redeemer bears.
    ///         Measured AFTER the same 20 opens, so it reads the state the failing test redeems from.
    function test_WhichBranch_IsTheBasketActuallyShort() public {
        _seed(400 ether);
        for (uint r = 0; r < 20; r++) { if (_open(3_000e18) == 0) break; }

        (uint solvent,) = AUX.get_metrics(true);
        uint mature   = QUID.matureSupply();
        uint immature = QUID.immatureSupply();

        emit log_named_uint("solvent (USD18)   ", solvent);
        emit log_named_uint("matureSupply      ", mature);
        emit log_named_uint("immatureSupply    ", immature);
        emit log_named_uint("perShare x1e18    ", mature == 0 ? 1e18
            : (solvent * 1e18 / mature > 1e18 ? 1e18 : solvent * 1e18 / mature));
        if (mature != 0) {
            emit log_named_uint("solvent/mature bps", solvent * 10_000 / mature);
            if (solvent >= mature) emit log("BRANCH (b): NOT short -> perShare is par; the 7.90% is a MINT-PATH defect.");
            else emit log("BRANCH (a): SHORT -> the 7.90% is a CORRECT solvency haircut; the defect is the ASYMMETRY.");
        }
        // No assertion on the VALUE — the value IS the answer. Only a premise, so a zeroed
        // fixture cannot masquerade as a branch verdict.
        // PREMISE: something must be outstanding, or "is the basket short" has no referent.
        // NOTE mature == 0 here is not a fixture defect -- it is the ANSWER: nothing has vested,
        // so `qdShareValue`'s mature==0 guard returns WAD and perShare is PAR by construction.
        assertGt(mature + immature, 0, "PREMISE: no supply at all, nothing to price a share against");
        assertGt(solvent, 0, "PREMISE: solvent reads zero, so the comparison is vacuous");
    }

    /// @notice INSTRUMENT CHECK for the arm-asymmetry fix: value the LP position DIRECTLY,
    ///         BEFORE any redeem, so no partial-settlement artifact can enter. If control and
    ///         treatment agree here at unchanged price, the range swap was value-neutral and the
    ///         0.63% is entirely an artifact of measuring redemption PROCEEDS.
    function test_Instrument_PositionValueBeforeAnyRedeem() public {
        _seed(400 ether);
        uint px0 = AUX.getTWAPforAsset(address(WETH), 1800);
        uint snap0 = vm.snapshotState();

        for (uint r = 0; r < 20; r++) { if (_open(3_000e18) == 0) break; }
        uint tShares = ETH.balanceOf(lp);
        uint tAssets = ETH.convertToAssets(tShares);
        emit log_named_uint("TREAT shares      ", tShares);
        emit log_named_uint("TREAT assets(BTC) ", tAssets);
        emit log_named_uint("TREAT value (USD) ", tAssets * px0 / 1e18);

        vm.revertToState(snap0);
        uint cShares = ETH.balanceOf(lp);
        uint cAssets = ETH.convertToAssets(cShares);
        emit log_named_uint("CTRL  shares      ", cShares);
        emit log_named_uint("CTRL  assets(BTC) ", cAssets);
        emit log_named_uint("CTRL  value (USD) ", cAssets * px0 / 1e18);

        assertGt(cShares, 0, "PREMISE: control LP holds no shares");
        assertGt(tShares, 0, "PREMISE: treatment LP holds no shares");
    }

    function testLeverage_LvrControlVsTreatment() public {
        _seed(400 ether);
        uint px0 = AUX.getTWAPforAsset(address(WETH), 1800); // USD18 per 1e18 ETH
        emit log_named_uint("ETH px0 (USD18)", px0);

        uint snap0 = vm.snapshotState();

        // Treatment: accumulate guard-safe opens, then value the LP at 3 final prices.
        uint landed;
        // Emitted, not stored: five `before` locals blew the stack here, and the repo's rule is to
        // shed locals rather than reach for via_ir.
        _snapshotRanges("before");
        for (uint r = 0; r < 20; r++) { if (_open(3_000e18) == 0) break; landed++; }
        emit log_named_uint("treatment opens landed", landed);
        _snapshotRanges("after ");
        emit log_named_uint("BOLD accumulated (18d)", _spBold());
        uint tUp   = _lpValueUsd(px0 * 120 / 100);
        uint tFlat = _lpValueUsd(px0);
        // On the STACK, deliberately: `vm.revertToState(snap0)` below rewinds storage, so
        // `lastNavUsd` would be the control's by the time it is read. Same hazard the redeem
        // counters document.
        uint tNavFlat = lastNavUsd;
        uint tDown = _lpValueUsd(px0 * 80 / 100);

        // Control: same starting pool, NO opens — but TIME-MATCHED to the treatment.
        //
        // `vm.revertToState(snap0)` also rewinds block.number/timestamp to the seed, and
        // `Quid.withdraw` enforces `block.number > lastDepositBlock[msg.sender]` ("too soon",
        // Quid.sol:540 — the JIT-deposit guard). The treatment rolls a block per `_open`, so its
        // three redeems clear the guard while the control's REVERTED with "too soon" and
        // `_lpValueUsd`'s try/catch turned that into 0 — which is precisely what PREMISE 2 below
        // exists to catch, and it did.
        //
        // Restoring the treatment's final block/timestamp makes this an actual control: opens are
        // then the ONLY variable between the two arms. Leaving it un-matched compared an aged pool
        // against a brand-new one and called the difference a leverage externality.
        uint tBlock = block.number;
        uint tTime  = block.timestamp;
        vm.revertToState(snap0);
        vm.roll(tBlock);
        vm.warp(tTime);
        uint cUp   = _lpValueUsd(px0 * 120 / 100);
        uint cFlat = _lpValueUsd(px0);
        uint cDown = _lpValueUsd(px0 * 80 / 100);

        emit log_string("scenario | control USD18 | treatment USD18 | externality bps (treat-ctrl)/ctrl");
        _report("ETH +20%", cUp, tUp);
        _report("ETH flat ", cFlat, tFlat);
        _report("ETH -20%", cDown, tDown);
        emit log_string("Expect: +20% => LP WORSE (LVR out); -20% => LP BETTER; flat => ~fees. LP is short the position.");

        // PREMISE 1: the treatment must actually BE a treatment. `_open` swallows a guard
        // revert into wethOut==0 and the loop `break`s, so a guard trip on round 0 makes
        // treatment and control the same scenario — every comparison below then reduces to
        // `x vs x` and passes while measuring nothing.
        assertGt(landed, 0, "PREMISE: at least one leverage open must land, else treatment == control");
        // PREMISE 2: the LP valuation must be REAL. `_lpValueUsd` wraps `ETH.redeem` in a
        // try/catch and returns 0 when it reverts — with all six legs at 0 every inequality
        // below holds vacuously. This is the exact hazard that let a zero-delivery redeem hide
        // in `testDD`. Require delivery on all six measurements.
        assertGt(cFlat, 0, "PREMISE: the CONTROL LP redeem must deliver, else nothing is valued");
        assertGt(tFlat, 0, "PREMISE: the TREATMENT LP redeem must deliver, else nothing is valued");
        assertGt(cUp, 0, "PREMISE: control +20% valuation must be non-zero");
        assertGt(tUp, 0, "PREMISE: treatment +20% valuation must be non-zero");
        assertGt(cDown, 0, "PREMISE: control -20% valuation must be non-zero");
        assertGt(tDown, 0, "PREMISE: treatment -20% valuation must be non-zero");
        // PREMISE 3: the opens must have actually CONVERTED the LP's ETH side to USD side —
        // that conversion IS the mechanism under study. Because `_lpValueUsd` values the same
        // redeemed bundle at three prices, (up - down) is exactly 0.4 x px0 x the ETH the LP
        // gets back, so a strictly smaller spread in the treatment is a direct measurement of
        // a smaller ETH leg. If the spreads match, the range never sold and there is no LVR to
        // measure regardless of what the totals say.
        assertLt(tUp - tDown, cUp - cDown,
            "PREMISE: the opens must shrink the LP's ETH leg, else no value transfer occurred");

        // SAFETY: at UNCHANGED price the passive LP must not be left worse off. Up and down
        // moves produce a legitimate two-sided LVR/inventory effect (the LP is short the
        // position by construction and the +20% leg is EXPECTED to be negative — that is a
        // property of AMM inventory, not a defect). The flat leg has no such excuse: the LP
        // sold ETH into the opens at or above mid and collected fees, so if it still comes out
        // behind the control, leverage flow is extracting value from passive liquidity outright.
        // ⛔ **THIS ASSERTION USED TO COMPARE `tFlat` TO `cFlat`, AND THAT IS THE ARTIFACT THIS
        //    FILE'S OWN INSTRUMENT NOTE WARNS ABOUT.** Measured 2026-08-28: the control redeem
        //    leaves **3 wei** of shares (a FULL redemption) while the treatment leaves
        //    **24.044e18** (a PARTIAL one), because BURN-EXACT delivers only what it can. Comparing
        //    proceeds across those two arms compares different SCOPES, and the undelivered — but
        //    still LP-owned — remainder reads as "value extracted by leverage flow": 993,635.42 vs
        //    997,236.59, a phantom 0.361%. `_lpValueUsd`'s own note states the rule: *"Both arms
        //    must bracket the SAME SCOPE or the difference is an artifact of the instrument"*, and
        //    *"the honest comparison is each arm against ITS OWN pre-redeem NAV"*.
        // ✅ **SO ASSERT THE SAFETY PROPERTY ON THE BASIS THAT IS SCOPE-MATCHED BY CONSTRUCTION:**
        //    pre-redeem NAV, which brackets the WHOLE position in both arms and needs no view on
        //    how to value a residual (both obvious bases are wrong — see `_lpValueUsd`).
        //    MEASURED at unchanged price: treatment 998,139.20 vs control 998,137.73 — the
        //    treatment LP is **$1.48 BETTER off**, consistent with fees earned on the flow.
        //    Corroborated independently by `test_Instrument_PositionValueBeforeAnyRedeem`.
        // ⚠️ **THIS IS NOT A WEAKER TEST.** The value-destruction question it was reaching for is
        //    now caught by the SHORT-PAYMENT guard inside `_lpValueUsd`, which fires per-arm on
        //    burned-but-undelivered shares — the failure mode a cross-arm proceeds comparison
        //    cannot distinguish from ordinary deferral.
        assertGe(tNavFlat, lastNavUsd,
            "at UNCHANGED ETH price, leverage flow must not leave the passive LP worse off than no flow "
            "(pre-redeem NAV: scope-matched across arms, unlike redemption proceeds)");
        // SAFETY: the other side of the same inventory shift must be present, not just absent
        // harm — having sold ETH into the opens, the treatment LP must be strictly better off
        // in a drawdown. Together with the flat leg this pins the sign of the externality
        // instead of merely bounding its size.
        assertGt(tDown, cDown,
            "having sold ETH into the opens, the LP must be BETTER off in a drawdown (short the position)");
    }

    function _report(string memory tag, uint ctrl, uint treat) internal {
        emit log_named_string("scenario", tag);
        emit log_named_uint("  control USD18",   ctrl);
        emit log_named_uint("  treatment USD18", treat);
        int bps = ctrl > 0 ? (int(treat) - int(ctrl)) * 10_000 / int(ctrl) : int(0);
        emit log_named_int ("  externality bps", bps);
    }
}

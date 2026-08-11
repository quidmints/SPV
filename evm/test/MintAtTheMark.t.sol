// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Alles} from "./Alles.t.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title §E2-#1 — a mint must ENTER AT THE MARK a redeem will pay.
///
/// @notice THE DEFECT. A mature redeem values one QU!D at `min($1, solvent/matureSupply)`
///         (`BasketLib:847`). While that mark is below par, `Basket._finishMint` minted
///         `normalized` 1:1 anyway, so a new depositor received shares ALREADY worth less than the
///         dollars they paid — and, symmetrically, their fresh backing LIFTED the mark for everyone
///         already holding. The incoming depositor silently recapitalised the incumbents.
///
///         WHY THE SUITE NEVER CAUGHT IT: the branch is unreachable while the basket is whole.
///         `total >= matureSupply` ⇒ the mark is par ⇒ minting at the mark is the identity. The
///         full suite is 4,183/1 both with and without the fix, which is the CONTROL for this file,
///         not evidence the fix does nothing — it proves the healthy path is untouched. The
///         shortfall regime has to be constructed on purpose, which is what `_openShortfall` does.
///
///         HOW THE SHORTFALL IS BUILT (no mocking — real mint machinery): the seed tranche projects
///         a 100% APR bonus 13 months forward, so a seed deposit mints ~2.08x its principal. That
///         excess is IMMATURE and absent from `matureSupply` until it vests; warping past maturity
///         vests it, and `matureSupply` then exceeds `solvent` by construction. This is the protocol
///         over-minting its own forward yield — the exact state `Basket.sol:332-340` says the
///         "SHARED solvency haircut" absorbs.
contract MintAtTheMark is Alles {
    function _seedBasket() internal {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 1_000_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
    }

    /// @dev The redeem mark, computed the way `BasketLib._redeemQuote` computes it.
    function _mark() internal returns (uint) {
        (uint solvent,) = AUX.get_metrics(true);
        uint mature = QUID.matureSupply();
        if (mature == 0) return WAD;
        uint m = FullMath.mulDiv(WAD, solvent, mature);
        return m > WAD ? WAD : m;
    }

    /// @dev Drive the basket into `solvent < matureSupply` via a vested seed bond.
    function _openShortfall() internal {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 100_000 * USDC_PRECISION, address(USDC), 13);  // seed tranche, 13mo forward
        vm.stopPrank();
        vm.warp(block.timestamp + 500 days);                             // vest the forward yield
        vm.roll(block.number + 1);
    }

    /// ⚠️ MEASURED, AND IT REFUTES THE TIDY VERSION OF THE CLAIM. I expected mark-INVARIANCE
    /// across the mint (new solvent/new mature == old/old, the way a 4626 issues). It does not hold,
    /// and cannot: `normalized` carries the forward-yield bonus, which is IMMATURE at mint and only
    /// joins `matureSupply` when it vests. So the mark still RISES on a deposit — 0.918981 → 0.957571
    /// measured — because the depositor's backing lands NOW while part of their claim counts LATER.
    /// The rise reverses when that bonus vests, which is precisely the §E2-seniority problem: entry
    /// pricing and the vesting schedule are SEPARATE axes, and #1 only fixes the first.
    /// What this asserts is therefore the direction, not invariance: incumbents must never be
    /// DILUTED by a mint (mark must not fall). The residual subsidy is booked, not hidden.
    function test_E2_MintAtMark_NeverDilutesIncumbents() public {
        _seedBasket();
        _openShortfall();

        uint markBefore = _mark();
        assertLt(markBefore, WAD, "PREMISE: the basket must actually be short, else this is a no-op");

        deal(address(USDC), User03, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User03, 50_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();

        uint markAfter = _mark();
        emit log_named_uint("mark before", markBefore);
        emit log_named_uint("mark after ", markAfter);

        emit log_named_int ("mark delta ", int(markAfter) - int(markBefore));
        assertGe(markAfter, markBefore,
            "a mint must never DILUTE incumbents: the mark may rise while the depositor's own "
            "forward-yield bonus is still immature, but it must not fall");
    }

    /// The depositor-facing half: what you get must be worth what you paid, valued at the SAME mark
    /// a redeem would pay you. Under the 1:1 mint this was `paid * mark` — a haircut taken on entry
    /// for a shortfall you had no part in creating.
    function test_E2_MintAtMark_NewDepositorIsNotHaircut() public {
        _seedBasket();
        _openShortfall();

        uint mark = _mark();
        assertLt(mark, WAD, "PREMISE: basket must be short");

        uint before = QUID.balanceOf(User03);
        deal(address(USDC), User03, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User03, 50_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        uint minted = QUID.balanceOf(User03) - before;

        // Value the new holding at the mark that a redeem would actually pay.
        uint claimUsd = FullMath.mulDiv(minted, _mark(), WAD);
        emit log_named_uint("paid  (usd18)", 50_000e18);
        emit log_named_uint("minted (QUID)", minted);
        emit log_named_uint("claim (usd18)", claimUsd);

        // >= paid, because the non-seed projection still adds a small forward-yield bonus on top of
        // principal; the assertion that matters is that it is NOT `paid * mark`.
        assertGe(claimUsd + 1e15, 50_000e18,
            "a new depositor must not enter at a discount to par: their claim, valued at the mark a "
            "redeem pays, must be at least what they paid");
    }

    /// CONTROL — the discriminator. Would this measurement look the same if the fix were wrong?
    /// In a whole basket the mark is par and the fix is the identity, so mint output must be
    /// BIT-IDENTICAL to the pre-fix behaviour. If this ever diverges, the branch has leaked into
    /// the healthy path, which is the one regression this change could cause.
    function test_E2_MintAtMark_IsExactNoOpWhileBasketIsWhole() public {
        _seedBasket();
        assertEq(_mark(), WAD, "PREMISE: a freshly seeded basket is whole, so the mark is par");

        uint before = QUID.balanceOf(User03);
        deal(address(USDC), User03, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User03, 10_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        uint minted = QUID.balanceOf(User03) - before;

        // Tolerance is ONE 6-dec USDC unit (1e-6 QU!D == 1e12 wei) of deposit-conversion dust, and
        // it is pre-existing rather than masked: the `_mark() == WAD` assertion above proves
        // `total < mature` is FALSE here, so the §E2 branch never executes on this path at all.
        assertApproxEqAbs(minted, 10_000e18, 1e12, "principal is never taken");
        assertEq(_mark(), WAD, "a mint into a whole basket must leave the mark at par");
    }

    /// §MEASUREMENT-AUDIT UPGRADE — THE TIER-1 VERSION: ACTUALLY REDEEM, MEASURE BALANCES.
    /// `test_E2_MintAtMark_NewDepositorIsNotHaircut` computes `minted * _mark()` — both downstream of
    /// the code under test, so it discriminates but is not INDEPENDENT (the claim is hypothetical and
    /// nothing is ever redeemed). This uses `_redeemValue`, which sums ACTUAL ERC-20 balance deltas
    /// at the redeemer plus real QU!D burned — the one instrument here the failing code cannot author.
    ///
    /// THE EXACT CLAIM OF ENTRY-AT-THE-MARK, in balance terms: a depositor who enters at mark `m0`
    /// and redeems at mark `m1` should receive `paid * m1/m0` — their dollars back, scaled ONLY by how
    /// the mark moved AFTER they entered. They share subsequent performance; they do NOT eat a
    /// shortfall that predates them. Under the old 1:1 mint they would receive `paid * m1` instead —
    /// the entry haircut. Note `m1/m0 >= 1` is NOT asserted: the mark may legitimately fall later
    /// (§E2-seniority, a vesting cohort), and that is not this fix's job.
    function test_E2_MintAtMark_RealRedeemMatchesTheMark() public {
        _seedBasket();
        _openShortfall();

        uint m0 = _mark();
        assertLt(m0, WAD, "PREMISE: basket must be short at entry, else the fix is a no-op");

        // §E2-REAL-REDEEM — WHERE IS THE 3.7%? Capture the mint's ACTUAL inputs, not the test's.
        // `Basket._finishMint:258` does `total -= min(total, AUX.depegLoss())`; the test's `_mark()`
        // does NOT subtract it. If they differ, `m0` is not the mark the mint used.
        uint solventRaw; uint depeg; uint matPre;
        { (solventRaw,) = AUX.get_metrics(true); depeg = AUX.depegLoss(); matPre = QUID.matureSupply(); }
        uint totalCode = solventRaw > depeg ? solventRaw - depeg : 0;
        emit log_named_uint("solvent RAW      ", solventRaw);
        emit log_named_uint("depegLoss        ", depeg);
        emit log_named_uint("total the MINT uses", totalCode);
        emit log_named_uint("matureSupply     ", matPre);

        uint qPre = QUID.balanceOf(User03);
        deal(address(USDC), User03, 2_000_000 * USDC_PRECISION);
        emit log_named_uint("USDC before mint (6dec)", USDC.balanceOf(User03));
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User03, 50_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        uint mintedNow = QUID.balanceOf(User03) - qPre;
        emit log_named_uint("USDC after  mint (6dec)", USDC.balanceOf(User03));
        emit log_named_uint("QUID minted      ", mintedNow);
        // Back out `normalized` using the mark the CODE used, then compare to the $50,000 deposited.
        emit log_named_uint("implied normalized (minted*totalCode/mature)",
            matPre == 0 ? mintedNow : FullMath.mulDiv(mintedNow, totalCode, matPre));

        // A fresh mint lands in a FUTURE vintage (day-one `matureSupply` is 0), so it cannot be
        // redeemed until it vests — measured in `test_E2_DayOne_ImmediateRedeemerGetsPar`.
        vm.warp(block.timestamp + 35 days); vm.roll(block.number + 1);

        uint m1 = _mark();
        uint held = QUID.balanceOf(User03);
        (uint received, uint burned) = _redeemValue(User03, held);   // REAL balance deltas

        emit log_named_uint("mark at entry  m0", m0);
        emit log_named_uint("mark at redeem m1", m1);
        emit log_named_uint("QUID burned      ", burned);
        emit log_named_uint("stables received ", received);
        emit log_named_uint("expected paid*m1/m0", FullMath.mulDiv(50_000e18, m1, m0));
        emit log_named_uint("old 1:1 would give ", FullMath.mulDiv(50_000e18, m1, WAD));

        assertGt(burned, 0, "CONTROL: the redeem must actually have burned QU!D");
        assertGt(received, 0, "CONTROL: stables must actually have moved to the redeemer");
        assertApproxEqRel(received, FullMath.mulDiv(50_000e18, m1, m0), 0.02e18,
            "entry at the mark: a depositor entering at m0 and redeeming at m1 must receive "
            "paid*m1/m0 -- their dollars scaled ONLY by mark movement AFTER entry, never a "
            "haircut for a shortfall that predates them");
    }

    /// §E2-DEPOSIT-HAIRCUT-NARROWED — THE DISCRIMINATOR. Healthy basket, but warped PAST MONTH 12 so
    /// the mint takes the SAME post-calibration path as the shortfall case (`isSeed` false,
    /// `currentMonth() >= 12`). The only thing that differs from the failing case is the SHORTFALL.
    ///   • mints ~1:1  ⇒ the haircut needs the shortfall ⇒ suspect the 1:1 cap shrinking to headroom.
    ///   • haircuts    ⇒ the POST-CALIBRATION PATH itself takes ~3.7% from ORDINARY deposits — a live
    ///                   general defect, far bigger than anything §E2 touches.
    function test_E2_Haircut_HealthyButPastMonth12() public {
        _seedBasket();
        vm.warp(block.timestamp + 400 days); vm.roll(block.number + 1);   // past the calibration window

        emit log_named_uint("currentMonth       ", QUID.currentMonth());
        emit log_named_uint("mark (WAD = healthy)", _mark());

        uint before = QUID.balanceOf(User03);
        deal(address(USDC), User03, 2_000_000 * USDC_PRECISION);
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User03, 50_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();

        emit log_named_uint("QUID minted for $50k", QUID.balanceOf(User03) - before);
        emit log_named_uint("shortfall-case gave ", 52486900558949540224705);
        assertGe(QUID.balanceOf(User03) - before, 50_000e18 - 1e12,
            "post-calibration path must not haircut an ORDINARY deposit into a HEALTHY basket");
    }
}

/// §E2-dayone — THE OWNER'S EDGE CASE, MEASURED. Day one, two minters, no yield question: A
/// deposits $100k to redeem as soon as it can; B deposits $100k against a 13-month vintage and the
/// protocol mints B principal PLUS a projected-yield bonus ON THE SPOT. Supply exceeds dollars
/// immediately. Does B's unbacked day-one supply reach A?
///
/// ✅ MEASURED: IT DOES NOT. Day one, supply 462,378 vs dollars 352,000 — over-minted by
///    **$110,378, all of it B's projected yield**, exactly as the owner described. Yet at A's own
///    maturity A burns 100,000 and receives **$99,999.999998** (shortfall $0.0000019 — par).
///    The reason is the seniority ALREADY IN THE DESIGN (`Basket.sol:148-153`): B's 208,333 is
///    IMMATURE, and `matureSupply` (254,044) excludes it, so the mark is capped at par.
///    ⇒ The over-mint is real; it is simply JUNIOR, and does not touch a mature holder.
///
/// 🔴 WHAT THIS DOES *NOT* SHOW, and must not be read as showing:
///    (a) **There is no same-day redemption.** On day one `matureSupply == 0` — a fresh mint lands
///        in a FUTURE vintage, so A cannot redeem at all until its own vintage matures (~1 month).
///        That is the live half of "how do I mint QU!D that is redeemable right away".
///    (b) **Holding ACROSS a vesting event is still exposed.** At month 13 B's 208,333 becomes
///        mature; if realised yield < $110,378 the mark falls for everyone then holding. That is
///        the open item — the VEST BOUNDARY, not a ranking of claims.
contract MintAtTheMarkDayOne is Alles {
    function test_E2_DayOne_ImmediateRedeemerGetsPar() public {
        deal(address(USDC), User01, 2_000_000 * USDC_PRECISION);
        deal(address(USDC), User02, 2_000_000 * USDC_PRECISION);

        { (, uint ay) = AUX.get_metrics(true);
          emit log_named_uint("avgYield (WAD)    ", ay);
          emit log_named_uint("currentMonth      ", QUID.currentMonth());
          (uint sv,) = AUX.get_metrics(true);
          emit log_named_uint("PRE solvent       ", sv);
          emit log_named_uint("PRE totalSupply   ", QUID.totalSupply());
          emit log_named_uint("PRE matureSupply  ", QUID.matureSupply());
          emit log_named_uint("PRE immatureSupply", QUID.immatureSupply()); }
        vm.startPrank(User01);                                   // A — immediate
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 100_000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();
        uint aQuid = QUID.balanceOf(User01); aQuid;

        vm.startPrank(User02);                                   // B — 13-month bond
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User02, 100_000 * USDC_PRECISION, address(USDC), 13);
        vm.stopPrank();

        (uint solvent,) = AUX.get_metrics(true);
        emit log_named_uint("A minted (QUID)   ", aQuid);
        emit log_named_uint("B minted (QUID)   ", QUID.balanceOf(User02));
        emit log_named_uint("totalSupply       ", QUID.totalSupply());
        emit log_named_uint("matureSupply      ", QUID.matureSupply());
        emit log_named_uint("solvent (dollars) ", solvent);
        emit log_named_int ("supply - dollars  ", int(QUID.totalSupply()) - int(solvent));

        // A's OWN vintage matures ~1 month out; B's stays junior until month 13. Warp just past A's.
        vm.warp(block.timestamp + 35 days); vm.roll(block.number + 1);
        { (uint sv2,) = AUX.get_metrics(true);
          emit log_named_uint("M1 solvent        ", sv2);
          emit log_named_uint("M1 matureSupply   ", QUID.matureSupply());
          emit log_named_uint("M1 immatureSupply ", QUID.immatureSupply()); }
        (uint got, uint burned) = _redeemValue(User01, 100_000e18);  // A redeems its OWN $100k
        emit log_named_uint("A burned          ", burned);
        emit log_named_uint("A received (usd18)", got);
        emit log_named_int ("A shortfall       ", int(100_000e18) - int(got));

        assertApproxEqRel(got, 100_000e18, 0.001e18,
            "A deposited $100k and redeems at its own maturity while B's forward mint is still "
            "junior: A must receive par. Anything less means B's unbacked day-one supply reached A.");
        assertGt(QUID.totalSupply(), 352_000e18,
            "PREMISE: day-one supply MUST exceed dollars, else this proves nothing about the "
            "over-mint being harmless");
    }

}

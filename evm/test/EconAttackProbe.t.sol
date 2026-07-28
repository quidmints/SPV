// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Empirical probes for two value-extraction attacks "of this nature":
///   A) Bootstrap over-credit: mint with when=13 in month 0 -> isSeed gives 100% APR with
///      the 1:1 cap SKIPPED -> the bonus may be unbacked. Mature it, redeem, measure $out
///      vs $in. If out > in, the seed bonus drains; if clamped, the redeem gate holds.
///   B) Backing inflation: donate the underlying to a venue 4626 vault -> does measured
///      basket backing (get_metrics) rise, opening mint headroom against value not deposited?
/// Run: forge test --match-contract EconAttackProbe -vv
contract EconAttackProbe is Alles {
    uint constant MONTH = 2420000;

    function testA_BootstrapSeedMaturityDrain() public {
        uint X = 50_000 * USDC_PRECISION;
        uint usdIn18 = X * 1e12;
        vm.startPrank(User01);
        uint minted = QUID.mint(User01, X, address(USDC), 13); // when=13 -> isSeed bonus
        emit log_named_uint("A: USD in (18d)", usdIn18);
        emit log_named_uint("A: QUI minted (18d)", minted);
        emit log_named_int ("A: bonus over deposit (18d)", int(minted) - int(usdIn18));
        vm.stopPrank();

        // Mature the month-13 batch.
        vm.warp(block.timestamp + 14 * MONTH);

        vm.startPrank(User01);
        uint qd = QUID.balanceOf(User01);
        uint u0 = USDC.balanceOf(User01);
        try AUX.redeem(qd) {} catch (bytes memory e) { emit log_named_bytes("A: redeem revert", e); }
        emit log_named_int ("A: USDC out from redeem (6d)", int(USDC.balanceOf(User01)) - int(u0));
        emit log_named_uint("A: QUI stuck after redeem (18d)", QUID.balanceOf(User01));
        vm.stopPrank();
        AUX.checkBacking();
    }

    /// A2: the seed CAP is a HARD per-mint bound, not a soft `seeded < CAP`
    /// eligibility gate. A single seed-window deposit whose 100%-APR/13mo
    /// projection (~2.08x) would push the senior tranche past CAP must NOT get
    /// the seed bonus — the WHOLE mint drops to the normal (avgYield) projection.
    /// Under the pre-fix soft gate this minted ~2.08x of a huge principal as
    /// unbounded unbacked QUI.
    function testA2_SeedCapBreachDropsToNormal() public {
        uint startSeeded = QUID.trancheTotal();
        // Pick a principal whose seed projection alone blows past whatever
        // CAP headroom remains: 500k * ~2.08 = ~1.04M ≫ 600k CAP.
        uint big = 500_000 * USDC_PRECISION;
        deal(address(USDC), User01, big);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        uint minted = QUID.mint(User01, big, address(USDC), 13);
        vm.stopPrank();

        uint prin18   = big * 1e12;
        uint seedAmt  = prin18 + prin18 * 13 / 12; // what the 100%-APR seed path WOULD mint
        emit log_named_uint("A2: principal (18d)", prin18);
        emit log_named_uint("A2: minted (18d)", minted);
        emit log_named_uint("A2: seed-path would-mint (18d)", seedAmt);
        emit log_named_uint("A2: trancheTotal after (18d)", QUID.trancheTotal());

        // (1) did NOT get the 100%-APR seed bonus (used avgYield instead of WAD).
        assertLt(minted, seedAmt, "CAP-breaching mint must NOT get the 100%-APR seed bonus");
        // (2) principal is never lost to the CAP mechanism (tolerate 4626
        //     vault-deposit rounding dust, which shaves ~1e-6 USDC off every
        //     deposit regardless of this fix).
        assertGe(minted, prin18 - 1e15, "depositor keeps principal (mod vault dust)");
        // (3) the senior tranche never exceeds CAP (the hard bound holds).
        assertLe(QUID.trancheTotal(), 600_000 * 1e18, "senior tranche stays <= CAP");
        // (4) since the mint dropped out of the seed path, seeded is unchanged.
        assertEq(QUID.trancheTotal(), startSeeded, "breaching mint adds nothing to the seed tranche");
    }

    /// A3: control — a deposit whose seed projection FITS under CAP still gets
    /// the full 100%-APR bonus (the fix doesn't neuter the bootstrap incentive).
    function testA3_WithinCapStillSeeds() public {
        uint startSeeded = QUID.trancheTotal();
        require(startSeeded + 208_000 * 1e18 <= 600_000 * 1e18, "fixture seeded too high for control");
        uint small = 100_000 * USDC_PRECISION;   // 100k * ~2.08 = ~208k < 600k CAP
        deal(address(USDC), User01, small);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        uint minted = QUID.mint(User01, small, address(USDC), 13);
        vm.stopPrank();

        uint prin18 = small * 1e12;
        emit log_named_uint("A3: minted (18d)", minted);
        // Got the seed bonus: ~2.08x principal (well above any avgYield projection).
        assertGt(minted, prin18 * 15 / 10, "within-CAP mint keeps the ~2.08x seed bonus");
        assertGt(QUID.trancheTotal(), startSeeded, "within-CAP mint accrues the seed tranche");
    }

    function testB_BackingInflationByDonation() public {
        (uint b0,) = AUX.get_metrics(true);
        address[] memory vs = AUX.getVaults(address(USDC));
        require(vs.length > 0, "no USDC vault");
        address vault = vs[0];
        uint donate = 1_000_000 * USDC_PRECISION;     // $1M donation
        deal(address(USDC), address(this), donate);
        // PROVE THE DONATION LANDED before drawing any conclusion from `b1 - b0`. A delta of zero is
        // ambiguous on its own: it means either "attack defended" or "fixture never exercised the
        // attack". Measuring the venue's OWN reported value disambiguates -- if this moves and backing
        // does not, the defence is real (§A.46).
        uint venueBefore = IERC4626(vault).totalAssets();
        IERC20(address(USDC)).transfer(vault, donate); // inflate the 4626's convertToAssets
        uint venueAfter = IERC4626(vault).totalAssets();
        emit log_named_uint("B: venue totalAssets before", venueBefore);
        emit log_named_uint("B: venue totalAssets after ", venueAfter);
        assertGt(venueAfter, venueBefore,
            "PREMISE: the donation must actually inflate the venue, else this test proves nothing");
        (uint b1,) = AUX.get_metrics(true);
        emit log_named_uint("B: backing before (18d)", b0);
        emit log_named_uint("B: backing after donate (18d)", b1);
        emit log_named_int ("B: backing delta (18d)", int(b1) - int(b0));
        emit log_named_uint("B: donated USD (18d)", donate * 1e12);

        // THE SAFETY PROPERTY (this test had NO assertion and always passed — §A.46).
        // A donation is a GIFT, so backing legitimately rises BY the donation. The attack is backing
        // rising by MORE than was donated: that is the protocol leveraging a gift, and it would let an
        // attacker mint against value nobody contributed. Bound is derived from the live measurement
        // (b0, b1, donate), never a constant (§A.22).
        assertLe(b1 - b0, donate * 1e12,
            "donation must not inflate recognized backing beyond its own face value");
    }

    /// C: JIT-LP — deposit AFTER swap fees accrue, then check pending. If the bookmark set
    /// at deposit works, a fresh LP earns ~0 of the fees generated before it joined.
    function testCC_JITLPFeeCapture() public {
        vm.prank(User02); V4.deposit{value: 100 ether}(0, User02);   // incumbent
        vm.startPrank(User03);                                        // generate swap fees
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 10; i++) {
            try AUX.swap(address(USDC), address(WETH), true, 50_000 * USDC_PRECISION, 0) {} catch { break; }
        }
        vm.stopPrank();
        (uint incE, uint incU) = V4.pendingRewards(User02);
        emit log_named_uint("C: incumbent pending eth", incE);
        emit log_named_uint("C: incumbent pending usd", incU);
        vm.prank(User01); V4.deposit{value: 100 ether}(0, User01);   // JIT joins AFTER fees
        (uint jitE, uint jitU) = V4.pendingRewards(User01);
        emit log_named_uint("C: JIT pending eth (want ~0)", jitE);
        emit log_named_uint("C: JIT pending usd (want ~0)", jitU);
    }

    /// D: redeem cherry-pick — depeg DAI 20%, compare pro-rata redeem vs preferring the GOOD
    /// stable (USDC). If cherry-pick's fair value beats pro-rata beyond the concentration fee,
    /// the attacker sheds the bad leg onto everyone else.
    function testDD_RedeemCherryPick() public {
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(DAI)), abi.encode(uint(2000)));
        vm.startPrank(User01);
        uint amt = QUID.balanceOf(User01) / 8;
        require(amt > 0, "no QUI");

        uint snap = vm.snapshotState();
        uint u0 = USDC.balanceOf(User01); uint d0 = DAI.balanceOf(User01);
        try AUX.redeem(amt) {} catch { emit log_string("D: prorata revert"); }
        uint pFair = (USDC.balanceOf(User01) - u0) * 1e12 + (DAI.balanceOf(User01) - d0) * 80 / 100;
        vm.revertToState(snap);

        u0 = USDC.balanceOf(User01); d0 = DAI.balanceOf(User01);
        try AUX.redeem(amt, address(USDC)) {} catch { emit log_string("D: cherry revert"); }
        uint cFair = (USDC.balanceOf(User01) - u0) * 1e12 + (DAI.balanceOf(User01) - d0) * 80 / 100;
        vm.stopPrank();

        emit log_named_uint("D: prorata fair value (18d)", pFair);
        emit log_named_uint("D: cherrypick fair value (18d)", cFair);
        emit log_named_int ("D: cherry advantage (18d)", int(cFair) - int(pFair));
    }
}

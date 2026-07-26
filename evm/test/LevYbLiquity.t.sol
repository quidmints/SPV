// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Reuse the real-fork weETH probe wholesale (mainnet fork via Alles, band/rally helpers, constants, interfaces).
import "./LevYbReal.t.sol";
import {LiquityTroveVenue} from "../src/LiquityTroveVenue.sol";

/// @notice REAL-FORK proof that a BOLD (Liquity V2) leveraged LP can be CLOSED depth-INDEPENDENTLY. BOLD is the one
///   venue whose DEBT leg can't ride the generic path — it can't be flashed (Morpho holds ~1052) nor bought on a
///   deep pool — so the manager flashes WETH and MINTS BOLD at face value via the venue's protocol trove, repays
///   the LP's own trove, and hands the LP FULL fair equity while the PROTOCOL funds the Liquity
///   over-collateralization from `boldCloseReserve` (it becomes the protocol trove's own equity = the counterparty
///   position). The COLLATERAL leg is the same generic WETH path as Aave/Morpho-WETH. Open → lever → close, live.
contract LevYbLiquityProbe is LevYbRealProbe {
    // Live Liquity V2 WETH branch (verified on mainnet; == LiquityVenue.t.sol / DeployL1_s). BOLD is inherited
    // from the Alles base (`IERC20 public BOLD`).
    address constant LQTY_BO = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address constant LQTY_TM = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;

    LevManager llm;
    LiquityTroveVenue lvenue;

    function _setupLiquity() internal {
        _seedBasket();
        rpx = AUX.getTWAPforAsset(address(WETH), 1800);
        llm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        lvenue = new LiquityTroveVenue(LQTY_BO, LQTY_TM, address(BOLD), address(WETH), address(llm), 0.05e18, 2000e18);
        // Flash provider = MORPHO. BOLD is NOT Morpho-flashable → the manager flashes WETH + mints BOLD instead.
        { address[] memory vs = new address[](1); vs[0] = address(lvenue); llm.init(address(V4), MORPHO, vs); }
        // One-time Liquity WETH gas-comp buffer at the venue (covers the LP + protocol trove opens; ~0.0375 each).
        deal(address(WETH), address(lvenue), 0.2 ether);
        // Fund the BOLD-close reserve: the protocol capital that covers the Liquity over-collateralization so the
        // closing LP still gets FULL fair equity (bounded in prod by a cap on total BOLD-leverage TVL).
        deal(address(WETH), address(this), 20 ether);
        IERC20R(address(WETH)).approve(address(llm), 20 ether);
        llm.fundBoldCloseReserve(20 ether);
    }

    function _openLiquityLp() internal {
        vm.deal(LP, 6 ether);
        vm.prank(LP); V4.deposit{value: 5 ether}(0, LP, 3);   // 5 ETH plain band equity
        deal(address(WETH), LP, 5 ether);                       // 5 WETH lev equity
        uint[] memory mins = new uint[](8);
        vm.startPrank(LP);
        IERC20R(address(WETH)).approve(address(llm), 5 ether);
        llm.openLev(5000, ILevVenue(address(lvenue)), 5 ether, mins); // cap 2x, zero leverage at entry
        vm.stopPrank();
        llm.setSoldFractionActive(true);
        // Rally +50% (not +20%): the Liquity MIN_DEBT floor (2000 BOLD) means the position opens ALREADY above a
        // small IL target, so it only levers up once t·E0·px clears the floor (~+33%). +50% clears it robustly
        // across the unpinned `latest` fork (at +20% whether it levers is block-marginal → flaky coll≈5).
        _rallyBand(_entrySqrt(llm, LP), 0.5e18, 40, 12_000 * USDC_PRECISION);
        llm.rebalance(LP, 0);         // lever up: borrow BOLD + SOR-buy WETH, supply back
    }

    function testReal_Liquity_OpenLeverClose() public {
        _setupLiquity();
        ETH.setLevManager(address(llm));    // BACKING: vogueETH counts this WETH lev book
        _openLiquityLp();

        uint debt0 = lvenue.debtOf(LP);
        uint coll0 = lvenue.collateralOf(LP);
        emit log_named_uint("Liquity BOLD debt after open+lever", debt0);
        emit log_named_uint("Liquity WETH collateral after open+lever", coll0);
        assertGt(debt0, 0, "open+lever must take on real Liquity BOLD debt");
        assertGt(coll0, 5 ether, "lever-up must grow WETH collateral beyond the 5 WETH equity");

        // Close via the depth-INDEPENDENT mint path (no BOLD flash, no BOLD DEX).
        _realignBandToReal();
        uint lpWethBefore = IERC20R(address(WETH)).balanceOf(LP);
        uint reserveBefore = llm.boldCloseReserve();
        vm.prank(LP);
        llm.closeLev(0);

        assertEq(lvenue.debtOf(LP), 0, "close: LP Liquity BOLD debt fully repaid");
        assertLt(lvenue.collateralOf(LP), 1e12, "close: LP collateral fully withdrawn (trove closed)");
        assertGt(IERC20R(address(WETH)).balanceOf(LP), lpWethBefore, "close: fair equity returned to the LP in WETH");
        assertEq(llm.grossCollateralEth(LP), 0, "close: position drops out of the band");
        (,,,,, bool stillOpen) = llm.pos(LP);
        assertTrue(!stillOpen, "close: position deleted");

        // Mint-close specifics: the BOLD came from the venue's PROTOCOL trove (the depth-independent source /
        // counterparty), and the protocol funded the over-collateralization from the reserve (so it shrank).
        assertGt(lvenue.protocolTroveId(), 0, "close: protocol trove opened as the BOLD source / counterparty");
        assertLt(llm.boldCloseReserve(), reserveBefore, "close: protocol funded the over-collateralization from reserve");
        emit log_named_uint("reserve consumed (over-collateralization funded)", reserveBefore - llm.boldCloseReserve());
    }

    /// @notice (#64 gap 3, HIGH) PARTIAL de-lever through the BOLD/Liquity MINT path (`_deleverMint` →
    ///   `_onFlashMint` partial branch) — previously untested (only `rebalance`-up + full `closeLev` were).
    ///   Open+lever a Liquity position, then a REAL band down-move shrinks the IL target so `deleverOne` must
    ///   de-lever PARTIALLY (NOT a full close): the manager flashes WETH, MINTS BOLD at face value from the
    ///   PROTOCOL trove, repays part of the LP's own trove, and withdraws the LP's fair WETH slice (equity-neutral).
    ///   Asserts the debt falls PARTIALLY (trove stays open), the fair collateral slice is withdrawn, the protocol
    ///   trove / reserve behave as in the full-close test, and the position is NOT deleted. Same crash→deleverOne
    ///   shape as testReal_Morpho_OpenAndDelever, over the mint venue.
    function testReal_Liquity_PartialDeleverMint() public {
        _setupLiquity();
        ETH.setLevManager(address(llm));    // BACKING: vogueETH counts this WETH lev book
        _openLiquityLp();

        uint debt0 = lvenue.debtOf(LP);
        uint coll0 = lvenue.collateralOf(LP);
        assertGt(debt0, 0, "open+lever must take on real Liquity BOLD debt");
        assertGt(coll0, 5 ether, "lever-up must grow WETH collateral beyond the 5 WETH equity");

        // Force a CONTROLLED PARTIAL de-lever: HALVE the LP's LTV cap so the live IL target drops to ~half the
        // levered LTV (a real band crash on the thin mock band over/under-shoots to a FULL unwind — sold fraction
        // hits 0). deleverRepayUsd = curDebt − E0·(target/2) is then a POSITIVE partial repay, and the new target
        // stays > 0 so the trove never fully closes — exactly the `_deleverMint` partial branch we want to cover.
        uint tgt0 = llm.ilTargetLtvBps(LP);                 // live IL target (bps), ~= the levered LTV
        assertGt(tgt0, 200, "levered to a meaningful IL target (headroom to halve)");
        vm.prank(LP); llm.setTargetLtv(uint64(tgt0 / 2));   // cap now < curLTV ⇒ partial de-lever needed

        uint reserveBefore = llm.boldCloseReserve();
        // De-lever ONE position through the mint venue (LP self-de-risk path; keeper uses cascadeDelever).
        vm.prank(LP);
        llm.deleverOne(LP, 0);

        emit log_named_uint("Liquity BOLD debt after partial delever", lvenue.debtOf(LP));
        emit log_named_uint("Liquity WETH collateral after partial delever", lvenue.collateralOf(LP));
        assertLt(lvenue.debtOf(LP), debt0, "partial de-lever: BOLD debt fell (mint-path repay)");
        assertGt(lvenue.debtOf(LP), 0, "PARTIAL: trove still open (not a full close)");
        assertLt(lvenue.collateralOf(LP), coll0, "partial de-lever: the LP's fair WETH slice was withdrawn");
        assertGt(lvenue.collateralOf(LP), 0, "PARTIAL: collateral remains (position not closed)");
        (,,,,, bool stillOpen) = llm.pos(LP);
        assertTrue(stillOpen, "partial de-lever: position NOT deleted");

        // Mint-path specifics (same as the full-close test): BOLD came from the venue's PROTOCOL trove, and the
        // protocol funded the Liquity over-collateralization out of the reserve (so it shrank).
        assertGt(lvenue.protocolTroveId(), 0, "protocol trove opened as the BOLD source / counterparty");
        assertLt(llm.boldCloseReserve(), reserveBefore, "protocol funded the over-collateralization from reserve");
        emit log_named_uint("reserve consumed (partial over-collateralization)", reserveBefore - llm.boldCloseReserve());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Alles} from "./Alles.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// §E69 — IS RESTORING THE BAND'S BALANCE NATURALLY PROFITABLE?
///
/// The owner asked this twice and I answered it twice with an ARGUMENT, then cited E25's
/// "0 bps across 300k" as if it settled the matter. IT DOES NOT: E25 measured dislocation
/// under ORDINARY volume on a balanced band. The question here is the dislocation present in
/// an IMBALANCED band — a different state, and the only one where a restorer would act.
/// Reusing the first measurement to answer the second is the error this fixture removes.
///
/// WHAT PROFITABLE MEANS, OPERATIONALLY. A restorer buys the abundant side out (or sells the
/// scarce side in) and unwinds at the oracle elsewhere. It nets only if the execution price it
/// receives BEATS oracle by more than its costs. So the measurable is
///
///     edge_bps = (execution price / oracle price - 1) * 10_000
///
/// on a swap that moves `inv` TOWARD target, in a band that has been driven away from it.
///   edge > 0  => the curve itself pays the restorer; an external arb will do this unaided.
///   edge == 0 => the band prices restoration AT oracle; the restorer nets exactly its gas
///                and LP fee NEGATIVE, so nobody does it and imbalance persists.
/// The sign is the whole result. Magnitude only matters if the sign is positive.
contract RestoreProfitability is Alles {
    address lpA = User02;
    address imbalancer = address(0xBEEF02);
    address restorer = address(0xBEEF03);
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

    /// Buy WETH with stable — ADDS volatile to the band (raises inv).
    function _buyEth(address who, uint boldAmt) internal returns (uint got) {
        deal(bold, who, boldAmt);
        uint before = WETH.balanceOf(who);
        vm.startPrank(who);
        IERC20(bold).approve(address(AUX), boldAmt);
        try AUX.swap(bold, address(WETH), true, boldAmt, 0) {} catch {}
        vm.stopPrank();
        got = WETH.balanceOf(who) - before;
        _settle();
    }

    /// Sell WETH for stable — REMOVES volatile from the band (lowers inv).
    function _sellEth(address who, uint ethAmt) internal returns (uint got) {
        deal(address(WETH), who, ethAmt);
        uint before = IERC20(bold).balanceOf(who);
        vm.startPrank(who);
        WETH.approve(address(AUX), ethAmt);
        AUX.swap(bold, address(WETH), false, ethAmt, 0);
        vm.stopPrank();
        got = IERC20(bold).balanceOf(who) - before;
        _settle();
    }

    /// THE MEASUREMENT. Drive the band ETH-HEAVY, then have a restorer SELL ETH BACK (the
    /// direction that lowers `inv` toward target) and compare what it received against oracle.
    function test_E69_IsRestoringNaturallyProfitable() public {
        _seedBasket();
        vm.prank(lpA);
        V4.deposit{value: 400 ether}(0, lpA, 3);
        _settle();

        uint px = AUX.getTWAPforAsset(address(WETH), 1800);   // USD18 per 1e18 raw
        emit log_named_uint("oracle px (usd18/eth)", px);
        emit log_named_uint("wellSkew BEFORE imbalance", AUX.wellSkew(address(WETH)));

        // ---- 1. DRIVE THE IMBALANCE. Repeated BUYS pile volatile into the band.
        for (uint i = 0; i < 12; ++i) _buyEth(imbalancer, 25_000 * 1e18);
        emit log_named_uint("wellSkew AFTER imbalance ", AUX.wellSkew(address(WETH)));

        // ---- 2. THE RESTORING TRADE. Selling ETH back lowers inv toward target.
        uint sellSize = 20 ether;
        uint stableOut = _sellEth(restorer, sellSize);
        emit log_named_uint("restorer sold (eth wei) ", sellSize);
        emit log_named_uint("restorer got (stable18)", stableOut);

        // ---- 3. THE EDGE. What would the same ETH have fetched at oracle?
        uint atOracle = sellSize * px / 1e18;
        emit log_named_uint("same eth at oracle     ", atOracle);

        if (stableOut == 0) {
            emit log("RESULT: restoring swap REVERTED or returned nothing");
        } else if (stableOut > atOracle) {
            emit log_named_uint("EDGE bps (POSITIVE)", (stableOut - atOracle) * 10_000 / atOracle);
            emit log("RESULT: curve PAYS the restorer -- an external arb closes this unaided");
        } else {
            emit log_named_uint("SHORTFALL bps         ", (atOracle - stableOut) * 10_000 / atOracle);
            emit log("RESULT: restorer receives AT-OR-BELOW oracle -- restoring does NOT pay for itself");
        }
    }
}

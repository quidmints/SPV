// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Alles} from "./Alles.t.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

/// §A.5e PIN. The refresh MARKER cannot discriminate (the post-redeem refresh runs regardless), so this
/// asserts on the PAYOUT. Treatment values through a STALE cache while a vault has lost value; control
/// values the same loss through a FRESH cache. With the guard they match — the stale path heals itself
/// before valuing. Devalues via balanceOf, NOT convertToAssets: an arg-matched convertToAssets mock does
/// not bite, because the code calls it with different share amounts (§A.20's inert-mock class).
contract A5eStaleCache is Alles {
    uint constant MONTH = 2_420_000; // BasketLib.MONTH

    function testA5e_StaleCacheCannotOverDraw() public {
        for (uint i; i < 2; i++) {
            address u = i == 0 ? User01 : User02;
            deal(address(USDC), u, 400_000 * USDC_PRECISION);
            vm.startPrank(u);
            USDC.approve(address(AUX), type(uint).max);
            QUID.mint(u, 200_000 * USDC_PRECISION, address(USDC), 0);
            vm.stopPrank();
        }
        // Freshly-minted QUI is maturity-locked (turn burns MATURED vintages only); without this warp
        // both redeems no-op and the comparison is vacuous (observed: 0 vs 0).
        vm.warp(block.timestamp + 3 * MONTH);
        vm.roll(block.number + 1);
        AUX.get_deposits();                                   // fresh baseline

        address[] memory vs = AUX.getVaults(address(USDC));
        require(vs.length > 0, "need a USDC vault to devalue");
        address v = vs[0];
        uint halved = IERC4626(v).balanceOf(address(AUX)) / 2;

        uint snap = vm.snapshotState();

        vm.warp(block.timestamp + 3 hours);                   // past HOLDINGS_MAX_STALE
        vm.mockCall(v, abi.encodeWithSignature("balanceOf(address)", address(AUX)), abi.encode(halved));
        uint b0 = USDC.balanceOf(User01);
        vm.prank(User01); try AUX.redeem(50_000e18, address(USDC)) {} catch {}
        uint paidStale = USDC.balanceOf(User01) - b0;

        vm.revertToState(snap);

        vm.mockCall(v, abi.encodeWithSignature("balanceOf(address)", address(AUX)), abi.encode(halved));
        AUX.get_deposits();                                   // refresh: nothing stale
        uint c0 = USDC.balanceOf(User01);
        vm.prank(User01); try AUX.redeem(50_000e18, address(USDC)) {} catch {}
        uint paidFresh = USDC.balanceOf(User01) - c0;

        emit log_named_uint("paid via STALE cache", paidStale);
        emit log_named_uint("paid via FRESH cache", paidFresh);
        assertLe(paidStale, paidFresh + paidFresh / 100,
            "a stale cache must not let a redeemer draw MORE than the fresh-cache valuation");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Alles} from "../Alles.t.sol";
import {Vault} from "../../src/Vault.sol";

/// @notice BTC-pool self-managed boundary orders — `Vault.outOfRangeBtc`/`pullBtc`,
///         the USD-funded BTC twin of the ETH `Vogue.outOfRange`/`pull` path. Mirrors
///         `Alles.testOutOfRangeUSDPosition` on the BTC (USD/WBTC) curve: place a
///         single-sided USD limit order outside range, then pull it back.
contract BtcSelfManagedTest is Alles {
    /// Create a USD-funded boundary order on the BTC curve, then fully pull it.
    function testOutOfRangeBtc_USDPosition() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint balanceBefore = USDC.balanceOf(User01);

        // distance sign mirrors the ETH USD test; the BTC pool ordering is handled
        // inside oorTicks via token1isBTC (same shared geometry).
        uint id = BTC.outOfRangeBtc(rack / 10, address(USDC), 1000, 100);

        assertGt(id, 0, "BTC self-managed position id > 0");
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore - rack / 10,
                          rack / 100, "USDC deducted for the boundary order");

        vm.roll(vm.getBlockNumber() + 1000);
        balanceBefore = USDC.balanceOf(User01);
        BTC.pullBtc(id, 100, address(USDC));
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore, rack / 50,
                          "USDC returned on full pull");
        vm.stopPrank();
    }

    /// USD-funded only: native/WBTC funding is rejected (no BTC user-deposit leg).
    function testOutOfRangeBtc_RejectsNative() public {
        vm.prank(User01);
        vm.expectRevert(Vault.NotAStable.selector);
        BTC.outOfRangeBtc(0, address(0), 1000, 100);
    }

    /// Only the position owner can pull it.
    function testPullBtc_OnlyOwner() public {
        vm.startPrank(User01);
        USDC.approve(address(AUX), rack);
        uint id = BTC.outOfRangeBtc(rack / 10, address(USDC), 1000, 100);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 1000);
        vm.prank(User02);
        vm.expectRevert(Vault.NotOwner.selector);
        BTC.pullBtc(id, 100, address(USDC));
    }
}

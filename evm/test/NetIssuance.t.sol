// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AllesFixture} from "./Alles.t.sol";

/// @title  §E326 — **ISSUANCE FLOW IS A DIFFERENT QUANTITY FROM SWAP FLOW, AND NOTHING MEASURED IT**
///
/// @notice `Core._bumpFlow` has exactly ONE call site, inside `Core.swap`. So `flowEwmaUsd` and
///         `Core.netFlowUsd` (§E320) both measure basket ↔ volatile TRADING travel, and the mint/redeem
///         of basket shares — Lyons & Viswanath-Natraj's `θ̇s`, the state variable their whole model
///         turns on — had **no register anywhere in `evm/src`**. `baseRate`, the Liquity-style
///         redemption velocity toll, was the only one and was deleted.
///
///         🔴 **THE CONTROL IS THE POINT, NOT THE HEADLINE.** "`netIssuanceUsd` moved" would also be
///         true of a counter that just added everything. What has to be shown is (a) the two legs land
///         on OPPOSITE sides of zero, and (b) `Core.netFlowUsd` — the register that already existed —
///         **does not move at all** on a mint or a redeem. Without (b) there would be no evidence the
///         new register measures anything the old one did not.
contract NetIssuanceTest is AllesFixture {

    function _mint(address who, uint usdc6) internal {
        vm.startPrank(who);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(who, usdc6, address(USDC), 0);
        vm.stopPrank();
    }

    /// A MINT is primary-market inflow: shares are created, so the counter rises.
    /// Scaled to 18-dec at the bump, so $1,000 of 6-dec USDC must register as ~1000e18, NOT 1000e6.
    function test_E326_MintDrivesNetIssuancePositive() public {
        int256 before = AUX.netIssuanceUsd();
        _mint(User01, 1_000 * USDC_PRECISION);
        int256 afterMint = AUX.netIssuanceUsd();

        emit log_named_int("netIssuanceUsd before", before);
        emit log_named_int("netIssuanceUsd after MINT", afterMint);
        assertGt(afterMint, before, "a mint is primary-market inflow and must raise netIssuanceUsd");

        // THE DECIMAL CONTROL. A missing 1e12 lift is the single most common bug in this repo, and it
        // would still pass the assertion above. Pin the BASE, not just the direction.
        uint moved = uint(afterMint - before);
        assertGt(moved, 900e18,  "the mint leg is not 18-dec -- a 1e12 lift is missing");
        assertLt(moved, 1_100e18, "the mint leg overshot 18-dec -- the lift is applied twice");
    }

    /// A REDEEM is primary-market outflow: shares are burned, so the counter falls.
    function test_E326_RedeemDrivesNetIssuanceNegative() public {
        _mint(User01, 3_000 * USDC_PRECISION);
        vm.warp(block.timestamp + 35 days);                 // mature the vintage so the burn can happen
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(0)));

        int256 beforeRedeem = AUX.netIssuanceUsd();
        vm.prank(User01);
        AUX.redeem(100 * WAD);
        int256 afterRedeem = AUX.netIssuanceUsd();

        emit log_named_int("netIssuanceUsd before REDEEM", beforeRedeem);
        emit log_named_int("netIssuanceUsd after  REDEEM", afterRedeem);
        assertLt(afterRedeem, beforeRedeem, "a redeem is primary-market outflow and must lower it");
        assertEq(beforeRedeem - afterRedeem, int256(100 * WAD),
            "the redeem leg burns 18-dec QU!D and must register exactly that, unscaled");
    }

    /// 🔴 THE DISCRIMINATOR. The register that already existed must NOT respond to issuance — otherwise
    /// this one is redundant and §E326's whole premise ("two different flows") is wrong.
    function test_E326_SwapFlowRegistersDoNotSeeIssuanceAtAll() public {
        int256 swapBefore = CORE.netFlowUsd();
        uint   ewmaBefore = CORE.flowEwmaUsd();

        _mint(User01, 5_000 * USDC_PRECISION);
        vm.warp(block.timestamp + 35 days);
        vm.mockCall(address(AUX),
            abi.encodeWithSignature("getDepegSeverityBps(address)", address(USDC)), abi.encode(uint(0)));
        vm.prank(User01);
        AUX.redeem(100 * WAD);

        emit log_named_int ("Core.netFlowUsd  after mint+redeem", CORE.netFlowUsd());
        emit log_named_uint("Core.flowEwmaUsd after mint+redeem", CORE.flowEwmaUsd());
        emit log_named_int ("AUX.netIssuanceUsd                ", AUX.netIssuanceUsd());

        assertEq(CORE.netFlowUsd(), swapBefore,
            "issuance moved the SWAP register -- the two quantities are not separable and E326 is wrong");
        assertLe(CORE.flowEwmaUsd(), ewmaBefore,
            "issuance bumped the swap-volume EWMA -- _bumpFlow is reachable from a path other than swap");
        assertTrue(AUX.netIssuanceUsd() != 0, "premise: the issuance register did move");
    }

    /// CONTROL — would this look the same if I were wrong? A swap must move the SWAP register and leave
    /// issuance untouched. Without this, "issuance doesn't move swap flow" could simply mean neither
    /// register works in this fixture.
    function test_E326_ControlASwapMovesSwapFlowAndNotIssuance() public {
        vm.prank(User02); ETH.deposit{value: 300 ether}(0, User02);
        int256 issuanceBefore = AUX.netIssuanceUsd();
        int256 swapBefore     = CORE.netFlowUsd();

        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        AUX.swap(address(USDC), address(WETH), true, 20_000 * USDC_PRECISION, 0, true);
        vm.stopPrank();

        emit log_named_int("Core.netFlowUsd   moved by", CORE.netFlowUsd() - swapBefore);
        emit log_named_int("AUX.netIssuanceUsd moved by", AUX.netIssuanceUsd() - issuanceBefore);
        assertTrue(CORE.netFlowUsd() != swapBefore, "control: a swap must move the swap register");
        assertEq(AUX.netIssuanceUsd(), issuanceBefore,
            "a swap moved the ISSUANCE register -- the mint/redeem legs are catching trading flow");
    }
}

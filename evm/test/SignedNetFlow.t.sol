// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AllesFixture} from "./Alles.t.sol";

/// @title §E320-SSRN — **THE SIGN SURVIVES THE SWAP. `flowEwmaUsd` CANNOT TELL THESE APART.**
///
/// @notice Lyons & Viswanath-Natraj (SSRN 3508006) build their whole empirical case on SIGNED order
///         flow — `OF = Σ V·(1[buy] − 1[sell])`, their eq. 25 — reconstructed from three exchanges'
///         tape. We produce the same quantity while settling a swap, and until §E320 we destroyed it
///         one line after computing it: `Core.swap` takes `uint(usdLeg < 0 ? -usdLeg : usdLeg)` and
///         hands the MAGNITUDE to `_bumpFlow`. `skewPremium` is `+=` only. So a range being drained
///         and a range being refilled were indistinguishable in stored state.
///
///         🔴 **THE CONTROL IS THE POINT OF THIS FILE, NOT THE HEADLINE ASSERTION.** "netFlowUsd
///         moved" proves nothing on its own — it would move for a counter that ignored direction
///         entirely. What has to be shown is that the two directions land on OPPOSITE SIDES of zero
///         while the existing unsigned instrument reports the same thing for both. Each test below
///         therefore checks the new counter AND asserts that `flowEwmaUsd` fails to discriminate.
contract SignedNetFlowTest is AllesFixture {

    function _seedInventory() internal {
        vm.prank(User02); ETH.deposit{value: 400 ether}(0, User02);
    }

    /// Buy the volatile leg for `usd6` of USDC and return the WETH the caller ends up holding.
    /// ⚠️ THE FILL PAYS IN NATIVE ETH, NOT WETH, AND THAT COST THIS FILE THREE FAILING PREMISES.
    /// `WETH.balanceOf(User01)` reads 0 after a buy that plainly succeeded, which looks exactly like
    /// a broken swap. `DrainProbe` already knew — it sums `User01.balance` and `WETH.balanceOf`
    /// (`nativeGot + wethGot`) — so the idiom existed and I did not copy it. Wrap the native half
    /// through WETH9's payable fallback so the sell leg has an ERC-20 to approve.
    function _buyVolatile(address who, uint usd6) internal returns (uint wethHeld) {
        uint nat0 = who.balance;
        uint w0   = WETH.balanceOf(who);
        AUX.swap(address(USDC), address(WETH), true, usd6, 0, true);
        uint nativeGot = who.balance - nat0;
        if (nativeGot > 0) {
            (bool ok,) = address(WETH).call{value: nativeGot}("");
            require(ok, "wrap failed");
        }
        wethHeld = WETH.balanceOf(who) - w0;
    }

    /// A BUY (dollars in, volatile out) is basket → volatile travel. USD ENTERS the pool, so the
    /// delta convention ("positive leaves the pool") makes `usdLeg` negative ⇒ `netFlowUsd` FALLS.
    /// In the paper's terms this is selling the stable side: their −OF.
    function test_E320_BuyingVolatileDrivesNetFlowNegative() public {
        _seedInventory();
        int256 before = CORE.netFlowUsd();

        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        AUX.swap(address(USDC), address(WETH), true, 50_000 * USDC_PRECISION, 0, true);
        vm.stopPrank();

        int256 afterBuy = CORE.netFlowUsd();
        emit log_named_int("netFlowUsd before", before);
        emit log_named_int("netFlowUsd after BUY", afterBuy);
        assertLt(afterBuy, before,
            "a buy is basket->volatile travel and must push netFlowUsd DOWN (their -OF)");
    }

    /// A SELL (volatile in, dollars out) is volatile → basket travel. USD LEAVES the pool, so
    /// `usdLeg` is positive ⇒ `netFlowUsd` RISES. Net buying pressure on the stable side: their +OF.
    function test_E320_SellingVolatileDrivesNetFlowPositive() public {
        _seedInventory();

        // Acquire the volatile leg first, then sell it back. The buy leg is measured and subtracted
        // so this test is about the SELL alone rather than the round trip.
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        uint got = _buyVolatile(User01, 50_000 * USDC_PRECISION);
        assertGt(got, 0, "premise: the buy delivered the volatile leg, else the sell below is vacuous");

        int256 beforeSell = CORE.netFlowUsd();
        WETH.approve(address(AUX), type(uint).max);
        AUX.swap(address(USDC), address(WETH), false, got, 0, true);   // forVolatile=false ⇒ SELL
        vm.stopPrank();

        int256 afterSell = CORE.netFlowUsd();
        emit log_named_int("netFlowUsd before SELL", beforeSell);
        emit log_named_int("netFlowUsd after  SELL", afterSell);
        assertGt(afterSell, beforeSell,
            "a sell is volatile->basket travel and must push netFlowUsd UP (their +OF)");
    }

    /// 🔴 THE DISCRIMINATOR, AND THE REASON THE COUNTER EARNS ITS SLOT (standing rule 3). Two
    /// opposite flows of comparable size are run in separate arms. The UNSIGNED instrument that
    /// already existed moves the SAME WAY for both — it is fed `|usdLeg|` — so on its evidence the
    /// two states are identical. The signed one separates them across zero. A failure of the old
    /// instrument to notice a one-directional drain is exactly the SILENT kind.
    function test_E320_UnsignedFlowCannotTellTheTwoDirectionsApart() public {
        _seedInventory();

        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        WETH.approve(address(AUX), type(uint).max);

        uint  flow0   = CORE.flowEwmaUsd();
        int256 signed0 = CORE.netFlowUsd();

        // ARM A — buy.
        uint got = _buyVolatile(User01, 50_000 * USDC_PRECISION);
        uint  flowAfterBuy   = CORE.flowEwmaUsd();
        int256 signedAfterBuy = CORE.netFlowUsd();

        // ARM B — sell the proceeds straight back, comparable notional.
        assertGt(got, 0, "premise: arm A delivered the volatile leg");
        AUX.swap(address(USDC), address(WETH), false, got, 0, true);   // forVolatile=false ⇒ SELL
        uint  flowAfterSell   = CORE.flowEwmaUsd();
        int256 signedAfterSell = CORE.netFlowUsd();
        vm.stopPrank();

        emit log_named_uint("flowEwmaUsd  start / buy / sell -- start", flow0);
        emit log_named_uint("flowEwmaUsd  after buy ", flowAfterBuy);
        emit log_named_uint("flowEwmaUsd  after sell", flowAfterSell);
        emit log_named_int ("netFlowUsd   after buy ", signedAfterBuy);
        emit log_named_int ("netFlowUsd   after sell", signedAfterSell);

        // The unsigned instrument rose on BOTH legs: it is a magnitude, so opposite travel adds.
        assertGe(flowAfterBuy,  flow0,        "control: the unsigned EWMA rises on a buy");
        assertGe(flowAfterSell, flowAfterBuy, "control: it rises AGAIN on the opposite trade -- it cannot subtract");

        // The signed one moved in opposite directions on the two legs. That is the whole claim.
        assertLt(signedAfterBuy,  signed0,        "buy must move the signed counter down");
        assertGt(signedAfterSell, signedAfterBuy, "the opposite trade must move it back up");
    }

    /// CONTROL — would this look the same if I were wrong? A round trip must leave the signed
    /// counter NEARER zero than the one-way leg did, because the two legs carry opposite signs.
    /// If `netFlowUsd` were secretly accumulating magnitude, the round trip would be FARTHER out.
    /// ⚠️ Deliberately not asserted as "returns to zero": the swapper pays the skew premium on both
    /// legs, so the dollars back out are strictly fewer than the dollars in and the residual is a
    /// REAL asymmetry, not noise. Asserting exact cancellation would be asserting a zero-fee AMM.
    function test_E320_ControlRoundTripMovesBackTowardZeroNotFurtherOut() public {
        _seedInventory();
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        WETH.approve(address(AUX), type(uint).max);

        int256 start = CORE.netFlowUsd();
        uint got = _buyVolatile(User01, 50_000 * USDC_PRECISION);
        int256 oneWay = CORE.netFlowUsd();
        assertGt(got, 0, "premise: the buy delivered the volatile leg");
        AUX.swap(address(USDC), address(WETH), false, got, 0, true);   // forVolatile=false ⇒ SELL
        int256 roundTrip = CORE.netFlowUsd();
        vm.stopPrank();

        uint distOneWay    = uint(oneWay    < start ? start - oneWay    : oneWay    - start);
        uint distRoundTrip = uint(roundTrip < start ? start - roundTrip : roundTrip - start);
        emit log_named_uint("|one-way    - start|", distOneWay);
        emit log_named_uint("|round-trip - start|", distRoundTrip);
        assertLt(distRoundTrip, distOneWay,
            "the return leg must CANCEL, not add -- if it adds, the counter is unsigned in disguise");
    }
}

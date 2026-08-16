// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Alles} from "./Alles.t.sol";

/// @notice End-to-end verification of the TWAP-anchor deadlock FIX (A+B+C).
///
/// BEFORE: `getTWAPforAsset` REVERTED `TwapDeviation` when the internal 30-min
/// TWAP diverged >5% from Chainlink. The internal TWAP only moves via a
/// swap/repack that ALSO route through `getTWAPforAsset`, so a fast >5% move
/// froze the protocol — and `redeemAsBody` read the price unconditionally, so
/// even fully stable-backed QUI redemption reverted (peg floor bricked).
///
/// AFTER:
///  (A) redeem fetches the ETH TWAP lazily (try/catch → price=0 ⇒ stables-only).
///  (C) getTWAPforAsset RETURNS fresh Chainlink when the internal TWAP is stale
///      (>5% off) instead of reverting — callers price against reality.
///  (B) a permissionless `Vogue.reseat()` MOVES the stale curve spot onto the
///      oracle price and re-ranges, so swaps (whose 50bps guard compares the
///      curve spot to the oracle) unblock at the real price.
///
/// Simulated fast crash = Chainlink mocked 10% below the fresh internal TWAP.
///
/// Run isolated:
///   forge test --match-contract TwapAnchorDeadlock -vv
contract TwapAnchorDeadlockTest is Alles {
    function _mockFeed(address feed, int256 answer, uint80 round) internal {
        vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(feed, abi.encodeWithSignature("latestRoundData()"),
            abi.encode(round, answer, uint(0), block.timestamp, round));
    }

    function testTwapAnchorDeadlock_FullFix() public {
        // ── Arrange (anchor not yet wired) ──
        V4.deposit{value: 100 ether}(0, address(this));
        deal(address(USDC), address(this), 60_000e6);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(address(this), 50_000e6, address(USDC), 0);
        vm.warp(block.timestamp + 40 days); // mature the batch

        uint pE = AUX.getTWAPforAsset(address(WETH), 1800);
        assertGt(pE, 0, "internal ETH TWAP must be seeded");
        bool t0isUSD = V4.token1isVol(); // getPrice's token0isUSD == token1isVol

        // ── Baseline: a FAIR anchor keeps the internal (DEX-native) TWAP ──
        // WETH 18-dec; feed 8-dec; ext18 = ans*1e10. Fair => ans == pE/1e10.
        address feed = address(0x7A33FEED);
        int256 fair = int256(pE / 1e10);
        _mockFeed(feed, fair, 1);
        AUX.setAssetFeed(address(WETH), feed); // pin-once
        assertEq(AUX.getTWAPforAsset(address(WETH), 1800), pE,
            "within 5%: keep internal TWAP (normal swaps unaffected)");

        // ── Act: fast crash — Chainlink 10% below the fresh internal TWAP. ──
        int256 crashed = int256((pE / 1e10) * 90 / 100);
        _mockFeed(feed, crashed, 2);

        // (C) The oracle read NO LONGER reverts; returns ≈Chainlink, not the
        //     stale internal TWAP.
        assertApproxEqRel(AUX.getTWAPforAsset(address(WETH), 1800), (pE * 90) / 100, 1e15,
            "stale TWAP -> getTWAPforAsset returns Chainlink (no revert)");

        // (A)+(C) QUI REDEMPTION still delivers stable backing during the crash —
        //         peg floor alive (previously reverted TwapDeviation).
        _healDepeg(address(USDC));
        _healDepeg(address(DAI));
        uint qdBefore = QUID.balanceOf(address(this));
        uint usdcBefore = USDC.balanceOf(address(this));
        AUX.redeem(1_000e18);
        assertGt(USDC.balanceOf(address(this)) - usdcBefore, 0,
            "crash: stable-backed redemption still DELIVERS (peg floor alive)");
        assertEq(qdBefore - QUID.balanceOf(address(this)), 1_000e18,
            "crash: redeem burns exactly the redeemed QUI");

        // (B) AUTO-HEAL: the swap SELF-HEALS — its repack-first detects the stale
        //     curve (internal TWAP >5% off Chainlink) and moves the spot onto the
        //     oracle before executing, so the swap succeeds at the real price with
        //     NO manual poke and NO freeze.
        uint usdcBeforeSwap = USDC.balanceOf(address(this));
        AUX.swap{value: 1 ether}(address(USDC), address(WETH), false, 0, 0);
        assertGt(USDC.balanceOf(address(this)) - usdcBeforeSwap, 0,
            "swap auto-heals during the crash (executes at the Chainlink price)");

        // the curve spot is now on the oracle (the auto-reseat moved it).
        (uint priceAfter,) = CORE.poolStats();   // §DETICK: a price, not a sqrt -- the name said otherwise
        assertApproxEqRel(priceAfter, (pE * 90) / 100, 3e16, // 3%
            "auto-reseat moved the curve spot onto the oracle price");

        // the permissionless reseat poke is a safe no-op once aligned.
        V4.reseat();
    }
}

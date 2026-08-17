// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevCascadeProbe} from "./LevCascade.t.sol";

interface IErc20Bal { function balanceOf(address) external view returns (uint); }

/// @notice BUFFER-SWAP INVARIANT PROBE (post-fold). The old audit worry — "a market swap consumes the debt-funded
///   BUFFER's mock-USD but pays REAL basket stables while a SEPARATE `POOLED_USD_ETH_LEV` counter goes stale, which
///   could be leveraged into an over-mint later" — is now STRUCTURALLY impossible: there is no `_LEV` counter. The
///   full-2x buffer folds into the ONE `POOLED_USD` slice, and `committedUsd18` recovers the pure equity claim
///   by subtracting the LP's LIVE leverage debt (`committed = in-range USD - totalDebtUsd`, buffer == debt exactly).
///   Nothing a swap touches can desync, because the debt is read live from the LevManager, not stored in Core.
///
///   Reuses LevCascadeProbe's REAL-Morpho + REAL-Vogue-band fork scaffolding (helpers/fields inherited).
contract BufferSwapDrain is LevCascadeProbe {
    /// @dev committed must equal (both pools' BASKET-SUPPLIED depth) minus the live ETH leverage
    ///      debt, at every step. (No BTC lev here ⇒ the BTC band's debt term is 0.)
    ///      §#12 RE-DERIVED: the fold's INTENT is unchanged — *committed excludes the debt-funded
    ///      buffer* — but the quantity it is measured against moved from CURVE INVENTORY
    ///      (`POOLED_USD_*`, which a swap moves) to BASKET CONTRIBUTION (`basketUsd*`, which only
    ///      `addLiq`/burn moves). Asserting against the curve leg now would pin the very coupling
    ///      #12 removed: it would demand that an LP's sale proceeds still count as basket depth.
    function _assertCommittedIdentity(string memory tag) internal {
        uint pooled18 = (CORE.basketUsd() + CORE.basketUsd()) * 1e12;
        uint debt18   = lm.totalDebtUsd();
        uint expect   = pooled18 > debt18 ? pooled18 - debt18 : 0;
        assertEq(CORE.committedUsd18(), expect, tag);
    }

    function test_BufferConsumingSwap_CommittedTracksLiveDebt_NoDrain() public {
        _setupLev();
        EV.setLevManager(address(lm));
        // Thick shared band so the swaps clear the 50bps manip guard.
        vm.deal(address(this), 40 ether);
        V4.deposit{value: 20 ether}(0, address(this));

        // Full-2x levered position ⇒ a real debt-funded buffer folded into POOLED_USD.
        _openAtEntry(lps[0], 5 ether);
        _rallyBand(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        assertGt(venue.debtOf(lps[0]), 0, "precondition: levered debt > 0");
        _calmVol();
        V4.syncLev(lps[0]);                                   // mints the GROSS (2x) depth ⇒ buffer USD → POOLED_USD
        assertGt(lm.totalDebtUsd(), 0, "precondition: live leverage debt > 0 (the folded buffer)");
        _assertCommittedIdentity("FOLD: committed == in-range USD - live debt (pre-swap)");

        // ── snapshot BEFORE the buffer-consuming swaps ──
        uint pooledUsd0 = CORE.POOLED_USD();
        uint tvl0       = _tvl();
        (, uint liquid0) = AUX.checkBacking();
        uint px0        = AUX.getTWAPforAsset(address(WETH), 1800); // PRE-swap fair upper bound on the WETH input

        address swapper = User03;
        vm.deal(swapper, 40 ether);
        uint usdcBefore = IErc20Bal(address(USDC)).balanceOf(swapper);
        uint ethBefore  = swapper.balance;

        // Sell WETH into the USD-heavy post-rally band, hard, in bounded (<=50bps) steps.
        for (uint i; i < 24; i++) {
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px == 0) break;
            _setEthFeed(px / 1e10);
            vm.prank(swapper);
            try AUX.swap{value: 0.5 ether}(address(USDC), address(WETH), false, 0, 0) {} catch { break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
        }

        uint usdcOut = IErc20Bal(address(USDC)).balanceOf(swapper) - usdcBefore;
        uint ethIn   = ethBefore - swapper.balance;
        assertGt(usdcOut, 0, "the swaps DID pay real basket stables out (drain vector exercised)");
        assertLt(CORE.POOLED_USD(), pooledUsd0, "the swap drained the basket in-range USD slice");

        // ── the fold's identity STILL holds after the swap: no counter to desync ──
        _assertCommittedIdentity("FOLD: committed == in-range USD - live debt (POST-swap, drift-free)");

        // ── guard (A): backing invariant still holds (committed excludes the debt-funded buffer) ──
        (uint committed1, uint liquid1) = AUX.checkBacking();
        assertLe(committed1, liquid1, "(A) backing holds: committed (equity-only) <= real liquid TVL after the drain");

        // ── guard (B): the swapper SELF-FUNDED every stable it received (valued at the PRE-swap price px0) ──
        uint ethInUsdc6 = ethIn * px0 / 1e18 / 1e12;
        assertLe(usdcOut, ethInUsdc6,
            "(B) SELF-FUNDING: stables paid out <= PRE-swap value of WETH paid in - no phantom buffer USD was paid");

        // ── net: no real basket drain (conserved net of the swapper's own self-funded input) ──
        assertGe(_tvl()  + ethInUsdc6 * 1e12 + 1e18, tvl0,   "no drain: basket TVL conserved net of input");
        assertGe(liquid1 + ethInUsdc6 * 1e12 + 1e18, liquid0, "no drain: real liquid conserved net of input");
    }

    /// @notice OVER-MINT PROBE — the sequel the audit demanded. Post-fold it is doubly settled: (1) the swap mints
    ///   NO QD, and (2) there is no stale `_LEV` for a later mint to feed on; committed is live. A real deposit made
    ///   AFTER the buffer-consuming swap brings its own backing and the committed<=liquid gate keeps holding.
    function test_BufferSwap_CannotBeLeveragedIntoOverMint() public {
        _setupLev();
        EV.setLevManager(address(lm));
        vm.deal(address(this), 40 ether);
        V4.deposit{value: 20 ether}(0, address(this));
        _openAtEntry(lps[0], 5 ether);
        _rallyBand(_entryPrice(lps[0]), 0.2e18, 20, 8_000 * USDC_PRECISION);
        lm.rebalance(lps[0], 0);
        _calmVol();
        V4.syncLev(lps[0]);
        assertGt(lm.totalDebtUsd(), 0, "precondition: the debt-funded buffer (live debt) > 0");

        uint supply0 = QUID.totalSupply();

        // ── run the buffer-consuming swap ──
        address swapper = User03;
        vm.deal(swapper, 40 ether);
        for (uint i; i < 24; i++) {
            uint px = AUX.getTWAPforAsset(address(WETH), 1800); if (px == 0) break;
            _setEthFeed(px / 1e10);
            vm.prank(swapper);
            try AUX.swap{value: 0.5 ether}(address(USDC), address(WETH), false, 0, 0) {} catch { break; }
            vm.roll(block.number + 1); vm.warp(block.timestamp + 20 minutes);
        }

        // ── (1) the swap is QD-supply-NEUTRAL: no QD minted/burned by the drain ──
        assertEq(QUID.totalSupply(), supply0,
            "(1) the buffer-consuming swap mints/burns NO QD - no DIRECT over-mint");

        (uint committedPre, uint liquidPre) = AUX.checkBacking();
        assertLe(committedPre, liquidPre, "committed <= liquid holds after the swap");
        uint supplyPre = QUID.totalSupply();

        // ── the LATER MINT the audit worried about — reuse User01 (already voted in _setupLev) so it clears the
        //    Basket vote-gate; deposit a KNOWN real value INTO the post-swap state ──
        uint depositUsdc = 200_000 * USDC_PRECISION;
        deal(address(USDC), User01, depositUsdc);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        uint minted = QUID.mint(User01, depositUsdc, address(USDC), 0);
        vm.stopPrank();
        assertGt(minted, 0, "the post-swap mint executed");

        // ── (2) the mint brought its OWN backing: real `liquid` rose by ~the deposit ──
        (uint committedPost, uint liquidPost) = AUX.checkBacking();
        assertGe(liquidPost + 1e18, liquidPre + depositUsdc * 1e12,
            "(2) the deposit lifted real backing by ~its value - no supply grew off a phantom buffer");
        // ── (3) the committed<=liquid gate still holds after minting into the post-swap state ──
        assertLe(committedPost, liquidPost,
            "(3) backing gate intact after the post-swap mint - no phantom headroom was spent");
        // ── (4) supply grew ONLY by the mint ──
        assertEq(QUID.totalSupply(), supplyPre + minted,
            "(4) supply grew by exactly the mint - nothing minted against the (now-nonexistent) stale buffer");
    }
}

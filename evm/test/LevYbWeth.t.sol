// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Reuse the real-fork weETH probe wholesale: it brings the mainnet fork (via Alles), the band/rally/crash
// helpers (all collateral-AGNOSTIC — they move the band, not the venue), the constants (MORPHO, ADAPTIVE_IRM,
// CL_ETH_USD, LP), and the Morpho/ERC20/Chainlink interfaces + MarketParams.
import "./LevYbReal.t.sol";

/// Morpho IOracle for a PLAIN-WETH collateral market. price() = collateral(WETH,18-dec) -> loan(USDC,6-dec),
/// 1e36-scaled: `collateral * price / 1e36 = loan`. WETH == ETH, so NO ether.fi rate leg (unlike the weETH
/// oracle) — just REAL Chainlink ETH/USD. Crash = override the SAME real feed (moves this AND the band oracle).
contract RealRateWethMorphoOracle {
    IChainlinkFeedT public immutable ETH_USD;
    constructor(address ethUsd) { ETH_USD = IChainlinkFeedT(ethUsd); }
    function price() external view returns (uint256) {
        (, int256 p,,,) = ETH_USD.latestRoundData();     // ETH/USD, 8-dec, REAL feed
        uint256 ethUsd1e18 = uint256(p) * 1e10;          // 8-dec -> 1e18
        return ethUsd1e18 * 1e6;                          // Morpho 1e36 scale (WETH 18-dec -> USDC 6-dec)
    }
}

/// @notice REAL-FORK proof of the ADDITIVE plain-WETH (non-LST) collateral branch on the SAME `LevManager`.
///   Mirrors `LevYbRealProbe` (real Morpho Blue market via permissionless createMarket + real Chainlink oracle
///   + the folded SOR legs + the REAL Vogue band), but with WETH collateral: the manager DERIVES the WETH type
///   from the venue's collateral token, so it values 1:1, skips the ether.fi weETH<->WETH mint/redeem, and
///   supplies/sells WETH directly. Proves: open supplies WETH, lever-up borrows USDC + buys WETH via SOR (no
///   mint), the GROSS collateral flows into the band 1:1 + the debt is buffered, and close unwinds cleanly.
contract LevYbWethProbe is LevYbRealProbe {
    LevManager wlm;
    MorphoEscrowVenue wvenue;
    address wOracle;

    function _setupMorphoWeth() internal {
        _seedBasket();
        rpx = AUX.getTWAPforAsset(address(WETH), 1800);
        RealRateWethMorphoOracle oracle = new RealRateWethMorphoOracle(CL_ETH_USD); // REAL Chainlink, no LST rate
        wOracle = address(oracle);
        // Plain-WETH collateral market: same real ADAPTIVE_IRM + 0.86 LLTV the canonical Morpho WETH/USDC
        // markets run; a fresh id (custom oracle) so createMarket never collides with a live market.
        MarketParams memory mp = MarketParams({
            loanToken: address(USDC), collateralToken: address(WETH),
            oracle: address(oracle), irm: ADAPTIVE_IRM, lltv: 0.86e18
        });
        IMorphoTest morpho = IMorphoTest(MORPHO);
        morpho.createMarket(mp);
        // Seed USDC borrow liquidity (this contract is the lender).
        deal(address(USDC), address(this), 2_000_000 * USDC_PRECISION);
        IERC20R(address(USDC)).approve(MORPHO, 2_000_000 * USDC_PRECISION);
        morpho.supply(mp, 2_000_000 * USDC_PRECISION, 0, address(this), "");
        // Wire against the real venue + REAL Vogue band (V4) as the E0 / sold-fraction source — no MockBandHost.
        // NB: the weeth ctor arg is unused for a WETH position (RATE is never called), but must be a real token.
        wlm = new LevManager(WEETH, address(AUX), address(WETH), address(this), address(QUID));
        wvenue = new MorphoEscrowVenue(MORPHO, mp, address(wlm));
        { address[] memory vs = new address[](1); vs[0] = address(wvenue); wlm.init(address(V4), MORPHO, vs); }
        vm.prank(LP);
        morpho.setAuthorization(address(wvenue), true); // one-time Morpho-native isolation
    }

    function _openWethLp() internal {
        // REAL band position (the E0 IL base) — bandEthOf(LP) == 5 ETH deposit, read live from V4.
        vm.deal(LP, 6 ether);
        vm.prank(LP); V4.deposit{value: 5 ether}(0, LP, 3);   // venue 3 = all-Galaxy (no ether.fi offramp noise)
        // Equity is PLAIN WETH (not weETH): give the LP 5 WETH.
        deal(address(WETH), LP, 5 ether);
        uint[] memory mins = new uint[](8);
        vm.startPrank(LP);
        IERC20R(address(WETH)).approve(address(wlm), 5 ether);
        wlm.openLev(5000, ILevVenue(address(wvenue)), 5 ether, mins); // cap = 2x, opens at zero leverage
        vm.stopPrank();
        // Real rally: buy ETH out of the band so it sells ETH => real IL accrues since the pinned entry.
        _rallyBand(_entrySqrt(wlm, LP), 0.2e18, 20, 8_000 * USDC_PRECISION);
        wlm.rebalance(LP, 0);         // lever up to the IL target (real Morpho USDC borrow + real Uniswap WETH buy)
    }

    /// @notice FULL real-venue e2e for PLAIN-WETH collateral: open (supply WETH) -> lever up (borrow USDC +
    ///   SOR-buy WETH, NO ether.fi mint) -> assert the GROSS collateral is in the band 1:1 and the debt buffers
    ///   net-equity -> close (sell WETH -> repay -> return WETH). Proves the additive branch end-to-end.
    function testReal_Weth_OpenLeverClose() public {
        _setupMorphoWeth();
        ETH.setLevManager(address(wlm));    // BACKING: vogueETH counts this WETH lev book
        _openWethLp();

        uint debt0 = wvenue.debtOf(LP);
        uint coll0 = wvenue.collateralOf(LP);
        emit log_named_uint("Morpho USDC debt after open+lever", debt0);
        emit log_named_uint("Morpho WETH collateral after open+lever", coll0);
        emit log_named_uint("LTV after open (bps)", wlm.getCurrentLtvBps(LP));
        assertGt(debt0, 0, "open+lever must take on real Morpho USDC debt");
        assertGt(coll0, 5 ether, "lever-up must grow WETH collateral beyond the 5 WETH equity");

        // GROSS collateral flows into the band 1:1 (WETH == ETH): grossCollateralEth == the raw WETH balance.
        assertEq(wlm.grossCollateralEth(LP), coll0, "WETH gross collateral valued 1:1 in ETH");
        assertEq(wlm.totalGrossCollateralEth(), coll0, "book gross collateral includes the WETH position");
        // Debt buffers net-equity: 0 < netEquity < gross, and the book debt is non-zero.
        uint netEq = wlm.netEquityEth(LP);
        assertGt(netEq, 0, "net-equity is positive");
        assertLt(netEq, coll0, "debt buffers gross above net-equity");
        assertEq(wlm.totalNetEquityEth(), netEq, "book net-equity includes the WETH position");
        assertGt(wlm.totalDebtUsd(), 0, "book debt (the buffer USD ceiling) includes the WETH position");

        // The band actually counts it — but against the SAME composition of ETH backing the protocol
        // itself uses, `vogueETH + totalBuffer` (VogueLib.addLiq: `IAux(aux).vogueETH() + grossBuffer`).
        // `vogueETH` counts a levered position at NET equity BY DESIGN (§A.5c: "lev net equity is
        // solvency backing, counted in vogueETH as net"); the debt-funded remainder is tracked
        // separately in `totalBuffer` and excluded from equity precisely so it cannot be withdrawn as
        // if it were the LP's. So asserting `vogueETH >= GROSS` asked one term to cover two, and failed
        // by exactly the debt (measured: vogueETH 5.920 vs gross 7.506, and netEquity == vogueETH).
        assertGe(AUX.vogueETH() + V4.totalBuffer(), coll0,
            "ETH backing (vogueETH net + totalBuffer gross) counts the WETH gross collateral");

        // Close unwinds cleanly. Realign the band oracle to real first (the rally elevated the mock band feed;
        // the WETH->USDC close leg executes on REAL Uniswap) — same fork-artifact fix the weETH close test uses.
        _realignBandToReal();
        uint lpWethBefore = IERC20R(address(WETH)).balanceOf(LP);
        vm.prank(LP);
        wlm.closeLev(0);    // sell WETH -> repay all USDC debt -> return the remaining WETH

        assertEq(wvenue.debtOf(LP), 0, "close: real Morpho USDC debt fully repaid");
        assertEq(wvenue.collateralOf(LP), 0, "close: real Morpho WETH collateral fully withdrawn");
        assertGt(IERC20R(address(WETH)).balanceOf(LP), lpWethBefore, "close: remaining WETH returned to the LP");
        assertEq(wlm.grossCollateralEth(LP), 0, "close: position drops out of the band");
        (,,,,, bool stillOpen) = wlm.pos(LP);
        assertTrue(!stillOpen, "close: position deleted");
    }

    /// @notice #113 — the MISSING ETH-side de-lever test. `LevManager.swapOutDelever` (`:799`) mirrors
    ///         `BtcLevManager.swapOutDelever` but DELIVERS WETH instead of un-encumbering sats, and until
    ///         now ONLY the BTC mirror was exercised (`VBtcLevFeeLane::testReal_DeliverSideDelever_...`).
    ///         The impl has been live since LevManager:781-810; this closes the test half.
    ///
    ///         The money-path invariant under test (same seven properties the BTC mirror asserts):
    ///         the Vault pre-transfers `stableUsd` of the swap's OWN proceeds to the venue, the manager
    ///         repays the LP's debt with it, frees EXACTLY the repaid value of collateral and delivers it
    ///         as WETH. VALUE-NEUTRAL: -collateral -debt of equal oracle value, so net-equity is
    ///         preserved and LTV can only improve. Real Morpho WETH/USDC market, real Chainlink oracle,
    ///         real Vogue band — no mocks.
    function testReal_DeleverEthBacking_SwapOutTapsLeveredSlice() public {
        _setupMorphoWeth();
        _openWethLp();

        uint debtBefore = wvenue.debtOf(LP);
        uint collBefore = wvenue.collateralOf(LP);
        uint netBefore  = wlm.netEquityEth(LP);
        uint ltvBefore  = wlm.getCurrentLtvBps(LP);
        assertGt(debtBefore, 0, "position carries real Morpho USDC debt (levered by _openWethLp)");
        assertGt(collBefore, 0, "position holds real WETH collateral");

        // De-lever a quarter of the debt. The Vault would pre-transfer the swap's own proceeds; here the
        // test plays the Vault, so fund the venue with that stable directly (same custody the real settle
        // uses -- ILevVenue takes the stable IN before repay).
        // UNITS: `debtOf` returns the venue's NATIVE stable decimals (Morpho borrow assets = USDC 6-dec),
        // NOT USD 1e18. `swapOutDelever` takes USD 1e18 and runs it through `LevMath._fromUsd`, which
        // divides by 1e12 — so passing the raw 6-dec debt floored BOTH the repay and the `deal` to zero.
        uint debtUsd18  = debtBefore * 1e12;                       // USDC 6-dec -> USD 1e18
        uint repayUsd18 = debtUsd18 / 4;                           // de-lever a quarter of the debt
        uint repayUsdc  = repayUsd18 / 1e12;                       // back to 6-dec to fund the venue
        deal(address(USDC), address(wvenue), repayUsdc);

        address swapper = address(0xE711);
        uint swapperWethBefore = IERC20R(address(WETH)).balanceOf(swapper);

        // Gated to the band: vogueSyncHook == address(V4) (set by wlm.init in _setupMorphoWeth).
        vm.prank(address(V4));
        (uint usedUsd, uint wethDelivered) = wlm.swapOutDelever(LP, repayUsd18, swapper, 0);

        // (a) It actually fired, and delivered WETH to the swapper (not to the LP, not stranded).
        assertGt(usedUsd, 0, "repaid a real USD amount from the pre-transferred stable");
        assertGt(wethDelivered, 0, "freed collateral was DELIVERED as WETH (the ETH-side difference vs BTC)");
        assertEq(IERC20R(address(WETH)).balanceOf(swapper) - swapperWethBefore, wethDelivered,
            "the swapper received exactly the reported WETH");

        // (b) DE-LEVERED: BOTH debt and collateral fell (equal oracle value removed).
        assertLt(wvenue.debtOf(LP), debtBefore, "debt reduced -- the swap's own proceeds repaid it");
        assertLt(wvenue.collateralOf(LP), collBefore, "collateral reduced -- WETH freed to deliver");
        assertApproxEqRel(collBefore - wvenue.collateralOf(LP), wethDelivered, 0.02e18,
            "collateral freed ~= WETH delivered (nothing retained in the venue)");

        // (c) VALUE-NEUTRAL: net-equity preserved. This is THE #113 invariant -- a de-lever that moved
        //     net-equity would be silently taxing or subsidising the LP on someone else's swap.
        assertApproxEqRel(wlm.netEquityEth(LP), netBefore, 0.03e18,
            "net-equity preserved (value-neutral: -collateral -debt of equal value)");

        // (d) LTV IMPROVES -- removing ~1:1 value from a levered position lowers the ratio.
        assertLe(wlm.getCurrentLtvBps(LP), ltvBefore, "LTV improved (LP only ever DE-levers here)");

        // (e) NO PHANTOM band depth behind the delivered WETH: the levered band slice must not exceed the
        //     LP's live net-equity, which would double-count the ETH just handed to the swapper.
        assertLe(V4.levPooled(LP), wlm.netEquityEth(LP) + 1e12,
            "levered band depth <= net-equity (no phantom depth behind delivered ETH)");

        // (f) The position stays OPEN (partial de-lever) so the keeper can re-lever next tick.
        (,,,,, bool open) = wlm.pos(LP);
        assertTrue(open, "partial de-lever keeps the position open for the keeper to re-lever");
    }
}

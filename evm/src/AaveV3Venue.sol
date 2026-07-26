// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevVenueBase, ILevERC20} from "./imports/LevVenueBase.sol";

/// ── Aave V3 Pool surface this adapter needs. Signatures proven against the LIVE Aave V3 Pool by the (tested)
///    Amp.sol integration: supply(asset,amt,onBehalf,ref) / borrow(asset,amt,rateMode,ref,onBehalf) /
///    repay(asset,amt,rateMode,onBehalf) / withdraw(asset,amt,to). V3 keys a position by the CALLER (no
///    sub-account / on-behalf-borrow), so per-LP isolation uses a per-LP escrow (mirror of AaveV4Venue).
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
}
/// @dev Aave's ProtocolDataProvider — the PROVEN read Amp.sol used (`getReserveTokensAddresses`). Its per-asset
///      `getUserReserveData` returns the CURRENT (already index-scaled, block-fresh, underlying-unit) aToken balance
///      and variable debt DIRECTLY — no vToken.balanceOf, no hardcoded reservesList index, one asset per call
///      (cheap on the on-chain vogueBTC sum). This is why we read positions here and not off the raw tokens.
interface IAaveV3DataProvider {
    function getUserReserveData(address asset, address user) external view returns (
        uint256 currentATokenBalance, uint256 currentStableDebt, uint256 currentVariableDebt,
        uint256 principalStableDebt, uint256 scaledVariableDebt, uint256 stableBorrowRate,
        uint256 liquidityRate, uint40 stableRateLastUpdated, bool usageAsCollateralEnabled);
}

/// @title  AaveV3Escrow — a single LP's ISOLATED Aave V3 position, owned by the venue (mirror of AaveV4Escrow)
/// @notice Aave V3, like V4, keys a position by the CALLER and has no sub-account/on-behalf-borrow, so the only way
///         one LP's liquidation can never touch another's is a per-LP escrow. VARIABLE-rate borrow (mode 2).
contract AaveV3Escrow {
    address    public immutable VENUE;
    IAaveV3Pool public immutable POOL;
    address    public immutable COLLATERAL;
    address    public immutable STABLE;
    uint256    internal constant VARIABLE_RATE = 2;   // Aave V3 interestRateMode

    error OnlyVenue();
    modifier onlyVenue() { if (msg.sender != VENUE) revert OnlyVenue(); _; }

    constructor(IAaveV3Pool pool, address coll, address stable) {
        VENUE = msg.sender;
        POOL = pool; COLLATERAL = coll; STABLE = stable;
        // Max-approve the POOL once: supply/repay pull the tokens via transferFrom in the Pool's context.
        ILevERC20(coll).approve(address(pool), type(uint256).max);
        ILevERC20(stable).approve(address(pool), type(uint256).max);
    }

    /// Supply `amt` collateral (already transferred in by the venue) → the escrow's own Aave account, marked as
    /// collateral (V3 does NOT auto-enable supplied assets as collateral; idempotent on later top-ups).
    function supplyColl(uint256 amt) external onlyVenue {
        POOL.supply(COLLATERAL, amt, address(this), 0);
        POOL.setUserUseReserveAsCollateral(COLLATERAL, true);
    }

    /// Borrow `amt` stable (variable rate) against this account, forward to `to` (venue → MANAGER). Returns delivered.
    function borrowStable(uint256 amt, address to) external onlyVenue returns (uint256 got) {
        uint256 bef = ILevERC20(STABLE).balanceOf(address(this));
        POOL.borrow(STABLE, amt, VARIABLE_RATE, 0, address(this));
        got = ILevERC20(STABLE).balanceOf(address(this)) - bef;
        if (got > 0) ILevERC20(STABLE).transfer(to, got);
    }

    /// Repay `amt` stable (already transferred in by the venue). Returns ASSETS actually spent (balance delta).
    function repayStable(uint256 amt) external onlyVenue returns (uint256 spent) {
        uint256 bef = ILevERC20(STABLE).balanceOf(address(this));
        POOL.repay(STABLE, amt, VARIABLE_RATE, address(this));
        spent = bef - ILevERC20(STABLE).balanceOf(address(this));
    }

    /// Withdraw `amt` collateral straight to `to` (venue → MANAGER). V3's withdraw sends to `to` and returns the amount.
    function withdrawColl(uint256 amt, address to) external onlyVenue returns (uint256 got) {
        got = POOL.withdraw(COLLATERAL, amt, to);
    }
}

/// @title  AaveV3Venue — per-LP isolated Aave V3 borrow venue as an `ILevVenue`
/// @notice The Aave V3 sibling of `AaveV4Venue`/`EulerEscrowVenue`/`MorphoEscrowVenue` (same `ILevVenue`, so the
///         managers stay venue-agnostic). Collateral (WBTC/vBTC/weETH) supplied, `stable()` (USDC) borrowed on Aave
///         V3 — the DEEPEST WBTC/USDC book (data-verified 2026-07: ~$14–19B TVL, deepest liquidity, vs Morpho's
///         thin ~$14M-avail isolated market), so the SPA picks it for sizeable positions. ISOLATION: each LP gets
///         its own `AaveV3Escrow`; a liquidation hits only that escrow, never another LP and never the QU!D basket.
///
///         POSITION READS use the ProtocolDataProvider's per-asset `getUserReserveData` (Amp.sol's PROVEN source):
///         `currentVariableDebt` / `currentATokenBalance` are the exact block-fresh underlying-unit amounts — no
///         raw vToken/aToken balanceOf, no hardcoded reservesList index, one asset per call (cheap for vogueBTC).
///
///         Custody (per ILevVenue): MANAGER sends collateral/stable to the venue before supply/repay; the venue
///         routes them through the LP's escrow and forwards borrowed stable / withdrawn collateral back to MANAGER.
contract AaveV3Venue is LevVenueBase {
    IAaveV3Pool         public immutable POOL;
    IAaveV3DataProvider public immutable DATA;         // ProtocolDataProvider (per-asset current-balance reads)
    address             public immutable COLLATERAL;
    uint256             public immutable LIQ_THRESHOLD_BPS; // collateral reserve liquidation threshold (Aave gov param)

    mapping(address => AaveV3Escrow) public escrowOf; // lp → isolated Aave account (0 = none yet)

    /// @param pool Aave V3 Pool. @param dataProvider Aave V3 ProtocolDataProvider (per-asset position reads).
    /// @param coll collateral underlying. @param stable the borrowed stable (== stable()). @param manager sole caller.
    /// @param liqThreshBps collateral reserve liquidation threshold (bps).
    constructor(address pool, address dataProvider, address coll, address stable, address manager, uint256 liqThreshBps)
        LevVenueBase(manager, stable)
    {
        POOL = IAaveV3Pool(pool); DATA = IAaveV3DataProvider(dataProvider); COLLATERAL = coll;
        LIQ_THRESHOLD_BPS = liqThreshBps;
    }

    // ── ILevVenue ────────────────────────────────────────────────────────────────
    function supply(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;
        AaveV3Escrow e = escrowOf[lp];
        if (address(e) == address(0)) { e = new AaveV3Escrow(POOL, COLLATERAL, STABLE); escrowOf[lp] = e; }
        ILevERC20(COLLATERAL).transfer(address(e), collAmount); // MANAGER already sent it to the venue
        e.supplyColl(collAmount);
        return collAmount;
    }

    function borrow(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV3Escrow e = escrowOf[lp];
        if (address(e) == address(0) || stableAmount == 0) return 0;
        return e.borrowStable(stableAmount, MANAGER);
    }

    function repay(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV3Escrow e = escrowOf[lp];
        if (address(e) == address(0) || stableAmount == 0) return 0;
        uint256 d = debtOf(lp);
        uint256 r = stableAmount > d ? d : stableAmount;   // never over-repay (clamp to current debt)
        if (r == 0) return 0;
        ILevERC20(STABLE).transfer(address(e), r);          // stable already transferred in by MANAGER
        return e.repayStable(r);
    }

    function withdraw(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV3Escrow e = escrowOf[lp];
        if (address(e) == address(0) || collAmount == 0) return 0;
        uint256 bal = collateralOf(lp);
        uint256 w = collAmount > bal ? bal : collAmount;    // capped at the position
        if (w == 0) return 0;
        return e.withdrawColl(w, MANAGER);
    }

    /// @notice Amount OWED — ProtocolDataProvider's `currentVariableDebt` (Amp's proven source; exact block-fresh
    ///         underlying-unit debt, one asset, no vToken.balanceOf / no hardcoded index).
    function debtOf(address lp) public view returns (uint256) {
        AaveV3Escrow e = escrowOf[lp];
        if (address(e) == address(0)) return 0;
        (,, uint256 currentVariableDebt,,,,,,) = DATA.getUserReserveData(STABLE, address(e));
        return currentVariableDebt;
    }

    /// @notice Collateral supplied — ProtocolDataProvider's `currentATokenBalance` (block-fresh underlying units).
    function collateralOf(address lp) public view returns (uint256) {
        AaveV3Escrow e = escrowOf[lp];
        if (address(e) == address(0)) return 0;
        (uint256 currentATokenBalance,,,,,,,,) = DATA.getUserReserveData(COLLATERAL, address(e));
        return currentATokenBalance;
    }

    function liqThresholdBps() external view returns (uint256) { return LIQ_THRESHOLD_BPS; }
}

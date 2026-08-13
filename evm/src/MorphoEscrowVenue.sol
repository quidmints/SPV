// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevVenueBase} from "./imports/LevVenueBase.sol";
import {IERC20Min} from "./imports/ILevVenue.sol";

/// Morpho Blue market parameters (the tuple whose hash IS the market id).
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv; // 1e18 scale (1e18 = 100%)
}

/// Minimal Morpho Blue surface used by the IL-protect.
interface IMorpho {
    function supplyCollateral(MarketParams memory m, uint256 assets, address onBehalf, bytes memory data) external;
    function withdrawCollateral(MarketParams memory m, uint256 assets, address onBehalf, address receiver) external;
    function borrow(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(MarketParams memory m, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function position(bytes32 id, address user)
        external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32 id)
        external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets,
            uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
    function accrueInterest(MarketParams memory m) external;
}

/// @title  MorphoEscrowVenue — generic (escrow-equivalent) collateral / stable-debt `ILevVenue` on Morpho Blue (weETH on ETH, vBTC on BTC)
/// @notice The weETH lev venue. Since Euler v2 and Aave V4 borrowing were removed (2026-08-13) this is the
///         ONLY ETH-side venue; it still implements `ILevVenue`, so `LevManager` stays venue-agnostic.
///         ISOLATION is Morpho-native: each LP's position lives under the **LP's own address**
///         (`onBehalf = lp`), so it's isolated by construction — one liquidation hits that LP's Morpho
///         account, never another LP and never the QU!D basket. The adapter acts as the LP's authorized
///         MANAGER; therefore every LP must `morpho.setAuthorization(thisAdapter, true)` ONCE before
///         opening (a one-time approval, the Morpho-native analog of Euler's sub-account ownership).
///
///         INVARIANT #1 (rehypothecation): Morpho Blue supplied COLLATERAL is **not lent** — collateral
///         in Morpho is never borrowed against the supply side; it just secures the loan. So weETH as
///         Morpho collateral is escrow-equivalent (still earns ether.fi staking intrinsically, never
///         re-lent) — the rehyp rule holds natively, no escrow-vault choice needed (unlike Euler).
///
///         Custody (per ILevVenue): `LevManager` sends weETH/stable to the adapter before `supply`/`repay`;
///         the adapter forwards borrowed stable / withdrawn weETH back to `LevManager`.
contract MorphoEscrowVenue is LevVenueBase {
    IMorpho public immutable MORPHO;
    address public immutable COLLATERAL;        // collateral (== marketParams.collateralToken)
    bytes32 public immutable MARKET_ID;    // keccak256(abi.encode(marketParams))
    uint256 public immutable LLTV;         // 1e18 scale

    // Cache the market params (Morpho calls take the full struct).
    address private immutable ORACLE;
    address private immutable IRM;

    error NotAuthorized();

    constructor(address morpho, MarketParams memory m, address manager) LevVenueBase(manager, m.loanToken) {
        MORPHO = IMorpho(morpho);
        COLLATERAL = m.collateralToken;
        ORACLE = m.oracle;
        IRM = m.irm;
        LLTV = m.lltv;
        MARKET_ID = keccak256(abi.encode(m));
    }

    function _params() internal view returns (MarketParams memory) {
        return MarketParams({ loanToken: STABLE, collateralToken: COLLATERAL, oracle: ORACLE, irm: IRM, lltv: LLTV });
    }

    /// @notice PERMISSIONLESS caller-funded repay of `lp`'s isolated Morpho debt. The LP's self-hosted
    ///         keeper protects the position by redeeming the LP's OWN mature QUID -> the venue stable -> here,
    ///         instead of selling collateral (never a par-burn; redeem is mature-only on-chain). Clamped to the
    ///         current debt (never over-repay) and pulls exactly what it repays from the caller. Safe to be
    ///         permissionless: repaying only ever REDUCES an ISOLATED position's debt (helps that LP), credits
    ///         the LP's own Morpho account, and can never touch another LP or the basket.
    function repayFor(address lp, uint256 amount) external nonReentrant returns (uint256 repaid) {
        if (amount == 0) return 0;
        uint256 d = debtOf(lp);
        uint256 r = amount > d ? d : amount;                 // clamp to current debt (never over-repay)
        if (r == 0) return 0;
        IERC20Min(STABLE).transferFrom(msg.sender, address(this), r);
        IERC20Min(STABLE).approve(address(MORPHO), r);
        (repaid,) = MORPHO.repay(_params(), r, 0, lp, "");
    }

    /// @notice Permissionless poke that accrues the Morpho market so a subsequent `debtOf`
    ///         reflects interest pending since `lastUpdate` (a `view` can't call `accrueInterest`). The keeper
    ///         either sends this before a health tick, or reads a fresh debt via `eth_call` on a wrapper that
    ///         calls this then `debtOf` — either way removing the pre-accrual drift `debtOf` documents.
    ///         Harmless to call anytime (idempotent within a block). No effect on Euler (its adapter has none).
    function accrue() external { MORPHO.accrueInterest(_params()); }

    /// @notice `accrue()` then `debtOf(lp)` — NON-view so the keeper can read a FRESH (fully-accrued) debt via
    ///         `eth_call` (the accrual runs in the simulation; no real tx / gas). Serves the health
    ///         read without a per-tick accrue transaction.
    function accrueAndDebtOf(address lp) external returns (uint256) {
        MORPHO.accrueInterest(_params());
        return debtOf(lp);
    }

    // ── ILevVenue ────────────────────────────────────────────────────────────────
    function supply(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;
        IERC20Min(COLLATERAL).approve(address(MORPHO), collAmount); // weETH already transferred in by MANAGER
        MORPHO.supplyCollateral(_params(), collAmount, lp, "");  // credits the LP's own account
        return collAmount;
    }

    function borrow(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        if (stableAmount == 0) return 0;
        // The adapter must be the LP's authorized Morpho manager (one-time LP setAuthorization).
        if (!MORPHO.isAuthorized(lp, address(this))) revert NotAuthorized();
        (uint256 got,) = MORPHO.borrow(_params(), stableAmount, 0, lp, address(this)); // debit lp, stable → adapter
        if (got > 0) IERC20Min(STABLE).transfer(MANAGER, got);
        return got;
    }

    function repay(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        if (stableAmount == 0) return 0;
        uint256 d = debtOf(lp);
        uint256 r = stableAmount > d ? d : stableAmount; // never over-repay (clamp to current debt)
        if (r == 0) return 0;
        IERC20Min(STABLE).approve(address(MORPHO), r);  // stable already transferred in by MANAGER
        (uint256 repaid,) = MORPHO.repay(_params(), r, 0, lp, "");
        return repaid;
    }

    function withdraw(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;
        if (!MORPHO.isAuthorized(lp, address(this))) revert NotAuthorized();
        uint256 bal = collateralOf(lp);
        uint256 w = collAmount > bal ? bal : collAmount; // capped at the position
        if (w == 0) return 0;
        uint256 before = IERC20Min(COLLATERAL).balanceOf(address(this));
        MORPHO.withdrawCollateral(_params(), w, lp, address(this)); // weETH → adapter
        uint256 got = IERC20Min(COLLATERAL).balanceOf(address(this)) - before;
        if (got > 0) IERC20Min(COLLATERAL).transfer(MANAGER, got);
        return got;
    }

    /// @dev Reads the LAST-accrued market totals (no `accrueInterest` in a view), so the returned debt is
    ///      understated by interest pending since `lastUpdate` — the keeper would see the position slightly
    ///      HEALTHIER than real. Bounded + safe: per-poll (~5min) borrow-interest drift is sub-bp vs the
    ///      keeper's ~15% (`safety_margin_bps`) urgent margin, and the next tick re-reads. A position genuinely
    ///      near liquidation is caught by that margin regardless of the drift.
    function debtOf(address lp) public view returns (uint256) {
        (, uint128 borrowShares,) = MORPHO.position(MARKET_ID, lp);
        if (borrowShares == 0) return 0;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(MARKET_ID);
        if (totalBorrowShares == 0) return 0;
        // toAssetsUp (Morpho SharesMathLib): assets = ceil(shares * totalAssets / totalShares).
        uint256 num = uint256(borrowShares) * uint256(totalBorrowAssets);
        return (num + uint256(totalBorrowShares) - 1) / uint256(totalBorrowShares);
    }

    function collateralOf(address lp) public view returns (uint256) {
        (,, uint128 collateral) = MORPHO.position(MARKET_ID, lp); // Morpho tracks collateral as raw assets
        return uint256(collateral);
    }

    /// Morpho LLTV is 1e18-scaled (1e18 = 100%); convert to bps (1e18/1e14 = 1e4 = 100%).
    function liqThresholdBps() external view returns (uint256) {
        return LLTV / 1e14;
    }
}

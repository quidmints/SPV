// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LevVenueBase, ILevERC20} from "./imports/LevVenueBase.sol";
// §A.52: the canonical Aave v4 spoke view (was a file-local `IAaveSpoke`).
import {IAaveV4Spoke} from "./imports/Interfaces.sol";

/// ── Aave V4 Hub/Spoke surface this adapter needs. Signatures are the ones proven against the LIVE Aave V4
///    Spoke by the (tested) Amp.sol integration: supply/borrow/repay/withdraw are keyed by (reserveId, amount,
///    onBehalfOf), and `onBehalfOf` is always the CALLER's own account (Amp used address(this)). There is no
///    sub-account / credit-delegation surface, so per-LP isolation is done with a per-LP escrow (see below).
interface IAaveHub {
    function getAssetId(address underlying) external view returns (uint256);
}

/// @title  AaveV4Escrow — a single LP's ISOLATED Aave V4 position, owned by the venue
/// @notice Aave has no sub-account (unlike Euler's EVC) and no manager-on-behalf borrow (unlike Morpho's
///         authorization), and Aave keys a position by the CALLER address. So the only way one LP's
///         liquidation can never touch another's is to give each LP its OWN account: this minimal escrow. The
///         venue deploys one per LP and drives it; the escrow is the `onBehalfOf` == caller for every Spoke op,
///         and the sole place that LP's collateral/debt lives. Only the venue can move it.
contract AaveV4Escrow {
    address public immutable VENUE;
    IAaveV4Spoke public immutable SPOKE;
    address public immutable COLLATERAL;
    address public immutable STABLE;
    uint256 public immutable COLL_RESERVE;
    uint256 public immutable STABLE_RESERVE;

    error OnlyVenue();
    modifier onlyVenue() { if (msg.sender != VENUE) revert OnlyVenue(); _; }

    constructor(IAaveV4Spoke spoke, address coll, address stable, uint256 collReserve, uint256 stableReserve) {
        VENUE = msg.sender;
        SPOKE = spoke; COLLATERAL = coll; STABLE = stable;
        COLL_RESERVE = collReserve; STABLE_RESERVE = stableReserve;
        // Max-approve the SPOKE once: supply/repay pull the supplied collateral / repaid stable via
        // transferFrom in the Spoke's own (delegatecall) context, so the SPOKE is the spender.
        ILevERC20(coll).approve(address(spoke), type(uint256).max);
        ILevERC20(stable).approve(address(spoke), type(uint256).max);
    }

    /// Supply `amt` collateral (already transferred in by the venue) → the escrow's own Aave account, and mark it
    /// as collateral (Aave V4 does NOT auto-enable supplied assets as collateral; idempotent on later top-ups).
    function supplyColl(uint256 amt) external onlyVenue {
        SPOKE.supply(COLL_RESERVE, amt, address(this));
        SPOKE.setUsingAsCollateral(COLL_RESERVE, true, address(this));
    }

    /// Borrow `amt` stable against this account and forward it to `to` (the venue → MANAGER). Returns delivered.
    function borrowStable(uint256 amt, address to) external onlyVenue returns (uint256 got) {
        uint256 before = ILevERC20(STABLE).balanceOf(address(this));
        SPOKE.borrow(STABLE_RESERVE, amt, address(this));
        got = ILevERC20(STABLE).balanceOf(address(this)) - before;
        if (got > 0) ILevERC20(STABLE).transfer(to, got);
    }

    /// Repay `amt` stable (already transferred in by the venue) against this account. Returns the ASSETS actually
    /// spent (balance delta) — SPOKE.repay's own return is shares (debt-index-scaled), not the token amount.
    function repayStable(uint256 amt) external onlyVenue returns (uint256 spent) {
        uint256 before = ILevERC20(STABLE).balanceOf(address(this));
        SPOKE.repay(STABLE_RESERVE, amt, address(this));
        spent = before - ILevERC20(STABLE).balanceOf(address(this));
    }

    /// Withdraw `amt` collateral from this account and forward it to `to` (the venue → MANAGER). Returns delivered.
    function withdrawColl(uint256 amt, address to) external onlyVenue returns (uint256 got) {
        uint256 before = ILevERC20(COLLATERAL).balanceOf(address(this));
        SPOKE.withdraw(COLL_RESERVE, amt, address(this));
        got = ILevERC20(COLLATERAL).balanceOf(address(this)) - before;
        if (got > 0) ILevERC20(COLLATERAL).transfer(to, got);
    }
}

/// @title  AaveV4Venue — per-LP isolated Aave V4 borrow venue as an `ILevVenue`
/// @notice The Aave V4 sibling of `EulerEscrowVenue`/`MorphoEscrowVenue` (same `ILevVenue`, so `LevManager` is
///         venue-agnostic). Collateral (e.g. WETH/weETH) is supplied and the venue's `stable()` (e.g. USDC) is
///         borrowed on Aave V4's Hub/Spoke. ISOLATION: each LP gets its own `AaveV4Escrow` account — one LP's
///         liquidation hits only that escrow, never another LP and never the QU!D basket (Aave has no
///         sub-account/on-behalf-borrow surface, so escrow is the only correct isolation, cf. the pooled Amp.sol).
///
///         Custody (per ILevVenue): MANAGER sends collateral/stable to the venue before supply/repay; the venue
///         routes them through the LP's escrow and forwards borrowed stable / withdrawn collateral back to MANAGER.
contract AaveV4Venue is LevVenueBase {
    IAaveV4Spoke public immutable SPOKE;
    address public immutable HUB;
    address public immutable COLLATERAL;
    uint256 public immutable COLL_RESERVE;
    uint256 public immutable STABLE_RESERVE;
    uint256 public immutable LIQ_THRESHOLD_BPS; // collateral reserve's liquidation threshold (Aave gov param)

    mapping(address => AaveV4Escrow) public escrowOf; // lp → isolated Aave account (0 = none yet)

    /// @param spoke   Aave V4 Spoke.  @param hub Aave V4 Hub (asset-id resolver).
    /// @param coll    collateral underlying (WETH/weETH).  @param stable the borrowed stable (== stable()).
    /// @param manager LevManager (sole caller).  @param liqThresholdBps collateral reserve liquidation threshold (bps).
    constructor(address spoke, address hub, address coll, address stable, address manager, uint256 liqThresholdBps)
        LevVenueBase(manager, stable)
    {
        SPOKE = IAaveV4Spoke(spoke); HUB = hub; COLLATERAL = coll;
        COLL_RESERVE   = IAaveV4Spoke(spoke).getReserveId(hub, IAaveHub(hub).getAssetId(coll));
        STABLE_RESERVE = IAaveV4Spoke(spoke).getReserveId(hub, IAaveHub(hub).getAssetId(stable));
        LIQ_THRESHOLD_BPS = liqThresholdBps;
    }

    // ── ILevVenue ────────────────────────────────────────────────────────────────
    function supply(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;
        AaveV4Escrow e = escrowOf[lp];
        if (address(e) == address(0)) {
            e = new AaveV4Escrow(SPOKE, COLLATERAL, STABLE, COLL_RESERVE, STABLE_RESERVE);
            escrowOf[lp] = e;
        }
        ILevERC20(COLLATERAL).transfer(address(e), collAmount); // MANAGER already sent it to the venue
        e.supplyColl(collAmount);
        return collAmount;
    }

    function borrow(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV4Escrow e = escrowOf[lp];
        if (address(e) == address(0) || stableAmount == 0) return 0;
        return e.borrowStable(stableAmount, MANAGER);
    }

    function repay(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV4Escrow e = escrowOf[lp];
        if (address(e) == address(0) || stableAmount == 0) return 0;
        uint256 d = debtOf(lp);
        uint256 r = stableAmount > d ? d : stableAmount;   // never over-repay (clamp to current debt)
        if (r == 0) return 0;
        ILevERC20(STABLE).transfer(address(e), r);          // stable already transferred in by MANAGER
        return e.repayStable(r);
    }

    function withdraw(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV4Escrow e = escrowOf[lp];
        if (address(e) == address(0) || collAmount == 0) return 0;
        uint256 bal = collateralOf(lp);
        uint256 w = collAmount > bal ? bal : collAmount;    // capped at the position
        if (w == 0) return 0;
        return e.withdrawColl(w, MANAGER);
    }

    function debtOf(address lp) public view returns (uint256) {
        AaveV4Escrow e = escrowOf[lp];
        return address(e) == address(0) ? 0 : SPOKE.getUserDebt(STABLE_RESERVE, address(e));
    }

    function collateralOf(address lp) public view returns (uint256) {
        AaveV4Escrow e = escrowOf[lp];
        return address(e) == address(0) ? 0 : SPOKE.getUserSuppliedAssets(COLL_RESERVE, address(e));
    }

    function liqThresholdBps() external view returns (uint256) { return LIQ_THRESHOLD_BPS; }
}

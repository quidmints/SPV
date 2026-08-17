// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// `IERC20Min` was declared here: a strict SUBSET of `IERC20Min` (4 of its members, identical
// signatures) — the same rule-2 violation `IERC20Min` records already absorbing once, from Core.
import {ILevVenue, IERC20Min} from "./ILevVenue.sol";

/// Minimal ERC20 surface shared by both weETH lending-venue adapters.

/// @title  LevVenueBase — shared scaffolding for the per-LP-isolated lending adapters
/// @notice What is ACTUALLY shared lives here and is small: the `MANAGER`-only auth, the reentrancy
///         guard, the `stable()` accessor and the custody convention.
///
/// ⚠️ THIS HEADER USED TO SAY THE TWO ADAPTERS "differ ONLY in the venue's isolation mechanism".
///    TRUE, AND MISLEADING — measured 2026-08-15. The isolation mechanism IS THE BODY OF EVERY
///    FUNCTION, so they share a six-function SHAPE and NO CODE:
///      • `supply`  — Morpho: `approve` + `supplyCollateral(_params(), amt, lp, "")`, `onBehalf = lp`.
///                    Aave:   lazily `new AaveV3Escrow(...)`, transfer to it, `e.supplyColl(amt)`.
///      • `borrow`  — Morpho: `isAuthorized(lp, this)` then debit the LP directly.
///                    Aave:   route through the per-LP escrow handle.
///    ⇒ Hoisting them into an abstract with six abstract members SAVES ZERO BYTECODE. Do not read
///    this file as evidence that a dedup is available; it was read that way once and the dedup was
///    refused on measurement (task #48). Nor is `AaveV3Venue` deletable in favour of a Morpho WBTC
///    market: `DeployL1_s.sol:93` keeps it on a DEPTH measurement (deepest WBTC/USDC book), which is
///    a REAL asymmetry, not drift.
///
///         (⛔ `SorExchange` IS DELETED, AND SO IS THE PRODUCT IT ADAPTED. This block used to argue
///         the opposite -- "a DISTINCT PRODUCT, NOT A DEPRECATED PATH -- do not delete it as an
///         unmerged straggler" -- and it outlived both `SorExchange.sol` and `LiquityTroveVenue.sol`,
///         which were removed with the Liquity-V2 directional long (owner: there is no way to borrow
///         against weETH with Liquity, so the tests were testing something untestable). The text had
///         also become duplicated mid-sentence, so it read as two overlapping claims.
///         WHY THIS MATTERED ENOUGH TO REWRITE RATHER THAN DELETE: an instruction NOT to delete
///         something is the one kind of stale comment that can resurrect dead code. A reader
///         restoring `SorExchange` on its authority would bring back the BOLD/Liquity mint path with
///         it. There is no BOLD mint anywhere in `evm/src` today -- no `withdrawBold`, no
///         `BORROWER_OPS`, no `openTrove`, verified by structure 2026-08-15 -- and BOLD survives ONLY
///         as basket stable slot 11, SUPPLIED to the Liquity Stability Pool. Held, never minted.)
abstract contract LevVenueBase is ILevVenue {
    address public immutable MANAGER;   // the only caller (LevManager)
    address public immutable STABLE;    // the debt asset this venue lends

    uint256 private _lock = 1;
    modifier nonReentrant() { require(_lock == 1, "reentrant"); _lock = 2; _; _lock = 1; }
    modifier onlyManager() { require(msg.sender == MANAGER, "auth"); _; }

    constructor(address manager, address stable_) { MANAGER = manager; STABLE = stable_; }

    function stable() external view returns (address) { return STABLE; }
}

// ═══ folded from src/MorphoEscrowVenue.sol (2026-08-15) — see the note in the base header ═══

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

// ═══ folded from src/AaveV3Venue.sol (2026-08-15) ═══

/// ── Aave V3 Pool surface this adapter needs. Signatures proven against the LIVE Aave V3 Pool by the (tested)
///    Amp.sol integration: supply(asset,amt,onBehalf,ref) / borrow(asset,amt,rateMode,ref,onBehalf) /
///    repay(asset,amt,rateMode,onBehalf) / withdraw(asset,amt,to). V3 keys a position by the CALLER (no
///    sub-account / on-behalf-borrow), so per-LP isolation uses a per-LP escrow (the pattern `LevVenueBase` holds).
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
        // §PM-INVARIANT-3 — AN INFINITE APPROVAL, AND A DELIBERATE EXCEPTION TO THE EXACT-AMOUNT
        // RULE. Recorded here rather than left to be rediscovered as an oversight:
        //   · the spender is PINNED AND IMMUTABLE (`POOL`, set in this constructor, never rotatable),
        //     so there is no address a later caller can point this allowance at;
        //   · this escrow holds NOTHING between operations -- the venue transfers the tokens in
        //     immediately before supply/repay, so a live allowance covers a zero balance;
        //   · Aave's Pool pulls by `transferFrom` in its OWN context, so a per-op exact approval
        //     would be two extra SSTOREs per leg for no reachable state a max approval exposes.
        // ⚠️ THE EXCEPTION RESTS ON THE SECOND BULLET. If this contract ever holds an idle balance,
        // the infinite approval stops being covered by "nothing to take" and must become exact.
        IERC20Min(coll).approve(address(pool), type(uint256).max);
        IERC20Min(stable).approve(address(pool), type(uint256).max);
    }

    /// Supply `amt` collateral (already transferred in by the venue) → the escrow's own Aave account, marked as
    /// collateral (V3 does NOT auto-enable supplied assets as collateral; idempotent on later top-ups).
    function supplyColl(uint256 amt) external onlyVenue {
        POOL.supply(COLLATERAL, amt, address(this), 0);
        POOL.setUserUseReserveAsCollateral(COLLATERAL, true);
    }

    /// Borrow `amt` stable (variable rate) against this account, forward to `to` (venue → MANAGER). Returns delivered.
    function borrowStable(uint256 amt, address to) external onlyVenue returns (uint256 got) {
        uint256 bef = IERC20Min(STABLE).balanceOf(address(this));
        POOL.borrow(STABLE, amt, VARIABLE_RATE, 0, address(this));
        got = IERC20Min(STABLE).balanceOf(address(this)) - bef;
        if (got > 0) IERC20Min(STABLE).transfer(to, got);
    }

    /// Repay `amt` stable (already transferred in by the venue). Returns ASSETS actually spent (balance delta).
    function repayStable(uint256 amt) external onlyVenue returns (uint256 spent) {
        uint256 bef = IERC20Min(STABLE).balanceOf(address(this));
        POOL.repay(STABLE, amt, VARIABLE_RATE, address(this));
        spent = bef - IERC20Min(STABLE).balanceOf(address(this));
    }

    /// Withdraw `amt` collateral straight to `to` (venue → MANAGER). V3's withdraw sends to `to` and returns the amount.
    function withdrawColl(uint256 amt, address to) external onlyVenue returns (uint256 got) {
        got = POOL.withdraw(COLLATERAL, amt, to);
    }
}

/// @title  AaveV3Venue — per-LP isolated Aave V3 borrow venue as an `ILevVenue`
/// @notice The WBTC lev venue, sibling of `MorphoEscrowVenue` (same `ILevVenue`, so the
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
        IERC20Min(COLLATERAL).transfer(address(e), collAmount); // MANAGER already sent it to the venue
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
        IERC20Min(STABLE).transfer(address(e), r);          // stable already transferred in by MANAGER
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

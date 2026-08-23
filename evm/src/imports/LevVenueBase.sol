// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// `IERC20Min` was declared here: a strict SUBSET of `IERC20Min` (4 of its members, identical
// signatures) — the same rule-2 violation `IERC20Min` records already absorbing once, from Core.
import {ILevVenue, IERC20Min, IAaveV3Pool, IAaveV3DataProvider} from "./Interfaces.sol";
import {IMorphoStaticTyping as IMorpho, MarketParams, Id, MarketParamsLib} from "./Interfaces.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
// §E266 — INHERIT MORPHO DIRECTLY. `MarketParams`, `IMorpho` and a hand-rolled
// `keccak256(abi.encode(m))` market id all lived here. `MarketParams` was compared FIELD-FOR-FIELD
// against Blue before swapping, because that order is hashed into the market Id and a mismatch
// would be a live correctness bug rather than duplication. It matched. `IMorphoStaticTyping` is
// the TUPLE-returning variant, matching the destructuring below; plain `IMorpho` returns structs.

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
    /// @dev §POOL-DONATION — VIRTUAL UNIT OFFSET. Without it the pooled unit model carries the classic
    ///      FIRST-DEPOSITOR INFLATION ATTACK, and it is reachable here because BOTH venues' pool
    ///      balances can be raised by a STRANGER: Morpho's `supplyCollateral(m, assets, onBehalf, data)`
    ///      takes an arbitrary `onBehalf` and is permissionless, and Aave's `supply` likewise.
    ///      THE ATTACK, concretely: LP1 supplies 1 wei and gets 1 unit; the attacker donates X directly
    ///      to the venue's position so the pool balance is X+1 while total units is still 1; LP2 then
    ///      supplies Y and mints `Y·1/(X+1)` = **ZERO units** for any Y ≤ X. LP2's collateral becomes
    ///      LP1's claim. Real theft, not rounding dust.
    ///      THE FIX is the standard virtual offset (OpenZeppelin's ERC-4626 mitigation): price units
    ///      against `total + OFFSET` over `balance + 1`, so an attacker must donate ~OFFSET times the
    ///      victim's deposit to round it to zero — and forfeits every wei of it. 1e6 puts that cost
    ///      beyond any griefing budget while costing nothing in precision.
    /// ⚠️   IT MUST BE APPLIED ON BOTH SIDES OF BOTH VENUES OR IT IS NOT APPLIED. A single un-offset
    ///      mint site re-opens the whole attack, because the attacker picks which one to enter through.
    uint256 internal constant UNIT_OFFSET = 1e6;

    /// @dev §POOL-UNITS — THE UNIT LEDGER, DECLARED ONCE FOR BOTH VENUES. `MorphoEscrowVenue` and
    ///      `AaveV3Venue` each grew their own copy (`collUnits/totalCollUnits` and `collUnits/totalCollUnits`)
    ///      — the SAME four quantities under two spellings, in ONE file. That is standing rule 2, and
    ///      it is worse than cosmetic here: the donation-inflation fix had to reach every mint site,
    ///      and two ledgers is two places to miss one.
    /// ⚠️   `internal`, not `private`, ONLY so the derived venues can read them; neither visibility
    ///      emits a getter, so there is no ABI consequence.
    mapping(address => uint256) internal collUnits;   // LP -> units of the pooled COLLATERAL
    uint256 internal totalCollUnits;
    mapping(address => uint256) internal debtUnits;   // LP -> units of the pooled DEBT
    uint256 internal totalDebtUnits;

    /// @dev units minted for `amt` against a pool holding `bal` with `tot` units outstanding.
    function _mintUnits(uint256 amt, uint256 tot, uint256 bal) internal pure returns (uint256) {
        return SoladyMath.fullMulDiv(amt, tot + UNIT_OFFSET, bal + 1);
    }
    /// @dev the assets `u` units claim from a pool holding `bal` with `tot` units outstanding.
    function _unitSlice(uint256 u, uint256 tot, uint256 bal) internal pure returns (uint256) {
        return u == 0 ? 0 : SoladyMath.fullMulDiv(u, bal + 1, tot + UNIT_OFFSET);
    }

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

/// Minimal Morpho Blue surface used by the IL-protect.

/// @title  MorphoEscrowVenue — generic (escrow-equivalent) collateral / stable-debt `ILevVenue` on Morpho Blue (weETH on ETH, vBTC on BTC)
/// @notice The weETH lev venue. Since Euler v2 and Aave V4 borrowing were removed (2026-08-13) this is the
///         ONLY ETH-side venue; it still implements `ILevVenue`, so `LevManager` stays venue-agnostic.
/// 🔴 §POOL-VENUE (2026-08-24) — **ISOLATION IS NO LONGER MORPHO-NATIVE, AND THIS PARAGRAPH USED TO SAY
///         IT WAS.** It read: *"each LP's position lives under the LP's own address (`onBehalf = lp`), so
///         it's isolated by construction — one liquidation hits that LP's Morpho account, never another
///         LP and never the QU!D basket… every LP must `morpho.setAuthorization(thisAdapter, true)` ONCE
///         before opening."* **All three clauses are now false.** There is ONE position under this
///         adapter; a liquidation hits every LP pro-rata; and there is no authorization to grant.
/// ⇒ **ISOLATION IS NOW PROTOCOL-ENFORCED, NOT VENUE-ENFORCED.** `cascadeDelever` and the ±3% LTV
///         hysteresis are the only things keeping the aggregate off the liquidation threshold — Morpho
///         will not do it per-LP any more. **Treat any change to that hysteresis as a change to the
///         liquidation guarantee itself.**
/// ✅ WHAT IT BOUGHT: the delivery-side de-lever is ONE `repayPool` call instead of one repay per LP, so
///         swap size is bounded by stable liquidity rather than by how many repays fit in a block
///         (§E342) — and the whole "stuck LP" class disappears with the authorization it depended on.
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
    Id public immutable MARKET_ID;      // MarketParamsLib.id(marketParams)    // keccak256(abi.encode(marketParams))
    uint256 public immutable LLTV;         // 1e18 scale

    // Cache the market params (Morpho calls take the full struct).
    address private immutable ORACLE;
    address private immutable IRM;

    error NotAuthorized();

    // ═══════════════ §POOL-VENUE — ONE MORPHO POSITION, PER-LP CLAIMS TRACKED HERE ═══════════════
    //
    // WHY: `SwapLib.deleverEthOnDelivery` had to repay EACH LP's own position, and a repay cannot be
    // aggregated across N `onBehalf` accounts on Morpho Blue — so swap size was capped by how many LP
    // repays fit in a block, and the cap TIGHTENED as the book grew (§E342). One position makes the
    // repay a single call whose size is bounded by liquidity, not by LP count.
    //
    // 🔴 THE PRICE, AND IT IS NOT THE ONE §E338 PRICED. §E338 costs the convexity of one hedge against
    // many entry prices (~13-15 bp typical, ~147 bp across a cycle). **The larger cost is that
    // PER-LP LIQUIDATION ISOLATION IS GONE.** This contract's header used to say a liquidation "hits
    // that LP's Morpho account, never another LP and never the QU!D basket" — with one position it
    // hits EVERY LP pro-rata, and the position is protocol-side. Isolation moves from MORPHO-ENFORCED
    // to PROTOCOL-ENFORCED: `cascadeDelever` plus the +/-3% LTV hysteresis must keep the aggregate away
    // from the liquidation threshold, because Morpho no longer does it for us.
    // ⚠️ AND IT INTRODUCES A CROSS-LP SUBSIDY ON THAT AXIS: each LP's LTV differs by its pinned
    // `ilBasisPx`, so pooling averages them and a late high-LTV entrant is carried by an early one.
    // `LeverageCrossSubsidyProbe` is the test that should be taught to measure it.
    // ✅ WHAT IT BUYS BESIDES THE AGGREGATE REPAY: the one-time `morpho.setAuthorization(adapter)` every
    // LP had to send is GONE — the adapter is its own principal now. That retires the entire "stuck LP"
    // class, whose only reachable cause was a revoked or never-granted authorization.
    //
    // THE ACCOUNTING IS TWO LAYERS, AND THE SECOND ONE IS WHY A POOLED REPAY IS O(1):
    //   • COLLATERAL is raw assets in Morpho (it never accrues), so a plain per-LP ledger is EXACT.
    //   • DEBT accrues, so per-LP debt is held as UNITS of the pool, never as Morpho shares. An LP's
    //     Morpho shares are `poolShares * units[lp] / totalUnits`, so when a pooled repay burns pool
    //     shares, EVERY LP's implied share falls pro-rata with NO per-LP write. That is the whole
    //     point: the delever loop becomes one call and one storage write.
    // ⭐ BOTH SIDES ARE UNITS, AND THE SYMMETRY IS THE POINT — an earlier draft made only DEBT a unit
    // system and left collateral as a plain per-LP ledger. That breaks at exactly the place this change
    // exists for: the delivery-side de-lever repays the pool and must then FREE COLLATERAL to deliver,
    // and with a plain ledger "whose collateral was freed" needs a per-LP loop — the loop being deleted.
    // ⇒ Units on both sides make `repayPool` and `withdrawPool` each O(1). It is also the CORRECT
    // semantics, not merely the cheap one: the swapper's input repaid every LP's debt in proportion, so
    // the collateral it frees must leave in the same proportion. Each position shrinks on both sides by
    // its own share, which is what "value-neutral per LP" means once the position is genuinely pooled.
    // §POOL-UNITS — the four unit variables that stood here are declared ONCE on `LevVenueBase`.

    /// @dev The pool's live Morpho collateral (raw assets — Morpho never accrues collateral).
    function _poolColl() internal view returns (uint256) {
        (,, uint128 c) = MORPHO.position(MARKET_ID, address(this));
        return uint256(c);
    }

    /// @dev The pool's live Morpho borrow shares. One read, used by every per-LP debt view.
    function _poolShares() internal view returns (uint256) {
        (, uint128 bs,) = MORPHO.position(MARKET_ID, address(this));
        return uint256(bs);
    }

    constructor(address morpho, MarketParams memory m, address manager) LevVenueBase(manager, m.loanToken) {
        MORPHO = IMorpho(morpho);
        COLLATERAL = m.collateralToken;
        ORACLE = m.oracle;
        IRM = m.irm;
        LLTV = m.lltv;
        MARKET_ID = MarketParamsLib.id(m);
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
        // Credits the NAMED LP, not the pool at large — a caller-funded repay must help who it names.
        repaid = _repayCreditingLp(lp, r);
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
        // §POOL-VENUE: credits the POOL, and the per-LP ledger below is what makes it the LP's.
        uint256 before = _poolColl();
        MORPHO.supplyCollateral(_params(), collAmount, address(this), "");
        // Mint units against what the pool held BEFORE, so an LP joining a pool that has already been
        // drawn down buys in at the CURRENT per-unit value rather than the original one.
        uint256 mint = _mintUnits(collAmount, totalCollUnits, before);   // §POOL-DONATION
        collUnits[lp] += mint; totalCollUnits += mint;
        return collAmount;
    }

    function borrow(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        if (stableAmount == 0) return 0;
        // §POOL-VENUE — NO `isAuthorized` CHECK: the adapter borrows on its OWN behalf, so there is no
        // LP authorization to grant, revoke, or forget. The one-time `setAuthorization` step is gone.
        uint256 before = _poolShares();
        (uint256 got, uint256 sharesUp) = MORPHO.borrow(_params(), stableAmount, 0, address(this), address(this));
        // Mint units against the shares this borrow added. First borrow anchors 1 unit = 1 share.
        uint256 mint = _mintUnits(sharesUp, totalDebtUnits, before);      // §POOL-DONATION
        debtUnits[lp] += mint; totalDebtUnits += mint;
        if (got > 0) IERC20Min(STABLE).transfer(MANAGER, got);
        return got;
    }

    function repay(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        if (stableAmount == 0) return 0;
        uint256 d = debtOf(lp);
        uint256 r = stableAmount > d ? d : stableAmount; // never over-repay (clamp to THIS LP's share)
        if (r == 0) return 0;
        return _repayCreditingLp(lp, r);   // stable already transferred in by MANAGER
    }

    /// @dev §POOL-VENUE — ONE repay-and-credit body. `repay` (manager-funded) and `repayFor`
    ///      (permissionless, caller-funded) differ ONLY in who supplies the stable; both then repay the
    ///      POOL and burn the named LP's units. Folding them means the unit arithmetic — the part that
    ///      must keep `sum(units) == totalUnits` — exists once. ⛔ `repayPool` deliberately does NOT
    ///      route through here: it credits nobody and burns no units, which is what makes it O(1).
    function _repayCreditingLp(address lp, uint256 r) private returns (uint256 repaid) {
        IERC20Min(STABLE).approve(address(MORPHO), r);
        uint256 before = _poolShares();
        uint256 sharesDown;
        (repaid, sharesDown) = MORPHO.repay(_params(), r, 0, address(this), "");
        uint256 burn = before == 0 ? 0 : SoladyMath.fullMulDiv(sharesDown, totalDebtUnits, before);
        if (burn > debtUnits[lp]) burn = debtUnits[lp];
        debtUnits[lp] -= burn; totalDebtUnits -= burn;
    }

    /// @notice §POOL-VENUE — THE AGGREGATE REPAY THIS WHOLE CHANGE EXISTS FOR. Repays the POOL without
    ///         naming an LP, in ONE call. ⭐ No per-LP write and no loop: `debtOf` converts units through
    ///         the pool's LIVE shares, so burning pool shares lowers EVERY LP's debt pro-rata by
    ///         construction. `totalDebtUnits` is deliberately UNTOUCHED — units are a claim on the pool,
    ///         and the pool got smaller, which is exactly what a pro-rata repay means.
    /// ⇒ This is what removes the swap-size ceiling: size is now bounded by stable liquidity, not by
    ///   how many LP repays fit in a block.
    function repayPool(uint256 stableAmount) external onlyManager nonReentrant returns (uint256 repaid) {
        if (stableAmount == 0) return 0;
        uint256 d = totalDebt();
        uint256 r = stableAmount > d ? d : stableAmount;
        if (r == 0) return 0;
        IERC20Min(STABLE).approve(address(MORPHO), r);
        (repaid,) = MORPHO.repay(_params(), r, 0, address(this), "");
    }

    function withdraw(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;
        // §POOL-VENUE — no authorization to check; the adapter withdraws its own collateral.
        uint256 bal = collateralOf(lp);
        uint256 w = collAmount > bal ? bal : collAmount; // capped at THIS LP's slice of the pool
        if (w == 0) return 0;
        {   // burn the units this withdrawal represents, before the pool shrinks under them
            uint256 pc = _poolColl();
            uint256 burn = pc == 0 ? collUnits[lp] : SoladyMath.fullMulDiv(w, totalCollUnits, pc);
            if (burn > collUnits[lp]) burn = collUnits[lp];
            collUnits[lp] -= burn; totalCollUnits -= burn;
        }
        uint256 before = IERC20Min(COLLATERAL).balanceOf(address(this));
        MORPHO.withdrawCollateral(_params(), w, address(this), address(this)); // weETH → adapter
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
        uint256 u = debtUnits[lp];
        if (u == 0 || totalDebtUnits == 0) return 0;
        // §POOL-VENUE: this LP's slice of the POOL's live shares. Interest accrues to the pool, so it
        // reaches every LP through this one conversion — no per-LP accrual bookkeeping exists or is needed.
        return _sharesToAssetsUp(_unitSlice(u, totalDebtUnits, _poolShares()));
    }

    /// @notice The POOL's total debt — O(1), and the reason `LevBase`'s Sigma-loops over `_openLps` can go.
    function totalDebt() public view returns (uint256) { return _sharesToAssetsUp(_poolShares()); }

    /// @dev toAssetsUp (Morpho SharesMathLib): assets = ceil(shares * totalAssets / totalShares).
    ///      Rounding UP is deliberate and unchanged — it never understates what is owed.
    function _sharesToAssetsUp(uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(MARKET_ID);
        if (totalBorrowShares == 0) return 0;
        uint256 num = shares * uint256(totalBorrowAssets);
        return (num + uint256(totalBorrowShares) - 1) / uint256(totalBorrowShares);
    }

    function collateralOf(address lp) public view returns (uint256) {
        return _unitSlice(collUnits[lp], totalCollUnits, _poolColl());   // §POOL-DONATION
    }

    /// @notice The POOL's total collateral — O(1) companion to `totalDebt`.
    function totalCollateral() external view returns (uint256) { return _poolColl(); }

    /// @notice §POOL-VENUE — THE AGGREGATE COLLATERAL WITHDRAW, the mirror of `repayPool` and the other
    ///         half of a one-call de-lever. Frees `collAmount` from the POOL and hands it to the manager.
    ///         ⭐ No per-LP write: `totalCollUnits` is untouched, so every LP's `collateralOf` falls
    ///         pro-rata by construction — the same trick that makes `repayPool` O(1).
    /// ⚠️      MUST be paired with a `repayPool` of the matching value. Alone it would free collateral
    ///         while leaving the debt, i.e. raise the pool's LTV toward the liquidation threshold that
    ///         Morpho no longer enforces per-LP.
    function withdrawPool(uint256 collAmount) external onlyManager nonReentrant returns (uint256 got) {
        uint256 pc = _poolColl();
        uint256 w = collAmount > pc ? pc : collAmount;
        if (w == 0) return 0;
        uint256 before = IERC20Min(COLLATERAL).balanceOf(address(this));
        MORPHO.withdrawCollateral(_params(), w, address(this), address(this));
        got = IERC20Min(COLLATERAL).balanceOf(address(this)) - before;
        if (got > 0) IERC20Min(COLLATERAL).transfer(MANAGER, got);
    }

    /// Morpho LLTV is 1e18-scaled (1e18 = 100%); convert to bps (1e18/1e14 = 1e4 = 100%).
    function liqThresholdBps() external view returns (uint256) {
        return LLTV / 1e14;
    }
}

// ═══ folded from src/AaveV3Venue.sol (2026-08-15) ═══

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
///         raw vToken/aToken balanceOf, no hardcoded reservesList index, one asset per call (cheap for rangeBTC).
///
///         Custody (per ILevVenue): MANAGER sends collateral/stable to the venue before supply/repay; the venue
///         routes them through the LP's escrow and forwards borrowed stable / withdrawn collateral back to MANAGER.
contract AaveV3Venue is LevVenueBase {
    IAaveV3Pool         public immutable POOL;
    IAaveV3DataProvider public immutable DATA;         // ProtocolDataProvider (per-asset current-balance reads)
    address             public immutable COLLATERAL;
    uint256             public immutable LIQ_THRESHOLD_BPS; // collateral reserve liquidation threshold (Aave gov param)

    // §POOL-VENUE (2026-08-24) — ONE ESCROW FOR THE VENUE, NOT ONE PER LP. Aave V3 keys a position by
    // the CALLER, so an escrow IS a position; `mapping(address => AaveV3Escrow) escrowOf` therefore
    // WAS the per-LP isolation, exactly as `onBehalf = lp` was on Morpho. Same trade, same reasons:
    // the delever loop could not aggregate across N escrows, so swap size was capped by how many
    // repays fit in a block. Isolation is now protocol-enforced (`cascadeDelever` + the LTV
    // hysteresis), not venue-enforced.
    // ⭐ THE UNIT MODEL FITS AAVE BETTER THAN MORPHO, WHICH IS WORTH SAYING: aTokens REBASE and the
    // variable-debt balance ACCRUES, so BOTH sides of the pool grow on their own. Units mean every
    // LP's slice grows with them through one conversion — there is no per-LP accrual bookkeeping to
    // write, and none to get wrong.
    AaveV3Escrow public poolEscrow;                  // the ONE Aave account this venue owns
    // §POOL-UNITS — same four variables as the Morpho venue, so they live on the shared base.

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
        AaveV3Escrow e = poolEscrow;
        if (address(e) == address(0)) { e = new AaveV3Escrow(POOL, COLLATERAL, STABLE); poolEscrow = e; }
        uint256 before = _poolReserve(false);
        IERC20Min(COLLATERAL).transfer(address(e), collAmount); // MANAGER already sent it to the venue
        e.supplyColl(collAmount);
        uint256 mint = _mintUnits(collAmount, totalCollUnits, before);          // §POOL-DONATION
        collUnits[lp] += mint; totalCollUnits += mint;
        return collAmount;
    }

    function borrow(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV3Escrow e = poolEscrow;
        if (address(e) == address(0) || stableAmount == 0) return 0;
        uint256 before = _poolReserve(true);
        uint256 got = e.borrowStable(stableAmount, MANAGER);
        uint256 mint = _mintUnits(got, totalDebtUnits, before);                 // §POOL-DONATION
        debtUnits[lp] += mint; totalDebtUnits += mint;
        return got;
    }

    function repay(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV3Escrow e = poolEscrow;
        if (address(e) == address(0) || stableAmount == 0) return 0;
        uint256 d = debtOf(lp);
        uint256 r = stableAmount > d ? d : stableAmount;   // never over-repay (clamp to THIS LP's slice)
        if (r == 0) return 0;
        uint256 before = _poolReserve(true);
        IERC20Min(STABLE).transfer(address(e), r);          // stable already transferred in by MANAGER
        uint256 spent = e.repayStable(r);
        // Burn the units this LP's repayment represents, so sum(units) stays == total.
        uint256 burn = before == 0 ? 0 : SoladyMath.fullMulDiv(spent, totalDebtUnits, before);
        if (burn > debtUnits[lp]) burn = debtUnits[lp];
        debtUnits[lp] -= burn; totalDebtUnits -= burn;
        return spent;
    }

    /// @notice §POOL-VENUE — aggregate repay. No per-LP write: `debtOf` reads through the pool, so a
    ///         pooled repay lowers every LP's debt pro-rata by construction. Mirror of Morpho's.
    function repayPool(uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV3Escrow e = poolEscrow;
        if (address(e) == address(0) || stableAmount == 0) return 0;
        uint256 d = _poolReserve(true);
        uint256 r = stableAmount > d ? d : stableAmount;
        if (r == 0) return 0;
        IERC20Min(STABLE).transfer(address(e), r);
        return e.repayStable(r);
    }

    /// @notice §POOL-VENUE — aggregate collateral withdraw. ⚠️ MUST follow a matching `repayPool`;
    ///         alone it raises the pool's LTV toward a threshold Aave no longer enforces per-LP.
    function withdrawPool(uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV3Escrow e = poolEscrow;
        if (address(e) == address(0) || collAmount == 0) return 0;
        uint256 c = _poolReserve(false);
        uint256 w = collAmount > c ? c : collAmount;
        return w == 0 ? 0 : e.withdrawColl(w, MANAGER);
    }

    function totalDebt() external view returns (uint256) { return _poolReserve(true); }
    function totalCollateral() external view returns (uint256) { return _poolReserve(false); }

    function withdraw(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        AaveV3Escrow e = poolEscrow;
        if (address(e) == address(0) || collAmount == 0) return 0;
        uint256 bal = collateralOf(lp);
        uint256 w = collAmount > bal ? bal : collAmount;    // capped at THIS LP's slice of the pool
        if (w == 0) return 0;
        {   uint256 pc = _poolReserve(false);
            uint256 burn = pc == 0 ? collUnits[lp] : SoladyMath.fullMulDiv(w, totalCollUnits, pc);
            if (burn > collUnits[lp]) burn = collUnits[lp];
            collUnits[lp] -= burn; totalCollUnits -= burn;
        }
        return e.withdrawColl(w, MANAGER);
    }

    /// @notice Amount OWED — ProtocolDataProvider's `currentVariableDebt` (Amp's proven source; exact block-fresh
    ///         underlying-unit debt, one asset, no vToken.balanceOf / no hardcoded index).
    function debtOf(address lp) public view returns (uint256) {
        return _slice(debtUnits[lp], totalDebtUnits, _poolReserve(true));
    }

    /// @notice Collateral supplied — ProtocolDataProvider's `currentATokenBalance` (block-fresh underlying units).
    function collateralOf(address lp) public view returns (uint256) {
        return _slice(collUnits[lp], totalCollUnits, _poolReserve(false));
    }

    /// @dev ONE conversion for both sides — units → the LP's slice of a pooled balance.
    function _slice(uint256 u, uint256 tot, uint256 poolBal) private pure returns (uint256) {
        return _unitSlice(u, tot, poolBal);   // §POOL-DONATION — one offset, defined once on the base
    }

    /// @dev ONE escrow-resolution body. Both reads MUST agree on which escrow they are
    ///      describing — a debt read against one escrow and a collateral read against
    ///      another would produce a plausible LTV for a position that does not exist.
    ///      `wantDebt` picks BOTH the asset and the slot, so they cannot be mismatched.
    function _poolReserve(bool wantDebt) private view returns (uint256) {
        AaveV3Escrow e = poolEscrow;
        if (address(e) == address(0)) return 0;
        (uint256 aTokenBal,, uint256 variableDebt,,,,,,) =
            DATA.getUserReserveData(wantDebt ? STABLE : COLLATERAL, address(e));
        return wantDebt ? variableDebt : aTokenBal;
    }

    function liqThresholdBps() external view returns (uint256) { return LIQ_THRESHOLD_BPS; }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// `Reentrancy` is a FILE-LEVEL error in Types.sol — imported, not redeclared. I nearly added a
// second declaration here; one grep for the existing body is what caught it (CLAUDE.md's first
// verification rule: grep the body you are about to wrap, not the name you are about to create).
import {Types, Reentrancy} from "./Types.sol";
import {RangeLib} from "./RangeLib.sol";
// §J.2 — ONE import from `Interfaces.sol`, not three. Rule 2 is "one declaration per interface in a
// shared file"; three import statements from the SAME file is the same fragmentation on the consumer
// side, and it is how `ILevPooled` came to look like a separate concern with its own line.
import {ILevVenue, ILevPooled, IAux, ICore, IERC20Min, IWeETH, DEFAULT_UNWIND_DEX, VenuePosition, TWAP_WINDOW_SECS} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";

/// @title  LevBase — the per-LP position registry both lev managers duplicated
///
/// @notice §A.71 STEP 3. `LevManager` and `BtcLevManager` each carried their own copy of this
///         registry: the same `pos` mapping, the same open-LP enumeration, the same target-LTV cap
///         and the same four functions. 15 of 33 bodies scored as near-duplicates, and these four
///         differed ONLY cosmetically — `uint256` vs `uint`, a parameter named `capBps` vs `cap`,
///         and one `address(AUX)` cast. One implementation now, two instances.
///
///         TWO RESIDUALS WERE SETTLED BY MEASUREMENT, NOT TASTE, BECAUSE BOTH ANSWERS COST SOMETHING:
///         • `AUX` was `IAux` in one manager and `address` in the other — which is exactly why
///           `swapOutDeleverAmt` read `_fromUsd(address(AUX), …)` on one side and `_fromUsd(AUX, …)`
///           on the other. Unified on `IAux`: ABI-SAFE, since both forms generate an
///           address-returning getter.
///         • `TARGET_LTV_CAP_BPS` was `internal` in one and `public` in the other. `internal` would
///           have DELETED BtcLevManager's existing public getter — an ABI break. `public` only adds a
///           getter to LevManager, which measured affordable AT THE TIME (24,352 bytes, 224 to
///           spare). So `public` is both the compatible answer and the affordable one.
///           🔴 **THAT NUMBER IS A READING WITH A TIMESTAMP, NOT A PROPERTY OF THE TREE, AND
///           `LevManager` IS THE BINDING CONTRACT HERE.** Re-run `tools/check-contract-sizes.py`
///           before AND after any addition to this base — everything here is `internal` or a
///           constant, so it inlines into BOTH managers — and note that `forge test` does NOT
///           enforce EIP-170, so a green suite says nothing about whether it still deploys.
///
///         ⚠️ `_openLps` / `_lpIdx` are `internal`, not `private`, ONLY because a derived contract
///         cannot see a `private` member. No ABI consequence — neither visibility emits a getter.
///         ⚠️ `pos` is PUBLIC, so its generated getter is an ABI-visible 6-tuple. Do not reorder
///         `Types.Pos`'s fields for tidiness; clients decode by position.
abstract contract LevBase {
    /// TWAP window both sides price against. Identical (1800) in each manager; PUBLIC here because
    /// BtcLevManager already exposed a getter and removing it would be an ABI break, while adding one
    /// to LevManager was affordable when measured (317 bytes of margin then — re-measure, see the
    /// header: `LevManager`'s margin is the binding one and it moves).
    /// §SESS-42 — one declaration (`TWAP_WINDOW_SECS`); this stays PUBLIC because it is ABI.
    uint32 public constant TWAP_WINDOW = TWAP_WINDOW_SECS;

    /// Max-leverage LTV ceiling for the WHOLE BOOK — nobody sets a per-LP one: 7500 bps ≈ 4×.
    uint256 public constant TARGET_LTV_CAP_BPS = 7500;
    /// @notice Gas one `rebalance` actually costs, MEASURED — not a risk parameter.
    /// @dev    §DERIVED-BAND — the band below is a cube root of `g/(C·K)`, and `g` is the only term
    ///         that cannot be read from chain state at decision time: the rebalance has not run yet,
    ///         so `gasleft()` cannot price it and the call site is `view`. This is a fact about the
    ///         bytecode rather than a judgement about risk, which is why it is admissible as a
    ///         literal AND WHY A BAND WIDTH IS NOT: a measured cost can be re-measured and falsified,
    ///         a chosen deadband can only be argued about. `LevDerivedBand.t.sol` measures a real
    ///         rebalance and fails if the figure drifts below what one costs, so it cannot rot into
    ///         a guess. The live PRICE of that gas is never frozen: `block.basefee` and the ETH TWAP
    ///         both move underneath it.
    /// @dev    🔴 **RE-MEASURE ONLY ON A PATH THAT ACTUALLY TRADES.** The figure is a WHOLE
    ///         rebalance with the venue leg executing (§C2.1 pool word): **1,248,673** on a mainnet
    ///         fork — borrow + Curve hub hop + Uniswap V3 + supply. A run that reverts
    ///         `NoVolatileRoute()` before the swap prices the Morpho borrow and nothing downstream
    ///         of it, and that number is roughly 3× too small.
    ///         ⚠️ **UNDER-PRICING `g` IS THE DANGEROUS DIRECTION AND IT DOES NOT ANNOUNCE ITSELF.**
    ///         It makes the band TIGHTER (`h = ∛(g/(C·K))`), so the book rebalances more often than
    ///         the fees can cover — a slow bleed, not a revert.
    ///         ⇒ Since `h` is a CUBE ROOT, tripling `g` widens the band only ~1.46×, which is why
    ///         a 3× error in the input is survivable long enough to go unnoticed.
    uint256 internal constant GAS_REBALANCE = 1_250_000;

    /// @notice Half-width of the no-trade band around the IL target, in LTV bps, for a position of
    ///         `collUsdWad`. DERIVED — see `LevMath.noTradeBandBps` for the economics.
    /// @dev    §DERIVED-BAND — THE BAND IS COMPUTED, NEVER CONFIGURED. Three inputs, all read: the
    ///         live cost of a rebalance, the size of the thing being hedged, and the range's own LVR
    ///         coefficient. Nothing here is anyone's choice, so nothing here is anyone's lever —
    ///         which is the property a fixed deadband constant could not have.
    ///
    ///         `K` is read through the pinned `RANGE` in the same `try/catch` idiom as
    ///         `_rangePrice()`: `RANGE` is genuinely unset between deploy and `init`, and a revert
    ///         there must not strand a position. Unmeasured ⇒ band 0 ⇒ always rebalance, the
    ///         fail-open direction argued at `LevMath.noTradeBandBps`.
    /// ⚠️ A ONE-LINE FORWARDER, AND THE BODY IS IN `LevMath` FOR EIP-170 REASONS. This is `internal`,
    ///     so whatever stands here is INLINED into `LevManager` AND `BtcLevManager` — and
    ///     `LevManager` is the binding contract in this tree. The reads it needs (`AUX`, `RANGE`,
    ///     `TWAP_WINDOW`) are this contract's immutables, which a delegatecalled library cannot
    ///     reach, so they are PASSED rather than looked up. That is the same shape every other body
    ///     moved out of these managers takes.
    /// @dev §POOL-VENUE — the headroom is resolved HERE because the venue is this contract's to know,
    ///      and it is READ off the venue rather than assumed. `ILevVenue.liqThresholdBps()` already
    ///      exists on both adapters (Morpho converts its 1e18 `LLTV`, Aave returns its own), so this
    ///      needs no new surface — and it retires the hardcoded 0.86 CLAUDE.md flags as *"hardcoded
    ///      three times over … should be READ, never configured"*.
    function _bandBps(uint256 collUsdWad, ILevVenue venue) internal view returns (uint256) {
        uint256 lltv;
        // Same `try` idiom as `_rangePrice`: a venue that cannot answer must not strand a position.
        // Unanswered ⇒ zero headroom ⇒ band 0 ⇒ rebalance always, the fail-safe direction.
        try venue.liqThresholdBps() returns (uint256 t) { lltv = t; } catch { return 0; }
        // §E358 — the headroom is the PROTOCOL's, not a position's: one cap for the whole book.
        uint256 headroom = lltv > TARGET_LTV_CAP_BPS ? lltv - TARGET_LTV_CAP_BPS : 0;
        return LevMath.bandBpsFor(address(AUX), RANGE, TWAP_WINDOW, GAS_REBALANCE, collUsdWad, headroom);
    }

    /// @notice How far the LP's debt is from the IL-hedge target, and in which direction.
    /// @dev §FOLD-DELTA — was duplicated on each manager (0.71 similarity). The two bodies computed
    ///      the SAME thing in a different statement order; the only real difference was ETH's
    ///      `if (!p.open)` early-out. BTC was not buggy — `closeBtcLev` does `delete pos[lp]`, so
    ///      `ilBasisPx == 0` makes `_ilTargetLive` return 0 and `debtDelta` reports in-range —
    ///      whereas ETH RETAINS the `Pos` with `open = false` on its keepState branch, which is why
    ///      only ETH needed the gate. A REAL asymmetry; the shared body keeps the gate because it is
    ///      correct for both and strictly cheaper than reaching `debtUsd` for a closed position.
    function debtDeltaToTarget(address lp) public view returns (bool levUp, uint256 amountUsd) {
        (bool open, uint256 e0, uint256 debtNow, uint256 target) = _targetInputs(lp);
        if (!open) return (false, 0);
        return LevMath.debtDelta(e0, debtNow, target, _bandFor(lp, e0));
    }

    /// @dev The band for `lp`'s OWN position — the venue it borrows from and the cap it chose.
    ///      §E357 — one routine because `debtDeltaToTarget` and `LevManager.deleverRepayUsd` each
    ///      grew an identical copy of it (`find-duplicate-bodies.py` scores the pair at 73.9%). They
    ///      already shared `_targetInputs`; this is the other half, and keeping it in one place also
    ///      means the band a position is JUDGED by and the band it is REPAID to cannot drift apart —
    ///      which is the same failure `_targetInputs`' own docblock exists to prevent.
    function _bandFor(address lp, uint256 collUsdWad) internal view returns (uint256) {
        Types.Pos memory p = pos[lp];
        return _bandBps(collUsdWad, p.venue);
    }

    /// @dev The four inputs EVERY target comparison needs, resolved in ONE place. `debtDeltaToTarget`
    ///      here and `LevManager.deleverRepayUsd` each rebuilt this preamble verbatim — load the
    ///      position, refuse a closed one, read the TWAP, derive E0 and the live IL target. Two
    ///      assemblies of the same comparison inputs can drift apart without reverting: they would
    ///      simply answer "lever up" and "repay this much" from different targets.
    ///      ⚠ `open == false` ⇒ the other three are zero and MUST NOT be read. This helper
    ///      deliberately does NOT decide what a closed position means, because the two callers
    ///      disagree on the shape of "nothing to do" (`(false, 0)` here, plain `0` there).
    function _targetInputs(address lp)
        internal view returns (bool open, uint256 e0, uint256 debtNow, uint256 target)
    {
        Types.Pos memory p = pos[lp];
        if (!p.open) return (false, 0, 0, 0);
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return (true, LevMath.entryEquityUsd(p.entryEquity, px), debtUsd(lp), _ilTargetLive(p, px));
    }

    /// Oracle (`getTWAPforAsset`) + the caller-funded paths both managers reach through.
    IAux public immutable AUX;

    /// @notice The asset this instance prices against — WETH on the ETH side, WBTC on the BTC side.
    ///         THE ONLY per-asset input to the shared valuation bodies. Before this existed, every
    ///         shared function differed solely by naming `WETH` or `WBTC` in its TWAP call, which is
    ///         what kept ~20 otherwise-identical lines from being one implementation.
    address public immutable ORACLE_KEY;

    // ─── §J.2 UNIFICATION — state that was declared TWICE, once per manager ──────────────────────
    // Every field below existed identically (or near-identically) in BOTH `LevManager` and
    // `BtcLevManager`. They are hoisted here as the first half of collapsing the pair into ONE
    // implementation with TWO INSTANCES — CLAUDE.md's §J.2 target, and the thing `isBTC`
    // polymorphism-by-hand exists to avoid.
    // ⚠️ HOISTING STATE INTO AN ABSTRACT BASE IS NOT ITSELF A BYTE SAVING (CLAUDE.md measured a fold
    //    of BODIES into a base at +41 bytes, zero saved) — immutables inline at each use exactly as
    //    before. What it buys is that the two managers stop DIVERGING, and that the merge has one
    //    place to merge INTO. The bytes come at the merge, when the second copy stops existing.

    /// Governance — the only party that may `init`. Was `address immutable GOV` in both managers.
    address public immutable GOV;

    /// The basket stablecoin, redeemed via `AUX` to repay a levered LP's OWN debt.
    /// §DEDUP-TYPES — `LevManager` held this as `IERC20Min` and `BtcLevManager` as `address`, for one
    /// `address(QUID)` use and zero direct uses respectively. The ADDRESS is the honest type: nothing
    /// on either side ever called an ERC-20 method on it.
    address public immutable QUID;

    /// The collateral this instance levers: weETH on the ETH side, vBTC on the BTC side. Was `WEETH`
    /// and `VBTC` — two names for "the venue's collateral token", neither read off the manager
    /// externally (`WEETH()` is read off `Quid`/`EthVenue`, which is a different contract).
    IERC20Min public immutable COLL;

    /// @notice weETH→ETH rate source. **ZERO MEANS `COLL` IS ALREADY BASE-DENOMINATED**, which is the
    ///         BTC case (vBTC IS sats, so the conversion is the identity).
    /// @dev §SEAM — THE PER-ASSET DIFFERENCE IS DATA, NOT CODE: "is there a rate source?" is a
    ///      constructor argument, so `_collToBase` is ONE concrete body with no `virtual` and no
    ///      per-manager override, and the merge has one seam point fewer to reconcile.
    IWeETH internal immutable RATE;

    /// Anti-Sybil floor on an open, in `COLL` units: 0.05e18 weETH on ETH, 50_000 sats (0.0005 BTC)
    /// on BTC. Same role, different denomination — so it is DATA, not a per-manager constant.
    uint256 public immutable MIN_OPEN;

    /// 1% oracle-derived floor on EVERY swap (anti-MEV). Was declared with the SAME VALUE in both.
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;

    /// Venue allowlist freeze — pin-once in `init`, then immutable. Both managers had it.
    bool public venuesFrozen;

    /// Morpho zero-fee flash provider (set in `init`), powering the flash-repay-first de-lever.
    address public flashProvider;

    uint256 private _lock = 1;

    /// @dev §RULE-8C — THE CHECK-AND-SET HALF IS A FUNCTION, SO EACH USE SITE COSTS A JUMP RATHER
    ///      THAN A COPY of `if (_lock != 1) revert Reentrancy(); _lock = 2;`. Folding it out of the
    ///      inline sites measured **+440 bytes** on the ETH side, and both managers inherit it here.
    /// ⚠️ THE RELEASE STAYS INLINE, AND THE STRUCTURE IS LOAD-BEARING: `_;` sits BETWEEN enter and
    ///      release, so every early return still releases the lock. Hoisting the release into a
    ///      function would not — and it is one `SSTORE`, so a call would cost more than it saves.
    modifier nonReentrant() { _enter(); _; _lock = 1; }
    function _enter() private { if (_lock != 1) revert Reentrancy(); _lock = 2; }

    /// @notice `COLL` units → the range's base unit (ETH wei / sats).
    /// @dev Not `virtual` — the per-asset difference is the `RATE` immutable, and this is the
    ///      identity when there is no rate source.
    function _collToBase(uint units) internal view returns (uint) {
        if (units == 0 || address(RATE) == address(0)) return units;
        return RATE.getEETHByWeETH(units);
    }

    /// Per-LP, one isolated position. PUBLIC ⇒ ABI-visible 6-tuple getter (see note above).
    mapping(address => Types.Pos) public pos;

    /// @dev Enumerable set of LPs with an open position, so the whole book's live net equity can be
    ///      summed on-chain. `_lpIdx` is 1-based (0 = absent); removal is swap-and-pop.
    address[] internal _openLps;
    mapping(address => uint256) internal _lpIdx;

    /// The range's sync range (Quid's `syncLev` / Vault's `syncLev`). GOV pin-once, then frozen —
    ///  the SETTER stays per-manager (BtcLevManager fuses it into `init` alongside `venuesFrozen`).
    address public RANGE;

    /// @notice §RANGE-UNWIND — the venue the RANGE uses when it force-closes a lever for an LP.
    /// @dev 🔴 **THE RANGE IS NOT A KEEPER AND CANNOT DISCOVER A ROUTE, AND §G.7 REQUIRES IT TO
    ///      TRADE ANYWAY.** `Quid.withdraw` auto-de-levers a withdrawal that reaches past an LP's
    ///      free depth into its own in-range levered slice (`Quid.sol:807`, #109), and that unwind's
    ///      debt-repay leg has to SELL. Every other volatile hop is fed a pool word by whoever
    ///      submits the tx; this one has no such caller — the range is executing the LP's own exit
    ///      inside `withdraw`, with no off-chain step to consult.
    ///      ⚠️ **THIS IS NOT THE "FALLBACK ROUTE MACHINERY" THAT WAS DELETED.** That was a SECOND
    ///      venue tried when a keeper's first choice failed — a silent downgrade of execution on a
    ///      path that already had a router. This is the ONLY venue on a path that has no router at
    ///      all, and it is not consulted anywhere a keeper can supply one: `closeLevFor` is
    ///      `_onlyRange()`, so `msg.sender == RANGE` is the whole audience.
    ///      ⛔ IT IS A CONSTANT AND THERE IS DELIBERATELY NO WAY TO REPOINT IT — THIS SYSTEM HAS NO
    ///      GOVERNANCE KNOBS (owner, 2026-09-07). If `DEFAULT_UNWIND_DEX` ever stops being the deepest
    ///      ETH/USDC pool, the fix is a code change and a redeploy, not a privileged write. ⛔ Do not
    ///      add a setter: the one that used to sit here was gated on RANGE — not GOV, despite the
    ///      justification written beside it — and RANGE never called it, so the slot was permanently 0
    ///      and every read fell through to the default regardless.
    /// The venue the range unwinds through. A function, not a bare constant, so the docblock above
    /// has a home and the call site keeps reading as a lookup rather than a magic number.
    function _unwindDex() internal pure returns (uint256) { return DEFAULT_UNWIND_DEX; }

    /// @notice §E298 — the five events `LevManager` and `BtcLevManager` each declared separately.
    ///         Both inherit this contract, so one declaration here reaches both and an inherited
    ///         event still appears in each child's ABI. Three were already byte-identical at every
    ///         emit site. Two had DRIFTED and are reconciled to the richer ETH shape:
    ///         `Opened` lacked `venue` on the BTC side even though BTC picks a venue too
    ///         (`ILevVenue(address(venue)).COLLATERAL()` decides vBTC vs WBTC mode), and
    ///         `VenueAllowed` lacked the `ok` flag, so a BTC de-authorisation was indistinguishable
    ///         from an authorisation in the log.
    /// ⚠️ `Closed`'s parameter is `assetReturned` — the venue's OWN collateral token, weETH at the
    ///         ETH instance and vBTC at the BTC one. DO NOT re-spell it per asset: one declaration
    ///         means one topic0 across both instances, and a per-asset name would put the same
    ///         topic0 on two different meanings, which an indexer reading both cannot tell apart.
    event Opened(address indexed lp, address venue, uint256 targetLtvBps);
    event Closed(address indexed lp, uint256 assetReturned);
    event VenueAllowed(address indexed venue, bool ok);
    event DeleverFailed(address indexed lp, uint256 ltvBps);
    event ProtectedFromQuid(address indexed lp, uint256 quidRedeemed, uint256 debtRepaid);
    event ReanchoredToRange(address indexed lp, uint syncKeyPx, uint256 entryEquity);

    error NotOpen();
    error BadTarget();

    /// §J.2 — ONE constructor for both instances. `rate == 0` means `coll` is already denominated in
    /// the range's base unit (the BTC case: vBTC IS sats), which is the whole of the per-asset
    /// difference `_collToBase` has to carry.
    constructor(address aux, address oracleKey, address gov, address quid,
                address coll, address rate, uint256 minOpen) {
        AUX = IAux(aux); ORACLE_KEY = oracleKey;
        GOV = gov; QUID = quid; COLL = IERC20Min(coll); RATE = IWeETH(rate); MIN_OPEN = minOpen;
    }

    /// @notice Poke the range to reconcile `lp`'s levered slice to live net equity. ONE routine for
    ///         what was THIRTEEN byte-identical inlined copies (6 in `LevManager`, 7 in
    ///         `BtcLevManager`), every one of them exactly
    ///         `if (RANGE != address(0)) { try ICore(RANGE).syncLev(lp) {} catch {} }`.
    /// @dev    §FOLD-SYNC. A FUNCTION, not a modifier, per standing rule 8c: a modifier's body is
    ///         inlined at every use site, so 13 uses would be 13 copies again — which is the thing
    ///         being removed. This is one body and 13 jumps. Precedent for the direction: §E210
    ///         collapsed per-stable `if` chains into one table and handed back 435 bytes on
    ///         `LevMath` — folding N INLINED BODIES into one routine gives bytes back, whereas
    ///         folding a whole CONTRACT in costs them (its code still has to land somewhere).
    ///
    ///         WHY THE try/catch IS LOAD-BEARING AND MUST NOT BECOME A BARE CALL: this is a
    ///         PERMISSIONLESS courtesy poke on the tail of money-moving operations. If the range
    ///         reverts, the lever/delever that already succeeded must still commit — the slice is
    ///         separately reconcilable by anyone calling `syncLev` directly, so a failed poke costs
    ///         a delay, while a propagated revert would strand the position. The `RANGE != 0` guard
    ///         is not defensive dressing either: `RANGE` is pin-once and genuinely unset between
    ///         deploy and wiring, and a call to address(0) SUCCEEDS silently rather than reverting,
    ///         so without it an unwired deploy would look reconciled and not be.
    /// @notice §FOLD-REBALANCE — THE ONE REBALANCE, FOR BOTH RANGES.
    /// @dev Both managers ran this identical shape: reanchor, require open, read the target, branch on
    ///      direction, sync the range. FOUR things actually differed and each is now a seam:
    ///        • an extra per-asset precondition (BTC requires WBTC collateral)  -> `_requireRebalancable`
    ///        • which lever-up leg runs                                          -> `_leverUp`
    ///        • which de-lever leg runs                                          -> `_delever`
    ///        • ETH emitted `Rebalanced`, BTC emitted NOTHING. That was an OBSERVABILITY GAP, not a
    ///          per-asset fact, so the shared body emits for both. ⚠️ A BTC rebalance now logs where it
    ///          previously did not — an ADDED event, which no consumer can break on, but say so.
    ///      ⚠️ `_delever` RECEIVES `deltaUsd` AND IS FREE TO IGNORE IT: ETH re-derives the closed-form
    ///      `Δ/(1−t)` via `deleverRepayUsd` so one flash lands on target with no withdraw-before-repay
    ///      health breach, while BTC repays the delta directly. The two ranges size the repay differently
    ///      and that is REAL, not drift.
    /// @dev Order note: ETH checked `open` BEFORE reanchoring and BTC after. Immaterial —
    ///      `_reanchorIfReseated` already early-returns on a closed position.
    /// @param dex AggregationRouter calldata for the volatile leg, computed OFF-CHAIN and passed
    ///        in. §E357 — **BOTH DIRECTIONS NEED ONE**, which is why it lives here and not on the
    ///        de-lever alone: `_leverUp` reaches `_stableToWethSor` → `_aggSwap` (stable→WETH) and
    ///        `_delever` reaches the sell twin, so a rebalance that levers UP was equally unable to
    ///        execute. Every keeper entrypoint previously passed nothing at all and `_aggSwap`
    ///        refuses an empty route, so **the whole keeper path reverted `NoVolatileRoute()`
    ///        regardless of any API key** — the volatile-route hole that has now been re-opened
    ///        three times (`Interfaces.sol:303`).
    /// ⛔ **THE CONTRACT DOES NOT DISCOVER A ROUTE AND MUST NOT LEARN TO.** Under v4 a pool is
    ///        `(currency0, currency1, fee, tickSpacing, hooks)` rather than an address, so liquidity
    ///        is fragmented across pools by hook and no pinned address can even NAME the deepest
    ///        one — which is precisely the job an aggregator does. Discovery is off-chain; the
    ///        contract's only defence is the oracle floor, which is unchanged and venue-agnostic.
    function _rebalance(address lp, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) internal {
        _reanchorIfReseated(lp);
        Types.Pos memory p = pos[lp];
        if (!p.open) revert NotOpen();
        _requireRebalancable(p);
        address stable = p.venue.stable();
        (bool levUp, uint256 deltaUsd) = debtDeltaToTarget(lp);
        if (deltaUsd != 0) {
            if (levUp) _leverUp(p.venue, lp, stable, deltaUsd, minOut, dex, dex2, route);
            else       _delever(p.venue, lp, stable, deltaUsd, minOut, dex, dex2, route);
            emit Rebalanced(lp, levUp, deltaUsd, getCurrentLtvBps(lp));
        }
        _syncRange(lp);
    }

    event Rebalanced(address indexed lp, bool levUp, uint256 amount, uint256 ltvBps);

    /// @dev Per-asset precondition. ETH has none; BTC requires WBTC collateral.
    function _requireRebalancable(Types.Pos memory p) internal view virtual {}
    function _leverUp(ILevVenue venue, address lp, address stable, uint256 deltaUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) internal virtual;
    function _delever(ILevVenue venue, address lp, address stable, uint256 deltaUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) internal virtual;

    function _syncRange(address lp) internal {
        if (RANGE != address(0)) { try ICore(RANGE).syncLev(lp) {} catch {} }
    }

    /// @notice The range's anchor price, or 0 if the range is unwired or reverts. §FOLD-SYNC — was
    ///         inlined identically in both managers' open paths.
    /// @dev    Returning 0 rather than reverting is deliberate and matches the pre-fold behaviour:
    ///         `syncKeyPx` is the sold-fraction REFERENCE, and `_ilTargetLive`/`reanchorCompute`
    ///         already treat 0 as "never anchored" (that is what `_reanchorIfReseated` exists to
    ///         repair). Reverting here would make an unwired range block position OPENING, which is
    ///         strictly worse than opening with a reference that the first reanchor fills in.
    function _rangePrice() internal view returns (uint px) {
        if (RANGE != address(0)) {
            try ICore(RANGE).rangePrice() returns (uint s) { px = s; } catch {}
        }
    }

    /// @notice Write a fresh position and enrol the LP in the book. §FOLD-OPEN — this tail was
    ///         duplicated verbatim in `LevManager.openLev` and `BtcLevManager.openBtcLev`; the two
    ///         differed ONLY in how they computed `entryEquity` (weETH→ETH for the ETH side, sats-as-is for
    ///         BTC, because vBTC IS sats) and in the local name of the LTV cap. Everything after
    ///         that — the range-price read, the `Types.Pos` literal, the book enrolment — was one
    ///         shape written twice, and a struct literal is not cheap in bytecode.
    /// @param  entryEquity  the IL base, FIXED at open. Caller computes it because it is the one genuinely
    ///             per-asset quantity here; passing it in is what lets the rest be shared.
    /// @notice §FOLD-MEASURE — body in `RangeLib` (§FOLD-BOOK). `_rangePrice()` is resolved HERE because it
    ///         try/catches a call to `RANGE`, and the struct is built here so the library takes one
    ///         memory pointer rather than five scalars (cheaper seam, and `Types.Pos`'s field order
    ///         stays owned by one place).
    function _openPos(ILevVenue venue, uint entryPx, uint entryEquity) internal {
        // §POOL-VENUE — pin the pool on the FIRST open; refuse any second venue for this range.
        // One position means one venue, and this is the only place that can be enforced cheaply.
        if (poolVenue == address(0)) poolVenue = address(venue);
        else if (poolVenue != address(venue)) revert VenueNotPooled();
        // §MULTI-VENUE step 1 — record it in the walked set. Idempotent: an LP joining the existing
        // pooled position must not append a duplicate, or every aggregate double-counts the book.
        if (!isPoolVenue[address(venue)]) { isPoolVenue[address(venue)] = true; poolVenues.push(address(venue)); }
        RangeLib.openPos(pos, _openLps, _lpIdx, msg.sender,
            Types.Pos({venue: venue, ilBasisPx: uint128(entryPx),
                       entryEquity: uint128(entryEquity), syncKeyPx: _rangePrice(), open: true}));
    }

    function _untrackOpen(address lp) internal {
        RangeLib.untrackOpen(_openLps, _lpIdx, lp);   // §FOLD-MEASURE
    }

    // ⚠️ §WSA-LEV-INERT — A LIVE INVARIANT ON `TARGET_LTV_CAP_BPS`, AND IT FAILS SILENTLY.
    // A cap at or below the band pins a position inside the deadband at EVERY price, so
    // `venue.borrow` is never reached and the overlay does nothing rather than saying so.
    // IL-protect is a PROTOCOL-WIDE liability on behalf of all LPs — no LP carries a
    // debt-to-collateral ratio of its own — so there is ONE cap for the whole book and it must stay
    // above the band, or the whole book is inert. It is 7500 bps against a band measured in tens,
    // so it holds by a wide margin today — but it is an invariant on a constant, not a per-call
    // check, and moving either number has to preserve it.

    /// @notice Venue + stable + native amount for a swap-out-driven delever of `lp`.
    function swapOutDeleverAmt(address lp, uint256 maxUsd18)
        external view returns (address venue, address stable, uint256 amtNative) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return (address(0), address(0), 0);
        venue = address(p.venue);
        stable = p.venue.stable();
        amtNative = LevMath._fromUsd(address(AUX), stable, maxUsd18);
    }

    /// @notice §POOL-VENUE — THE PINNED POOL. Set on the FIRST open and never cleared.
    /// ⛔ DO NOT DERIVE THE VENUE FROM THE BOOK (`pos[_openLps[0]].venue`) — THAT CARRIES A SILENT
    ///    UNDER-REPORT. Reading the book's first entry is correct only while the book is non-empty,
    ///    and the pool can hold residual collateral or debt after the LAST position closes (a
    ///    rounding remainder, or an LP closed while the pool was mid-de-lever). The book is then
    ///    empty, the read yields `address(0)`, and EVERY aggregate — `totalDebtUsd`,
    ///    `totalNetEquity`, `totalGrossCollateral`, `totalDeliverableDollars` — reports **0 for a
    ///    pool that is not empty**. Nothing reverts; the backing math simply stops seeing it.
    /// ⇒ A pinned venue cannot go stale that way: it is the pool's identity, not a fact about who
    ///   currently holds a claim on it. It also makes the one-venue-per-range assumption EXPLICIT
    ///   rather than incidental — see the warning below, which is now enforceable.
    /// ⚠️ If a second venue is ever admitted for one range, this pin is where it breaks, loudly and
    ///    in one place: `_openPos` reverts rather than silently pooling two positions into one set of
    ///    aggregates. That is the failure we want.
    address public poolVenue;
    error VenueNotPooled();

    /// @notice §MULTI-VENUE step 1 — EVERY venue this book holds a position in, in open order.
    ///         `poolVenue` remains `poolVenues[0]`: it is the pool's identity and the thing
    ///         `SwapLib.deleverEthOnDelivery` and `LevManager`'s delivery guard already read.
    /// ⭐ WHY THIS LANDS WHILE THE PIN IS STILL IN PLACE. `_openPos` still refuses a second venue, so
    ///    this array has exactly one entry today and every aggregate below is BYTE-IDENTICAL to the
    ///    O(1) form it replaces. That is the point: the walk is verifiable NOW, against a book whose
    ///    numbers are already pinned by `PoolVenueAggregates.t.sol`, instead of being written and
    ///    verified in the same commit that first admits a second venue.
    /// ⚠️ BOUNDED BY CONSTRUCTION, SO THIS IS NOT THE Σ-LOOP THE §POOL-VENUE WORK DELETED. That one
    ///    was O(open LPs) and grew without limit as the protocol succeeded. This is O(venues), and
    ///    the venue allowlist is FROZEN at init (`venuesFrozen`), so its ceiling is fixed before the
    ///    first position ever opens — three entries today.
    /// ⛔ ENTRIES ARE NEVER REMOVED, deliberately, for the reason the pin exists: a venue can hold a
    ///    residual remainder after its last LP closes, and dropping it would make the aggregates
    ///    report 0 for a pool that is not empty — the exact silent under-report `poolVenue` replaced
    ///    `pos[_openLps[0]].venue` to fix.
    address[] public poolVenues;
    mapping(address => bool) public isPoolVenue;

    /// @notice How many venues the book holds positions in. 0 before the first open.
    function poolVenueCount() external view returns (uint256) { return poolVenues.length; }

    /// §POOL-VENUE — BOUNDED BY VENUE COUNT, NOT BY OPEN LPs. Each venue holds ONE pooled position,
    /// so its deliverable dollars come from that pool's own collateral, debt and liquidation
    /// threshold — exactly the per-LP formula, evaluated once per venue instead of once per LP.
    /// ⚠️ THIS IS NOT THE SAME NUMBER A PER-LP SUM PRODUCES, AND THE DIFFERENCE IS THE POINT.
    /// `LevMath.deliverableDollars` is NON-LINEAR in LTV (it bounds the extraction so the position
    /// stays under its liquidation threshold), so a sum of per-LP results systematically DIFFERS
    /// from the aggregate — the same sum-of-floors error that made `totalNetEquity` over-count and
    /// tripped `checkBacking`. One pooled position means one evaluation of it, which is the honest one.
    function totalDeliverableDollars() external view returns (uint usd) {
        // §POSITION-IS-THE-LENDERS-OWN-VIEW — the POOL-level twin of `getCurrentLtvBps`, and it has
        // to move in the SAME commit: leaving this on `AUX` while the per-LP path reads the venue
        // would give the contract two disagreeing notions of the same pool's health, and they would
        // only diverge once the venue's oracle drifted from ours — i.e. in production.
        // No TWAP read, no `_collNativePool`, no `_toUsd18` on this path: both sides share the
        // venue's quote unit, so nothing needs converting.
        // 🔴 §MULTI-VENUE — AND THIS SUMS **PER VENUE**, WHICH IS THE OPPOSITE OF `totalNetEquity`.
        //    The two look like the same shape and the difference is the whole correctness question:
        //      · `totalNetEquity` asks *what is the book worth* — one number over pooled totals, so an
        //        underwater venue's deficit MUST offset a solvent one's surplus. Floor once.
        //      · this asks *what can actually be withdrawn today* — and that is gated by each venue's
        //        OWN `liqThresholdBps` against its OWN collateral. Venue A's spare collateral cannot
        //        unlock a withdrawal from venue B; they are separate lending positions with separate
        //        liquidation engines. An underwater venue contributes 0 because nothing can be taken
        //        out of it, and that zero is CORRECT rather than a clamp hiding a deficit.
        //    ⇒ Summing floored per-venue values is the bug in one and the requirement in the other.
        uint256 n = poolVenues.length;
        for (uint256 i; i < n; ++i) {
            VenuePosition memory pp = ILevVenue(poolVenues[i]).position();
            uint collUsd = pp.collateral;
            uint d = pp.debt;
            uint netEq = collUsd > d ? collUsd - d : 0;
            usd += LevMath.deliverableDollars(netEq, collUsd, LevMath.ltvBps(d, collUsd), pp.liqThresholdBps);
        }
    }

    /// @dev ⚠️ WHEN THESE MOVE TO A DELEGATECALL LIBRARY, THE CALLER COMPUTES THIS AND PASSES IT AS
    ///      A VALUE — a library cannot call a virtual on its caller. That constraint is why the
    ///      per-asset step is kept as narrow as possible: one `uint → uint` conversion is trivial to
    ///      pass by value, whereas a range that needed the venue or the LP would not be.
    /// @notice §FOLD-COLL — **THE ONLY PER-ASSET PRIMITIVE IN THE VALUATION STACK** (`_collToBase`,
    ///         declared above). Collateral UNITS as held by the venue → the instance's native base
    ///         unit, and the two sides differ ONLY in whether there is a rate source:
    ///           • ETH: weETH → eETH/ETH via the ether.fi rate (`RATE.getEETHByWeETH`).
    ///           • BTC: IDENTITY — vBTC IS sats, and the WBTC price already carries the ×1e10 lift
    ///             that closes the 8↔18 decimal gap, so a second conversion here would double-count.
    /// @dev    It takes UNITS, not `(venue, units)`: the conversion is a property of the INSTANCE
    ///         (`RATE`), not of the venue, so a venue argument would widen the signature without
    ///         being read.

    /// @notice Collateral units → USD(1e18) at the instance's own oracle key. §FOLD-COLL — one
    ///         formula, `base · TWAP / 1e18`, for both instances: the only per-asset step is the
    ///         `_collToBase` conversion, which is the identity on the BTC side.
    function collValueUsd(uint units) public view returns (uint) {
        if (units == 0) return 0;
        return (_collToBase(units) * AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW)) / 1e18;
    }

    /// @notice Per-LP collateral in the native base unit. §FOLD-COLL — CONCRETE, not `virtual`: the
    ///         venue reports raw collateral units on both sides and `_collToBase` carries the whole
    ///         per-asset difference, so there is nothing left for an override to say.
    function _collNative(ILevVenue v, address lp) internal view returns (uint) {
        return _collToBase(v.collateralOf(lp));
    }

    /// @notice The LP's venue debt in USD(1e18). §FOLD-LTV — was declared `virtual` here and
    ///         overridden with the SAME body in both managers (0.88 similarity; the only difference
    ///         was ETH hoisting `v.stable()` into a local). Concrete now, and the overrides go.
    /// @dev ⚠️ THE `address(v) == 0` EARLY-OUT IS NOT A DEFENSIVE CLAMP — it is the one case the
    ///      §FOLD-LTV trace below missed. That note argues the `!open` guards were droppable because
    ///      every downstream helper returns 0 on a zeroed struct. True — but ALL of them are reached
    ///      THROUGH this function, and a zeroed `Pos` zeroes `venue` too, so `v.stable()` is a
    ///      high-level call to `address(0)`: solc's extcodesize check REVERTS before any zero-guard
    ///      runs. `BtcLevManager.closeBtcLev` does `delete pos[lp]`, so this is reachable for every
    ///      closed BTC position and any address that never opened one — and `debtUsd`,
    ///      `getCurrentLtvBps` and `debtDeltaToTarget` are all `public`. Returning 0 for "no position"
    ///      makes the query TOTAL; it cannot mask a real debt, because a real debt requires a venue.
    function debtUsd(address lp) public view returns (uint) {
        ILevVenue v = pos[lp].venue;
        if (address(v) == address(0)) return 0;
        return LevMath._toUsd18(address(AUX), v.stable(), v.debtOf(lp));
    }

    /// @notice Delegated QU!D-protect: redeem the LP's OWN opted-in QU!D to repay the LP's OWN debt
    ///         when the position nears venue liquidation. Moves NO value to the caller.
    ///
    /// §PROTECT-FOLD (2026-08-22) — ONE body for both managers. The two copies were identical except
    /// for the keeper reimbursement, which is now the `_afterProtect` seam — so the gate, the
    /// `LevMath.protectExec` call and the event live once.
    /// ⚠️ **THE MECHANICS WERE ALREADY SHARED** — both copies delegated to the SAME
    /// `LevMath.protectExec`. What was duplicated was the WRAPPER, which is the part that drifts
    /// silently: a gate added to one side and not the other reads as a per-asset decision.
    /// ⚠️ **`internal`, AND THE REENTRANCY GUARD SITS ON THE ENTRYPOINT, NOT HERE.** `_lock`,
    /// `nonReentrant` and `_enter()` are all declared in this contract above; each manager exposes a
    /// thin `external nonReentrant protectFromQuid` over this body. The guard belongs where the call
    /// ENTERS, and the body — the gate, the `protectExec` call, the event — lives once, which is the
    /// part that drifts silently.
    function _protectFromQuidBody(address lp, uint256 minStableOut) internal returns (uint256 repaid) {
        if (!pos[lp].open) revert NotOpen();
        uint256 pull;
        (pull, repaid) = LevMath.protectExec(
            // §POOL-VENUE — **THE NEAR-LIQUIDATION GATE MUST READ THE POOL, NOT THE LP.**
            // `protectExec` refuses (`NotNearLiq`) unless `curLtvBps + PROTECT_MARGIN_BPS >=
            // liqThresholdBps`. Liquidation is POOLED: Morpho holds ONE position under the venue and
            // seizes it whole, hitting every LP pro-rata (see `LevVenueBase`'s header). So gating on this
            // LP's own ratio asks a question liquidation does not depend on — a comfortable LP
            // inside a stressed pool is refused protection right up until the pool is seized, and
            // then the loss lands on it anyway.
            // ⇒ MAX of the two, the same shape the Rust keeper's safety gate now uses: the POOL
            //   figure is the trigger (is the book in danger), the per-LP one identifies who to act
            //   on. Taking the max means neither can mask the other, and it is a strict SUPERSET of
            //   the old gate — it can only ever admit MORE protection, never less.
            QUID, address(AUX), address(pos[lp].venue), lp,
            _worstLtvBps(lp), minStableOut);
        _afterProtect(msg.sender);
        emit ProtectedFromQuid(lp, pull, repaid);
    }

    /// @dev Post-protect keeper settlement. ETH reimburses from the WETH gas reserve; BTC has no
    ///      reserve to draw on, so the default is a NO-OP and that asymmetry is REAL, not drift.
    function _afterProtect(address keeper) internal virtual {}

    /// @notice Live LTV against CURRENT collateral value (the venue-liquidation view).
    /// @dev    §FOLD-LTV. ⚠️ THE `if (!open) return 0` EARLY-OUTS FROM THE ETH COPIES ARE DROPPED,
    ///         AND THAT IS A DELETION OF DEAD CHECKS, NOT A WEAKENING — traced through every layer
    ///         before removing them: a closed position zeroes the struct, and
    ///         `LevMath.ltvBps` returns 0 when `collValue == 0`, `collValueUsd` returns 0 when
    ///         `units == 0`, and `ilTargetBps` returns 0 when `ilBasisPx == 0`. So every path
    ///         returns 0 for a closed position WITHOUT the guard. The BTC copies never had it and
    ///         were correct; the asymmetry was drift, and keeping it would have been a clamp that
    ///         cannot change an outcome (standing rule 3).
    /// @dev §POSITION-IS-THE-LENDERS-OWN-VIEW — BOTH SIDES NOW COME FROM THE VENUE, so this is the
    ///      LTV the LENDER computes rather than the one our oracle implies. That is a correctness
    ///      change, not a simplification: the old body priced debt through `AUX`'s feed for
    ///      `v.stable()` and collateral through `AUX.getTWAPforAsset`, while Aave liquidates on ITS
    ///      oracle — so the two could disagree, and the direction that matters is believing we are
    ///      at 70% while the venue believes 80%.
    ///      ⭐ It also deletes the unit problem rather than solving it: `p.debt` and `p.collateral`
    ///      share the venue's quote unit, so the ratio is unitless and NO conversion is needed on
    ///      either side. `positionOf` (not `position`) because per-LP shares of debt and collateral
    ///      are independent fractions — see `ILevVenue.positionOf`.
    function getCurrentLtvBps(address lp) public view returns (uint) {
        ILevVenue v = pos[lp].venue;                       // same address(0) case as `debtUsd`
        if (address(v) == address(0)) return 0;
        VenuePosition memory p = v.positionOf(lp);
        return LevMath.ltvBps(p.debt, p.collateral);
    }

    /// @notice §POOL-VENUE — `poolLtvBps` (declared below) IS THE LTV THE VENUE ACTUALLY LIQUIDATES
    ///         ON: debt and collateral of the pooled position, not of any LP.
    /// @dev 🔴 **`getCurrentLtvBps` IS NOT THIS NUMBER, AND THE KEEPER WAS WATCHING THAT ONE.** Since
    ///      the venue holds a single Morpho position (`address(this)` on every call), Morpho's health
    ///      check reads the AGGREGATE — so an LP can be individually comfortable while the pool sits
    ///      one tick from liquidation, and a keeper gated on the per-LP figure HOLDS through it. That
    ///      is the no-liquidation guarantee failing OPEN, which is the direction that does not
    ///      announce itself: nothing reverts, nothing logs, until the pool is seized and
    ///      `LevVenueBase:117`'s "a liquidation hits every LP pro-rata" lands on the whole book.
    ///      ⚠️ The per-LP view is still correct FOR WHAT IT MEASURES and is still the right input for
    ///      choosing WHICH LP to de-lever — it is the contributor. This is the trigger; that is the
    ///      target. Both are needed and neither substitutes for the other.
    ///      Both read the VENUE (`position()` for the pool, `positionOf()` per LP) and both ratio
    ///      through `LevMath.ltvBps`, so the aggregate and the per-LP reads cannot drift apart by a
    ///      convention or by a quote unit.
    /// @dev The LTV that decides whether protection may fire: the WORSE of this LP's own ratio and
    ///      the POOL's. No `Math` import for one comparison — a ternary is the whole body.
    function _worstLtvBps(address lp) internal view returns (uint) {
        uint a = getCurrentLtvBps(lp); uint b = poolLtvBps();
        return a > b ? a : b;
    }

    /// @dev §POSITION-IS-THE-LENDERS-OWN-VIEW — the THIRD and last venue-health LTV to move onto the
    ///      venue's own view, and the one the KEEPERS read (`poolLtvBps()` is in
    ///      `check-signer-allowlist`'s READ_ONLY set, sampled in both keepers' snapshot builders).
    ///      Leaving it behind would have meant the keeper deleveraged against OUR oracle while the
    ///      venue liquidated against ITS own.
    ///      ⛔ NOTE WHICH LTV DELIBERATELY DID **NOT** MOVE: `ilLtvBps` measures debt against
    ///      `entryEquity`, a HISTORICAL basis recorded in AUX units at open. Pairing a venue-quoted
    ///      debt with an AUX-quoted basis would be a genuine unit error — that one is correct as it
    ///      stands, and it is not an oversight.
    /// §MULTI-VENUE — Σdebt / Σcollateral, NOT the average of per-venue ratios (a mean of ratios is
    /// not the ratio of the sums, and the book's health is the latter). Reduces exactly to the
    /// single-venue value.
    /// ⚠️ HONEST LIMIT, STATED BECAUSE IT DOES NOT EXIST AT ONE VENUE: `VenuePosition` is quote-unit
    ///    18-dec and the quote unit is the VENUE'S OWN, and `liqThresholdBps` is per venue too. Two
    ///    venues with different thresholds do not have one meaningful pooled LTV — this number is a
    ///    book-level indicator, and any per-venue liquidation decision must read that venue's own
    ///    `position()`. Nothing today does otherwise; recorded so nothing starts to.
    function poolLtvBps() public view returns (uint) {
        uint256 n = poolVenues.length;
        uint256 debt; uint256 coll;
        for (uint256 i; i < n; ++i) {
            VenuePosition memory p = ILevVenue(poolVenues[i]).position();
            debt += p.debt; coll += p.collateral;
        }
        return coll == 0 ? 0 : LevMath.ltvBps(debt, coll);
    }

    /// @notice LTV against the FIXED IL base `entryEquity` — the reference the IL target is measured against,
    ///         which is why it does NOT move with collateral. §FOLD-LTV.
    function ilLtvBps(address lp) public view returns (uint) {
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return LevMath.ltvBps(debtUsd(lp), LevMath.entryEquityUsd(pos[lp].entryEquity, px));
    }

    /// @notice The live IL target in bps. §FOLD-LTV. `view` all the way down — `_ilTargetLive`
    ///         reads only the position in memory and the TWAP, and touches the range not at all.
    function ilTargetLtvBps(address lp) public view returns (uint) {
        return _ilTargetLive(pos[lp], AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW));
    }

    /// @notice Per-LP deliverable dollars, taken from the VENUE's own view of this LP's slice.
    ///         NO price argument and NO oracle read: `positionOf` reports debt and collateral in
    ///         ONE quote unit, so the ratio is unitless and there is nothing left to price.
    function _deliverableDollarsAt(address lp) internal view returns (uint) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        // 🔴 **THIS LEG AND `totalDeliverableDollars`'S POOL LEG MUST SHARE ONE VALUATION SOURCE.**
        //    Both read the VENUE; do not price either through AUX. `VBtcLevFeeLane` asserts that a
        //    per-LP deliverable sits within the book aggregate, and pricing one side by our oracle
        //    against the other by the lender's broke it by 2.2e11 on 1.17e21 — not rounding, two
        //    different sources.
        //    ⚠️ §POSITION-LEAVES-THREE-LOOSE-ENDS — *"they must be collapsed in ONE commit, not
        //    migrated caller-by-caller"*. That is why moving one of these legs alone is never safe.
        VenuePosition memory vp = p.venue.positionOf(lp);
        uint netEq = vp.collateral > vp.debt ? vp.collateral - vp.debt : 0;
        return LevMath.deliverableDollars(netEq, vp.collateral,
                                          LevMath.ltvBps(vp.debt, vp.collateral), vp.liqThresholdBps);
    }

    /// @notice Per-LP net equity in NATIVE units at price `px`. THIS one genuinely needs a price,
    ///         unlike `_deliverableDollarsAt`: `netEquityBase` nets a USD debt against NATIVE
    ///         collateral, so `px` is what puts the two in one unit. Floors at zero.
    function _netEquityAt(address lp, uint px) internal view returns (uint) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        return LevMath.netEquityBase(_collNative(p.venue, lp), debtUsd(lp), px);
    }

    /// @notice Per-LP net-of-debt equity in the instance's OWN native unit — 1e18 ETH on the ETH side,
    ///         8-dec sats on the BTC side. The unit differs; the MEANING does not, which is why one
    ///         name serves both, and why `_reanchorIfReseated` needs no per-asset branch.
    function netEquity(address lp) public view returns (uint256) {
        return _netEquityAt(lp, AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW));
    }

    // ─── §LEV-FOLD — five bodies that were written TWICE, identically ─────────────────────────
    //
    // These lived once in `LevManager` and once in `BtcLevManager` and differed only in the
    // spelling `uint` vs `uint256`. Every symbol they touch already lives HERE -- `AUX`,
    // `ORACLE_KEY`, `TWAP_WINDOW`, `_openLps`, `pos`, `_netEquityAt`, `_deliverableDollarsAt`,
    // `debtUsd` -- so neither copy was ever expressing a per-asset difference; the base simply had
    // not been given them. `netEquity` above was the same case one step further along.
    //
    // ⚠️ ONE `ILevEquity` NOW SERVES BOTH INSTANCES, so a handle pointed at the wrong manager no
    // longer reverts on a missing selector — it answers, with the other range's book. What stops
    // that is the ROOT gate, not a name: `Shares.setLevManager` refuses any manager whose
    // `ORACLE_KEY` is not this range's own asset (`Shares.setLevManager`), so a lev manager cannot be
    // pinned to the wrong range at all. Full argument in the ⛔ under §LEV-FOLD-2 below.

    /// @notice Deliverable dollars for `lp` — oracle read ONCE.
    function deliverableDollars(address lp) public view returns (uint256) {
        return _deliverableDollarsAt(lp);   // no price needed — see the note in that function
    }

    /// @notice How many LPs have an open levered position.
    function openLevCount() external view returns (uint256) { return _openLps.length; }

    /// @notice The `i`-th open LP — lets an off-chain keeper enumerate the book.
    function openLpAt(uint256 i) external view returns (address) { return _openLps[i]; }

    /// @notice Live sum of every open position's debt (USD 1e18).
    /// §POOL-VENUE — NOT O(open LPs). Each venue holds ONE pooled position whose `totalDebt()` IS
    /// the sum over its LPs, so the book is never walked. §E332 measured this function's siblings at
    /// up to 18 callers apiece, each O(open LPs) and reachable from state-changing paths — the cliff
    /// that got closer the more the protocol succeeded. It is gone by construction, not clamped.
    /// §MULTI-VENUE — a WALK, and each venue converts through ITS OWN `stable()`. Two venues
    /// denominated in different stables cannot share one conversion, which is why the `_toUsd18` is
    /// inside the loop rather than applied to a summed native total.
    function totalDebtUsd() external view returns (uint256 usd18) {
        uint256 n = poolVenues.length;
        for (uint256 i; i < n; ++i) {
            address v = poolVenues[i];
            usd18 += LevMath._toUsd18(address(AUX), ILevVenue(v).stable(), ILevPooled(v).totalDebt());
        }
    }

    /// @dev The IL target at the live price, for a position already in memory. Two reads and a cap:
    ///      the position's ENTRY-PINNED basis `ilBasisPx` and the live price. It touches neither
    ///      `RANGE` nor storage, which is what lets every caller above it be `view`.
    function _ilTargetLive(Types.Pos memory p, uint256 px) internal view returns (uint256) {
        // ⛔ §C22 — THE TARGET IS THE ENTRY-PINNED ESTIMATE. Do not source it from the range's
        // `soldFractionWad(syncKeyPx)`: that ratio is a CONSTANT in the price (0.500750000 =
        // f(RANGE_DELTA) alone, because the range recentres on spot so the price cancels out).
        // The full argument, with the measured divergence, is at `LevMath.ilTargetBps`.
        return LevMath.ilTargetBps(p.ilBasisPx, px, uint64(TARGET_LTV_CAP_BPS));
    }

    // ─── §LEV-FOLD-2 — the last three per-asset accessors, folded through `_collNative` ────────
    //
    // These three looked like a REAL per-asset difference and were not: the ETH side converted
    // weETH -> ETH via the ether.fi rate while BTC took `v.collateralOf(lp)` raw, because vBTC IS
    // sats. That difference is isolated ONE CALL DOWN, in `_collToBase` behind `_collNative`, so
    // it was never in these bodies at all.
    //
    // ⛔ THE WRONG-MANAGER GUARD IS `Shares.setLevManager`, AND IT MUST STAY. One `ILevEquity`
    // serves both instances, so `ILevEquity(btcManager).totalNetEquity()` no longer reverts on a
    // missing selector -- it returns the OTHER range's book, which looks perfectly valid. This
    // tree has shipped that bug class three times (an `ethVenue` passed into a parameter named
    // `btc`, among them). What makes it unconstructible is the pin refusing any manager whose
    // `ORACLE_KEY` is not this range's own asset (`Shares.sol:91`) -- standing rule 17: the root
    // fix, not a per-call clamp. Delete that check and the quiet failure comes back.

    /// @notice This LP's GROSS collateral in the range's native unit (1e18 ETH / 8-dec sats).
    function grossCollateral(address lp) public view returns (uint256) {
        Types.Pos memory p = pos[lp];
        return p.open ? _collNative(p.venue, lp) : 0;
    }

    /// @notice LIVE sum of every open position's GROSS collateral, native unit.
    /// §POOL-VENUE — NOT O(open LPs), same reasoning as `totalDebtUsd`.
    /// §MULTI-VENUE — a WALK. Collateral is the SAME asset across venues (the manager's `COLL`), so
    /// unlike debt these native amounts are directly additive.
    function totalGrossCollateral() external view returns (uint256 coll) {
        uint256 n = poolVenues.length;
        for (uint256 i; i < n; ++i) coll += _collNativePool(poolVenues[i]);
    }

    /// @notice LIVE sum of every open position's NET equity, native unit. Oracle read ONCE.
    /// §POOL-VENUE — NOT O(open LPs), AND IT DISSOLVES §E333 RATHER THAN IMPLEMENTING IT.
    /// §E333 refused to accumulate this because `LevMath.netEquityBase` floors PER POSITION, so a
    /// running total would socialise one LP's underwater slice across the book. **The floor is now
    /// applied to the POOLED TOTALS, not per LP**, so it applies once, where it belongs — the
    /// objection was to accumulating N floors, and there are no longer N of them.
    /// ⚠️ AND THE SUM-OF-FLOORS WAS THE LIVE DEFECT, not merely a refused optimisation: summing
    /// per-LP floored equity over a POOLED position over-counts, which is what drove `committedUsd18`
    /// high enough to trip `checkBacking` on the BTC delivery path.
    /// 🔴 §MULTI-VENUE — SUM FIRST, FLOOR ONCE. `LevMath.netEquityBase` FLOORS AT ZERO, so calling it
    ///    per venue and adding would clamp an underwater venue's deficit to 0 and let it vanish —
    ///    SOCIALISING that venue's shortfall across the book and OVER-reporting equity. That is
    ///    exactly §E333's error, the one that drove `committedUsd18` high enough to trip
    ///    `checkBacking` on the BTC delivery path.
    ///    ⇒ Collateral and debt are accumulated across the walk and the floor is applied ONCE to the
    ///      totals. With one venue the two orders coincide, which is why nothing today would catch
    ///      the wrong one — `NetEquityFloorsOnce` in `PoolVenueAggregates.t.sol` pins the difference
    ///      with a fork-free unit test so it cannot regress silently.
    function totalNetEquity() external view returns (uint256) {
        uint256 n = poolVenues.length;
        if (n == 0) return 0;
        uint256 coll; uint256 debtUsd;
        for (uint256 i; i < n; ++i) {
            address v = poolVenues[i];
            coll    += _collNativePool(v);
            debtUsd += LevMath._toUsd18(address(AUX), ILevVenue(v).stable(), ILevPooled(v).totalDebt());
        }
        return LevMath.netEquityBase(coll, debtUsd, AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW));
    }

    /// @dev The pool's gross collateral in the range's NATIVE unit. Uses the SAME `_collToBase`
    ///      conversion `_collNative` applies per LP (weETH→ETH on the ETH side, the identity on BTC),
    ///      so the aggregate and the per-LP reads cannot drift apart by a unit.
    function _collNativePool(address v) internal view returns (uint256) {
        return _collToBase(ILevPooled(v).totalCollateral());
    }

    /// @notice A range reseat REALIZES accrued IL, so re-anchor `E0` to the position's CURRENT
    ///         net-equity — the new fixed base — NOT the range position (which is 0 in the (A) model,
    ///         the deposit having no separate unlevered range slice). Net-equity IS the delta-1 slice
    ///         now sitting in the recentered range; the next hedge cycle sizes from it at zero IL.
    /// @dev    The over-hedge fix still holds: `E0` tracks NET-EQUITY, never the growing collateral.
    ///         One body for both instances, because `netEquity` already carries the per-asset unit.
    /// @notice §FOLD-MEASURE — body in `RangeLib` (§FOLD-BOOK). The new base is computed HERE and
    ///         passed BY VALUE because a library cannot reach this contract's immutables (`AUX`,
    ///         `ORACLE_KEY`) that `netEquity` reads through. That is the hard boundary on what can
    ///         move, and it is why the `open` guard is re-checked in the library rather than only
    ///         here: computing the base for a closed position is wasted gas but never wrong, and one
    ///         `open` check in the library is cheaper than two.
    function _reanchorIfReseated(address lp) internal {
        if (!pos[lp].open) return;   // cheap pre-filter: skip the equity read entirely
        // §C19 — NO ORACLE READ ON THIS PATH. The reseat re-bases the seat (`syncKeyPx`) and the
        // equity, never the entry price `ilBasisPx` — see the ⛔ in `RangeLib.reanchorIfReseated`
        // for why writing that field makes the levered book inert.
        RangeLib.reanchorIfReseated(pos, RANGE, lp, netEquity(lp));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Homed here from `src/LevOracles.sol` (2026-08-15) to cut a file. THE CONTRACT STAYS
// STANDALONE, DELIBERATELY — do not fold it into `LevBase` above. Morpho's marketId is
// `keccak256(abi.encode(MarketParams))` and `oracle` is one of those five fields, so the
// oracle's ADDRESS IS PART OF THE MARKET'S IDENTITY. Pointing the market at a manager
// would make a manager redeploy a *different market*, silently, orphaning the old one.
// A tiny immutable is the most stable address we can give it.
// ─────────────────────────────────────────────────────────────────────────────

/// @notice No usable price. These are Morpho `IOracle` implementations, so MORPHO calls them — which
///         makes the failure mode a security decision, not a style one (BUILD-QUEUE §A.13/§A.25):
///           • RETURNING 0 would have Morpho value collateral at zero ⇒ EVERY position instantly
///             liquidatable ⇒ irreversible value destruction.
///           • PANICKING (division by zero) reverts Morpho's calls too, but with an undiagnosable
///             `Panic(0x12)` and after burning all forwarded gas.
///         REVERTING with a named error is the safe failure: Morpho cannot price, so new borrows and
///         liquidations halt, and everything RESUMES once the feed recovers. A frozen market is
///         recoverable; a mass liquidation at a false zero is not.
error NoPrice();

/// @notice REAL Morpho IOracle for the vBTC/USDC market (collateral→loan, 1e36-scaled), from the SAME live
///   source the manager values vBTC through: `getTWAPforAsset(WBTC)` (USD18 per 1e18-raw, WBTC-lifted ×1e10).
///   vBTC is 8-dec sats: `sats · twap / 1e18 = USD18`; Morpho wants `sats · price / 1e36 = USDC6 = USD18/1e12`
///   ⇒ price = twap × 1e6. Fork-proven (incl. real Morpho seizure off this price) in test/VBtcLevFeeLane.t.sol.
///
///   ⚠️ It prices vBTC through `Aux.getTWAPforAsset`, and AUX is deployed inside the same broadcast, so
///   `MORPHO_VBTC_ORACLE` can NEVER be a pre-supplied env address — DeployL1_s must deploy it inline.
contract RealRateBtcMorphoOracle {
    address public immutable AUX;
    address public immutable WBTC;
    constructor(address aux, address wbtc) { AUX = aux; WBTC = wbtc; }
    function price() external view returns (uint256) {
        uint256 twap = IAux(AUX).getTWAPforAsset(WBTC, 1800);
        if (twap == 0) revert NoPrice();   // 0 would value all vBTC collateral at zero — see NoPrice
        return twap * 1e6;
    }
}

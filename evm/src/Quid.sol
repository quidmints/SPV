
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {WAD, AlreadyInitialized, InsufficientAllowance, LevManagerPinned, WrongRangeManager} from "./imports/Types.sol";
import {ILevHost, ILevEquity, ILevClose} from "./imports/Interfaces.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IDepositAdapter, ILevEquity} from "./imports/Interfaces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SwapLib} from "./imports/SwapLib.sol";
import {QuidLib} from "./imports/QuidLib.sol";
import {RangeLib} from "./imports/RangeLib.sol";
import {Types} from "./imports/Types.sol";

import {Basket} from "./Basket.sol";
import {Shares} from "./Shares.sol";
import {Core} from "./Core.sol";
import {Aux} from "./Aux.sol";

/// EthVenue — the ETH yield-venue custody (AAVE WETH + ether.fi weETH) carved out
/// of Aux. Quid routes its WETH venue ops here. rangeETH() is still read via AUX
/// (a thin forwarder), so only the WRITE ops (rangeOp/supply*/offramp/arb) re-point.
/// IL-protect fee lane: Quid reads the LevManager through the Vault's already-secure 
/// needs NO new trust surface of its own (Quid renounces ownership at setup). 
// `netEquityEth(lp)` is the LIVE net-of-debt equity the levered slice is sized to.

    // §E252 — the THIRTEEN shared range-state declarations moved to `State` (Shares.sol).
    // They were byte-identical in both managers; the merge aligns STORAGE LAYOUT, which is the
    // precondition for one implementation with two instances. No bytecode changes: state emits none.
contract Quid is Shares,
    Ownable, ReentrancyGuard {
    error WrongQuid();
    error Dust();
    error NoPosition();
    error InsufficientBalance();
    error AllowanceFlow();
    error ZeroTwap();
    error NotOwner();
    error BadPercent();

    // §NAMING — was `V4`, which read as Uniswap v4. It is the Core range engine and always was.
    /// @dev `CORE` is PUBLIC for the reason spelled out on `Vault.CORE`: each range must be able to
    ///      name its own engine, or "these two ranges are isolated" cannot be checked from outside.
    Core public CORE; WETH9 WETH;

    // There is NO venue choice: `deposit(assets, receiver)` takes no venue argument and every ETH
    // deposit becomes weETH. `QuidLib._supplyEtherFi` is the single destination, and a placement of
    // 0 reverts `VenueUnavailable` rather than redirecting.

    // §DE-TICK — `token1isVol` DELETED. It mirrored Core's v4 leg ordering, itself derived from
    // the lex order of freshly-deployed MOCK addresses. Nothing orders legs by token identity now.
    // range = between ticks
    /// §ONE-ANCHOR — was `UPPER_PRICE` + `LOWER_PRICE`, always `updateBounds(anchor, RANGE_DELTA)`
    /// of one another. Two slots for one number; `rangeBounds()` derives the pair on read.
    uint public LAST_REPACK;
    // ^ timestamp allows us
    // to measure APY% for
    Basket QUID; Aux AUX;

    // ════════════════════════════════════════════════════════════════════════════════════════
    //  §ETHVENUE-FOLD — the ETH yield venue IS this contract. `EthVenue` is deleted.
    //
    //  It was carved out of `Vault` for a good reason: `Vault` was ETH-VENUE CUSTODY and BTC RANGE
    //  ACCOUNTING fused, and `Quid`'s real counterpart is the BTC-range slice, not the whole of
    //  `Vault`. That argument said where the custody must NOT live; it never said it needed its own
    //  address. It belongs to the ETH RANGE, and the ETH range is this contract.
    //
    //  ⚠️ AND IT CANNOT LIVE IN THE MERGED RANGE MANAGER LATER. One range manager with two instances
    //  means every member exists on BOTH; ETH venue custody has NO BTC counterpart, because BTC
    //  custody is Lightning channels and not 4626 venues. That asymmetry is real, so this state
    //  stays on the ETH side however the range managers merge.
    //
    //  WHAT THE FOLD DELETES, which is why it fits: three of the five immutables (`RANGE` is now
    //  `this`; `AUX` and `WETH` already existed here), all eight `msg.sender != address(RANGE)`
    //  gates, the `IEthVenue` external-call stubs on this side, the standing WETH approval that
    //  existed only so a separate address could pull, and one deployable contract.
    // ════════════════════════════════════════════════════════════════════════════════════════

    // ether.fi — fixed mainnet contracts. It is the ONLY ETH yield venue: `QuidLib.supplyVenueBody`
    // routes every inflow here unconditionally.
    address public constant ETHERFI_ADAPTER    = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address public constant ETHERFI_CURVE_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
    address public constant ETHERFI_LP         = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address public constant ETHERFI_EETH       = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    /// Cached from the adapter when the venue is armed. NOT immutable any more: it is read in
    /// `setup`, which runs after construction, and an immutable cannot be written there.
    address public WEETH;

    /// The IL-protect orchestrator. Its levered book's LIVE net-equity counts in `rangeETH`.

    error NotSelf();
    error NotAux();

    /// @notice Pin the LevManager (one-shot, no repoint).
    /// @dev §LEV-FOLD-2 — THE IDENTITY CHECK THAT REPLACES THE SUFFIXED SELECTORS. What used to stop
    ///      a BTC lev manager being pinned to the ETH range was that the two managers exposed
    ///      DIFFERENT selectors, so a wrong-range read reverted. That is a clamp: per call, forever,
    ///      and only if the caller reaches for the suffixed name. With one `ILevEquity` the bad state
    ///      is made UNCONSTRUCTIBLE here instead, once: a manager carries its range asset in
    ///      `ORACLE_KEY` (immutable from construction), so the wrong one cannot be installed at all.
    ///      Standing rule 17 — the root fix is the one that makes the previous guard DELETABLE.
    function setLevManager(address m) external {
        require(msg.sender == DEPLOYER, "403");
        if (LEV_MANAGER != address(0)) revert LevManagerPinned();
        if (ILevEquity(m).ORACLE_KEY() != address(WETH)) revert WrongRangeManager();
        LEV_MANAGER = m;
    }

    /// @dev ether.fi offramp config. Shared by `offrampEtherFi` and the opportunistic sourcing.
    function _etherfiCfg() internal view returns (SwapLib.OfframpCfg memory) {
        return SwapLib.OfframpCfg({
            weeth: WEETH, weth: address(WETH), curvePool: ETHERFI_CURVE_POOL, lp: ETHERFI_LP
        });
    }

    /// @dev Immutables gathered for the delegatecalled `QuidLib` (it cannot read them itself).
    function _ethCfg() internal view returns (QuidLib.EthCfg memory) {
        return QuidLib.EthCfg({
            weth: address(WETH), aux: address(AUX), curvePool: ETHERFI_CURVE_POOL,
            weeth: WEETH, eeth: ETHERFI_EETH, levManager: LEV_MANAGER
        });
    }

    /// @notice Stake WETH into weETH (restaking yield), held HERE and valued in `rangeETH()`.
    /// @dev No `msg.sender` gate: the caller is this contract. The gate existed to keep a separate
    ///      address from being driven by anyone but Quid, and there is no separate address now.
    function supplyEtherFi(uint amount) public returns (uint) {
        return QuidLib.supplyVenueBody(_ethCfg(), amount, address(this));
    }

    /// @notice OFFRAMP the ether.fi slice of a withdrawal: weETH → WETH, delivered to `recipient`.
    function offrampEtherFi(uint amount, address recipient) public returns (uint served) {
        return QuidLib.offrampBody(amount, recipient, _etherfiCfg());
    }

    /// @notice Current ETH-equivalent backing: weETH valued in ETH + idle WETH, PLUS the levered
    ///         book's net-equity.
    function rangeETH() public view returns (uint) {
        return QuidLib.rangeETH(_ethCfg());
    }

    /// @notice Venue op selector. @param op 1 = take ETH, 2 = read the current claim.
    function rangeOp(uint amount, uint8 op) public returns (uint sent) {
        sent = SwapLib.rangeOpBody(amount, op, WETH, rangeETH());
    }

    /// @notice DELIVERABLE ETH backing for the redemption path — each leg capped at what is
    ///         actually withdrawable, so the ETH leg DEFERS the undeliverable slice.
    function deliverableETH() external view returns (uint total) {
        return QuidLib.deliverableETH(_ethCfg());
    }

    /// @notice Self-gated wrapper. The DELEGATECALL'd library bodies reach back in via
    ///         `IAux(address(this)).withdrawSelf(...)` — `msg.sender == address(this)`.
    function withdrawSelf(address token, uint amount, address to) external returns (uint sent) {
        if (msg.sender != address(this)) revert NotSelf();
        return _withdrawETH(token, amount, to);
    }

    /// @notice Aux-gated WETH supply (the BOLD/SP liquidation re-supply leg).
    function supplyFromAux(uint amount) external returns (uint) {
        if (msg.sender != address(AUX)) revert NotAux();
        return QuidLib.supplyVenueBody(_ethCfg(), amount, address(AUX));
    }

    /// @notice Aux-gated WETH withdraw (redemption / take / ETH-fallback legs).
    function withdrawForAux(uint amount, address to) external returns (uint) {
        if (msg.sender != address(AUX)) revert NotAux();
        return _withdrawETH(address(WETH), amount, to);
    }

    /// @notice WETH withdraw — the ladder in `QuidLib.withdrawETH`. Only WETH is served.
    function _withdrawETH(address token, uint amount, address to) internal returns (uint sent) {
        return QuidLib.withdrawETH(_ethCfg(), _etherfiCfg(), token, amount, to);
    }

    /// @notice ETH-yield accounting. Single venue (Morpho 4626 wethVault
    /// — see Aux.wethVault). The previous per-venue maps (lpShares/
    /// feesPerShare/bookmark indexed by a uint8 tag, plus the
    /// lpVenue[user] selector and the VENUE_MORPHO constant) were
    /// scaffolding for a multi-venue future that hasn't materialized;
    /// every keyed access was uniformly `[VENUE_MORPHO]`. Collapsed to
    /// plain uints. If multi-venue support is ever needed, the
    /// mapping form can be re-introduced.
    uint public bookmark;

    /// @notice SEPARATE accumulator for VENUE (Morpho WETH) appreciation, distinct from the
    ///         CORE-trading-fee `feesPerShare`. Venue yield is funded ONLY by PLAIN LP deposits (the
    ///         lev slice's capital lives in the external lev venue; the buffer is range depth), so it
    ///         accrues over PLAIN depth (`lpShares - totalLevPooled`) and is paid on weight
    ///         `pooled - levPooled` -- never diluting plain LPs to the lev/buffer depth. Trading fees
    ///         stay on gross depth (the buffer IS real CORE depth). `venueBm` is the per-LP bookmark.
    uint public venueFeesPerShare;
    mapping(address => uint) public venueBm;
    /// @notice Sum of every levered LP's `levPooled` (the net-equity range leg). Plain depth for the
    ///         venue-yield denominator is `lpShares - totalLevPooled` (moves in lockstep with the lev
    ///         reconcile, so it is invariant under lev changes and tracks only plain deposits).
    uint public totalLevPooled;

    /// @notice The NET-equity portion of an LP's `pooled` that is LEVERAGE-backed (the IL-protect fee lane,
    ///         synced to the LevManager net-equity by `syncLev`). `pooled`/`lpShares` are NET (equity): this
    ///         net leg IS counted in them, but is UNWIND-ONLY: `_withdraw` excludes it (redeemed via
    ///         `LevManager.closeLev`, never the free ladder), so a levered claim never competes with unlevered
    ///         LPs for deliverable ETH.

    /// @notice The DEBT-FUNDED BUFFER range depth of a levered LP (gross collateral - net equity), in range-ETH.
    ///         It is NOT equity, so it is EXCLUDED from `pooled`/`lpShares` (net), but it IS real CORE range depth,
    ///         so it earns range fees: the per-LP fee WEIGHT is `pooled + levBuf` and the fee denominator is
    ///         `lpShares + totalBuffer` (both GROSS). This is how the leverage keeps its yield on the 2x depth
    ///         while the LP's share accounting stays net. Cleared (with the net leg) on reconcile/close.
    /// @notice Sum of every levered LP's `levBuf` — the gross buffer total. Fee denominator = lpShares + this.

    /// @notice The 6-dec USD counterpart of an LP's DEBT-funded BUFFER range leg. Post-fold there is no
    ///         separate POOLED_USD_ETH_LEV bucket: the buffer USD folds into POOLED_USD like any in-range USD
    ///         and is EXCLUDED from committed because committedUsd18
    ///         subtracts live debt (committed = POOLED_USD − debt = net equity). A venue liquidation un-pairs
    ///         it without stranding basket USD. Bounded by the LP's own debt by construction (`levAddBuf`
    ///         sizes it to the buffer collateral at the range price, capped at debtUsd).

    /// @notice Bumped whenever the range ticks RECENTER (repack/reseat in `_rebalance`). A reseat realizes the
    ///         range's IL and moves the ticks, so the IL-protect re-anchors its `entryPrice`/`E0` when this
    ///         advances past a position's recorded epoch — otherwise the sold-fraction would be measured
    ///         across a tick-config change and mis-hedge.


    // CORE.POOLED() = principal + ALL compounded fees (even unclaimed)
    // The previous singular `totalShares` is now exposed via this
    // view because Core reads `RANGE.totalShares()`.
    function totalShares() public view returns (uint) {
        return lpShares;
    }

    /// @notice The LP's UNLEVERED range-ETH depth (`pooled` minus the leverage slice) — the `E0` the leverage
    ///         IL-protect must size its debt against (`LevManager` reads this at `openLev`). At open the
    ///         leverage slice is 0, so this is the LP's raw range deposit. Sizing the IL hedge to THIS fixed
    ///         base (not the buffer's own growing collateral) is what avoids the 1/(1−t) over-hedge.
    function rangeOf(address lp) external view returns (uint) {
        uint p = autoManaged[lp].pooled;
        uint lev = levPooled[lp];
        return SwapLib.plainNet(p, lev);
    }

    // BTC LP accounting (autoManaged/lpShares/feesPerShare/USD_FEES/
    // btcFeesOwedSats + UPPER_TICK_BTC/LOWER_TICK_BTC) lives entirely in
    // BtcVault.sol — Quid is the ETH vault; its helpers are ETH-only now.


  
    // WHY A TIMELOCK AND NOT JUST A PIN. A pin that the LP key can SET, the LP key can also UNSET —
    // a keeper would simply unpin, then withdraw. The delay is the entire mechanism: a stolen key may
    // REQUEST a change but cannot act on it inside the window, which is the LP's chance to notice and
    // exit. This is a genuine SUBSET of §A.5f, not a substitute for per-action authorisation.
    //
    // ADDITIVE BY CONSTRUCTION: zero == unpinned == unrestricted, which is every existing LP, so no
    // current behaviour changes and no call site moves.
    mapping(address => address) public pinnedRecipient;
    mapping(address => address) public pendingRecipient;
    mapping(address => uint)    public recipientUnlockAt;
    uint public constant RECIPIENT_TIMELOCK = 3 days;

    error RecipientNotPinned();
    error RecipientTimelocked();
    event RecipientPinRequested(address indexed lp, address indexed to, uint effectiveAt);
    event RecipientPinned(address indexed lp, address indexed to);

    /// @notice Pin (or re-point) the only address this LP's withdrawals may pay.
    ///         FIRST pin applies IMMEDIATELY — going from unrestricted to restricted cannot make an
    ///         LP worse off, and making opt-in instant is what gets it adopted. Every SUBSEQUENT
    ///         change is delayed, because that is the direction an attacker needs.
    function pinRecipient(address to) external {
        if (pinnedRecipient[msg.sender] == address(0)) {
            pinnedRecipient[msg.sender] = to;
            emit RecipientPinned(msg.sender, to);
        } else {
            pendingRecipient[msg.sender] = to;
            recipientUnlockAt[msg.sender] = block.timestamp + RECIPIENT_TIMELOCK;
            emit RecipientPinRequested(msg.sender, to, block.timestamp + RECIPIENT_TIMELOCK);
        }
    }

    /// @notice Apply a previously requested re-point, once its window has elapsed.
    function applyPinnedRecipient() external {
        uint at = recipientUnlockAt[msg.sender];
        if (at == 0 || block.timestamp < at) revert RecipientTimelocked();
        address to = pendingRecipient[msg.sender];
        pinnedRecipient[msg.sender] = to;
        delete pendingRecipient[msg.sender];
        delete recipientUnlockAt[msg.sender];
        emit RecipientPinned(msg.sender, to);
    }

    /// @dev Unpinned (zero) LPs are unaffected — this is the additive default.
    function _requirePinnedRecipient(address owner, address receiver) internal view {
        address pin = pinnedRecipient[owner];
        if (pin != address(0) && receiver != pin) revert RecipientNotPinned();
    }

    /// (JIT-lock) block of the position's most recent auto-managed deposit; `_withdraw`
    /// refuses a same-block exit so an atomic deposit→swap→withdraw can't snipe a swap fee.
    mapping(address => uint) public lastDepositBlock;
    // ^ key is tokenId of ID++ for that position
    // ^ always grows

    // ^ allows several selfManaged positions...

    /// @notice The deployer — gates `setLevManager`; the EthVenue pin is gone with the contract (§ETHVENUE-FOLD)
    ///         WETH approval + drives every WETH venue op. `setup` RENOUNCES ownership, so that pin can't use
    ///         onlyOwner; this immutable survives the renounce and keeps the pin front-run-proof (a hostile
    ///         pre-pin would drain Quid's WETH). Captured at construction; equals the wiring caller in both
    ///         the deploy script and tests.
    address immutable DEPLOYER;
    constructor()
        Ownable(msg.sender) {
        DEPLOYER = msg.sender;
    }   fallback() external payable {}

     modifier onlyUs {
        require(msg.sender == address(AUX)
             || msg.sender == address(CORE)
             || msg.sender == address(this), "403"); _;
    }

    function setup(address _quid,
        address _aux, address _core) external onlyOwner {
        if (address(AUX) != address(0)) revert AlreadyInitialized();
        AUX = Aux(payable(_aux)); CORE = Core(_core);
        QUID = Basket(_quid);
        renounceOwnership();
        if (QUID.RANGE() != address(this)) revert WrongQuid();
        // The rest is deploy-time-only work that was costing Quid RUNTIME bytes
        // under a hard EIP-170 deficit (E32) -- the WETH read + approval, the range
        // seed read, and the initial tick derivation. Only the value-type state
        // writes stay here; they have no storage pointer to hand the library.
        address weth;
        uint lo_; uint hi_;
        (weth, lo_, hi_) = QuidLib.setupBody(_aux, _core);
        // §ONE-ANCHOR — `setupBody` still returns the pair it derived; the midpoint of
        // `p·(1−δ)`/`p·(1+δ)` recovers `p`. Exact enough HERE (and only here) because this is the
        // deploy seed, immediately superseded by the first repack, which passes the anchor directly.
        RANGE_ANCHOR = (lo_ + hi_) / 2;
        WETH = WETH9(payable(weth));
        // §ETHVENUE-FOLD — arm the ether.fi venue here, where `EthVenue`'s constructor used to.
        // The standing WETH approval to a SEPARATE venue address is gone with the address.
        WEETH = IDepositAdapter(ETHERFI_ADAPTER).weETH();
        IERC20(weth).approve(ETHERFI_ADAPTER, type(uint).max);
        IERC20(ETHERFI_EETH).approve(ETHERFI_LP, type(uint).max);
    }


    /// @notice Create a single-sided liquidity position outside the current price range
    /// @dev Automatically adjusts for token ordering to ensure valid positions
    /// @param amount Amount of tokens to deposit (0 if sending ETH as msg.value)
    /// @param token Token address (address(0) for ETH, or stablecoin address for USD)
    /// @param distance Distance from current price in ticks
    /// positive = subtract (below), negative = add (above)
    /// @param range Width of the position in ticks
    /// @return next The ID of the newly created position
    /// @notice Per-deposit venue variant (same idea as the LP deposit
    ///         overload): the self-managed position's ETH backing earns at the
    ///         single weETH destination. No wall
    ///         attribution (there's no pledge): exits via pull() are served by
    ///         the generic withdraw ladder, which reaches every venue.
    function outOfRange(uint amount, address token,
        int distance, uint range) 
        external nonReentrant payable returns (uint next) {
        return _outOfRange(amount, token, distance, range);
    }

    function _outOfRange(uint amount, address token,
        int distance, uint range) internal
        returns (uint next) {
        SwapLib.validateOorParams(range, distance);

        SwapLib.Oor memory t;
        {   // geometry in a scope so currentSqrtPrice frees before sizing.
            // §J.8b: was an inline copy of `SwapLib.oorBounds` (identical branch structure, identical
            // alignment, same width 10) plus a local `_outOfRangeTicks`. The BTC path
            // (`BtcLib.outOfRangeBtc`) already called the shared helper, so ONE definition now
            // computes the out-of-range geometry for both assets — the same consolidation §A.56 did
            // §DE-TICK: `oorBounds` no longer negates `distance` from an ordering flag -- the
            // sign IS the side. The old warning about not pre-negating therefore no longer applies.
            (uint currentPrice, uint curLo, uint curUp,,) = _rebalance();
            t = SwapLib.oorBounds(currentPrice, range, distance, curLo, curUp);
        }
        // Backing deposit + single-sided sizing lives in QuidLib (EIP-170
        // headroom); self-managed positions take no wall attribution (pledge==0).
        // §V4-CUT — THE POSITION NOW STORES THE AMOUNT, NOT THE LIQUIDITY.
        // `liquidity` was v4's encoding of the position; settling against our own inventory needs
        // the token AMOUNT, and converting back would mean reimplementing the inverse AMM math
        // (absent from every importable library here). The sizer already computes `placed` on the
        // way to `liquidity` -- it was discarding it.
        // ⚠️ THE PRO-RATA ARITHMETIC IS UNCHANGED. Every consumer does `pos.amt * percent / 100` and
        // `pos.amt -= x`; both liquidity and amount scale LINEARLY with position size, so partial
        // closes behave identically. That is why this is a representation change, not a maths change.
        // `liquidity` is still computed and still gates on Dust, because it is the sizing function's
        // own validity check -- a range that can hold nothing yields zero liquidity.
        (uint liquidity, uint placed) = QuidLib.sizeOutOfRange(
            address(WETH), address(AUX), address(this),
            amount, token, t);
        if (liquidity == 0) revert Dust();

        next = ++ID;
        // §E258 — RECORD WHICH SIDE FUNDED IT. `token == address(0)` is the ETH branch of
        // `sizeOutOfRange`, so a nonzero token is a stable and the order is a resting BID. The
        // sizer's two branches already knew this and threw it away; the fill needs it, and it is
        // not recoverable later (see the note on `Types.SelfManaged.usdFunded`).
        RangeLib.openOor(oorBook, selfManaged, positions,
            next, msg.sender, token != address(0), t.newLo, t.newUp, int(placed));
        CORE.outOfRange(msg.sender, int(placed), t.newLo, t.newUp, address(0));
    } // Re-audited 2026-07-24 (self-managed OOR position create): internally consistent.
    // tick ordering — newUpper-newLower == range, aligned to width=10 and range a multiple
    // of 50 ≥ 100, so lower<upper always (no degenerate/inverted range); liquidity cast
    // int(uint(uint128)) is always +, passed positive = a MINT (correct); CORE.outOfRange args
    // (ETH pool, sender, +liq, newLo<newUp, token=address(0)) — the address(0) is CORRECT:
    // on a mint the USD side is settled by minting mock-USD, and `token` is only read on the
    // usdDelta>0 BURN branch (Core._settleUsdSide); real-token delivery is on pull(), and the
    // stablecoin for the USD side was already pulled in sizeOutOfRange; dust guard fires before
    // any write; ++ID unique/monotonic; state-before-external-call under nonReentrant.


    function pendingRewards(address user) public view returns (uint ethReward, uint usdReward) {
        return _pendingFor(user);
    }

    /// @dev Shared body for ETH/BTC pending rewards. Picks the right
    ///      LP mapping + fee accumulators based on isBTC. ETH yield is
    ///      from the ETH venue; BTC LPs earn USD fees only (no native
    ///      BTC yield source — feesPerShare holds V4 trading fees in
    ///      WBTC raw).
    /// @dev Refresh LP's fee bookmarks against current per-share accumulators.
    ///      Called whenever LP.pooled changes (deposit, withdraw, reward
    ///      settlement) to mark the LP as up-to-date through this point.
    function _refreshBookmarks(address user, 
        uint tokAccum, uint usdAccum) internal {
        Types.Deposit storage LP = autoManaged[user];
        // GROSS fee weight = net pooled + the debt-funded levered buffer (see levBuf) -- TRADING fees.
        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[user], tokAccum, usdAccum);
        // VENUE yield: PLAIN weight only (excludes the lev slice's net-equity + buffer).
        uint plainW = SwapLib.plainNet(LP.pooled, levPooled[user]);
        venueBm[user] = SoladyMath.fullMulDiv(plainW, venueFeesPerShare, WAD);
    }

    /// @dev Settle pending rewards. `mintRecipient == address(0)` accumulates
    ///      usd into `LP.usd_owed` (deposit-side semantics); non-zero mints
    ///      outstanding USD to that address (withdraw-side). Tok reward
    ///      always compounds into LP.pooled + lpShares (or BTC variant).
    function _settlePending(Types.Deposit storage LP,
        address user, address mintRecipient) internal {
        if (LP.pooled == 0) return;
        (uint tokR, 
         uint usdR) = _pendingFor(user);
        if (tokR > 0) {
            LP.pooled += tokR;
            lpShares  += tokR;
        }
        if (mintRecipient != address(0)) {
            usdR += LP.usd_owed;
            if (usdR > 0) {
                LP.usd_owed = 0;
                // §A.57: 6-dec USD fee accumulator → 18-dec QU!D. Same fix as BtcLib.settleBtcLp;
                // both paths shared the missing scale-up, so both move together.
                QUID.mint(mintRecipient,
                usdR * 1e12, address(QUID), 0);
            }
        } else if (usdR > 0) {
            LP.usd_owed += usdR;
        }
    }

    function _pendingFor(address user)
        internal view returns (uint tokReward, uint usdReward) {
        Types.Deposit storage LP = autoManaged[user];
        // TRADING fees (CORE): gross range-depth weight (buffer IS real CORE depth).
        (tokReward, usdReward) = SwapLib.pendingFor(LP, LP.pooled + levBuf[user], feesPerShare, USD_FEES);
        // VENUE yield: PLAIN weight only. The lev slice earns its own yield via the
        // LevManager, not this Morpho position, so crediting it here would skim plain LPs.
        uint plainW = SwapLib.plainNet(LP.pooled, levPooled[user]);
        uint venueOwed = SoladyMath.fullMulDiv(plainW, venueFeesPerShare, WAD);
        if (venueOwed > venueBm[user]) tokReward += venueOwed - venueBm[user];
    }

    // _settleBtcLp regrouped into BtcVault.sol.

    /// @dev Burn `amount` of in-range virtual liquidity (capped at the pool's
    ///      active slice) and return what was actually delivered. ETH passes the
    ///      LP's recipient (WETH paid out on-chain); BTC passes address(0) — the
    ///      native sats return via the cooperative-close tx, so nothing is
    ///      delivered here, only the mockBTC is burned. Shared by _withdraw (ETH)
    ///      and requestRedeem (BTC); the orchestration around it diverges
    ///      (fee model, native-vs-on-chain delivery, the BTC-only per-channel
    ///      claim), which is why the two callers stay distinct.
    /// §V4-RESIDUE (2026-08-18) — the three price/bound args went with `SwapLib.burnInRange`'s.
    function _burnInRange(uint amount, address recipient)
        internal returns (uint sent) {
        return SwapLib.burnInRange(address(CORE), amount, recipient);
    }

    /// @dev Shared body. `recipient` receives the ETH; the accrued-fee QD is
    /// COMPOUNDED (deferred to `usd_owed`) on a PARTIAL exit and only MINTED out
    /// on a FULL exit — see JIT-DEPTH-GUARANTEE.md §4.1. `msg.sender` is the
    /// position owner (kept for accounting).
    ///
    /// JIT-DEPTH §4 folding status (docs/actionable/JIT-DEPTH-GUARANTEE.md):
    ///   • §4.1 compound-QD-on-partial  — DONE (below: settle→usd_owed, mint only on full exit)
    ///   • §4.3 CEI-ordering            — DONE (debit pooled/lpShares BEFORE the ETH sends,
    ///                                     re-credit the undelivered shortfall)
    ///   • §4.2 cover-open-levers-first — ✅ **DONE (#109). INLINE WIRING IS LIVE** — see `_withdraw` below:
    ///     when the ask exceeds the LP's FREE (non-levered) balance it calls
    ///     `ILevClose(levManager).closeLevFor(msg.sender, 0)` then `_reconcileLev(msg.sender)`, i.e. a
    ///     past-free withdraw crystallizes the whole in-range lever (full-close, not partial — that IS the
    ///     opt-in). `closeLevFor` stays gated to the GOV-pinned RANGE OR GOV, and `closeLev`'s
    ///     LP-only msg.sender gate is untouched.
    ///     **CORRECTED 2026-07-26 — this comment previously read "PRIMITIVE BUILT, INLINE WIRING DEFERRED"
    ///     and listed two blocking forks. That text outlived the code and is what caused #109 to be tracked as
    ///     in_progress while it was in fact shipped** (the exact "anchor claims to HEAD, never to comments"
    ///     trap the build-queue STANDING LAW names). For the record, the two forks resolved as: (a) minOut —
    ///     the inline call passes `0`, deliberately, because the slice is closed at the LP's own request during
    ///     THEIR withdraw, and the swap is bounded by the venue's own oracle/LTV rather than a caller floor;
    ///     (b) re-entrancy — `closeLevFor`'s flash callback re-enters `syncLev` under this contract's
    ///     nonReentrant lock, so it is try/caught and the range slice is cleared here by the explicit
    ///     `_reconcileLev` instead of by the hook. The withdraw still CAPS at `pooled − levPooled`, so a
    ///     levered claim can never pull unlevered ETH.
    ///   • §2  JIT depth-guarantee core — DEFERRED (backing-model fork): the spec's redeem→addLiq top-up does
    ///     NOT compose backing-neutrally. `addLiq` headroom is surplus = TVL − committed (independent of QUID
    ///     supply S); `Aux.redeem`/`redeemAsBody` pays real stables OUT of the vaults (TVL↓), SHRINKING that
    ///     surplus rather than funding it, while the true D≥S+L requirement is unchanged. A bare `Basket.turn`
    ///     burn (S↓, TVL unchanged) is the neutral primitive the doc's math actually describes. See the
    ///     swap-out path notes in SwapLib.swapToBody + the JIT-DEPTH handoff.

    /// @dev Venue-shortfall delivery frame, extracted from _withdraw to stay within the legacy
    ///      stack (no via_ir): the LP's pro-rata share of the PLAIN venue balance, capped by what
    ///      POOLED can't already cover. Returns the ETH actually sent to `recipient`.
    function _deliverVenueShortfall(uint amount, uint shortfall, uint plainDepth, address recipient)
        private returns (uint excess) {
        uint venueBal = _venueBalance();
        uint vaultShare = plainDepth > 0 ? SoladyMath.fullMulDiv(venueBal, amount, plainDepth) : venueBal;
        uint inPool = CORE.POOLED();
        excess = Math.min(shortfall, vaultShare > inPool ? vaultShare - inPool : 0);
        if (excess > 0) excess = _sendETH(excess, recipient);
    }

    /// @dev §#12 DELIVERY LEG — its OWN frame because `_withdraw` is the tightest stack in this
    ///      file (two extra function-scope locals there is stack-too-deep; `via_ir` stays off).
    ///
    ///      The burn releases BOTH legs. It reduces `POOLED_USD` (the curve's USD) AND
    ///      `basketUsd` (the basket's contribution — the mod path passes `basketLeg = true`),
    ///      so the DIFFERENCE between those two reductions IS the LP-owned slice. No ratio math,
    ///      no oracle, no new state.
    ///
    ///      Without this the LP's claim prices correctly across both legs but can only be PAID in
    ///      ETH, so the USD-backed part becomes a `pooled` deferral that can never materialise —
    ///      the "prices but cannot be redeemed" failure #12's own spec warns about.
    ///
    ///      Paid as QU!D against dollars the burn just freed into the basket: the SAME shape as
    ///      the `usd_owed` fee leg (`_settlePending`), hence backed 1:1 by construction.
    ///      RETURNS `paidEth` — the ETH-EQUIVALENT of the QU!D just paid. `_withdraw`'s ledger is
    ///      ETH-DENOMINATED and its ONE invariant is *pooled debited == value delivered*; its
    ///      `shortfall` re-credit exists for a SINGLE cause, venue illiquidity, which is temporary
    ///      and recoverable. Paying part of the claim in a SECOND asset gives "undelivered" a
    ///      second cause with the OPPOSITE remedy, so the QU!D-settled slice MUST be netted off
    ///      the shortfall or it is paid AND re-credited (measured: 12.887 phantom `pooled`,
    ///      un-recoverable by a second exit, inflating `lpShares` and diluting every other LP).
    /// @param burnAmt  what the in-range burn may take — CAPPED at `deliverableETH`.
    /// @param claimAmt the LP's FULL withdrawal. The USD leg is sized from THIS, not from `burnAmt`.
    ///
    /// §E28-r: the mint used to pay only what the BURN RELEASED, which coupled the USD leg to a cap
    /// that exists for the ETH leg alone — measured, the burn released 99.958% of the increment and
    /// the claim was debited for 100%, leaking 25.200001 USD. **The range's USD leg is a MOCK
    /// MIRROR; the REAL stables are basket-held**, so the mint never needed the burn to release
    /// anything. Pay the LP's PRO-RATA share of the increment directly and let the burn govern only
    /// the ETH leg. `lpShares` is already debited by `claimAmt` at this point, so the pre-debit
    /// total is `lpShares + claimAmt` — using it un-restored would over-pay a partial exit.
    /// §V4-RESIDUE (2026-08-18) — `spotPrice`/`lo`/`hi` went when `_burnInRange` stopped taking them.
    function _burnAndDeliverUsdLeg(uint burnAmt, uint claimAmt, address recipient)
        private returns (uint sent) {
        uint incrPre = _rangeIncrement6();
        sent = _burnInRange(burnAmt, recipient);
        sent += _payUsdLeg(incrPre, lpShares + claimAmt, claimAmt, recipient);
    }

    /// @dev The range's LP-OWNED USD leg, 6-dec: everything in the curve's USD mirror beyond what the
    ///      BASKET put there. Signed-safe — a range that BOUGHT ETH with basket dollars reads 0 here
    ///      (the negative case is priced, not paid: see `_pricingBacking`).
    function _rangeIncrement6() private view returns (uint) {
        uint usd6 = CORE.POOLED_USD(); uint base6 = CORE.basketUsd();
        return usd6 > base6 ? usd6 - base6 : 0;
    }

    /// @dev Pays `claimAmt`'s pro-rata slice of the range's USD increment in QU!D and returns its
    ///      ETH-EQUIVALENT, the caller's ledger unit (returning two numbers costs a stack slot
    ///      `_withdraw` lacks). `incrPre`/`denom` MUST be captured BEFORE the burn: the burn removes
    ///      the increment proportionally, so reading them after would pay on an already-shrunk leg.
    ///
    ///      §E28-r(2) — this is a SEPARATE helper, not a branch of `_burnAndDeliverUsdLeg`, because
    ///      the ether.fi offramp needs the SAME payment with a DIFFERENT ETH recipient. That slice
    ///      burns its range liquidity to `address(0)` (its ETH comes from ether.fi, not the range),
    ///      and before this it burned the USD leg away too and paid the LP NOTHING for it. Measured
    ///      on the LVR control-vs-treatment probe: a 13.016% ether.fi slice silently consumed
    ///      7,809.44 USD of a 60,000 USD increment — the whole 104 bps by which the treatment LP
    ///      came out behind the control, i.e. the entire remaining #12 leak.
    function _payUsdLeg(uint incrPre, uint denom, uint claimAmt, address recipient)
        private returns (uint ethEquiv) {
        if (incrPre == 0 || denom == 0 || claimAmt == 0) return 0;
        uint owed6 = claimAmt >= denom ? incrPre : SoladyMath.fullMulDiv(incrPre, claimAmt, denom);
        if (owed6 == 0) return 0;
        QUID.mint(recipient, owed6 * 1e12, address(QUID), 0);
        // Re-anchor the mirror: what the LP still owns is what it owned MINUS what was just paid,
        // NOT whatever the burn happened to release. See `Core.absorbPaidUsd` for the measurement.
        CORE.absorbPaidUsd(incrPre - owed6);
        // Valued at the SAME basis the claim was PRICED at — the ORACLE, never the range's leg
        // ratio, which is not a price for a concentrated position (measured: it implied ~840
        // USD/ETH against an actual 1,854, over-pricing a 400-share claim by 73,116 USD).
        uint px = AUX.getTWAPforAsset(address(WETH), 1800);
        if (px > 0) ethEquiv = SoladyMath.fullMulDiv(owed6 * 1e12, 1e18, px);
    }

    function _withdraw(uint amount, address recipient) internal {
        // LENIENT: LP withdrawal SHRINKS POOLED_USD (Core lines
        // 512-513) → shrinks committedSum → heals over-commit. Allow
        // the repack attempt to run but don't gate the exit on its
        // success. Tradeoff: first-out LPs are made whole at the
        // expense of remaining-LP backing share. Accepted for liveness:
        // gridlock during a stress event is worse than first-out
        // unfairness, and once enough LPs exit, the invariant restores.
        AUX.tryCheckBacking();

        // full-2×: self-heal a levered position seized by an EXTERNAL venue liquidation BEFORE this LP extracts
        // value — reconciles the (possibly stale) levered slice to the live gross so the withdrawal cap
        // (`pooled − levPooled`) and fee accrual use post-seizure truth, not vanished backing. Early-outs (cheap)
        // for non-levered LPs and for a levered LP already in sync.
        if (levPooled[msg.sender] > 0) _reconcileLev(msg.sender);
        Types.Deposit storage LP = autoManaged[msg.sender];
        if (LP.pooled == 0) revert NoPosition();

        // (JIT-lock) refuse a same-block exit — see _depositImpl. Blocks the atomic
        // deposit→swap→withdraw JIT fee-snipe the composition audit found on this 4626 path.
        //
        // ⚠️ WHY 1 BLOCK HERE AND 47 ON THE OOR PATHS (`QuidLib.pullBody`,
        //    `BtcLib.pullBtc`) — the asymmetry is REAL, not drift (E146):
        //    a RANGE position is UNCONDITIONALLY exposed the moment it is in range, so one
        //    block already puts the whole deposit at risk of a block of price movement, and
        //    breaking ATOMICITY is what matters — an atomic snipe risks nothing because it
        //    borrows, captures and repays in one transaction. An OOR BOUNDARY ORDER is
        //    CONDITIONALLY exposed: it only fills if price crosses it, so a short lock lets
        //    the placer cancel the instant it moves against them and the option is free.
        //    47 blocks (~9.4 min) forces it to bear real risk before cancellation.
        //    ⇒ Different exposure shapes, therefore different locks.
        // 🔎 WHAT IS STILL NOT ESTABLISHED, and is NOT what the above claims: that ONE block
        //    SUFFICES here. It defeats the atomic case only. A deposit at block N and a
        //    withdrawal at N+1, aimed at a large fee event visible in the mempool, is
        //    untouched — fees are distributed pro-rata over `totalShares` AT THE INSTANT OF
        //    ACCRUAL (`SwapLib.feeIncrements`), so a large enough deposit takes a share of an
        //    event it was present for by one block. Whether that is PROFITABLE after a block
        //    of price risk is a measurement nobody has taken (E146); do not raise 1→47 as a
        //    reflex, it changes LP UX and the 4626 redeem semantics.
        require(block.number > lastDepositBlock[msg.sender], "too soon");
        _rebalance();   // §V4-RESIDUE 2026-08-18: kept for its EFFECT (repack/re-centre); returns unused.
        // §4.1 COMPOUND-not-transfer: settle with mintRecipient==0 so the USD fee leg
        // ACCRUES to `usd_owed` (a deferred, unrealized claim — strictly conservative, no
        // mint) rather than being minted out. The token (ETH) leg still compounds into
        // pooled/lpShares unconditionally (inside _settlePending). On a FULL exit the
        // accrued usd_owed is realized (minted to `recipient`) just before _onExit clears
        // the slot — see the mint-out block below.
        _settlePending(LP, msg.sender, address(0));

        // #109 (§G.7): a withdraw that reaches PAST the LP's FREE (plain) depth into their OWN in-range levered
        // slice AUTO-DE-LEVERS it. `levPooled>0` ⟺ in-range ⟺ auto-close candidate (2× auto-ranged OR a
        // directional lever the LP CHOSE to range — both opted in); an out-of-range directional lever has
        // levPooled==0 and is structurally untouched. `closeLevFor` repays debt and hands the freed collateral
        // (weETH/WETH — the LP's FULL residual: YB guarantee, or directional upside) straight to the LP, so the
        // levered value IS delivered. Fires ONLY when the ask exceeds free depth (know-WHEN-to-delever; a
        // free-only withdraw never touches the lever). minOut=0 is BOUNDED: closeLev returns equity as UNSOLD
        // collateral — only the debt-repay swap sells, and it self-floors to ≤MAX_SLIPPAGE_BPS via the flash-
        // coverage requirement (the op reverts past it). The callback's syncLev re-entrancy is nonReentrant-
        // BLOCKED under this withdraw lock (LevManager try/catches it → the slice stays stale for the tx), so
        // reconcile INLINE right after to burn the now-0 levPooled leg (net-equity==0 post-close) BEFORE the cap
        // re-reads to the full remaining pooled. Full-close (not partial): reuses the existing closeLevFor
        // primitive — a past-free withdraw crystallizes the whole in-range lever, which is the opt-in.
        if (levPooled[msg.sender] > 0 && amount > SwapLib.plainNet(LP.pooled, levPooled[msg.sender])) {
            ILevClose(QuidLib.levManager(address(AUX))).closeLevFor(msg.sender, 0);
            _reconcileLev(msg.sender);                      // hook re-entrancy was blocked → clear the slice here
        }
        // Cap withdrawal at the user's FREE (non-levered) balance. The levered slice (levPooled) leaves via the
        // auto-close above (or LP-initiated LevManager.closeLev) — repay debt → withdraw collateral — never the
        // free ladder, so a levered claim can never pull deliverable ETH that backs unlevered LPs.
        amount = Math.min(amount, SwapLib.plainNet(LP.pooled, levPooled[msg.sender]));
        // The exit is served via the offramp ladder. The served slice burns its virtual
        // liquidity with no on-chain delivery (the WETH came from ether.fi).
        if (amount > 0) {
            // Every exit is an ether.fi exit: all ETH is weETH, so the slice IS the withdrawal.
            uint ethfiPart = amount;
            if (ethfiPart > 0) {
                uint incrPre = _rangeIncrement6();          // BEFORE the burn shrinks it
                uint served = offrampEtherFi(ethfiPart, recipient);
                if (served > 0) {
                    _burnInRange(served, address(0));
                    // §E28-r(2): the ETH came from ether.fi, so the range burn delivers to nobody —
                    // but the USD leg it burned away is LP-OWNED and must still be paid. Skipping it
                    // was the leak the LVR probe measured (7,809.44 USD of a 60,000 increment).
                    _payUsdLeg(incrPre, lpShares, served, recipient);
                    LP.pooled -= served; 
                    lpShares -= served;
                    amount -= served;
                } else if (incrPre > 0) {
                    // THE USD LEG MUST BE PAYABLE INDEPENDENTLY OF THE ETH LEG.
                    // When the offramp serves nothing -- no weETH left to sell -- `_payUsdLeg` above is
                    // never reached, and the `amount > 0` fallback then caps its burn at
                    // `deliverableETH`, which is ~0 for the same reason. So a residual whose backing is
                    // USD became UNRECOVERABLE: measured as a bit-identical position across a second
                    // redeem (12.67e18 both sides) in test_CHECK_FullExitResidualIsRecoverable and
                    // test_SETTLE_LvrResidualIsDeferralNotLeak.
                    // It passed before the all-weETH change only incidentally: the venue split left
                    // non-weETH backing, so `served > 0` on the second pass and the USD leg was paid as
                    // a side effect. Removing venue choice removed that accident without replacing it.
                    // Gating a USD claim on ETH deliverability is the defect; the two legs are
                    // independent settlements of the same position.
                    uint usdEq = _payUsdLeg(incrPre, lpShares, ethfiPart, recipient);
                    if (usdEq > 0) {
                        _burnInRange(usdEq, address(0));
                        LP.pooled -= usdEq;
                        lpShares  -= usdEq;
                        amount    -= usdEq;
                    }
                }
            }
        } if (amount > 0) {
            // CAP the in-range burn at the ETH venue's instantly-DELIVERABLE
            // capacity. Burning virtual liquidity we can't back with real ETH
            // would zero the LP's `pooled` while delivering only a partial
            // amount (Core.modLP returns the virtual size, not what takeETH
            // actually sent) — a PERMANENT BAG. Capping makes virtual-burn ==
            // real-delivery; whatever can't be delivered now STAYS as `pooled`,
            // a recoverable deferral the LP re-withdraws once the venue thaws —
            // the LP-side analog of the redemption path's _illiquidLoss. When
            // the venue is healthy `deliverable` >> one LP's slice, so this is a
            // no-op on the normal path (the LP gets all their ETH + fees).
            //
            // §4.3 CEI: the per-LP venue pro-rata denominator (`plainDepth`) must reflect
            // PRE-debit depth (the LP's claim on the venue is proportional to its share of
            // total plain depth INCLUDING the slice being withdrawn), so capture it BEFORE
            // the debit below.
            uint plainDepth = lpShares > totalLevPooled ?
                            lpShares - totalLevPooled : 0;

            // §4.3 CEI: DEBIT the intended withdrawal from per-LP + global share state
            // BEFORE any ETH leaves the contract, so a re-entrant observes the debited
            // position (not the lagging pre-send value). The undelivered shortfall is
            // RE-CREDITED after the sends — net decrement == what was actually delivered,
            // byte-for-byte the same end state as the prior send-then-debit ordering, but
            // with no window where a reentrant sees full `pooled` after ETH already left.
            LP.pooled -= amount; lpShares -= amount;

            uint deliverable = AUX.deliverableETH();
            uint firstBurn = amount > deliverable ? deliverable : amount;
            // §#12: `sent` is VALUE DELIVERED in ETH-equivalent — the ETH burn PLUS the
            // QU!D-settled USD slice — so the shortfall re-credit below nets it off automatically.
            uint sent = firstBurn > 0 ? _burnAndDeliverUsdLeg(firstBurn, amount, recipient) : 0;

            if (amount > sent) { uint shortfall = amount - sent;
            { // Venue-share delivery — extracted to _deliverVenueShortfall (own frame, no via_ir).
              // `_venueBalance` is the PLAIN venue ETH (excludes the levered net-equity, backed
              // EXTERNALLY on Euler/Morpho). `amount` (capped at pooled-levPooled above) <= plainDepth,
              // so the share never over-delivers.
                uint excess = _deliverVenueShortfall(amount, shortfall, plainDepth, recipient);
                sent += excess; shortfall -= excess;
            } // the LP receives only what its OWN in-range burn + venue
             // share can deliver — already IL-adjusted, since convertToAssets =
            // pro-rata of rangeETH (the loss is socialized fairly via the share
           // price, no first-out advantage). Any residual is VENUE ILLIQUIDITY
          // only; it stays as LP.pooled (recoverable deferral, re-withdrawn on
         // venue thaw). NO surplus-funded make-whole here that would compensate
        // a first-out LP at the shared backing's expense for this claim must
       // divide over depth (`lpShares - totalLevPooled`), NOT gross `lpShares`
      // exactly the denominator uses for venue YIELD. Gross would dilute LPs.
     // whatever the burn + venue-share could NOT deliver stays
    // as the LP's recoverable `pooled` deferral (re-withdrawn on venue thaw).
            if (shortfall > 0) { LP.pooled += shortfall; lpShares += shortfall; }
                                                    bookmark = _venueBalance();
            }
        }
        // §4.1 MINT-OUT ON FULL EXIT: the USD fee leg was accrued to usd_owed (not minted)
        // above. When the position has FULLY exited (pooled hit 0) realize it now — mint the
        // owed QD to `recipient` BEFORE _onExit deletes the slot (which would otherwise drop
        // usd_owed). A PARTIAL exit leaves usd_owed as the deferred claim (claimable later via
        // collectFees or the eventual full exit). Backing-neutral: a mint against already-earned
        // basket-USD fees, identical to the prior per-withdraw mint, just deferred to full exit.
        if (LP.pooled == 0 && LP.usd_owed > 0) {
            uint owed = LP.usd_owed; LP.usd_owed = 0;
            // §A.57/C5: `usd_owed` is 6-dec; QU!D is 18-dec. This was the FOURTH sibling of the same
            // mint and the ONLY one missing the scale-up (cf. `_settlePending:439`,
            // `BtcLib.settleBtcLp:57`, `settleDelivered:74`). Without it, an LP whose fees were
            // DEFERRED by a partial exit and who then FULLY exits was paid 1e-12 of the leg.
            QUID.mint(recipient, owed * 1e12, address(QUID), 0);
        }
        _onExit(LP, msg.sender);
    }

    /// @dev Called at the end of a withdrawal. If the LP's position dropped
    ///      to zero, clear their slot; if they were the last LP, zero out
    ///      both per-share accumulators so a future LP joining doesn't see
    ///      stale historical fees attributed to no one. Otherwise refresh
    ///      bookmarks against the current accumulators.
    function _onExit(Types.Deposit storage LP, 
                        address user) internal {
        if (LP.pooled == 0) {
            delete autoManaged[user];
            // Hygiene: clear the per-LP venue attribution so a stale residual
            // (e.g. a partial-fill offramp leaving ethfiBacked > 0) can't
            // mis-route a later re-deposit's exit venue.
            // Defensive: a fully-exited position carries no buffer depth (levBurnAll
            // already zeroed it on close); clear any residual so totalBuffer stays exact.
            if (levBuf[user] > 0) { totalBuffer -= levBuf[user]; delete levBuf[user]; }
            // Only zero the accumulators when NO fee-earning depth remains — net shares
            // AND the gross buffer (levered LPs may still hold buffer with 0 net pooled).
            if (lpShares == 0 && totalBuffer == 0) {
                feesPerShare = 0; USD_FEES = 0; 
                venueFeesPerShare = 0; totalLevPooled = 0;
            }
        } else {
            _refreshBookmarks(user, 
            feesPerShare, USD_FEES);
        }
    }

    /// @dev The 7-arg in-range modLP in its own frame so _depositImpl stays within
    ///      the legacy stack (no via_ir crutch). Mirrors Vault._modLpBtc.
    /// §V4-RESIDUE (2026-08-18) — `spotPrice`/`loPrice`/`upPrice` DELETED, same three as
    /// `_burnInRange`: `CORE.modLP` takes deltas and a pledge, and never read them.
    function _modLpEth(uint deltaETH, uint deltaUSD, address pledge) private {
        CORE.modLP(-int256(deltaETH), -int256(deltaUSD), pledge);   // ENTERS ⇒ negative
    }
    /// @notice Reconcile `lp`'s LEVERED range position to its LIVE net-equity — the IL-protect fee lane.
    ///         PERMISSIONLESS (keeper/monitor/anyone): when the leverage's net-equity GROWS, mint range depth
    ///         for `lp` so the levered weETH earns range fees via the SAME machinery as a weETH deposit
    ///         (settle → addLiq → pooled/lpShares/levPooled += → modLP); when it SHRINKS or is liquidated,
    ///         burn that depth WITHOUT delivery (the equity is on the venue, not here), un-pairing POOLED_USD
    ///         back to the basket — so a venue liquidation leaves the basket fully intact. The minted slice is
    ///         UNWIND-ONLY (`levPooled`, excluded from `_withdraw`): it leaves via `LevManager.closeLev`, never
    ///         the free ladder, so it never introduces leverage-induced deferral. No tokens move here — the
    ///         backing is the net-equity already counted in `rangeETH` (so addLiq's headroom includes it).
    /// @notice Permissionless reconcile of `lp`'s levered range slice to the LIVE gross collateral. Anyone (keeper,
    ///         monitor, or the LP) may poke it; it is ALSO called lazily at the entry of `_withdraw` so a position
    ///         seized by an EXTERNAL venue liquidation self-heals before the LP can extract value — closing the
    ///         "external liquidation → stale slice earns fees on vanished backing" gap on-chain, not by poke-hope.
    function syncLev(address lp) external { _reconcileLev(lp); }

    function _reconcileLev(address lp) internal {
        address lm = QuidLib.levManager(address(AUX));
        uint gross = lm == address(0) ? 0 : ILevEquity(lm).grossCollateral(lp);
        // full-2×: reconcile range CAPACITY to the GROSS collateral. `levPooled` is the NET leg and `levBuf`
        // the debt-funded buffer, so the live gross depth is their sum. Skip only when the gross depth AND
        // the buffer-USD target are already in sync (nothing to do).
        if (gross == levPooled[lp] + levBuf[lp] && levBufferUsd[lp] == QuidLib.bufTarget(lm, lp)) return;
        _doReconcile(lp, lm, gross);
    }

    /// @dev Own frame (stack) for the reconcile tail: rebalance, settle, then
    ///      delegatecall the burn/add legs. lpShares is value-type — applied here
    ///      from the returned (added, burned) deltas.
    function _doReconcile(address lp, address lm, uint gross) private {
        Types.Deposit storage LP = autoManaged[lp];
        Types.RangeP memory p;
        (p.spotPrice, p.loPrice, p.upPrice,,) = _rebalance();
        p.mgr = lm; p.gross = gross;   // §RANGE-MERGE: `lm` and the BTC side's `mgr` were one field
        _settlePending(LP, lp, address(0));          // settle fees up to now (→ usd_owed) before pooled moves
        (uint addedNet, uint burnedNet, uint bufAdded, uint bufBurned) = QuidLib.reconcileLegs(
            Types.RangeCfg(address(CORE), address(AUX), address(WETH)),
            LP, levPooled, levBufferUsd, levBuf, lp, p);
        lpShares = lpShares + addedNet - burnedNet;       // NET equity leg
        totalLevPooled = totalLevPooled + addedNet - burnedNet; // the levered share of lpShares
        totalBuffer = totalBuffer + bufAdded - bufBurned; // GROSS buffer depth (fee weight)
        _onExit(LP, lp);                              // refresh bookmarks (or clear the slot if fully exited)
    }

    function _depositImpl(uint amount, address pledge) internal {
        // (JIT-lock) Stamp the receiving position's deposit block. `_withdraw`
        // refuses a same-block exit, so `deposit → Aux.swap → withdraw` can't be
        // composed atomically to snipe a victim swap's fee (the ONE composition the
        // audit found open on the auto-managed 4626 path; `onlyUs` never blocked it —
        // only this lock does). Keyed on the RECEIVER so a throwaway-receiver bypass is
        // also stamped. Residual: dust-depositing to a victim delays them one block, but
        // that gifts the victim capital + costs gas each block — self-defeating grief.
        lastDepositBlock[pledge] = block.number;

        // Verify cross-pool backing invariant BEFORE any new commit
        // STRICT: LP deposit grows POOLED_USD → grows committedSum. A
        // new entry into an over-committed pool worsens the invariant.
        // Reverts if backing can't be restored.
        AUX.checkBacking();

        uint price = AUX.getTWAPforAsset(
                     address(WETH), 1800);
        
        if (price == 0) revert ZeroTwap();
        uint deltaETH; uint deltaUSD;
        
        if (amount == 0 && 
         msg.value == 0) return;

        // _repack MUST run before _depositETH so that _syncYield reads
        // the pre-deposit balance. Otherwise the deposit is
        // misattributed as yield, inflating ETH_FEES.
        Types.Deposit storage LP = autoManaged[pledge];
        _rebalance();   // §V4-RESIDUE 2026-08-18: called for its EFFECT (repack/re-centre); every returned
                        // value became unused when the v4 price bounds left the burn path. Do NOT delete the call.

        // _depositETH pulls WETH from msg.sender (payer), routes it to the
        // per-deposit chosen venue, and attributes the slice (hard-wall)...
        amount = _depositETH(msg.sender, pledge, amount);

        // Guard: if nothing was pulled, no bookmark update is needed.
        // Without this early-return, _settlePending would compound pending
        // rewards into LP.pooled without _refreshBookmarks running
        // (since both deltaETH and unpaired would be 0). The next settle
        // would then over-credit the LP by the just-compounded amount,
        // since the bookmark would lag pooled by exactly that delta.
        // (BTC side gets the same guard in the channel-lock LP path.)
        if (amount == 0) return;
        // (venue attribution happens inside _depositETH, consistent with where
        // the WETH was actually placed. The yield bookmark is reset to the
        // REALIZED aggregate venue balance at the end of this function — see note.)

        // _rebalance (above) already accrued CORE fees + venue yield into
        // feesPerShare/USD_FEES, and neither _settlePending nor addLiq writes them
        // — so read the accumulators directly (the old pre-settle snapshot was
        // redundant; its two locals only pinned the stack). Mirrors requestDeposit.
        _settlePending(LP, pledge, address(0));
        (deltaUSD, deltaETH) = this.addLiq(                      amount, price);
        if (deltaETH > 0) {
            LP.pooled += deltaETH;
            lpShares += deltaETH;
            _refreshBookmarks(pledge, 
            feesPerShare, USD_FEES);

            _modLpEth(deltaETH, deltaUSD, pledge);
        }
        uint unpaired = amount - deltaETH;
        if (unpaired > 0) {
            // Universal retention. Unpaired ETH stays on deposit at the
            // ETH venue earning its yield. LP shares grow by
            // the unpaired amount so the deposit isn't silently
            // discarded and the LP can withdraw + earn fees
            // proportionally. Withdrawals always honour the full
            // pooled position regardless of pairing state.
            LP.pooled += unpaired;
            lpShares += unpaired;
            _refreshBookmarks(pledge, feesPerShare, USD_FEES);
        }
        // Re-sync the yield bookmark to the REALIZED aggregate venue balance
        // (NOT `+= amount`): for multi-venue / ether.fi deposits the staked or
        // supplied value can differ from `amount` by dust, and `_syncYield` would
        // otherwise book that delta as pro-rata yield. Runs for fully-paired
        // deposits too (the previous code only reset on the unpaired branch).
        bookmark = _venueBalance();
    }

    /// @dev Live PLAIN-venue ETH balance for the venue-yield sync + withdrawal delivery. `rangeOp`
    ///      op=2 returns rangeETH -- ALL plain venues (weETH/AAVE/idle) PLUS the lev net-equity. SUBTRACT the lev net-equity so this is the
    ///      pure plain-venue value: the lev collateral earns its own yield via the LevManager, so
    ///      including it would (a) skim plain LPs' venue yield and (b) make a lev open/close appear
    ///      as fake venue yield in _syncYield. No-op when no leverage (totalNetEquity == 0).
    function _venueBalance() internal returns (uint) {
        uint total = rangeOp(0, 2);   // rangeETH (all plain venues + lev net-equity)
        address lm = QuidLib.levManager(address(AUX));
        if (lm != address(0)) {
            try ILevEquity(lm).totalNetEquity() returns (uint n) { total = total > n ? total - n : 0; } catch {}
        }
        return total;
    }

    // ───────── θ DERIVED LIVE from the sizing inequality (no owner, no synthetic const) ─────────
    // (The earlier owner-set ThetaMode/setThetaMode scaffold was REMOVED — dead code: setup()
    //  renounces ownership so it was permanently uncallable. θ is now derived live below.)
    // The owner-set thetaWad above is DEAD (setup() renounces ownership), so it is pinned at 1e18
    // (reckless). The real, un-stuck θ is COMPUTED from the certified inequality θ = yield/(K·σ²−f)
    // using on-chain avgYield + realized variance from the price oracle — it self-adjusts with
    // yield and vol, needs no owner, and uses no synthetic value. (f omitted = conservative: fees
    // only shrink LVR, so dropping them yields a SMALLER, safer θ.)
    // K = the LVR coefficient (annual LVR_rate = K·σ²). NO HARDCODE: K is NOT a free constant — for a
    // concentrated-liquidity range it is a CLOSED-FORM function of the range's own geometry, computed LIVE
    // from the on-chain ticks in `_kLvrWad()` below. The earlier 0.71/2.24 sim-fit constants are gone.
    /// @notice The LIVE LVR coefficient K (WAD) for the pool's current range — read the real, dynamic
    ///         number (front-end / probe / monitoring). 0 ⇒ range unset/degenerate (caller fails open).
    ///         Body in QuidLib (EIP-170 headroom); range ticks passed in.
    function kLvrWad() external view returns (uint) {
        return QuidLib.kLvrWad(address(CORE), _lo(), _hi());
    }

    /// @notice (A) The range's LIVE realized concavity α (WAD). Body in QuidLib.
    function realizedAlphaWad() public view returns (uint) {
        return QuidLib.realizedAlphaWad(address(CORE), _lo(), _hi());
    }

    /// @notice (B) The range's ACTUAL sold-volatile fraction (WAD) since `entryPrice` — the ground-truth IL the
    ///         hedge must cancel, straight from the concentrated-position geometry, so it reflects the real
    ///         (drifting) α with NO sqrt/pow and NO α parameter. Held-volatile amount is ∝ (1/√P − 1/√P_b)
    ///         when the volatile is token0 (sold as √P RISES) or ∝ (√P − √P_a) when it's token1 (sold as √P
    ///         FALLS); soldFrac = 1 − amount_now/amount_entry. VALID WITHIN ONE TICK-CONFIG ONLY — a reseat
    ///         recenters the ticks and realizes IL, so the CALLER must re-anchor `entryPrice` on reseat.
    ///         Returns 0 on the non-IL side (up-side-only, matching the current target) or a degenerate range.
    ///         ETH range (the BTC parallel lives on the Vault with the BTC ticks/ordering).
    function soldFractionWad(uint entryPrice) public view returns (uint) {
        (uint priceWad,) = CORE.poolStats();
        return SwapLib.soldFractionWad(entryPrice, priceWad, _lo(), _hi());
    }

    /// @notice The range's current spot √P (Q96) — the leverage records this as its `entryPrice` at open so
    ///         `soldFractionWad` can measure the IL from the true range price (not the oracle).
    /// @dev NO isBTC ARGUMENT, deliberately. Quid is the ETH range manager, so it reads the ETH pool
    ///      — full stop. It previously FORWARDED the caller's flag, meaning `rangePrice(true)` returned
    ///      the BTC pool's price from the ETH contract, while `Vault.rangePrice` IGNORED the same flag
    ///      and always read BTC. Two implementations disagreeing about one parameter is a silent
    ///      mis-pricing waiting on a hook mis-wiring: it returns the wrong asset's price rather than
    ///      reverting. Each side now names its own asset and cannot be asked for the other's.
    function rangePrice() external view returns (uint priceWad) {
        (priceWad,) = CORE.poolStats();
    }

    /// @notice θ derived live: yield / (K·σ²), clamped to ≤1. Body in QuidLib
    ///         (EIP-170 headroom); range ticks + Core/Aux handles passed in.
    function derivedThetaWad() public view returns (uint) {
        return QuidLib.derivedThetaWad(address(CORE), _lo(), _hi());
    }

    /// @notice θ for an EXPLICIT range range. The BTC range ticks live in the Vault (LOWER_TICK_BTC/
    ///         UPPER_TICK_BTC), so it passes them in here -- Quid stays the single home of the range-θ
    ///         math for BOTH pools, and the Vault needs no QuidLib link of its own.
    /// 🔴 §ISBTC-SPLIT — THE CORE IS A PARAMETER NOW, AND THAT IS A BUG FIX, not tidying. This
    ///         took a `bool isBTC` it NEVER READ and always used `address(CORE)` -- Quid's own core,
    ///         the ETH instance. `derivedThetaWad` reads `ICore(core).realizedVarianceWad()`, so the
    ///         BTC range was getting theta from the ETH ORACLE'S VARIANCE applied to BTC's price
    ///         bounds. Theta throttles range depth by the range's OWN volatility; mixing the two is
    ///         wrong in both directions and silent -- it returns a plausible number either way.
    ///         Harmless while one Core held both rings; wrong the moment they became two instances.
    ///         Quid stays the single home of the range-theta math (the Vault still needs no QuidLib
    ///         link); it just has to be told WHOSE ring to measure.

    /// @notice Annualized realized variance (WAD) from Core's oracle ring. Body in QuidLib.
    function realizedVarianceWad() public view returns (uint) {
        return CORE.realizedVarianceWad();   // §E59: ONE source — Core reads its own ring
    }

    /// @notice Size how much of the volatile asset (`deltaTok`) + paired
    ///         synthetic USD to commit into the in-range V4 position. Returns
    ///         the LARGEST pairing that fits BOTH bounds below; the
    ///         requested amount is clamped DOWN to fit.
    ///
    ///         THE TWO BOUNDS:
    ///         (1) `surplus` — free basket backing = TVL − already-committed USD
    ///             (both pools). SOLVENCY bound: the position's USD leg is
    ///             synthetic mockUSD redeemable against the basket, so committing
    ///             beyond `surplus` would make POOLED_USD > TVL — quoting AMM
    ///             depth backed by dollars that don't exist, breaking D ≥ S+L.
    ///             (BTC allocation is demand-driven within this same ≤TVL bound —
    ///             no separate BTC-share cap.)
    ///         (2) `available` — volatile-asset inventory free to pair (venue
    ///             holdings − what's already in-range). PHYSICAL: can't pair more
    ///             token than is held.
    ///
    ///         WHAT HAPPENS TO THE EXCESS (deltaTok beyond the clamp): NOTHING is
    ///         lost or moved. The unpaired token stays at the yield venue (the
    ///         "Universal retention" — still LP-owned, still earning venue yield,
    ///         and bearing NO IL because it isn't in the short-gamma position);
    ///         the uncommitted basket USD stays as general backing. The clamp is
    ///         precisely the IL-footprint bound: only the paired slice is the LP
    ///         overlay, the rest is the IL-free yield reserve.
    ///
    ///         ROUNDING: every mulDiv floors → commits ≤ requested, never more
    ///         (conservative; can only under-pair by dust, never over-commit).
    function addLiq(
        uint deltaTok, uint price) public
        onlyUs returns (uint usdOut, uint outDelta) {
        // Body in QuidLib (EIP-170 headroom). The onlyUs guard stays here; the
        // delegatecalled body preserves address(this) == Quid for the θ self-call.
        // Pass totalBuffer so addLiq sizes headroom on GROSS range backing (Quid is ETH-only).
        return QuidLib.addLiq(address(CORE), address(AUX), deltaTok, price, totalBuffer);   // §ISBTC-SPLIT: Quid IS the ETH range, so the flag was always false
    }

    // _addLiqChannel (channel-lock liquidity sizer) regrouped into BtcVault.sol.

     // pull liquidity from. . .
    /// @dev Thin forwarder: body in QuidLib.pullBody (delegatecall — EIP-170); the nonReentrant guard stays here,
    ///      storage refs (selfManaged/positions) mutate in place. Logic unchanged.
    function pull(uint id, // existing self-managed position
        int percent, address token) external nonReentrant {
        RangeLib.pull(address(CORE), oorBook, selfManaged, positions, id, percent, token, msg.sender);
    }

    /// @notice §E258 — execute the resting boundary orders the range's price has crossed.
    /// @dev    Driven by `Core.swap`: the moment the price is known to have moved. Capped there, so
    ///         `fillOOR` below is what drains whatever the cap left. Body in `RangeLib` — this
    ///         contract is the tightest in the tree under EIP-170 and can afford the call, not the code.
    function sweepOor(uint px, uint maxFills) external onlyUs returns (uint) {
        return RangeLib.sweepOor(address(CORE), oorBook, selfManaged, positions, px, maxFills);
    }

    /// @notice §E258 — the permissionless poke. See `RangeLib.pokeOor` for why it is a liveness
    ///         requirement rather than a convenience, and why it pays no tip yet.
    function fillOOR(uint id) external nonReentrant {
        RangeLib.pokeOor(address(CORE), address(AUX), address(WETH),
            oorBook, selfManaged, positions, id);
    }

    // _distributeV4Fees + _calcYield folded into QuidLib.rebalanceBody (their ONLY caller was _rebalance; the
    // APY `yield` _calcYield computed was already discarded there). The token-canonical reorder + fee-increment
    // distribution now live in the library body; LAST_REPACK is stamped by the _rebalance forwarder.

    /// @dev Thin forwarder: the venue-routing body lives in QuidLib (EIP-170
    ///      headroom). Delegatecall preserves msg.value/address(this), so the WETH
    ///      wrap + venue placement + per-LP wall attribution behave identically.
    function _depositETH(address sender, address pledge,
        uint amount) internal returns (uint sent) {
        return QuidLib.depositETH(address(WETH), address(AUX), address(this),
            sender, pledge, amount);
    }

    // §RULE-1 — `takeETH` DELETED. `external`, declared in NO interface, and ZERO references
    // anywhere in src/, test/ or script/ -- inside this contract or out. A one-line forwarder to
    // `_sendETH` that nothing could reach.

    /// @notice Redemption unwind. QU!D's dollars work as the range's USD side (capital
    ///         efficiency); when a redemption exceeds the FREE stables, free them back out by
    ///         BURNING in-range range liquidity -- this shrinks POOLED_USD (committedUsd18 down,
    ///         so the redeemer's usdAvailable rises for the subsequent take()). Reuses the
    ///         LP-withdraw burn primitive (_burnInRange) with recipient=0: the paired ETH is NOT
    ///         paid out (Core._settleTokSide gates delivery on `who != 0`), so it stays in the
    ///         venue -- LP EQUITY NEUTRAL (rangeETH/lpShares unchanged; only the range's mock
    ///         mirror shrinks, returning ETH from in-range to in-venue). Bounded by POOLED
    ///         (_burnInRange caps at it), so a truly insolvent basket simply frees all it can and
    ///         QU!D bears the residual via the haircut. onlyUs -- Aux drives it inside redeemAsBody.
    /// @param usdWanted 18-dec USD shortfall to free. @return usdFreed 18-dec USD actually freed.
    function unwindForRedeem(uint usdWanted) external onlyUs returns (uint usdFreed) {
        if (usdWanted == 0) return 0;
        uint usd6 = CORE.POOLED_USD();     // range's in-range USD leg (6-dec)
        uint eth  = CORE.POOLED();         // range's in-range ETH leg (18-dec)
        if (usd6 == 0 || eth == 0) return 0; // empty range -> free stables only
        _rebalance();   // §V4-RESIDUE 2026-08-18: kept for its EFFECT; returns are all unused now.
        // ROOT-PRECISE: size the ETH removal by the range's OWN in-range USD/ETH ratio, NOT an external TWAP.
        // Removing the fraction `usdWanted/(usd6·1e12)` of the position releases EXACTLY `usdWanted` USD (plus
        // the paired ETH, which stays in-venue). ETH to pull = usdWanted·eth/(usd6·1e12); _burnInRange caps at
        // POOLED. This frees precisely what redemption asks (no over/under-free) with ZERO oracle dependency
        // — so a dead TWAP no longer zeroes the unwind, and the mixed USD/ETH release no longer under-delivers.
        _burnInRange(SoladyMath.fullMulDiv(usdWanted, eth, usd6 * 1e12), address(0));
        uint after6 = CORE.POOLED_USD();
        usdFreed = usd6 > after6 ? (usd6 - after6) * 1e12 : 0;
    }

    /// @notice §E5 — route the RETAINED A-S scarcity premium to LPs through the SAME per-share
    ///         accumulator trading fees use. Called by Core from `recordSkewPremium`.
    ///
    ///         WHY THIS EXISTS: the premium is withheld from a drainer's output — *"the drainer's
    ///         full USD entered the pool, they just take less out"* — so those dollars are already
    ///         basket backing. But basket backing prices QU!D, NOT LP shares: an LP's claim runs
    ///         through `rangeETH()`/`pooled`, which never reads it. So a premium charged FOR THE
    ///         LP'S INVENTORY RISK was accruing to QU!D holders. Every comment on the path said it
    ///         *"accrues to LPs as backing"*; structurally it did not.
    ///
    ///         Backed 1:1 by construction — identical in shape to the existing USD trading-fee leg
    ///         (`USD_FEES` → `usd_owed` → `QUID.mint`), against dollars that are already in the
    ///         basket. GROSS fee weight (`lpShares + totalBuffer`), matching `SwapLib.feeIncrements`,
    ///         so the debt-funded buffer earns on the depth it actually provides.
    ///
    ///         NO-LP CASE IS DELIBERATE: with zero fee-earning depth there is nobody to attribute
    ///         to, so the premium simply STAYS as basket backing — the prior behaviour — rather
    ///         than being dropped or stranded.
    ///         Uses `SwapLib.feeIncrements` — the SAME scaling trading fees take — rather than a
    ///         hand-rolled `mulDiv`, so the premium can never drift from the fee math, and the
    ///         zero-denominator case is handled in one place (it returns 0).
    function creditSkewPremium(uint premium6) external onlyUs {
        (, uint usdInc) = SwapLib.feeIncrements(0, premium6, lpShares + totalBuffer);
        USD_FEES += usdInc;
    }

    // ─── ICore — the ETH range's face (see docs/actionable/IRANGE-THE-RANGE-MANAGER-FACE.md) ───
    // `Core` used to branch on `IS_BTC` to reach one of two managers for each of these. The facts
    // differ per range, so they live in the range, and `Core` asks one interface.

    /// @notice This range's leverage manager. `totalDebtUsd` is shared; only the LOOKUP differed.
    function levManager() external view returns (address) {
        return LEV_MANAGER;
    }

    /// @notice Gross levered collateral in the range's NATIVE unit (wei here, sats on the BTC side).
    function levGrossNative() external view returns (uint) {
        address m = LEV_MANAGER;
        if (m == address(0)) return 0;
        try ILevEquity(m).totalGrossCollateral() returns (uint g) { return g; } catch { return 0; }
    }

    /// @notice Share base the shortfall trigger compares against. NET here: `rangeETH()` (the
    ///         inventory side) already adds the lev book's NET equity, so both sides are net and no
    ///         gross buffer term belongs. The BTC side adds one, for the mirror-image reason.
    function sharesForShortfall() external view returns (uint) { return totalShares(); }

    /// @notice REAL inventory, never just the in-pool token: in-range POOLED plus AAVE/ether.fi
    ///         venue retention plus idle. Comparing raw POOLED over-fired the shortfall arb on
    ///         off-range retention.
    function realInventory() external view returns (uint) { return AUX.rangeETH(); }

    /// @notice 🔴 A DELIBERATE NO-OP, AND NOT AN OMISSION. BTC routes a shortfall to the hop, which
    ///         delivers real BTC and consumes no basket stables. ETH must NOT: a surplus-funded
    ///         refill buys ETH to cover a shortfall that is usually IMPERMANENT, realising that IL
    ///         onto the SHARED backing and compensating the flow at every LP's expense. Real ETH
    ///         demand is met fairly at withdrawal instead -- `convertToAssets` pays each LP
    ///         pro-rata of `rangeETH`, so the IL is socialised through the share price.
    ///         Do not "implement" this.
    function onShortfall(address, uint) external {}

    /// @notice Pay the volatile leg out. ETH sends real ether; the BTC range's counterpart is a
    ///         no-op because settlement there is a Lightning cooperative close.
    function deliverVolatile(uint amount, address who) external onlyUs returns (uint) {
        return _sendETH(amount, who);
    }

    /// @notice Sync Morpho wethVault appreciation into the per-LP fees
    /// accumulator. NOT an aToken-era artifact — the bookmark/feesPerShare
    /// pattern is what attributes 4626 share appreciation to LPs (since
    /// the share count is fixed at Aux, only the per-share value moves;
    /// LPs don't hold shares directly, they hold a `pooled` claim
    /// against the shared Aux position). Removing this would leave
    /// Morpho appreciation unclaimable by LPs.
    // _syncYield folded into QuidLib.rebalanceBody (its ONLY caller was _rebalance). The plain-venue
    // appreciation accrual over PLAIN depth into venueFeesPerShare is unchanged; `_venueBalance` (below) STAYS
    // because _withdraw/_depositImpl also call it.

    /// @dev The delivery ladder itself lives in `QuidLib.sendEth` (E32: it was 777
    ///      RUNTIME bytes against a hard EIP-170 deficit, and it is called from only
    ///      two places). Delegatecall keeps `address(this) == Quid`, so the balance
    ///      read, the WETH unwrap and `deleverEthOnDelivery`'s recipient are all
    ///      unchanged. Priced on the gas axis too: one extra delegatecall per ETH
    ///      send, on a path that already does a venue pull and an unwrap.
    function _sendETH(uint howMuch,
       address toWhom) internal returns (uint sent) {
        return QuidLib.sendEth(address(WETH), address(this),
            address(AUX), howMuch, toWhom);
    }


    // ════════════════════════════════════════════════════════════════
    //  BTC LP path REGROUPED into BtcVault.sol (requestDeposit /
    //  requestRedeem / resize / _resize). The shared isBTC-
    //  parameterized helpers above stay here for the ETH side; the BTC
    //  repack is now driven by BtcVault.repack(true).
    // ════════════════════════════════════════════════════════════════


    /// @notice ETH (isBTC=false) is the live entrypoint; the wrapper keeps the
    ///         `bool isBTC` shape so the same calls and the JIT/repack flow read
    ///         identically to the pre-library code. The SHARED skeleton (range
    ///         read, TWAP manipulation guard, CORE.repack, JIT-defense collect)
    ///         lives in SwapLib.rebalanceCore; only the ETH-only steps stay
    ///         here: the Morpho _syncYield pre-sync, the _calcYield post-metric
    ///         (LAST_REPACK + avgYield), and the per-pool fee reorder/distribute.
    /// @dev Thin forwarder: the fee/yield harvest cluster (_syncYield + rebalanceCore + _calcYield/
    ///      _distributeV4Fees) moved to QuidLib.rebalanceBody (delegatecall — EIP-170; relocates the inlined
    ///      rebalanceCore). It mutates only value-type accumulators, returned as increments/flags applied here.
    ///      Byte-identical: same ordering (_syncYield reads venue balance BEFORE rebalanceCore), same arithmetic;
    ///      the discarded `_calcYield` APY return is dropped. `_venueBalance` STAYS (its other callers use it).
    function _rebalance() internal returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint resolvedTwap) {
        QuidLib.RebalOut memory o = QuidLib.rebalanceBody(QuidLib.RebalIn({
            core: address(CORE), aux: address(AUX), ev: address(this), weth: address(WETH),
            lpShares: lpShares, totalLevPooled: totalLevPooled,
            totalBuffer: totalBuffer, loPrice: _lo(), upPrice: _hi(), bookmark: bookmark}));
        venueFeesPerShare += o.venueFeesPerShareInc;             // _syncYield accrual
        bookmark = o.newBookmark;
        feesPerShare += o.feesPerShareInc; USD_FEES += o.usdFeesInc; // _distributeV4Fees
        
        if (o.setLastRepack) LAST_REPACK = block.timestamp;      // _calcYield's live effect
        RANGE_ANCHOR = o.spotPrice;   // §ONE-ANCHOR: store the anchor; the range derives from it
        return (o.spotPrice, o.loPrice, o.upPrice, o.myLiquidity, o.resolvedTwap);
    }

    /// @notice Repack the ETH pool's in-range LP position when it drifts
    ///         outside the LP range. The `bool` arg is retained only for the
    ///         Core IQuidRepack interface (BtcVault repacks the BTC
    ///         pool); Quid is ETH-only. Returns the post-repack pool state.
    function repack() public onlyUs returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint resolvedTwap) {
        return _rebalance();
    }

    /// @notice PERMISSIONLESS deadlock-recovery poke. The auto-heal lives in
    ///         `SwapLib.rebalanceCore` (folded into the repack-first of every
    ///         swap/deposit/withdraw): when the internal TWAP is >5% off Chainlink
    ///         the curve spot is moved onto the oracle so swaps resume at the real
    ///         price. This entry just runs that rebalance WITHOUT a swap, so anyone
    ///         can unstick the pool even if no one is trading. No-op when aligned.
    function reseat() public nonReentrant {
        _rebalance();
    }

    function paddedSqrtPrice(uint spotPrice,
        bool up, uint delta) public pure returns (uint160) {
        return SwapLib.paddedSqrtPrice(spotPrice, up, delta);
    }


    // §ONE-ANCHOR — `_updateBounds` DELETED. It forwarded to `SwapLib.updateBounds`, and every
    // caller went away when the range bounds became derived from `RANGE_ANCHOR`: `rangeBounds()` calls
    // the library directly. Zero call sites left in this contract. (The BTC range manager has its own
    // copy, which is a separate contract's business.)

    // ════════════════════════════════════════════════════════════════
    //          ERC-20 TRANSFER FACE + NATIVE LP ENTRYPOINTS
    // ════════════════════════════════════════════════════════════════
    //
    // Makes Quid LP positions transferable. The underlying autoManaged
    // mapping + lpShares + feesPerShare + USD_FEES accumulators are
    // PRESERVED EXACTLY — this layer adds standard ERC-20 transfer/
    // approve plus the deposit/redeem entrypoints.
    //
    // THE ERC-4626 IDENTITY IS HERE, with the state it describes. It was split to
    // `VEth.sol` on the premise that Quid manages both asset classes; that was
    // measured false (no BTC state, and nothing ever supplied the `isBTC`
    // arguments), so the projection was an indirection over a distinction that
    // did not exist. `asset`, `totalAssets`, `convertTo*`, `preview*`, `max*`,
    // `name`, `symbol` and the ERC-20 mutators all sit below, over the same
    // `autoManaged[].pooled` / `lpShares` they have always described.
    //
    // Yield attribution preservation invariant:
    //   On any transfer, BOTH parties' pending rewards are settled
    //   (compounded into pooled / accumulated in usd_owed) BEFORE
    //   the principal moves. The transferred pooled therefore
    //   carries no entitlement to past rewards — they're already
    //   credited to the sender. The receiver starts earning on the
    //   transferred principal from the current accumulator bookmark.
    //
    // V4 position ownership: Core's V4 positions use salt=0 (read
    // _modifyLiquidity at line ~561). All LP capital sits in ONE
    // collective V4 position per range, with autoManaged tracking
    // per-LP proportional ownership. ERC-20 transfer just rebalances
    // the mapping — no CORE-side coordination needed.

    uint8  public constant decimals = 18;




    event Deposit(address indexed sender, 
                  address indexed owner, 
                uint assets, uint shares);

    event Withdraw(address indexed sender, address indexed receiver,
                   address indexed owner, uint assets, uint shares);
    
    // BtcLpFeesOwed event regrouped into BtcVault.sol.
    /// @notice ERC-20 balance = LP's principal in pool. This is the
    /// already-compounded value; pending rewards (not yet credited)
    /// are revealed via previewRedeem / pendingRewards.
    // ─── THE vETH TOKEN FACE — 4626 identity and ERC-20, both HERE ────────────────
    // §J.2b/§J.2c split this out to `VEth` on the premise that "Quid manages BOTH asset
    // classes, so a single-asset 4626 on it would be dishonest". THAT PREMISE WAS MEASURED
    // FALSE (2026-08-15): Quid declares NO BTC state — not one `Btc`/`BTC` member. Its
    // `isBTC` arguments were pass-throughs to QuidLib math bodies, and NOTHING supplied
    // them. Quid is, and was, the ETH range manager; `rangePrice` already said so in its own
    // docblock while the comments here said the opposite.
    //
    // So the face returns to the state instead of projecting through a call boundary. That
    // deletes the whole span the split needed to exist: the `VETH` pin, its one-shot setter,
    // `VEthPinned`, the `msg.sender == VETH` gate, and `transferSharesFor` — a trampoline
    // whose only job was letting the projection reach `_transferShares`. The allowance is no
    // longer stranded on a contract that owns none of the balances it approves.
    //
    // The ENTRYPOINTS (`deposit`/`mint`/`withdraw`/`redeem`) remain the protocol's native LP
    // API below, carrying the per-deposit `venue` selector and the payable ETH path.

    string public constant name   = "QU!D Quid ETH LP";
    string public constant symbol = "vETH";

    /// The single asset this vault is defined over.
    function asset() external view returns (address) { return address(WETH); }

    /// @notice Total ETH-equivalent backing all LP positions: principal + ALL accrued
    ///         CORE/Morpho fees, claimed or not. Deliberately `rangeETH()` RAW, NOT
    ///         `_pricingBacking()`, which restates the levered book onto the denominator's
    ///         clock for SHARE PRICING (§A.16b); the conversions below carry that
    ///         restatement, so applying it here too would double-count it.
    function totalAssets() external view returns (uint) { return AUX.rangeETH(); }

    function totalSupply() external view returns (uint) { return lpShares; }

    /// @notice ERC-20 balance = LP's principal in pool. This is the already-compounded
    ///         value; pending rewards (not yet credited) are revealed via previewRedeem /
    ///         pendingRewards.
    function balanceOf(address user) public view returns (uint) {
        return autoManaged[user].pooled;
    }

    function maxDeposit(address) external pure returns (uint) { return type(uint).max; }
    function maxMint(address) external pure returns (uint) { return type(uint).max; }
    function previewDeposit(uint assets) external view returns (uint) { return convertToShares(assets); }
    function previewMint(uint shares) external view returns (uint) { return convertToAssets(shares); }
    // §E295 — **THE REDEMPTION-SIDE 4626 ACCESSORS ARE DELETED: THEY DESCRIBED AN ASYNC FLOW AS
    // SYNCHRONOUS.** `redeem`/`withdraw` reach `_withdraw`, whose own comment is the finding — *"4626
    // path defaults to WAIT (no forced haircut)"* — so a redemption may DEFER. ERC-7540 requires
    // `preview*` to REVERT on an async flow for exactly this reason; ours returned a number.
    //   `maxRedeem` claimed the owner's WHOLE balance was redeemable and `previewRedeem` named an
    // exact asset amount, while capacity gating can defer both. **That is rule 3's inverse: the
    // failure was SILENT and produced plausible-but-wrong output**, which is the class of check that
    // earns its place — or, having none to make, the accessor that must go.
    // ⇒ **THE DEPOSIT SIDE IS UNTOUCHED AND THAT ASYMMETRY IS THE POINT.** `_deposit4626` mints
    // immediately, so `previewDeposit`/`previewMint`/`maxDeposit`/`maxMint` describe a genuinely
    // SYNCHRONOUS flow and are honest 4626. **It was never "both faces deny it" — it is the
    // redemption half, and which half is decided by which side defers.**
    // ⚠️ SAFE TO DELETE, CONTROLLED: zero references in `spa/src` and `quid-ln`, where the same
    // search finds `redeem` (6 / 43) and `totalSupply` (3 / 0) — so the method sees client usage
    // where it exists. `check-client-abis.py` is the gate and was run.

    mapping(address => mapping(address => uint)) public allowance;
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint amount) external nonReentrant returns (bool) {
        _transferShares(msg.sender, to, amount);
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint amount) external nonReentrant returns (bool) {
        uint allowed = allowance[from][msg.sender];
        if (allowed != type(uint).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transferShares(from, to, amount);
        emit Transfer(from, to, amount);
        return true;
    }

    /// @dev Move `amount` of pooled from `from` to `to`. Settles
    /// pending rewards on BOTH sides first so the moved principal
    /// carries no past-rewards claim. Self-transfers rejected: would
    /// double-settle the same position (second settle reads inflated
    /// pooled against the not-yet-refreshed bookmark → phantom
    /// reward = R × feePerShare / WAD).
    /// @dev Thin forwarder: the settle-both-sides + move-principal + refresh body moved to
    ///      QuidLib.transferSharesBody (delegatecall — EIP-170). Value-type `lpShares` growth returns as a delta
    ///      applied here; the Transfer event stays here (emitted for amount==0 too — Transfer(from,to,0)). Logic
    ///      unchanged (pendingRewards reached via self-staticcall; _refreshBookmarks replicated in the lib).
    function _transferShares(address from, address to, uint amount) internal {
        lpShares += QuidLib.transferSharesBody(
            autoManaged, levPooled, levBuf, venueBm, from, to, amount, feesPerShare, USD_FEES, venueFeesPerShare);
    }

    // ─── share math ──────────────────────────────────────────────────
    // The conversions the 4626 face above is defined in terms of. One implementation, so the
    // §A.16b same-clock pricing cannot diverge between the identity and the entrypoints.

    /// @dev Pricing backing: `rangeETH` with the levered book restated onto the SAME CLOCK as the
    ///      denominator. `rangeETH` adds `totalNetEquity()` read LIVE from the venues
    ///      (`QuidLib:150`), but the matching term inside `lpShares` is `totalLevPooled`, which is
    ///      STORED and only refreshed by `_reconcileLev`/`syncLev` — i.e. on the levered LP's own next
    ///      action. Live numerator over lazy denominator is the whole defect (§A.16b): an external
    ///      Morpho liquidation cut the numerator instantly while the denominator still carried the
    ///      seized collateral, so the price fell 32% for EVERY holder and a passive LP absorbed ~half
    ///      of a liquidation it had no part in.
    ///
    ///      Swapping the LIVE term for the RECORDED one makes both sides move together: while the book
    ///      is stale the price is simply unchanged, and when reconciliation lands, the levered LP's own
    ///      shares burn alongside the backing. NOT the same as netting the levered book OUT — that was
    ///      tried and REVERTED (§A.16d): the levered capital is commingled in the range, so removing it
    ///      strips backing that genuinely supports plain claims (measured: 69% under-pricing).
    ///      In steady state (`totalNetEquity == totalLevPooled`) this is EXACTLY `rangeETH`, so
    ///      normal-case pricing is byte-identical to before.
    function _pricingBacking() internal view returns (uint total) {
        total = AUX.rangeETH();
        // §#12 — READ BOTH LEGS. `rangeETH` is the ETH leg of a TWO-legged range position; the USD
        // leg beyond what the BASKET supplied (`basketUsd`) is LP-owned and was invisible here,
        // so a range that sold LP ETH for USD priced the LP down by the whole sale.
        // Valued at the range's OWN in-range ratio — NOT a TWAP — so this stays `view` and carries
        // no oracle dependency, the same choice `unwindForRedeem` makes deliberately.
        // SIGNED: when the range has BOUGHT ETH with basket dollars the increment is NEGATIVE and
        // must REDUCE the claim (B11) — flooring at zero would gift the LP the basket's capital.
        {
            uint usd6 = CORE.POOLED_USD(); uint base6 = CORE.basketUsd();
            // ⚠️ VALUED AT THE ORACLE, NOT THE RANGE'S LEG RATIO. `POOLED / POOLED_USD` is
            // NOT a price for a CONCENTRATED position — measured, it implied ~840 USD/ETH against
            // an actual 1,854, valuing the increment ~2.2x too high and inflating a 400-share claim
            // to 439.44 ETH (a 73,116 USD over-price). `unwindForRedeem` uses that ratio to size a
            // PROPORTIONAL BURN, where it is correct; it is not a price, and I carried its
            // oracle-free justification across without checking the property held.
            uint px = AUX.getTWAPforAsset(address(WETH), 1800);
            if (px > 0 && usd6 != base6) {
                if (usd6 > base6) total += SoladyMath.fullMulDiv((usd6 - base6) * 1e12, 1e18, px);
                else {
                    uint down = SoladyMath.fullMulDiv((base6 - usd6) * 1e12, 1e18, px);
                    total = total > down ? total - down : 0;
                }
            }
        }
        address lm = QuidLib.levManager(address(AUX));
        if (lm == address(0)) return total;
        // GUARDED like every other lev read: a broken manager must not brick share pricing.
        try ILevEquity(lm).totalNetEquity() returns (uint live) {
            total = total > live ? total - live : 0;   // drop the LIVE term
            total += totalLevPooled;                   // restore the RECORDED one (denominator's clock)
        } catch {}
    }

    function convertToShares(uint assets) 
        public view returns (uint) {
        uint total = _pricingBacking();
        if (lpShares == 0 || total == 0) return assets;
        return SoladyMath.fullMulDiv(assets, lpShares, total);
    }

    function convertToAssets(uint shares) public view returns (uint) {
        uint total = _pricingBacking();
        if (lpShares == 0 || total == 0) return shares;
        return SoladyMath.fullMulDiv(shares, total, lpShares);
    }

    // ─── ERC-4626 deposit / redeem (thin wrappers) ──────────────────
    // The standard 4626 entrypoints. They route into the existing
    // _depositImpl / _withdraw paths so the full machinery still runs
    // (checkBacking, _rebalance, addLiq, JIT-defense, AUX.take, etc.).

    function deposit(uint assets, address receiver)
        external payable nonReentrant returns (uint shares) {
        return _deposit4626(assets, receiver);
    }

    function _deposit4626(uint assets, address receiver)
        internal returns (uint shares) {
        require(receiver != address(0), "receiver");
        uint preShares = autoManaged[receiver].pooled;
        _depositImpl(assets, receiver);
        shares = autoManaged[receiver].pooled - preShares;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint shares, address receiver)
        external payable nonReentrant returns (uint assets) {
        return _mint4626(shares, receiver);
    }

    function _mint4626(uint shares, 
        address receiver)
        internal returns (uint assets) {
        require(receiver != address(0), "receiver");
        assets = convertToAssets(shares);
        uint preShares = autoManaged[receiver].pooled;
        
        _depositImpl(assets, receiver);
        uint actualShares = autoManaged[receiver].pooled - preShares;
        // 4626-compliance: mint must yield AT LEAST the requested shares.
        // If the caller's allowance/balance falls short, _depositImpl pulls
        // less than `assets` and actualShares < shares — revert to surface
        // the underdelivery rather than silently returning a stale `assets`.
        require(actualShares >= shares, "mint:short");
        emit Deposit(msg.sender, receiver, assets, actualShares);
    }

    function redeem(uint shares, address receiver, address owner)
        external nonReentrant returns (uint assets) {
        // Direct-owner-only path. Allowance flow not supported on Quid:
        // _withdraw reads autoManaged[msg.sender], so debiting `owner`'s
        // position requires msg.sender == owner. Front-ends wanting to
        // act on behalf of `owner` must first transferFrom the LP shares
        // to msg.sender, then redeem normally. Reverts AllowanceFlow on
        // owner != msg.sender to keep the surface honest.
        if (owner != msg.sender) revert AllowanceFlow();
        _requirePinnedRecipient(owner, receiver);
        assets = convertToAssets(shares);
        _withdraw(assets, receiver);   // 4626 path defaults to WAIT (no forced haircut)
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function withdraw(uint assets, address receiver, address owner)
        external nonReentrant returns (uint shares) {
        if (owner != msg.sender) revert AllowanceFlow();
        _requirePinnedRecipient(owner, receiver);
        // CAP FIRST, then convert (2026-07-26). `convertToShares` used to run on the RAW `assets`, so
        // the standard "exit everything" sentinel `withdraw(type(uint).max)` REVERTED with no message:
        // it is `SoladyMath.fullMulDiv(assets, lpShares, rangeETH())`, whose overflow guard is a bare
        // `require`, and `type(uint).max * lpShares` trips it unconditionally. 10+ call sites use the
        // sentinel, so this reverted in NORMAL operation.
        //
        // The cap is the LP's FULL position (≡ `maxWithdraw`), NOT their free/plain slice. That
        // distinction is load-bearing: `_withdraw` fires #109's auto-de-lever on the strict test
        // `amount > plainNet(pooled, levPooled)` (:504) and only THEN clamps (:511), re-reading
        // `plainNet` after `_reconcileLev` has zeroed the closed slice. Capping to `plainNet` here
        // would make that test unsatisfiable by construction and silently disable auto-de-lever on
        // the whole 4626 path — a levered LP could never exit past their free depth. Capping to the
        // full position keeps `amount > plainNet` reachable, bounds the conversion, and makes the
        // sentinel mean "exit my entire position", which is exactly what `maxWithdraw` advertises.
        // UNITS: cap in POOLED units, which is what `_withdraw` itself clamps in (`amount` vs
        // `plainNet(LP.pooled, levPooled)`, :511) — NOT through `convertToAssets`. Routing the cap
        // through the share-conversion made the payout depend on `rangeETH()`, so once the redeem
        // turns had unwound the range the ceiling floored to 0 and a full-exit LP received NOTHING
        // (measured: `test_RunSim_AllExit_Normal`, LP1 got 0 of 8 ETH — a test that PASSES upstream).
        // Capping at the raw `pooled` reproduces upstream's effective behaviour exactly (upstream left
        // `assets` huge and let `_withdraw` clamp it) while still bounding `convertToShares`, and it
        // keeps `amount > plainNet` reachable whenever `levPooled > 0` so #109 still fires.
        uint ceiling = autoManaged[msg.sender].pooled;
        if (assets > ceiling) assets = ceiling;
        shares = convertToShares(assets);
        _withdraw(assets, receiver);   // 4626 path defaults to WAIT (no forced haircut)
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Harvest accrued fees WITHOUT withdrawing the position. The USD-leg
    ///         mints as QUID to the LP; the token-leg (ETH fees) compounds into the
    ///         position — the same realization withdraw/deposit perform, just
    ///         position-preserving. Mirrors the deposit's settle→rebaseline exactly,
    ///         so a repeated call yields nothing (no double-pay).
    function collectFees() external nonReentrant {
        Types.Deposit storage LP = autoManaged[msg.sender];
        if (LP.pooled == 0) revert NoPosition();
        _rebalance();                                // harvest pool fees into the accumulators
        uint eth_fees = feesPerShare;
        uint usd_fees = USD_FEES;
        _settlePending(LP, msg.sender, msg.sender);  // mint usd_owed+pending QUID; token-leg compounds
        _refreshBookmarks(msg.sender, eth_fees, usd_fees);   // rebaseline → next pending is 0
    }

    /// @notice PERMISSIONLESS auto-compound of `lp`'s accrued fees — WITHOUT any
    ///         action from the LP. Anyone (a keeper, a monitor, or the LP) may
    ///         crank it: it harvests pool fees into the accumulators, folds `lp`'s
    ///         owed TOKEN leg into their `pooled` (so from now on it earns
    ///         fees-on-fees — the actual compounding), and accrues the USD leg to
    ///         `usd_owed`. Compounding is otherwise gated on `_settlePending`,
    ///         which only runs when the LP is TOUCHED (their own collectFees /
    ///         deposit / withdraw, or an incidental levered-slice syncLev poke),
    ///         so a plain LP who never touches their position silently donates the
    ///         compounding on their unclaimed fees to the rest of the pool.
    ///
    ///         Crucially this moves NOTHING out of the contract: `mintRecipient`
    ///         is `address(0)`, so the USD leg only accrues to the LP's own
    ///         `usd_owed` and the token leg only grows the LP's own `pooled`. It is
    ///         therefore pure benefit to `lp` with NO theft or grief vector — no
    ///         revocable-client scope / opt-in is needed to let a keeper crank
    ///         every LP on a schedule. Same three-call shape as `collectFees`; the
    ///         arbitrary-`lp` `_settlePending`/`_refreshBookmarks` path is already
    ///         proven by the permissionless `syncLev` reconcile. No-op (not revert)
    ///         on an empty position so a keeper can sweep a list cheaply.
    /// Conservative gas an on-chain `compound` crank burns; the self-funding tip reimburses up to
    /// this × a grief-capped gasprice out of the LP's OWN harvested token-leg — so the keeper needs
    /// ZERO operator gas subsidy (the operator covers no gas at all).
    /// §E46 (2026-08-04) — RAISED 140,000 -> 200,000. The old value UNDER-REIMBURSED the cranker on
    /// every single crank: measured 172,299 gas on a 400-ETH range after real flow
    /// (`test_E45_CompoundCrankGasVsTheSelfFundingConstant`), against a 140,000 basis — short 32,299,
    /// so the only keeper that cranked was one subsidising it. 200,000 is that measured worst case
    /// plus ~16% headroom. It does NOT need to carry a RESEAT: `_rebalance()` is repack-first on the
    /// SWAP path too, so the range is recentred inside the swapper's own tx and a later crank never
    /// finds an out-of-range range (verified — 30 trades at 4x size left `reseatEpoch` unmoved).
    /// The tip is still `min(gasprice, COMPOUND_MAX_GASPRICE) x this`, GRIEF-CAPPED at half the
    /// harvest, so over-sizing can never take more than that cap; under-sizing costs liveness
    /// always, which is the asymmetry that argues for the headroom.
    uint private constant COMPOUND_GAS = 200_000;
    /// Anti-grief ceiling on the gasprice the tip pays for: a caller can't inflate `tx.gasprice`
    /// to skim more of the LP's fees as "gas".
    uint private constant COMPOUND_MAX_GASPRICE = 200 gwei;

    /// @notice Permissionless, keeper-crankable fee compounding for a plain ETH LP — folds owed
    ///         token-leg fees into `pooled` (fees-on-fees) so a passive LP no longer donates that
    ///         compounding to the pool. SELF-FUNDING: reimburses the caller's gas as an ETH tip
    ///         skimmed from the LP's OWN harvested token-leg (grief-capped, ≤ half the harvest so the
    ///         LP always keeps the majority), unwrapped from the JUST-HARVESTED WETH (in-flight — no
    ///         idle WETH is ever held). Below the floor ⇒ keeper-safe no-op:
    ///         the fees stay pending and compound later (a bigger crank, or when the LP itself touches
    ///         its position). Backing-consistent: `pooled` grows by exactly `tokR − tipSent`, and
    ///         exactly `tipSent` WETH leaves, so `pooled` ↔ backing stays matched.
    function compound(address lp) external nonReentrant {
        Types.Deposit storage LP = autoManaged[lp];
        if (LP.pooled == 0) return;                  // nothing to compound — keeper-safe no-op
        _rebalance(); // repack-first: roll pool fees into feesPerShare — §V4-RESIDUE 2026-08-18: returns unused
        uint eth_fees = feesPerShare;
        uint usd_fees = USD_FEES;
        (uint tokR, uint usdR) = _pendingFor(lp);    // token-leg (WETH-units) + USD-leg owed

        // SELF-FUNDING TIP. The token leg is NEVER free WETH — like every LP fee it lives as range
        // liquidity (see _settlePending: `LP.pooled += tokR`), so there is nothing to unwrap. Instead the
        // cranker is paid by burning a `tip`-sized sliver of the range to itself as native ETH — the SAME
        // _burnInRange primitive _withdraw uses to deliver an LP's ETH. The tip is grief-capped at half the
        // harvest and comes out of THIS LP's realized fees only (the LP compounds `tokR − sent`, other LPs'
        // feesPerShare bookmarks are untouched), so backing == claims is preserved and no operator gas is
        // ever needed. Zero gasprice (default in unit tests) ⇒ tip 0 ⇒ full compound, unchanged behaviour.
        uint gp  = tx.gasprice < COMPOUND_MAX_GASPRICE ? tx.gasprice : COMPOUND_MAX_GASPRICE;
        uint tip = gp * COMPOUND_GAS;
        if (tip > tokR / 2) tip = tokR / 2;          // cranker never takes more than half the harvest

        // Burn-to-cranker FIRST so `sent` (capped at the range's active slice) is the truth for the
        // accounting below; the whole fn is nonReentrant so the native-ETH send can't re-enter.
        uint sent = tip > 0 ? _burnInRange(tip, msg.sender) : 0;

        // EFFECTS: compound only what was NOT paid to the cranker; carry the USD leg (nothing leaves).
        uint net = tokR > sent ? tokR - sent : 0;
        if (net > 0) { LP.pooled += net; lpShares += net; }
        if (usdR > 0) LP.usd_owed += usdR;
        _refreshBookmarks(lp, eth_fees, usd_fees);   // rebaseline → next pending is 0
    }

    /// @notice This range's range, DERIVED from the one stored anchor: `[p·(1−δ), p·(1+δ)]`.
    /// @dev    §ONE-ANCHOR. Every consumer wanted the PAIR (`soldFractionWad`, `derivedThetaWad`,
    ///         `kLvrWad`, the rebalance body), which is why storing two looked natural. But the pair
    ///         is a function of ONE number, and two slots that must move together are two slots that
    ///         can fail to. Deriving is also cheaper: two `mulDiv`s against a cold SLOAD, and a
    ///         repack writes one slot instead of two.
    function rangeBounds() public view returns (uint lo, uint hi) {
        return SwapLib.updateBounds(RANGE_ANCHOR, SwapLib.RANGE_DELTA);
    }

    function _lo() internal view returns (uint) { (uint l,) = rangeBounds(); return l; }
    function _hi() internal view returns (uint) { (, uint h) = rangeBounds(); return h; }

}

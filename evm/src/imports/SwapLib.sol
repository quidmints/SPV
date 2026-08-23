// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WAD, BadAsset} from "./Types.sol";
// §A.52: the canonical view (was a file-local `IBasketTurn2`).
import {IBasket} from "./Interfaces.sol";   // §rule-2: Interfaces.sol is the canonical declaration site
                                                     // (BasketLib only RE-imports it, so importing from there does not resolve)
// §A.52: the canonical Core view (was a file-local variant).
import {ICore} from "./Interfaces.sol";
import {ILevManagerDeliver, ILevEthDeliver} from "./Interfaces.sol";
import {IBTCChannels} from "./Interfaces.sol";
import {ICore} from "./Interfaces.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// §A.52: the SHARED WETH view (was a file-local `IWethDeposit` declaring just `deposit()`).
import {IWETH9} from "./Interfaces.sol";
// §A.52: canonical shared views — these were file-local `IWeEth_L`/`IRedeem_L`/`ILiq_L`.
import {IWeETH, ICurvePool} from "./Interfaces.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
// §E68 — `lnWad` for the drain kernel's INTEGRAL (solmate has no lnWad; solady does, and is
// already remapped). Aliased so it cannot be confused with solmate's same-named library above.
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {BasketLib} from "./BasketLib.sol";
import {FeeLib} from "./FeeLib.sol";
import {Types} from "./Types.sol";
import {LevMath} from "./LevMath.sol";
import {IAux} from "./Interfaces.sol";
import {IAggregatorV3} from "./Interfaces.sol";
import {QuidLib} from "./QuidLib.sol";

// ether.fi offramp interfaces (suffixed `_L` to avoid clashing with Aux's own
// copies, since Aux imports SwapLib). Same signatures as Aux's.
// outputToken ∈ {0xEeee…EEeE native-ETH sentinel, stETH} — else InvalidOutputToken.
/// Chainlink-style USD feed — the external anchor for the TWAP cross-check.


/// @notice V4 (Quid) repack. 5th return = the resolved oracle price (Chainlink-when-stale, else internal
///         TWAP) computed during the repack-first; the swap reuses it as fillPrice so it doesn't read the
///         internal `observe` ring a 2nd time. 0 ⇒ live-read fallback. (Was two identical decls
///         IQuidRepack2/IQuidRepackRet — now collapsed onto the CANONICAL `IEthVenue.repack`
///         in `Interfaces.sol` (rule 2), which already declared this exact signature.)

/// @title  SwapLib — non-V4-callback bodies extracted from Aux to free
///         bytecode under the EIP-170 limit. unlockCallback itself stays
///         in Aux directly (PoolManager calls Aux.unlockCallback by
///         interface; the DELEGATECALL-to-library pattern doesn't
///         compose with V4's unlock semantics — established prior).
///
/// LIBRARY SEMANTICS:
///   External library functions are DELEGATECALL'd by the caller. Inside
///   each function below, `address(this)` resolves to the CALLER's
///   address (Aux), and `msg.sender` is the original caller of Aux's
///   wrapper. The library has no storage of its own; all reads/writes
///   target Aux's storage via either direct access (immutables passed
///   as args) or self-gated callbacks (supplySelf / withdrawSelf).
library SwapLib {
    using SafeERC20 for IERC20OZ;


    /// @notice Body of Aux.getTWAPforAsset — moved here to free Aux
    /// bytecode. `core` is Core; reads its observation ring.
    /// §ISBTC-SPLIT — `weth` and `asset` ARE GONE. They existed only to compute `!isETH` and pick
    /// which of one Core's two rings to read. The CALLER now picks the instance, and the instance
    /// owns exactly one ring, so the asset is decided before this frame is entered rather than
    /// re-derived inside it from a token address it had to be handed for the purpose.
    function twapBody(address core, uint32 period)
        external view returns (uint price) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period == 0 ? 1800 : period;
        secondsAgos[1] = 0;
        uint192[] memory pc = ICore(core).observe(secondsAgos);
        price = BasketLib.cumsToPrice(pc[0], pc[1], secondsAgos[0]);
    }

    /// @notice Resolve the canonical asset price from the internal TWAP + the
    ///         opt-in Chainlink anchor. `price` is the internal TWAP (1e18-RAW
    ///         USD18 per 1e18 raw units); `feed` the opt-in Chainlink USD feed
    ///         (0 → no anchor). `isWbtc` lifts the per-whole feed value to the
    ///         1e18-RAW basis (×1e10) for the 8-dec asset.
    ///
    ///         WITHIN `maxDevBps`: return the internal (DEX-native) TWAP — it is
    ///         manipulation-resistant for the curve guards and matches the price
    ///         the pool actually executes at, so normal swaps are unaffected.
    ///         BEYOND `maxDevBps`: the internal TWAP is STALE vs the real market
    ///         (a fast move the 30-min average hasn't caught up to) → return the
    ///         Chainlink price so callers price against reality.
    ///
    ///         NEVER reverts: a stale/zero/dead/reverting feed DEFERS to the
    ///         internal TWAP. (The previous version REVERTED on divergence, which
    ///         bricked QUI redemption and froze swaps/deposits on every fast
    ///         >maxDevBps move — the internal TWAP can only be moved by a
    ///         swap/repack, which also route through here, so the read-revert
    ///         deadlocked the protocol until the price mean-reverted. 
    ///         
    ///         Proven by test/TwapAnchorDeadlock.t.sol; see also the permissionless
    ///         curve-reseat that re-aligns the pool spot to this resolved price...
    ///         Also returns `stale` = true when the internal TWAP diverged >maxDevBps
    ///         from a fresh Chainlink (i.e. the returned price IS Chainlink) — the
    ///         curve-reseat auto-heal keys off this (move the spot onto Chainlink),
    ///         and it fires ONLY in this genuine-dislocation regime, never on normal
    ///         post-swap drift, so there's no churn.
    function twapResolve(address feed, uint price, bool isWbtc,
        uint maxDevBps, uint maxAge) external view returns (uint, bool stale) {
        // `price == 0` MUST fall through to the anchor, not short-circuit past it (fixed 2026-07-26,
        // BUILD-QUEUE §A.13). The Chainlink feed exists exactly for an unusable internal TWAP, and
        // price==0 is the MOST unusable state — yet it was the one case that skipped the anchor. That
        // caused a self-reinforcing deadlock: a one-directional drain walks the pool to
        // MAX_SQRT_RATIO, `ticksToPrice` yields 0, this returned 0, and `rebalanceCore:1531`'s
        // `if (twap == 0) return r` then left `didRepack == false` — so `addLiq` was never called and
        // the range could never be re-paired (measured: 8 repacks during the crash, 0 addLiq, with
        // $176,779 of basket surplus and 7.88 ETH of headroom sitting unused).
        // No new logic is needed below: with price==0, `diff == ext18`, so the deviation test trips and
        // it already returns (ext18, true) = "stale TWAP → trust Chainlink", which is precisely the
        // signal the curve-reseat auto-heal keys off.
        if (feed == address(0)) return (price, false);
        try IAggregatorV3(feed).latestRoundData() returns (
            uint80, int256 ans, uint256, uint256 updatedAt, uint80
        ) {
            if (ans > 0 && block.timestamp >= updatedAt
                && block.timestamp - updatedAt <= maxAge) {
                uint8 d = IAggregatorV3(feed).decimals();
                if (d <= 18) {
                    uint ext18 = uint(ans) * (10 ** (18 - d));
                    if (isWbtc) ext18 *= 1e10;
                    uint diff = price > ext18 ? price - ext18 : ext18 - price;
                    if (diff * 10000 > ext18 * maxDevBps) return (ext18, true); // stale TWAP → trust Chainlink
                }
            }
        } catch {}
        return (price, false);
    }

    error UnknownStableSweep();
    error BadOp();          // takeOrRead op ∉ {0,1,2} (custom error — no string-revert bytecode, EIP-170)
    /// @notice Body of Aux.sweep (delegatecall, address(this)==Aux).
    /// Returns (vbtcDelta, swept): caller adds vbtcDelta to rangeBTC and
    /// emits Swept(token, swept).
    function sweepBody(address token, address weth, address wbtc, address gho, address usdg)
        external returns (uint vbtcDelta, uint swept) {
        if (token == address(0)) {
            swept = address(this).balance;
            if (swept == 0) return (0, 0);
            WETH9(payable(weth)).deposit{value: swept}();
            IAux(address(this)).supplySelf(weth, swept);
            return (0, swept);
        }
        if (token == wbtc) {
            swept = IERC20(wbtc).balanceOf(address(this));
            return (swept, swept); // caller adds to rangeBTC inventory
        }
        if (token == weth || IAux(address(this)).toIndex(token) != 0
            || token == gho || token == usdg) {
            swept = IERC20(token).balanceOf(address(this));
            if (swept == 0) return (0, 0);
            IAux(address(this)).supplySelf(token, swept);
            return (0, swept);
        }
        revert UnknownStableSweep();
    }

    error ZeroAddress();
    error NotBasketStable();
    error SameToken();
    error ZeroAmount();
    error SlippageExceeded();

    /// @notice Body of Aux.auxSwap. Aux wraps this, pre-passing cheap state
    ///         (idxIn/idxOut, stables, LINK) and DELEGATECALL'ing here.
    ///         Inside, address(this) is Aux, msg.sender is the original
    ///         user. State mutations route back via IAux's self-gated
    ///         entries (supplySelf / withdrawSelf), gated by NotSelf —
    ///         the gate passes because msg.sender of those self-calls
    ///         equals address(this) = Aux.
    ///
    ///         WRAPPER (Aux.auxSwap) holds the `nonReentrant` lock for
    ///         the entire chain. This function MUST NOT carry its own
    ///         lock or duplicate the gate.
    function auxSwapBody(
        address tokenIn,
        address tokenOut,
        uint    amountIn,
        address recipient,
        uint    minOut,
        uint    idxIn,
        uint    idxOut,
        address linkAddr
    ) external returns (uint amountOut) {
        if (recipient == address(0))         revert ZeroAddress();
        if (idxIn == 0 || idxOut == 0)       revert NotBasketStable();
        if (tokenIn == tokenOut)             revert SameToken();

        IAux aux = IAux(address(this));

        // Inbound: pull tokenIn from caller, supply to its vault.
        uint pulled = Math.min(amountIn,
            IERC20(tokenIn).allowance(msg.sender, address(this)));
        if (pulled == 0)                     revert ZeroAmount();
        IERC20OZ(tokenIn).safeTransferFrom(msg.sender, address(this), pulled);
        pulled = aux.supplySelf(tokenIn, pulled);

        // Fee math + native conversion in its own frame (legacy stack — no via_ir).
        uint requested = _convert(aux, tokenIn, tokenOut, pulled, idxOut, linkAddr);
        amountOut = aux.withdrawSelf(tokenOut, requested, recipient);
        if (amountOut < minOut)              revert SlippageExceeded();

        // Backing invariant after the rebalance.
        aux.checkBacking();
    }

    /// @dev tokenIn→USD (fee+haircut)→tokenOut native conversion in its own frame
    ///      so auxSwapBody's 9 params stay within the legacy stack.
    function _convert(IAux aux, address tokenIn, address tokenOut, uint pulled,
        uint idxOut, address linkAddr) private returns (uint) {
        (uint[15] memory amounts, uint[15] memory yieldW,,) = aux.get_deposits();
        uint usdIn  = BasketLib.scaleTokenAmount(pulled, tokenIn, true);
        uint usdOut = FeeLib.applyFeeAndHaircut(
            tokenOut, idxOut - 1, usdIn, amounts, yieldW, linkAddr);
        return BasketLib.scaleTokenAmount(usdOut, tokenOut, false);
    }

    /// @notice Body of Aux.rangeOp. Wrapper enforces `msg.sender == V4`
    ///         BEFORE delegating; library trusts that gate. State
    ///         mutations route via supplySelf / withdrawSelf (self-gated).
    ///
    ///         The `weth` / `wbtc` immutables come from Aux's storage; we
    ///         pass them as args rather than re-fetching to avoid extra
    ///         external calls back. `rangeBTC` and `_rangeETHPrincipal`
    ///         are touched ONLY indirectly: rangeBTC via Aux's storage
    ///         pointer (passed by ref), principal via supplySelf's
    ///         internal _supply which updates it.
    /// @notice ETH-side Quid↔Vault op body. The BTC ops that once shared this
    ///         entry (op==1 native/Lightning out, op==3 WBTC ERC20 delivery, and
    ///         the isBTC branches of op 0/2) were DEAD — every caller passes
    ///         isBTC=false and rangeBTCNow=0 (Quid routes BTC through BTCChannels,
    ///         not here). Removed along with the now-redundant result struct and
    ///         the isBTC/wbtc/ctx/rangeBTCNow params. op 0=deposit, 1=take, 2=read.
    function rangeOpBody(uint amount, uint8 op, WETH9 weth, uint rangeETHLive)
        external returns (uint sent) {
        IAux aux = IAux(address(this));
        // op == 1: take ETH, capped at the live rangeETH claim.
        if (op == 1) {
            amount = Math.min(amount, rangeETHLive);
            sent = aux.withdrawSelf(address(weth), amount, address(this));
            weth.transfer(msg.sender, sent);
            return sent;
        }
        // op == 2: read current ETH claim.
        if (op == 2) return rangeETHLive;
        revert BadOp();
    }

    /// @notice Deposit body (extracted from Aux for EIP-170). Pulls up to `amount` of `tok` from `sender` into
    ///         `address(this)` (Aux, under delegatecall — so `msg.value`/balance are Aux's): if `tok == weth`
    ///         and ETH was sent, wraps `msg.value` first, then `safeTransferFrom`s the rest. Returns `sent` (0 if
    ///         nothing moved — the Aux wrapper reverts `ZeroSent`, selector preserved). Byte-identical to Aux._deposit.
    function depositBody(address tok, address weth, address sender, uint amount) external returns (uint sent) {
        if (tok == weth && msg.value > 0) {
            sent = msg.value;
            IWETH9(weth).deposit{value: msg.value}();
            amount -= Math.min(amount, msg.value);
        }
        if (amount > 0) {
            uint available = Math.min(IERC20OZ(tok).allowance(sender, address(this)), IERC20OZ(tok).balanceOf(sender));
            uint took = Math.min(amount, available);
            if (took > 0) {
                IERC20OZ(tok).safeTransferFrom(sender, address(this), took);
                sent += took;
            }
        }
    }

    /// @dev Resolve the execution price: the repack-provided core mark if non-zero, else the live oracle TWAP.
    ///      Factored from the 5 swap-body sites — no-optimizer build ⇒ ONE shared body (jump target), not 5
    ///      inlined copies of the getTWAPforAsset call, so it genuinely reclaims deployed bytecode (EIP-170).
    ///      §D3 (2026-07-31): this claim was ASPIRATIONAL until now — two verbatim inline copies survived
    ///      in `swapToBody`, tagged "stack-tight", because a CALL in argument position blew the no-`via_ir`
    ///      stack. Fixed by resolving once into the `SwapReq.px` STRUCT FIELD (no new stack slot) and
    ///      SEQUENCING the call out of argument position. Freed 197 bytes. `Stack too deep` is a code-shape
    ///      problem, never a licence to duplicate.
    function _priceOr(uint priceHint, address aux, address asset) internal view returns (uint) {
        return priceHint != 0 ? priceHint : IAux(aux).getTWAPforAsset(asset, 1800);
    }
    /// @dev Revert unless `token` is a real basket stable (toIndex>0). Factored from creditSwapIn/OutBody (dedup).
    function _requireStable(address aux, address token) internal view {
        if (IAux(aux).toIndex(token) == 0) revert StableMissing();
    }

    error NoShedPath();   // §E56: an overshoot in a pool that has traded before and has now gone dead
    error BtcInflowsViaChannels();
    error NoBtcRecipient();
    error StableMissingS();
    error SlippageMaxS();
    error UnderBackedS();
    error DeleverStableUnavailable();

    /// @notice Config for swapToBody (the immutables/handles Aux holds).
    struct SwapToCfg {
        address weth; address wbtc; address quid; address core;
        // §SLOP — ONE `range`, not `core` + `btc`. Carrying BOTH and picking between them by
        // `isBTC` re-made a dispatch the CALLER had already made: `Aux` knows the asset, so it
        // knows the range. Same collapse as `rangeOf` for cores, one level along.
        address range; address btcChannels;
    }

    /// @notice Body of Aux.swapTo — delegatecall'd (address(this)==Aux), so the
    ///         IAux callbacks (deposit/_depositVol/_tipSelf/withdrawSelf/
    ///         get_deposits/getTWAPforAsset/tokens/toIndex/bumpQuidBTC) and the
    ///         `stables`/`tranche` reads all resolve to Aux's own storage.
    ///         Verbatim of the prior in-place swapTo body; only the home moved.
    ///         The wrapper (Aux.swapTo) holds the nonReentrant lock + msg.value.
    /// @notice swapToBody's per-call request bundled — one memory pointer keeps
    ///         the swap body within the legacy stack (6 scalar params would
    ///         overflow it without via_ir).
    struct SwapReq {
        address token;
        address asset;
        bool forVolatile;
        uint amount;
        uint minOut;
        address recipient;
        /// §E308 — the swapper's load-balance consent, carried with the trade rather than
        ///          stored per address: consent belongs to the swap it affects.
        bool loadBalance;
        address inToken;   // #105: the actual INPUT token (set inside swapToBody) for the partial-fill refund
        uint px;           // §D3: resolved oracle price, set inside swapToBody. A STRUCT FIELD, not a
                           // local, so both skew branches share `_priceOr` WITHOUT adding a stack slot —
                           // that is what makes the dedup fit under the no-`via_ir` stack budget.
    }

    function swapToBody(SwapReq memory r, SwapToCfg memory c, address[] memory stables)
        external returns (uint max) {
        if (r.asset != c.weth && r.asset != c.wbtc) revert BadAsset();
        // §ISBTC-ZERO — THE LAST FOUR, AND THE NAME WAS THE PROBLEM. `isBTC` asserted an IDENTITY;
        // what all three guards below actually test is the SETTLEMENT RAIL: this range pays out
        // native ether on delivery, or it does not because it settles by Lightning cooperative
        // close. `nativeWETH` is that fact, the codebase already used it two lines down as
        // `!isBTC`, and it is the discriminator the guards were reaching for through the identity.
        // The predicate stays -- it is a REAL asymmetry -- but it no longer claims to be about
        // which coin this is.
        bool nativeWETH = r.asset != c.wbtc;
        if (!r.forVolatile && !nativeWETH) revert BtcInflowsViaChannels();
        IAux aux = IAux(address(this));
        bool stable = aux.toIndex(r.token) > 0;
        // #105: capture the actual INPUT token for the partial-fill refund BEFORE the forVolatile branch
        // zeros r.token — volatile-in = the asset, stable-in = the token, QD-in = 0 (burned => unrefundable).
        r.inToken = r.forVolatile ? (r.token == c.quid ? address(0) : r.token) : r.asset;
        if (r.forVolatile && !nativeWETH && r.recipient != address(this)) {
            if (IBTCChannels(c.btcChannels).btcRecipientOf(r.recipient) == bytes32(0)) revert NoBtcRecipient();
        }
        // _buildContext(asset): ETH-side vault always address(0) (dispatched to
        // GALAXY via the venue); nativeWETH on ETH.
        Types.AuxContext memory ctx = Types.AuxContext({
            asset: r.asset, vault: address(0), core: c.core,
            nativeWETH: nativeWETH
        });
        // E9: capture the range's OWN tick range from the repack we already run. These were
        // discarded before, and `spotPrice` was then handed to `Core.swap` only to be thrown
        // away in `_handleSwap` — so the swap ran to the TICK EXTREME. Measured consequence
        // (`PooledUsdRepackMatrix::testMatrix_S6`): a swap crossing `upPrice` with input left
        // drove the spot to `MAX_SQRT_PRICE - 1` moving ZERO tokens, which corrupts every price
        // read (`getPrice` truncates to 0) and bricks the range. The edge is the honest limit.
        // Block-scoped so `lo`/`hi`/`p` are freed at its end: `swapToBody` is stack-tight by
        // design (`via_ir = false`), and carrying the two ticks as function-scope locals is
        // stack-too-deep. Net locals are UNCHANGED from before — `rangeTicks` simply replaces the
        // old `spotPrice` carrier, which was assigned, reassigned and passed, never read.
        uint priceHint;   // §DE-TICK: `rangeTicks` deleted — it packed a range-edge PRICE LIMIT for core's
                    // swap, and settlement is at oracle bounded by inventory, so there is no limit to pack.
        {
            (,,,, uint p) = ICore(c.range).repack();
            priceHint = p;
        }
        {
            // Drain-side backing gate counts standing holdings at PAR (NOT the depeg haircut): the mint/issuance
            // side haircuts depeg (Core range-add + mint-headroom) to block over-mint, but the drain side stays at
            // par so a transient depeg can't brick redeems/swaps for existing holders (intentional asymmetry;
            // redeem VALUE is separately haircut in _redeemQuote). See DepegBackingProbe.
            (uint[15] memory _deposits,,,) = aux.get_deposits();
            if (ICore(c.core).committedUsd18() > _deposits[14]) revert UnderBackedS();
        }
        // token1is inlined per-branch (not a local) — frees a stack slot so
        // swapToBody stays within the legacy pipeline (no via_ir) after threading
        // the reused core price `priceHint`. One executed branch ⇒ still one token1is call.
        // §DE-TICK — NO `zeroForOne` LOCAL. It was assigned `token1isVol` in one branch and
        // `!token1isVol` in the other, and `Core` then re-derived the direction with a flip that
        // cancelled both. The quantity actually being transported is `r.forVolatile`: the user
        // wants volatile OUT, so the user is paying USD IN. Passed directly, and the stack slot
        // this local was costing (the note above worried about exactly that) comes back.
        if (!r.forVolatile) {
            if (r.token != c.quid && !stable) revert StableMissingS();
            r.amount = aux._depositVol{value: msg.value}(r.asset, msg.sender, r.amount);
            max = ICore(c.core).POOLED_USD();
            // JIT-DEPTH-GUARANTEE.md §2 range site (DEFERRED — design gap, NOT built): this is the
            // volatile→USD leg whose fill is bounded by the range's in-range USD depth (`max`), so a
            // large sell can exhaust it / partial-fill → uncertain impact → sandwich room. The
            // guarantee would, before executing, top USD depth up to what `r.amount` needs within a
            // target impact bound (tryPair: idle range USD → unwindForRedeem-inverse → redeem mature
            // QUID→addLiq) then unwind it post-swap. Three unresolved blockers keep it out for now:
            //   (1) NO impact formula: the spec's "USD depth needed within a target impact bound" is
            //       "a pure function of size + current in-range depth" but gives neither the function
            //       nor the target bound value;
            //   (2) place+unwind-in-ONE-tx is INCOMPATIBLE with the existing outOfRange/pull
            //       primitive — pull() enforces `block.number >= created + 47`, so an outOfRange
            //       position cannot be unwound in the same block (Quid.sol pull());
            //   (3) this body runs DELEGATECALL'd in Aux context; a mid-swap re-entry into Quid's
            //       onlyUs addLiq/unwindForRedeem on the SHARED range needs its reentrancy + price-
            //       impact interaction with the V4 unlock callback worked out.
            // SYMMETRIC A-S skew (its own frame ⇒ no via_ir): a sell that pushes the pool's
            // volatile inventory PAST target is inventory-INCREASING (the self-funded short's
            // range-leg shed) ⇒ charge the same A-S premium the drain does; a sell that REFILLS
            // a scarce reservoir REDUCES imbalance ⇒ sellSkew's mirror+flush yields 0 (EXEMPT).
            // Scale the volatile input DOWN by the premium ⇒ less USD credited out; the
            // withheld input stays as basket backing (same mechanism as the drain leg).
            {
                r.px = _priceOr(priceHint, address(aux), r.asset);
                uint skew = sellSkew(c.core, r.px, r.amount); // inline (swapToBody stack-tight)
                retainSkewPremium(c.core, r, skew, true);   // NATIVE volatile input ⇒ convert   // mutates r.amount; r.px declares NATIVE
            }
        } else { max = ICore(c.core).POOLED();
            // QD-in valued at the SAME perShare a redeem uses (no-drain: never worth more swapped than redeemed).
            // DESIGN NOTE: unlike redeem, swap-out is NOT capacity-gated / deferred during stable
            // illiquidity — it pays volatile from the pool's OWN inventory (bounded by `max` = POOLED depth +
            // the in-swap committed<=backing gate), a DIFFERENT liquidity source than the (possibly illiquid)
            // stable vaults. Point-in-time value per QD is identical to redeem, so this is fair value, NOT a
            // drain; the only asymmetry is a liquidity-TIMING preference (swap exits immediately, redeem may
            // defer). Hard-gating swap-out by the redeem capacity would block legitimate QD->ETH swaps for a
            // bounded, fair transfer, so it is deliberately left ungated.
            r.amount = _consumeVolInput(aux, r.token, r.amount, c.quid, stable, stables);
            r.token = address(0);
            // same effective-rate scarcity skew on the volatile-OUT drain as the
            // native-BTC well (creditSwapOutBody). ETH reuses the IDENTICAL surface (SOR depth
            // isn't guaranteed); WBTC swap-out drains the same POOLED, so it's skewed too
            // (else arbers route around the premium). Scale the buy DOWN so a scarce pool hands
            // out less volatile; the withheld input stays as backing. The swap still executes at
            // the honest oracle (priceHint) through routeSwap ⇒ no manip-guard exemption.
            {
                r.px = _priceOr(priceHint, address(aux), r.asset);
                uint skew = wellSkew(c.core, r.px, r.amount); // §E68: r.amount IS the 6-dec drain size
                retainSkewPremium(c.core, r, skew, false);  // buy-driving USD ⇒ already 6-dec   // mutates r.amount; r.px declares NATIVE
            }
        }
        max = _finishSwap(ctx, aux, r, r.forVolatile, max, priceHint);
    }

    /// @dev routeSwap (8-field RouteParams build) + bumpQuidBTC + slippage guard
    ///      in its own frame so swapToBody stays within the legacy stack — no
    ///      via_ir crutch.
    /// @dev Pack the range's tick range into one word. Two int24 function-scope locals are
    ///      stack-too-deep in `swapToBody`; one packed carrier is not. int24→uint24→int24 is
    ///      bit-preserving, so negative ticks round-trip exactly.

    function _finishSwap(Types.AuxContext memory ctx, IAux aux, SwapReq memory r,
        bool inputIsUsd, uint pooled, uint priceHint) private returns (uint max) {
        uint poolSupplied;
        // Reuse the resolved oracle price from the repack-first (priceHint) instead of
        // re-reading the internal `observe` ring + Chainlink a 2nd time per swap;
        // fall back to a live read only if the repack couldn't resolve it (priceHint==0,
        // e.g. a bootstrap pre-history read that try/catch'd to 0).
        uint fillPrice = _priceOr(priceHint, address(aux), r.asset);
        uint consumed;
        (max, poolSupplied, consumed) = BasketLib.routeSwap(ctx, Types.RouteParams({
            inputIsUsd: inputIsUsd, token: r.token,
            amount: r.amount, pooled: pooled,
            fillPrice: fillPrice,
            recipient: r.recipient,
            loadBalance: r.loadBalance
        }));
        // §ISBTC-SPLIT: derived, not threaded -- `ctx.nativeWETH` IS `!isBTC` (set at the call
        // site above), so the frame already carried the answer and the parameter was a second copy.
        if (poolSupplied > 0 && !ctx.nativeWETH) aux.bumpQuidBTC(poolSupplied);
        // a dry volatile pool delivers max==0; with minOut==0 the
        // `max < minOut` guard wouldn't fire and the already-consumed input
        // (burned QUID / supplied stable) would strand with nothing out. Revert
        // on max==0 unconditionally so the tx rolls back to a clean refund.
        if (max == 0 || max < r.minOut) revert SlippageMaxS();
        // #105 SWAPPER REFUND (ALL input legs): an inventory-bounded partial fills only `consumed`; refund
        // the unfilled remainder to the swapper. Own frame (_refundExcess) so this helper stays within the
        // no-via_ir stack. QD-in is skipped (inToken==0 — the QD was burned, structurally unrefundable).
        _refundExcess(aux, r, consumed);
    }

    /// @dev Refund the swapper's unfilled input remainder (r.amount − consumed) after a partial fill — own
    ///      frame so _finishSwap stays within the legacy stack. r.inToken carries the input: volatile-in is
    ///      NATIVE (r.amount from _depositVol; no conversion); stable-in is 6-dec USD (deposit's scale) →
    ///      native via scaleTokenAmount; QD-in is 0 (skipped — burned). Aux context ⇒ direct withdrawSelf.
    function _refundExcess(IAux aux, SwapReq memory r, uint consumed) private {
        if (r.inToken == address(0) || r.amount <= consumed) return;
        uint excess = r.amount - consumed;
        aux.withdrawSelf(r.inToken,
            r.forVolatile ? BasketLib.scaleTokenAmount(excess * 1e12, r.inToken, false) : excess,
            msg.sender);
    }

    /// @dev Consume the volatile-swap INPUT (QUID-turn + seed un-tip, or
    ///      stable/vault deposit) in its own frame. Returns the post-consume input
    ///      amount. Verbatim of the prior inline else-branch.
    function _consumeVolInput(
        IAux aux, address token, uint amount, address quid, bool stable,
        address[] memory stables
    ) private returns (uint) {
        if (token == quid) {
            // QD-in valuation lives in its OWN frame (_consumeQdIn) — the value math + seed-untip loop
            // otherwise overflow the legacy stack (no via_ir crutch).
            amount = _consumeQdIn(aux, quid, amount, stables);
        } else {
            address vault = aux.tokens(token);
            uint index = aux.toIndex(vault);
            if (index > 5) {
                amount = aux.withdrawSelf(vault, amount, address(this));
            } else if (!stable) revert StableMissingS();
            // §A.50/C1: native → 6-dec, same reasoning as `_swapOutPrep`. No-op for 6-dec stables.
            amount = scaleTo6(aux.deposit(msg.sender, token, amount), token);
        }
        return amount;
    }

    /// @dev QD-in swap valuation in its own frame. BASKET-SHARES: value the burned QD at the SAME per-share
    ///      value redeemAsBody uses — min(par, SOLVENT backing / matureSupply) — so QD is NEVER worth more
    ///      swapped-out than redeemed (closes the drain: without this, drift lets a holder swap QD->volatile
    ///      for $1/QD > its share value). `solvent` = par TVL − depeg ONLY: temporary illiquidity does NOT
    ///      discount value (it only caps redeem CAPACITY; a swap delivers volatile from pool depth, bounded
    ///      separately by `max` in swapToBody).
    ///      SCALE (CRITICAL): BasketLib.qdShareValue returns 18-dec USD (redeem feeds it to 18-dec take()), but
    ///      the SWAP pipeline (routeSwap→convert→POOLED_USD_*→Core.swap) is 6-dec. Feeding the 18-dec value
    ///      straight in made `min(amount, poolCap6)` always pick the 6-dec pool cap → ~1e12x over-delivery of
    ///      pool volatile for dust QD burned (a drain). Down-scale to 6-dec here so the swap sizes on the true
    ///      USD value; the dropped ≤1e12 sub-unit dust is immaterial to a USD amount.
    function _consumeQdIn(IAux aux, address quid, uint amount, address[] memory stables)
        private returns (uint) {
        (uint burned, uint seedBurned) = IBasket(quid).turn(msg.sender, amount);
        uint solvent;
        {   (uint[15] memory d, uint[15] memory yW,, uint dl) = aux.get_deposits();
            // yW[0] = Σ balance×rate (the annualised-rate numerator), NOT d[0] = Σ yieldWeighted.
            (solvent,) = aux.get_metricsWith(d[14], yW[0]);
            solvent = solvent > dl ? solvent - dl : 0; }
        amount = BasketLib.qdShareValue(burned, solvent, IBasket(quid).matureSupply() + burned) / 1e12;
        if (seedBurned > 0) {
            uint n = stables.length;
            for (uint i = 0; i < n; i++) {
                address s = stables[i];
                aux.tipSelf(SoladyMath.fullMulDiv(aux.tranche(s), seedBurned, burned), s, -1);
            }
        }
        return amount;
    }

    // ─── ether.fi offramp (extracted from Aux to free bytecode) ──────────────
    // Immutables/consts passed in via OfframpCfg (the library can't read Aux's
    // immutables). The msg.sender==V4 gate stays in the Aux wrapper; these bodies
    // run via DELEGATECALL so address(this)==Aux (its weETH, its caller id).

    /// @dev `curvePool` REPLACED `v3router`+`poolFee`+`poolFee2` (2026-08-09). Measured live against the
    ///      weETH/WETH oracle, Curve vs the Uniswap 0.01% tier: −1.39 vs −17.55 bps at size 1, −1.51 vs
    ///      −18.79 at 100, −3.47 vs −28.16 at 1000. Both cliff near 2,000 where Curve's 2,047 WETH runs
    ///      out — which is the ONLY case the wait-NFT rung now exists for.
    struct OfframpCfg {
        address weeth; address weth; address curvePool; address lp;
    }

    /// @notice Sell `weethIn` for WETH on Curve, floored at `minOut`. Returns 0 on failure (caller decides).
    /// @dev  weETH is coin1, WETH is coin0 -> exchange(1, 0, ...). The pool pays msg.sender, so a caller
    ///       needing delivery elsewhere transfers after. Approval is set per call rather than infinite:
    ///       this runs in the VAULT's delegatecall context and a standing allowance there is protocol
    ///       inventory exposed to a pool upgrade.
    function curveSellWeeth(OfframpCfg memory c, uint weethIn, uint minOut) internal returns (uint) {
        if (c.curvePool == address(0) || weethIn == 0) return 0;
        // §PM-INVARIANT-3 — exact-amount in, zeroed in the `catch`. This is the SHAPE every external
        // venue call in this tree follows, and it is the one `SOR._v3Route` was measured against and
        // found missing its zeroing.
        IERC20(c.weeth).approve(c.curvePool, weethIn);
        try ICurvePool(c.curvePool).exchange(int128(1), int128(0), weethIn, minOut) returns (uint out) {
            return out;
        } catch { IERC20(c.weeth).approve(c.curvePool, 0); return 0; }
    }

    /// @notice Body of Aux._sourceWethFromEtherfi — opportunistic, non-blocking.
    function sourceWethBody(uint want, OfframpCfg memory c) external returns (uint) {
        if (want == 0 || c.weeth == address(0) || c.curvePool == address(0)) return 0;
        uint idle = IERC20(c.weeth).balanceOf(address(this));
        if (idle == 0) return 0;
        uint weethFull = IWeETH(c.weeth).getWeETHByeETH(want);
        if (weethFull == 0) return 0;
        uint weethIn = weethFull > idle ? idle : weethFull;
        if (weethIn == 0) return 0;
        uint fairWeth = SoladyMath.fullMulDiv(want, weethIn, weethFull);
        uint minOut = (fairWeth * 995) / 1000;            // 0.5% slippage cap
        return curveSellWeeth(c, weethIn, minOut);   // proceeds land here; caller is the Vault
    }

    // ─── BTC swap-IN / swap-OUT bodies (extracted from Aux to free bytecode) ──
    // DELEGATECALL'd → address(this)==Aux, msg.sender==Aux's original caller.
    // The `onlyBTCChannels` gate stays in Aux's wrapper (rogue-mirror defense:
    // a rogue contract must not drive these by delegatecalling the library).
    // CORE / V4 / WBTC are Aux immutables, passed in as args (the library
    // can't read Aux's immutables). The AuxContext is reconstructed inline,
    // matching Aux._buildContext(WBTC) exactly: vault address(0), nativeWETH
    // false.
    error StableMissing();
    error SwapOutShort();
    error SwapInShort();
    error SwapInDrainsProceeds();

    /// @notice Body of Aux.creditSwapIn — settle a BTC→USD swap-IN. See Aux's
    ///         wrapper docblock for the full semantics.
    /// @param rangeVault THE BTC VAULT, not Quid. It was named `core` — which means Quid/ETH everywhere
///        else — while `Vault.creditSwapIn` passes `address(this)`. That is why `repack(true)` below
///        is CORRECT and must not be "fixed" to false during the isBTC fold.
    function creditSwapInBody(address seller, uint sats, address token, uint minDeliveredUsd,
        address core, address rangeVault, address wbtc, address aux) external returns (uint consumedSats) {
        if (sats == 0) return 0;
        // The USD-side output must be a real basket stable. QUID is NOT takeable
        // (it's the liability, not a reserve asset) — so a swap-IN can never mint
        // QUI, and an invalid `token` reverts up-front rather than running the swap
        // (drawing pool USD) and then silently delivering nothing to the seller.
        _requireStable(aux, token);
        // ETH-PARITY: a swap-IN is the on-curve MIRROR of swap-OUT, not a bespoke
        // off-curve refill. The hop having received `sats` over Lightning is the
        // BTC analog of swapTo's `_deposit` — "the contract now holds the asset" —
        // so from here we run the SAME V4 swap path swap-OUT uses, in the BTC→USD
        // direction (`!forVolatile`), delivering the USD output to `seller` as
        // `token`. Consequences, all by construction (no special-casing):
        //   • the curve (POOLED_USD liquidity) bounds the payout — the old
        //     BtcInflowCap is gone; over-supply just slips / partial-fills;
        //   • netDeliveredBtc / swapUsdBtc decrement from the swap DELTA in
        //     Core._handleSwap (the symmetric `-=`), so per-channel exit
        //     attribution stays honest with no manual draw/dec calls here;
        //   • `token == QUID` reverts inside take (QUID is not a basket stable),
        //     so a swap-IN can NEVER mint QUI — settlement is always existing
        //     pooled dollars, exactly like the ETH side.
        // `sats` are 8-dec (== mockBTC), so they are the exact BTC input; the
        // USD-side cap (POOLED_USD) converts to sats via the same flat-1e18 scale
        // swap-OUT uses, keeping units coherent.
        // ctx + RouteParams built field-by-field (not an inline literal) so the
        // added priceHint reuse fits this body's legacy stack without via_ir — the literal
        // construction peak is what overflowed. vault=0 / nativeWETH=false are the
        // zero-defaults of a fresh memory struct.
        Types.AuxContext memory ctx;
        ctx.asset = wbtc; ctx.core = core;
        // Reuse the repack-resolved oracle price (5th return); live-read only if
        // priceHint==0 — same as _finishSwap. POOLED_USD is passed RAW: `convert` now uses a flat
        // 1e18 for both assets, so the reserve converts to its true sats-equivalent directly. The
        // former ×1e10 pre-scale here CANCELLED convert's 1e18/1e8 under-scaling — two wrongs that
        // agreed on this path only; both are removed together, leaving this path unit-neutral.
        // §E9 — this field now carries the RANGE'S PACKED TICKS, not a price. `Core._handleSwap`
        // unpacks it into the swap's `sqrtPriceLimitX96`. ALL THREE producers must agree: this one,
        // `_swapOutPrep` below, and `_finishSwap`. Passing a real spotPrice here is what broke
        // 132 tests (`InvalidTick` / `PriceLimitAlreadyExceeded`) when only one was converted.
        // Block-scoped: these bodies are stack-tight by design (`via_ir = false`).
        uint priceHint;
        Types.RouteParams memory rp;
        {
            (,,,, uint p_) = ICore(rangeVault).repack();
            priceHint = p_;
        }
        rp.inputIsUsd   = false;   // BTC→USD: the volatile side is the INPUT (mirror of the buy)
        rp.token        = token;                            // USD-side output stable → seller
        rp.amount       = sats;                             // exact BTC input
        rp.pooled       = ICore(core).POOLED_USD();
        // SWAP-IN REFILL PRICING. This leg settles FLAT at the honest oracle, and that is FINAL —
        // not a placeholder. CORRECTED 2026-07-26: this comment used to describe a SYMMETRIC skew
        // BONUS (mirror of the swap-OUT drain penalty) as a "corrected design" that would "land with
        // the on-chain refill change once EIP-170 slimming frees room". That design was REJECTED and
        // its implementation REMOVED (`payRefillBonus`, 2026-07-22): paying a swapper a bonus is
        // exactly what the removal was meant to stop, so that the retained drain premium STAYS with
        // LPs as backing (`retainSkewPremium` -> `Core.skewPremium*`, refilling direction exempt at
        // `:452`/`:962`). Do NOT rebuild it. The refill mechanism is: LP entry
        // (`Vault.requestDeposit`) as the PRIMARY, self-funding path, plus the ACTIVE flash-serve
        // (#100 / J.3) — flash the scarce asset, serve the opposite flow, repay, premium stays with
        // LPs. A flash-and-repay, never a subsidy to whoever swaps in first.
        // §E18 — "still-unbuilt" DELETED 2026-08-18: IT WAS BUILT, AND THIS COMMENT CONTRADICTED
        // ANOTHER ONE THIRTY LINES BELOW IT. `:703` describes the same mechanism as operating —
        // "the refill is a self-funding fleet op (JIT Morpho-flash BTC → creditSwapIn → repay)" —
        // and the rail it names is live: `BTCChannels.creditSwapIn` → `Vault.creditSwapIn:711` →
        // `creditSwapInBody` here, driven off-chain by the hop daemon.
        // ⚠️ THIS EXACT LINE COST THREE FINDINGS. §E18 records that they were built on it and had to
        // be withdrawn when the owner said "flash refill was already built". A stale comment does
        // not merely mislead a reader — it survives long enough to become the premise of new work.
        rp.fillPrice = _priceOr(priceHint, aux, wbtc);
        rp.recipient    = seller;
        // routeSwap + both gates + the refill bonus run in their OWN frame (_swapInSettle) so
        // creditSwapInBody stays within the legacy stack (no via_ir). Returns the sats actually converted so
        // the hop can refund any inventory-bounded remainder.
        consumedSats = _swapInSettle(ctx, rp, minDeliveredUsd);
    }

    /// @dev Own-frame tail of creditSwapInBody: base swap + minDeliveredUsd floor + solvency gate. NO refill
    ///      BONUS (removed 2026-07-22): the refill is a self-funding fleet op (JIT Morpho-flash BTC →
    ///      creditSwapIn → repay, gas via #87), so the drainer's retained skew premium accrues to LPs as
    ///      backing (recordSkewPremium) rather than being paid out to the refiller — the refill settles at the
    ///      honest fillPrice. Serves the creditSwapIn rail
    ///      (JIT sell-to-pool reward); requestDeposit (become-LP, pooled fees) never reaches here.
    function _swapInSettle(Types.AuxContext memory ctx, Types.RouteParams memory rp, uint minDeliveredUsd)
        private returns (uint consumedSats) {
        // core / seller / token are already carried by the structs (ctx.core, rp.recipient, rp.token) — read
        // them here rather than as params so creditSwapInBody's call site stays within the legacy stack.
        address core = ctx.core;
        // `consumedSats` = the seller's BTC actually converted (routeSwap caps input at the POOLED_USD USD
        // inventory). On an inventory-bounded partial it is < the `sats` sent, and the caller signals the hop to
        // refund the `sats − consumedSats` remainder (the seller's BTC is held off-chain over the deposit/HTLC).
        uint deliveredUsd;
        (deliveredUsd,, consumedSats) = BasketLib.routeSwap(ctx, rp);
        if (deliveredUsd < minDeliveredUsd) revert SwapInShort();
        if (ICore(core).POOLED_USD() < ICore(core).pendingSwapOutUsd())
            revert SwapInDrainsProceeds();
        // NO refill BONUS: the refill is a self-funding fleet op (JIT Morpho-flash BTC → creditSwapIn → repay,
        // gas already refunded via #87). The drainer's retained skew premium stays in the basket as LP backing
        // (recorded by recordSkewPremium) instead of being paid out here — the fleet captures the imbalance for
        // the protocol directly, so the swapper-facing bonus is redundant. Refill settles at the honest oracle.
    }

    /// §E275 — **`MAX_WELL_SKEW` IS DELETED. IT WAS ONE NUMBER DOING THREE JOBS**, and the cap job
    /// was the one that could not be justified: the curve was CALIBRATED TO LAND ON IT
    /// (`Γ ≡ MAX_WELL_SKEW` exactly), so it never bounded anything it did not also define.
    /// The two honest jobs are separated below. They hold the SAME VALUE TODAY BY INHERITANCE, NOT
    /// BY DERIVATION — §E274 derives Γ = 5.48e15 from `FLOW_DECAY`'s 48h half-life, and splitting
    /// them is what lets Γ move without silently repricing the unknown-variance case.
    ///
    /// Γ — the Avellaneda–Stoikov scale, folding risk-aversion γ and the horizon (T−t) into one
    /// coefficient. THIS IS PRICING, NOT A BOUND: it multiplies `σ²·qBar` (`skewWad`, `sellSkew`).
    /// ⚠️ Still the inherited 3e16 (⇒ a 10.95-day horizon nobody chose). §E274 measured the
    /// replacement but does NOT land it here — that is a separate money-path change, deliberately
    /// not bundled with the cap removal so a regression can be attributed to one of them.
    uint internal constant GAMMA_WAD = 3e16;
    /// §E289 — **THE POLE'S LOCATION, in units of `target`** — our analogue of A–S's ω.
    /// A–S do NOT clamp: they place the singularity where the agent cannot go. §2.3's denominator is
    /// `2ω − γ²q²σ²`, and the paper says ω *"may be interpreted as an upper bound on the inventory
    /// position our agent is allowed to take"*, with a natural choice that *"would ensure that the
    /// prices defined above are bounded"*. Our kernel is `q/(1−q)` — a pole at `q = 1` — and
    /// `q = (target−inv)/target`, so **`q = 1` IS `inv = 0`: our singularity sits exactly ON the
    /// reachable boundary, which is the one thing A–S take care to avoid.** Generalised, the pole
    /// lives at `q = κ`, i.e. `inv = (1−κ)·target` — NEGATIVE inventory, unreachable, for any κ > 1e18.
    ///
    /// 🔴 **`1e18` IS TODAY'S BEHAVIOUR, EXACTLY — NOT APPROXIMATELY.** At this value the generalised
    /// expression below collapses to the original character for character (`κ·x/1e18 == x`), so this
    /// landing is a PURE REFACTOR: it installs the dial and changes no economics, which is what makes
    /// a regression attributable to the refactor alone (rule 10).
    /// ▶️ **MOVING IT IS A SEPARATE, ECONOMIC COMMIT** with its own prediction, and it is GATED on a
    /// restoration mechanism existing — §E276 (the shift) or the refill. Raising κ makes the range
    /// drainable at a finite price, and §E276 established that nothing currently pulls inventory back:
    /// we never move the bid, the refill direction is exempt rather than paid, and §V-R1 is not in
    /// code. **That sequencing is what refuted §E287; do not repeat it by editing this constant early.**
    /// ⚠️ A–S's own choice is one unit beyond the maximum ⇒ `κ = 2e18` here, because our unit of `q`
    /// is one flow-window. **That coincidence is an ANALOGY, not a derivation** — see §E289's caveats.
    uint internal constant KAPPA_WAD = 1e18;
    /// The conservative charge for `σ² == 0` — "we could not MEASURE the variance", never "there
    /// was none" (§E59/§E79). A POLICY price for absent information, not a ceiling on a computed
    /// one: nothing is compared against it, it is only ever RETURNED.
    uint internal constant UNKNOWN_VARIANCE_SKEW = 3e16;
    /// The arithmetic limit of a rate haircut. `retainSkewPremium` computes
    /// `premium = amount·skew/1e18` then `amount -= premium`, so `skew > 1e18` means a premium
    /// exceeding the trade — checked arithmetic, i.e. **panic 0x11** (§E273, measured).
    /// §E274 MEASURED that the kernel crosses this at FINITE scarcity — q ≥ 0.893 at 200% vol under
    /// today's Γ — so this is REACHED IN NORMAL OPERATION once the cap is gone, not at the pole only.
    /// ⇒ It is the DECLINE THRESHOLD, not a clamp: past it the quote is unfillable and is refused by
    /// name instead of arriving as a panic from inside a subtraction. **Under solver routing an
    /// unfillable quote is the honest answer** — the solver routes that leg elsewhere (§E272).
    uint internal constant SKEW_UNFILLABLE = 1e18;
    /// §E216 — the σ²-FREE component: the cost of inventory that WAS there and LEFT.
    /// **210 ppm = 2.1e14 WAD, AND IT IS NOW THE WHOLE CHARGE.** A drain of D from a balanced range
    /// creates exactly 2·D·px of idle inventory, so 210 ppm on that base equals 420 ppm on D itself
    /// (§E48) — which is why deleting the flat 420 (§E311) took no revenue with it: this term already
    /// WAS that charge, in inventory-proportional form, and the fill was paying both.
    /// ⚠️ THE DERIVATION IS STATED HERE, NOT CITED. It used to read `Aux.swapFeePpm()/2`; that
    /// accessor is deleted, and **a constant explained by pointing at a symbol becomes unexplained the
    /// moment the symbol goes** — this is the second time this same constant lost its citation
    /// (`imbalanceFeeUsd6` carried it before).
    /// Scaled by the FRACTION DRAINED, so it is bounded BY this value: a full drain owes 2.1 bps,
    /// half a drain 1.05 bps, and a range that was never funded owes nothing at all.
    uint internal constant DEPLETION_RATE_WAD = 2.1e14;   // 210 ppm = half the pool fee tier
    // Avellaneda–Stoikov calibration. `realizedVarianceWad` is ANNUALIZED realized
    // variance in WAD (QuidLib:294-318: tickVar·(SECS_PER_YEAR/THETA_STEP)·1e10 ⇒ a
    // fraction² scaled 1e18; e.g. 80%-annualized vol ⇒ σ²≈0.64 ⇒ ~6.4e17). SIGMA_REF is
    // the REFERENCE variance = 1e18 (variance 1.0 = 100% annualized vol) at which full
    // scarcity saturates the cap — picking the per-interval-scale 1e16 instead would peg
    // skew at the cap for any real crypto vol (>10% ann), so the annualized 1e18 is the
    // unit-correct anchor. Γ folds the risk-aversion γ and the horizon (T−t) into ONE
    // coefficient (the horizon is already carried by the FLOW_DECAY-smoothed flow/scarcity),
    // fixed so skew(q=1, σ²=SIGMA_REF)=Γ·SIGMA_REF=MAX_WELL_SKEW.
    // STABLENESS = ρ, the DEPLETION-BARRIER ORDER (derived, NOT a fit exponent). The skew is
    // Γ·σ²·q / (1−q)^ρ: the A-S linear reservation premium Γσ²q amplified by the shadow price of the
    // last inventory units. Derived from the HJB with a HARD inv≥0 constraint — a −log(inv) barrier
    // (the LP physically cannot serve at inv=0) whose marginal ∝ 1/inv makes depletion convexly
    // costly. ρ=1 = the log-barrier (constraint exactly at inv=0); ρ=0 recovers plain linear A-S;
    // ρ>1 = a harder barrier. Calculus-derived — the one parameter is a barrier order, not a curve fit.
    // Volatile range half-width, in bps of price (paddedSqrtPrice reads it as (10000±delta)/10000).
    // THIN range (±0.2%). Quid SERVES swaps and RESEATS, so it can't go to a literal one-tick like a static
    // static position: at delta=10 the reseat re-add (updateTicks(targetSqrt,10)) collapses lower==upper and V4
    // reverts. 0.2% is the thinnest that keeps the reseat re-add non-degenerate while staying maximally thin
    // (near-zero natural slippage, whale-friendly). Frequent repacks are covered by repack-first (swapper-paid)
    // + the self-funded reseat keeper — no separate gas budget needed.
    uint internal constant RANGE_DELTA = 20;

    // DYNAMIC CAP calibration. Instead of a fixed 3%, the ceiling tracks the native-BTC MM's
    // REAL drain-edge cost, which is dominated by the BTC-price risk while its capital is
    // locked from committing sats until the swap-in settles + it holds the USD (~6 confs ≈ 1
    // hour). That cost ≈ σ over the confirmation window · a safety multiple + the splice fee.
    uint internal constant CONF_FRAC_WAD = 114_000_000_000_000; // ≈ 1hr / 1yr (WAD) — confirmation-window fraction of a year
    uint internal constant SPLICE_FLOOR  = 2e15;                // 0.2% — on-chain splice-fee floor (the feerate term)
    // ETH settles in ~one block — NO ~1hr confirmation-capital lock and NO splice — so its cap uses a
    // one-block settlement window and a zero splice floor. Charging ETH the BTC 1hr window over-priced its cap.
    uint internal constant ETH_CONF_FRAC_WAD = 380_000_000_000; // ≈ 12s / 1yr (WAD) — one-block settlement window

    /// §ISBTC-SPLIT — THE PER-ASSET RISK PROFILE, PASSED AS NUMBERS. The skew math used to take a
    /// `bool isBTC` purely so it could look up WHICH of the constants above to use. That is the
    /// hand-rolled dispatch this refactor removes, one layer down: the instance knows its own risk
    /// parameters, so it hands them over and the math stops knowing what an asset is. A THIRD range
    /// then needs no edit here at all -- it brings its own numbers.
    /// ⚠️ A STRUCT, NOT TWO PARAMETERS, DELIBERATELY. `sellSkew` sits EXACTLY at the stack limit
    /// (`via_ir = false`; its own comments record two measured stack-too-deep incidents), and one
    /// memory pointer costs less stack than two values -- CLAUDE.md's stated remedy.
    struct Risk { uint confFracWad; uint spliceFloor; }

    /// The two canonical profiles, named. Callers that are not an instance (tests exercising the
    /// pure math, chiefly) state WHICH profile they mean instead of passing a boolean the function
    /// would have to resolve -- the numbers are the subject, so they are what appears.
    function btcRisk() internal pure returns (Risk memory) { return Risk(CONF_FRAC_WAD, SPLICE_FLOOR); }
    function ethRisk() internal pure returns (Risk memory) { return Risk(ETH_CONF_FRAC_WAD, 0); }

    function _risk(address core) private view returns (Risk memory rk) {
        (rk.confFracWad, rk.spliceFloor) = ICore(core).riskParams();
    }

    /// @notice THE ADVERSE-SELECTION BASE — the MM's settlement-window loss DERIVED from live
    ///         volatility: `σ²_annual · T_settle/yr / 8` (LVR over the window the MM's capital is at
    ///         risk, MMRZ eq.16) **plus** the per-asset `SPLICE_FLOOR`. Low vol ⇒ small base; high
    ///         vol ⇒ larger base; no ceiling of any kind. See the §E62 note in the body.
    /// ⛔ **THE NAME SAYS "MAX" AND THE FUNCTION IS NOT A MAXIMUM. §E79 INVERTED IT FROM CEILING TO
    ///     BASE** and the name did not follow. Every caller ADDS it (`skew += _maxWellSkew(…)` at the
    ///     kernel's tail, `kernel + _maxWellSkew(…)` in `_composePrice`) or RETURNS it as the whole
    ///     charge (`skewWad`'s `target == 0` and flush branches). Nothing is ever compared against it.
    /// 🔴 **CORRECTED — THIS DOCBLOCK DESCRIBED A FORMULA THE BODY DOES NOT CONTAIN, IN FIVE PLACES,
    ///     AND EVERY SYMBOL IT NAMED IS NOW COMMENT-ONLY.** It read *"√(σ²·T) · CAP_SAFETY +
    ///     SPLICE_FLOOR, hard-capped at MAX_WELL_SKEW … never above 3% … reuses
    ///     FixedPointMathLib.sqrt"*. MEASURED in `evm/src`: **`MAX_WELL_SKEW`, `CAP_SAFETY`,
    ///     `SIGMA_REF` and `STABLENESS` have ZERO code references — every remaining hit is a comment**,
    ///     the body takes NO square root (it is LINEAR in σ², which is the whole reason the
    ///     clock-stretching vector is linear too — see the kernel's §E68/§E289 notes), CAP_SAFETY's
    ///     2× was folded away with the cap, and §E62 forty lines below already records that the hard
    ///     3% stopped bounding this path. ⇒ The header survived four separate changes that each
    ///     falsified one of its clauses, which is exactly how a comment becomes the premise of new
    ///     work (§E18: *"THIS EXACT LINE COST THREE FINDINGS"*, `:677`).
    function _maxWellSkew(uint sigmaSqWad, Risk memory rk) internal pure returns (uint) {
        // PER-ASSET settlement window: BTC locks capital through ~1hr of confirmations (CONF_FRAC_WAD) + an
        // on-chain splice-fee floor; ETH settles in ~one block with no confirmation lock and no splice.
        uint confFrac = rk.confFracWad;
        // §UNIT-B-PATIENCE — σ² IS ATTACKER-STRETCHABLE AND THIS WINDOW DOES NOT DEFEND IT.
        // σ² is a per-unit-time rate whose ring advances only on swaps, so spacing slices collapses it
        // (MEASURED: 4h gaps → σ² 24× down, charge 93.3% down). Pricing this base over the ACTUAL idle
        // window was built and measured: it moves the charge ~1% because the base is ~0.002% of it, and
        // it cost 378 bytes + 2 staticcalls/swap, so it was REVERTED. The vector sits in the KERNEL's
        // σ² linearity. See §UNIT-B-PATIENCE / §UNIT-B-PATIENCE-STEP2 before attempting either again.
        // ⚠️ §E345 — "σ² IS ATTACKER-STRETCHABLE" IS NOW A STATEMENT ABOUT **ONE OF TWO LEGS**, AND
        // NOT THE ONE THAT BINDS. The 24×/93.3% measurement was taken when `realizedVarianceWad` WAS
        // `ringVariance`. It now returns `max(ringVariance, anchorVarianceWad)`, and the anchor leg
        // divides accumulated squared Chainlink returns by accumulated ELAPSED SECONDS while skipping
        // rounds where the anchor did not move — so widening the gap between swaps enlarges numerator
        // and denominator together instead of padding the series with zero returns. ⇒ **Stretching
        // the clock still collapses the RING; it no longer collapses σ², because `max` means the
        // suppressible leg can only ever raise the answer.** ⛔ Do NOT read that as "the vector is
        // closed" — the anchor is a floor, not a proof, and the residual named in `Core`'s own §E345
        // note is the opposite direction: the ring's permissionless writer can still INFLATE σ² and
        // widen the spread other traders pay, bounded by the ±50 bps push range.
        // LVR = σ²/8 per unit time (Milionis-Moallemi-Roughgarden-Zhang arXiv:2208.06046 eq.16: for a
        // constant-product pool the loss per unit time as a fraction of pool value is exactly σ²/8).
        // This is the EXPECTED cost of the displacement being arbitrageable over the settlement
        // window. CAP_SAFETY (=2) was a 2σ WORST-CASE multiple — a risk-aversion choice, i.e. γ under
        // another name, and the only reason a BTC swap capped near 127bps rather than its measured
        // expected cost. The /8 is constant-product geometry, derived; the window is chain physics.
        // §E59 — UNKNOWN VARIANCE MUST NOT PRICE AS ZERO VARIANCE.
        //
        // `sigmaSqWad == 0` is the "we could not measure it" sentinel, not a reading of a genuinely
        // still market. MEASURED under the original mechanism: a drain that took POOLED from 400 to
        // 0.00097 ETH — a total inventory wipe — reported variance 0.
        // ⛔ CORRECTED — THIS PARAGRAPH NAMED A MECHANISM THIS FILE ITSELF RETIRED 200 LINES BELOW,
        // AND THE TWO SENTINEL CONSUMERS THEREFORE DISAGREED ABOUT WHY ZERO HAPPENS. It read
        // *"`realizedVarianceWad` samples `observe` on a WALL-CLOCK grid … and `observe` LINEARLY
        // INTERPOLATES between stored points"*. `skewWad`'s §E213 note (`:1026`) already says that
        // story is **RETIRED**: `observe` has ONE consumer left in the tree, the TWAP price at `:74`,
        // and it never touches the variance path — `Core.realizedVarianceWad` calls
        // `OracleLib.ringVariance` DIRECTLY. The correction STRENGTHENS this guard for the same
        // reason it strengthened that one: under the interpolation story a zero could come from a
        // quiet but well-sampled ring, the one reading that would make charging the ceiling look
        // punitive; under the real mechanism (`card < 3`, `m < 2`, uninitialised/non-advancing
        // timestamps) every zero means TOO FEW DISTINCT SAMPLES and none means "measured, and calm".
        // 🔴 §E345 — AND ZERO NOW REQUIRES **BOTH** LEGS TO BE SILENT, WHICH IS A STRICTLY NARROWER
        // STATE THAN THIS COMMENT WAS WRITTEN AGAINST. `Core.realizedVarianceWad` returns
        // `max(ringVariance, anchorVarianceWad)`: the anchor leg accumulates squared CHAINLINK
        // returns into two `Flow` registers, sampled once per swap and gated on the anchor having
        // MOVED. So σ² == 0 no longer means only "the ring is thin" — it means the ring is thin AND
        // the Chainlink anchor has never been sampled. ⚠️ **THE SENTINEL'S BEHAVIOUR IS UNCHANGED AND
        // DELIBERATELY SO**: zero still means unmeasured, and unmeasured still prices at the ceiling.
        // What changed is how rare the state is and who can produce it, not what it means.
        //
        // Feeding that 0 through the formula gave `cap = 0` on ETH (which, unlike BTC, has no
        // SPLICE_FLOOR), and a zero cap means **a fully drained range charges NOTHING at maximum
        // scarcity** — the crisis case priced at free. Returning the HARD CEILING instead is the
        // conservative reading of "unknown", and it needs no new constant: MAX_WELL_SKEW already
        // exists for exactly this role. A genuinely calm market reports a SMALL NON-ZERO variance
        // and still caps low; only the unmeasured case is treated as dangerous.
        //
        // This is the third instance of one lesson (cf. E56 dead-vs-new, E59): a sentinel that
        // means "no data" must never be consumed as if it meant "none of the thing".
        // §E62 — THE HARD 3% NO LONGER CAPS THE *DERIVED* PATH; it survives ONLY as the
        // unknown-variance value above. Rationale: `σ²·confFrac/8` IS a derivation — LVR over the
        // settlement window (MMRZ eq.16), chain physics times measured volatility — so clamping it
        // at an asserted 3% could only ever make us charge LESS than the measured expected cost, and
        // it bound exactly in the high-vol regime where the skew is most needed. That clamp was
        // defensible while σ² was unreliable; it is not now that variance measures (§E59).
        // What remains of MAX_WELL_SKEW is the honest one: a ceiling for the case we CANNOT measure.
        return SoladyMath.fullMulDiv(sigmaSqWad, confFrac, 8e18) + rk.spliceFloor;
    }

    /// ⚠️ §E313 — RESTORED. Deleted by §E301 as "restoration sizing"; it is not. This is the rule-17
    /// root fix for the ROUND-TRIP EXIT ATTACK — an attacker enters as an LP and EXITS FIRST, escaping a
    /// shortfall the incumbent eats. Sharing it removes the PRIZE rather than pricing it, so the attack
    /// has nothing to extract. §E301's argument ("we never source inventory") is about VENUE restoration
    /// and says nothing about EXIT ORDERING. It was deleted for sitting in the same file and tests as
    /// `refillPlacement`, which is proximity, not a reason.
    /// @notice §UNIT-ROUNDTRIP-LIVE — PRO-RATA SHORTFALL. Decided on evidence 2026-08-16 after the
    ///         owner could not pick between this and the forella brake.
    ///         **THE MECHANISM IS THE EXIT RACE, NOT THE PATH.** An entrant buys volatile out, redeposits
    ///         as an LP, and EXITS FIRST — escaping a shortfall the incumbent then eats. MEASURED:
    ///         incumbent seeds 500 ETH and withdraws 499.2385, i.e. **15.2 bps of principal** taken.
    ///         ⛔ THE FORELLA BRAKE IS REFUTED BY ITS OWN FRAME-CHECK (§UNIT-FORELLA-FRAMECHECK: *"the
    ///         coincide-on-monotone premise is refuted"*) — a total-variation charge does NOT leave
    ///         honest monotone flow untouched, so it taxes everyone to stop one attack, and it prices
    ///         a symptom.
    ///         ⭐ SHARING THE SHORTFALL REMOVES THE PRIZE INSTEAD OF PRICING IT (rule 17: make the bad
    ///         state UNCONSTRUCTIBLE, not merely costly). With no first-out advantage the round trip
    ///         has nothing to extract, and the brake becomes unnecessary rather than tuned.
    /// @param shortfallUsd6  the whole shortfall to be shared, 6-dec USD
    /// @param exitShares     the shares this exiter is redeeming
    /// @param totalShares    total shares outstanding BEFORE this exit
    function proRataShortfall(uint shortfallUsd6, uint exitShares, uint totalShares)
        internal pure returns (uint bornUsd6)
    {
        if (totalShares == 0 || exitShares == 0 || shortfallUsd6 == 0) return 0;
        // Cap at the full shortfall: an exiter redeeming everything bears all of it, never more.
        if (exitShares >= totalShares) return shortfallUsd6;
        bornUsd6 = SoladyMath.mulDiv(shortfallUsd6, exitShares, totalShares);
    }

    /// @notice The convex inventory-skew CURVE — returns a WAD skew FRACTION
    ///         (0..MAX_WELL_SKEW), not a price. Applied as an effective-rate scalar on the
    ///         swap-OUT (drain) leg: a scarce pool hands out less volatile per unit input, so
    ///         the imbalance-causer pays a scarcity premium and the withheld input stays as
    ///         basket backing (funding the pool's ability to pay a refill). Re-admits the
    ///         benign inventory-rebalancing arber WITHOUT the toxic LVR one: the swap itself
    ///         still executes at the honest oracle through routeSwap (the manip-guard sees an
    ///         UNSKEWED price ⇒ no exemption needed) — the skew is a separate output scalar,
    ///         which is precisely what lets it exceed the range's ±50-bps ceiling in a genuine
    ///         drought (the range + in-window benign arb own the near-target regime; the skew
    ///         is a TAIL layer that only bites past what the range can express).
    ///
    ///         Inputs (all 6-dec USD except σ²), asset-agnostic:
    ///           inv    = poolVolUsd − lockedUsd      (deliverable volatile, gross-lev-excluded)
    ///           target = flowUsd    + committedUsd   (normal-flow buffer + lev demand)
    ///         The leverage claim hits scarcity on BOTH sides but with DISTINCT bases: POOLED
    ///         already carries the full 2× GROSS collateral as tokenless depth, so `inv` must
    ///         subtract `lockedUsd` (GROSS) to recover the true deliverable reservoir — subtracting
    ///         only the ~1× DEBT would leave one equity leg of phantom inventory (#6/F3). `target`
    ///         adds `committedUsd` (DEBT), the uncovered forward draw/return claim (the net-equity
    ///         leg self-heals via bounded de-lever). In the un-levered case lockedUsd==committedUsd==0.
    ///
    ///         AVELLANEDA–STOIKOV reservation skew (LINEAR, replacing the ad-hoc convex
    ///         curve): the optimal MM inventory shift is q·γ·σ²·(T−t). Here
    ///           q  = scarcity   (WAD inventory imbalance, (target−inv)/target, the A-S q)
    ///           σ² = sigmaSqWad  (WAD annualized realized variance, realizedVarianceWad)
    ///           Γ  = GAMMA_WAD  = γ·(T−t) folded into ONE coefficient (the horizon T−t is
    ///                already carried by the FLOW_DECAY EWMA smoothing of flow/scarcity).
    ///         skew = Γ·σ²·q — both σ² and q enter LINEARLY (no scarcity², no separate vol
    ///         steepening term). The flush guard (inv≥target ⇒ 0, range owns the common case)
    ///         and the MAX_WELL_SKEW hard cap are preserved.
    /// @notice §UNIT-C — THE REFILL TRIGGER, AND IT IS THE SKEW'S OWN PREDICATE (owner, 2026-08-16:
    ///         *"the threshold that fires a refill swap [is] the same threshold that triggers a skew
    ///         price — if it's an imbalance to be balanced profitably it must trigger."*)
    ///         ⭐ **NO NEW CONSTANT AND NO SECOND DEFINITION OF "IMBALANCED".** This is `skewWad`'s
    ///         own flush test, character for character (`inv1 >= target ⇒ no scarcity`), so the thing
    ///         we CHARGE for and the thing we FIX cannot drift apart. A separate threshold would be
    ///         two definitions of one condition, and the one that drifts is always the one nobody
    ///         tests.
    ///         `shortfallUsd6` is what must be sourced to clear the imbalance — the input to the
    ///         profitability half (fire when the retained premium covers the cost of sourcing).
    /// @param poolVolUsd  pre-swap deliverable inventory, 6-dec USD (`inv0`)
    /// @param flowUsd     the shed target the range is measured against (`target`)
    /// @param drainUsd6   the swap's volatile-side draw, 6-dec USD
    function refillNeeded(uint poolVolUsd, uint flowUsd, uint drainUsd6)
        internal pure returns (bool fire, uint shortfallUsd6)
    {
        if (flowUsd == 0) return (false, 0);          // no target ⇒ no scarcity to measure
        uint inv1 = drainUsd6 >= poolVolUsd ? 0 : poolVolUsd - drainUsd6;
        fire = inv1 < flowUsd;                        // IDENTICAL to skewWad's flush test
        shortfallUsd6 = fire ? flowUsd - inv1 : 0;
    }

    function skewWad(uint poolVolUsd, uint flowUsd, uint sigmaSqWad, Risk memory rk, uint drainUsd6)
        public pure returns (uint skew)
    {
        // §E68 — `lockedUsd` and `committedUsd` DELETED FROM THE SIGNATURE, not merely unused. E58
        // removed both from the arithmetic and left the parameters behind; they appeared nowhere but
        // this line and the note below, so they were dead surface costing stack at a call site that
        // is annotated stack-tight. Removing them is behaviour-neutral BY CONSTRUCTION (an unread
        // argument cannot change a pure function's output), so it does not confound the one real
        // change in this run — the `drainUsd6` size thread.
        // §E58 — BOTH LEVERAGE TERMS DELETED (owner: *"leverage shouldn't be perceived by this skew
        // at all… whether levered or not, in the range is in the range alike"*). They entered TWICE and
        // both inflated scarcity: `inv` SUBTRACTED `lockedUsd` (levered GROSS collateral — which IS
        // range depth), and `target` ADDED `committedUsd` (the leverage DEBT). Together they made the
        // range read scarcer than it is by an amount that SCALES WITH THE LEV BOOK.
        //   The skew prices the cost of SHEDDING volatile the range holds. How an LP FINANCED its
        //   participation is not a property of that inventory: it is in the range either way, and a
        //   levered position is collateralised and unwindable (`closeLev` repays debt and returns
        //   collateral), so it never consumes the range's shed capacity. Nothing about a levered LP
        //   changes how hard it is to sell the range's ETH.
        //   What remains IS the E54 derivation: scarcity is inventory against the flow we shed into.
        uint target = flowUsd;
        // §UNIT-A — RETURN THE BASE, NOT ZERO. This sat ABOVE `_maxWellSkew`, so a fresh OR idle
        // range charged NOTHING: not the kernel, not `σ²·confFrac/8`, not `SPLICE_FLOOR`. §E98
        // measured BTC's floor never applying on a fresh range; §E99 measured a 30-day-old imbalance
        // pricing at 0; and `wellSkew` read 0 at σ² = 4.09 on a violent tape, proving the base is
        // unreachable INDEPENDENT of variance.
        if (target == 0) return _maxWellSkew(sigmaSqWad, rk);
        // §E68 — THE DRAIN IS NOW SIZE-AWARE, AND THIS IS WHERE THE LEAK WAS.
        //
        // `inv` used to be read PRE-swap and the flush test used to be `inv >= target ⇒ 0`. Two
        // separate defects fell out of that, both MEASURED as present:
        //   1. SIZE-BLINDNESS. `q` was the pre-swap LEVEL, so a $1 drain and a drain-the-reservoir
        //      quoted the IDENTICAL premium. Nothing about the swap's own magnitude reached the
        //      kernel — the rate was a property of the pool alone.
        //   2. THE FLUSH HOLE, which is the worse of the two. If the range sat AT OR ABOVE target,
        //      the pre-swap test returned 0 for EVERY size, so a single trade could convert the
        //      WHOLE inventory and pay NO skew at all — it only ever paid the range's ~10 bps
        //      cushion. The premium began only on the NEXT trade, by which time the inventory was
        //      already gone. That is the "one trade converts the range for ~10 bps" leak.
        // Both die the same way: evaluate scarcity on the inventory this swap LEAVES BEHIND, and
        // charge the average rate along the path from where it started to where it ends.
        uint inv0 = poolVolUsd;                           // pre-swap deliverable inventory
        uint inv1 = drainUsd6 >= inv0 ? 0 : inv0 - drainUsd6;   // what the drain LEAVES
        // Flush now means flush AFTER the drain. A swap that ends at/above target created no
        // scarcity and is genuinely free; a swap that ENDS below it is charged for the crossing,
        // however flush the range looked before it. Size-blindness cannot survive this test.
        // §UNIT-A — THE FLUSH OWES THE BASE TOO. A well-stocked range is not an UNEXPOSED one: the
        // settlement-window loss accrues whether or not inventory is scarce, so only the DEPLETION
        // (kernel) term flushes away, never the adverse-selection floor.
        if (inv1 >= target) return _maxWellSkew(sigmaSqWad, rk);
        // §E59/§E79 — THE SENTINEL IS RESOLVED HERE, BEFORE IT REACHES THE ARITHMETIC.
        // Past this line scarcity is REAL (inv1 < target ⇒ q1 > 0). §E59 part 2 states the rule:
        // "real scarcity (q > 0) plus UNMEASURED variance ⇒ charge the ceiling", and §E79 restates
        // it after the cap→base inversion: "UNMEASURED variance must price at the CEILING… returning
        // [the base] here would re-open the free-drain hole E59 closed."
        // 🔴 IT HAD RE-OPENED. MEASURED 2026-08-16 on a $1m range with a $2m shed target: at σ²=0 the
        // ETH charge was 0 at 10%, 50% AND 90% drains, and only a 100% drain reached the ceiling
        // (via the separate `qBar == type(uint).max` pole at `:941`). BTC returned SPLICE_FLOOR
        // alone. The kernel is `Γ·σ²·qBar`, which is identically 0 when σ² is 0 NO MATTER HOW SCARCE
        // the range is — so the guard §E59 added had to live outside the product, and after the §E79
        // inversion moved `_maxWellSkew` from ceiling to base there was nothing left holding it.
        // ⚠️ WHY THIS IS NOT A CLAMP (standing rule 3 / rule 17). It does not bound a computed
        // number; it declines to run a formula on an input that carries NO INFORMATION. σ² == 0 is
        // "we could not measure it", and post-tick-removal that is UNAMBIGUOUS: `realizedVarianceWad`
        // calls `OracleLib.ringVariance` DIRECTLY, and `ringVariance` returns 0 only where the ring
        // cannot support an estimate at all — `card < 3 || n < 3` (too few slots), `m < 2` (too few
        // DISTINCT samples), and an uninitialised / non-advancing timestamp pair. Every one of those
        // means TOO FEW DISTINCT SAMPLES. None of them means "measured, and calm".
        // ⛔ CORRECTED 2026-08-16 (§E213, caught by a parallel thread). This comment first cited the
        // old story — wall-clock sampling plus `observe`'s linear interpolation manufacturing zeros.
        // That mechanism is RETIRED: `observe` has exactly ONE consumer left in the tree, the TWAP
        // price at `:74` (the note said `:80`; re-measured 2026-08-23 — a rotted coordinate inside a
        // note whose whole subject is a claim going stale), and it never touches the variance path. The correction STRENGTHENS this
        // guard rather than weakening it: under the interpolation story a zero could come from a
        // quiet but well-sampled ring, which is the one reading that would make charging the ceiling
        // look punitive. Under the real mechanism that reading does not exist.
        // So feeding it through a multiplicative kernel prices "unknown" as "none" — the sentinel
        // error §E59 named: a value meaning "no data" must never be consumed as if it meant "none of
        // the thing". Resolving it BEFORE the multiply is the root fix; bounding the product after
        // would be the clamp.
        // ⚠️ AND IT WAS REACHABLE, NOT THEORETICAL: §UNIT-B-PATIENCE MEASURED σ² AS ATTACKER-
        // STRETCHABLE — 4h spacing drove σ² 24× down and the charge 93.3% down. Suppress σ² to the
        // sentinel, then drain up to 90% of the range for free. That is the vector this closes.
        // 🔴 §E345 — THAT ROUTE TO THE SENTINEL IS NOW SHUT, AND THIS GUARD IS KEPT ANYWAY.
        // `Core.realizedVarianceWad` returns `max(ringVariance, anchorVarianceWad)`, so a drainer who
        // stretches the clock suppresses only the RING leg; the Chainlink-anchor leg accumulates
        // squared per-round returns over real elapsed seconds and `max` takes whichever is larger.
        // Reaching `sigmaSqWad == 0` now requires the ring to be thin AND the anchor never to have
        // been sampled — a fresh deployment or a dead feed, not a patient attacker.
        // ⛔ **THE GUARD DOES NOT MOVE, AND "IT IS NO LONGER REACHABLE" IS NOT A REASON TO DELETE IT
        // (standing rule 1 vs the §E88/§E59 sentinel rule).** Rule 1 removes code that CANNOT be hit;
        // this branch is hit by exactly the states the sentinel was written for, and it is the only
        // thing standing between "we have no variance estimate" and a kernel that prices no estimate
        // as no risk. The correct reading of §E345 is that the branch got RARER, not wrong: an
        // unmeasured σ² still charges the ceiling, deliberately, and that is unchanged.
        if (sigmaSqWad == 0) return UNKNOWN_VARIANCE_SKEW;
        uint q1 = (target - inv1) * 1e18 / target;        // post-swap scarcity ∈ (0, 1e18]
        uint q0 = inv0 >= target ? 0 : (target - inv0) * 1e18 / target;  // pre-swap, 0 if flush
        // §E289 — `oneMinusQ` is gone: the distance to the pole is now `KAPPA_WAD − q1` (`kMinusQ1`,
        // computed at the kernel below), because the pole's LOCATION is a parameter rather than
        // hard-coded at 1. At κ = 1e18 they are the same number.
        // DEPLETION-BARRIER skew = Γ·σ²·q / (1−q)^ρ, ρ = STABLENESS (see the constant's derivation):
        // the A-S linear premium Γσ²q amplified by the log-barrier shadow price 1/(1−q)^ρ of the last
        // inventory units. Blows up convexly as inv→0 (oneMinusQ→0), bounded by the cap below.
        // DEPLETION-BARRIER skew = Γ·σ²·q/(1−q). Written out rather than parameterised, because
        // NEITHER Γ NOR ρ WAS EVER AN INDEPENDENT DIAL (proved 2026-08-04, arithmetic unchanged):
        //   ρ (STABLENESS) was 1, so `for (i = 1; i < 1; ...)` NEVER EXECUTED — dead code, and the
        //     barrier is a SIMPLE POLE q/(1−q), which is what A&S §2.3's infinite-horizon reservation
        //     price derives anyway (exponent fixed at 1 by the CARA value function, not fitted).
        //   Γ (GAMMA_WAD) was `MAX_WELL_SKEW·1e18/SIGMA_REF` with SIGMA_REF = 1e18, i.e. Γ ≡
        //     MAX_WELL_SKEW EXACTLY. It was the cap under a second name — defined so that
        //     skew(q=1, σ²=1e18) lands on the cap, which makes it a restatement, not a choice.
        // So the whole curve has ONE number in it, the cap, and it appears twice. Three constants
        // deleted with byte-identical behaviour: SIGMA_REF, GAMMA_WAD, STABLENESS.
        // §E59 (part 2) — THE CAP FIX ALONE WAS NOT ENOUGH: σ² ZEROES THE KERNEL TOO.
        // `skew = Γ·σ²·qBar` is 0 whenever σ² is 0, no matter how scarce the range is, so flooring
        // only `_maxWellSkew` left a drained range still charging nothing (MEASURED: the fix went in,
        // `wellSkew` stayed 0 at inv/target = 0). σ² gates the curve in TWO places and both had to
        // be answered. Here: real scarcity (q > 0) plus UNMEASURED variance ⇒ charge the ceiling.
        // That is the conservative reading of "unknown" and it is consistent with the cap's, so the
        // two consumers of the sentinel can no longer disagree.
        // §E79: with the inversion, `_maxWellSkew(0)` is now a FLOOR of ~0 — returning it here would
        // re-open the free-drain hole E59 closed. UNMEASURED variance must price at the CEILING,
        // which is the conservative reading E59 intended and now says so in the right units.
        // §E68 — THE KERNEL IS NOW THE INTEGRAL OF THE SAME POLE, NOT A POINT SAMPLE OF IT.
        //
        // The curve is UNCHANGED: still `q/(1−q)`, still A&S's simple pole, still one constant.
        // What changed is WHERE it is sampled. Charging `rate(q0)` on every unit of a swap that
        // itself moves q0→q1 misprices in BOTH directions at once:
        //   • the last units of a big drain belong near the pole and were billed at the cheap
        //     starting rate ⇒ THE LARGEST IMBALANCER WAS UNDERCHARGED, and one large drain was
        //     strictly cheaper than the same volume split across txs (an atomicity arbitrage);
        //   • every later swap then faced a rate set by an imbalance it did not cause ⇒ INNOCENT
        //     FLOW WAS OVERCHARGED, and the deterrent landed on the wrong party.
        // The average rate along the swap's OWN displacement fixes both, because each unit is
        // billed at the scarcity IT sees:
        //     (1/Δ)·∫[q0→q1] q/(1−q) dq = [ ln((1−q0)/(1−q1)) − Δ ] / Δ,   Δ = q1 − q0
        // using ∫q/(1−q)dq = −ln(1−q) − q. The bracket is ≥ 0 because the integrand is ≥ 0 on
        // [0,1), so the subtraction cannot underflow on exact math; it is saturated anyway to keep
        // a rounding artifact from wrapping into an enormous premium.
        // §E289 — THE POLE LOCATION IS NOW THE PARAMETER `κ` (`KAPPA_WAD`), A–S's ω. The kernel is
        //     q/(1 − q/κ) = κ·q/(κ − q),   whose integral keeps §E68's shape:
        //     qBar(q0,q1) = κ·[ κ·ln((κ−q0)/(κ−q1)) − Δ ] / Δ,   using ∫q/(κ−q)dq = (κ−q) − κ·ln(κ−q)
        // 🔴 AT κ = 1e18 EVERY LINE BELOW IS THE ORIGINAL: `fullMulDiv(κ, x, 1e18) == x`, so the two
        // outer κ factors vanish and `κ − q` is `1e18 − q`. **This is a refactor, not a repricing** —
        // it installs the dial that lets the singularity move OFF the reachable range later.
        uint kMinusQ1 = KAPPA_WAD - q1;                   // κ > q1 for κ > 1e18 ⇒ never zero
        uint qBar;
        if (kMinusQ1 == 0) {
            // REACHABLE ONLY AT κ = 1e18, where it is `q1 == 1e18` ⇔ `inv1 == 0` — today's pole.
            // ⚠️ For any κ > 1e18 this branch is DEAD (q1 ≤ 1e18 < κ), and rule 1 then deletes it
            // along with `SKEW_UNFILLABLE` and the producers' decline. **Delete them in the commit
            // that RAISES κ, not before** — removing them while κ = 1e18 would drop the only brake.
            qBar = type(uint).max;                        // ends at inv=0 ⇒ pole → ∞ ⇒ pinned to the cap
        } else if (q1 == q0) {
            // Δ = 0. Either a zero-size READ (the Aux/MM signal, which wants the instantaneous
            // rate) or a drain too small to move q. The integral's limit as Δ→0 IS the point rate,
            // so this branch is the formula's own limit, not a special case bolted beside it.
            qBar = SoladyMath.fullMulDiv(
                SoladyMath.fullMulDiv(KAPPA_WAD, q0, 1e18), 1e18, KAPPA_WAD - q0);
        } else {
            uint d = q1 - q0;
            // ln(u0/u1) in WAD. u0 > u1 > 0 here, so the ratio exceeds 1e18 and the log is positive.
            uint lnTerm = uint(SoladyMath.lnWad(int(
                SoladyMath.fullMulDiv(KAPPA_WAD - q0, 1e18, kMinusQ1))));
            lnTerm = SoladyMath.fullMulDiv(KAPPA_WAD, lnTerm, 1e18);   // the inner κ·ln(·)
            qBar = lnTerm > d
                ? SoladyMath.fullMulDiv(
                    SoladyMath.fullMulDiv(KAPPA_WAD, lnTerm - d, 1e18), 1e18, d)   // the outer κ·
                : 0;
        }
        // §E104 — CLAMP THE KERNEL *BEFORE* THE BASE IS ADDED. E89 made the base additive and left
        // the pole sentinel as `type(uint).max`, so a drain that EMPTIES the range produced
        // `type(uint).max + base` and PANICKED (`0x11`) — a full drain REVERTED instead of charging
        // the 3% ceiling, which is the exact case the ceiling exists for. The suite never caught it
        // because it never drains a range to zero: 4,308 green, a pinned controlled comparison,
        // `--sizes` and `check-client-abis` all passed over an UNREACHED state.
        //   The pole means "charge the maximum", so resolve it to `MAX_WELL_SKEW` directly rather
        // than to a sentinel that must survive arithmetic. The finite branch is clamped too: near
        // the pole `qBar` is large and the product can exceed the ceiling on its own, which would
        // overflow the same way once the base is summed.
        // §E275 — THE POLE RETURNS DATA. IT DOES NOT REVERT, AND THAT DISTINCTION IS LOAD-BEARING.
        // ⛔ BOTH OF MY EARLIER ATTEMPTS WERE MEASURED AND BOTH FAILED, IN OPPOSITE DIRECTIONS:
        //   1. `return type(uint).max` with no producer guard reproduced §E104's panic one frame out
        //      — `sellSkew` hands this to `_composePrice` as `kernel`, which does `kernel + risk`,
        //      so it overflowed on the ADD instead of on the base (`panic 0x11`,
        //      `testMatrix_S5_UnfillableSwapMovesPriceForFree`).
        //   2. reverting HERE broke the REFILL TRIGGER (§E275, since removed): `skewWad` is read
        //      DIRECTLY as an observation by `test_TriggerFiresExactlyWhenTheSkewLeavesFlush`,
        //      `test_E104_ConstantSensitivity` and `test_E105_BoundarySweep`. A reverting read cannot
        //      report that the range is empty — **at exactly the moment the refill exists for.** Same
        //      principle `Core.sol` states for the observation source: THE READ MUST NOT BE ABLE TO
        //      HALT THE RANGE.
        // ⇒ `skewWad` is the MEASUREMENT and says "unfillable" by returning the sentinel; the
        // PRODUCERS (`wellSkew`/`sellSkew`) are the fill path and decline before touching it. The
        // early return is what makes the sentinel safe: nothing is added to it here.
        if (qBar == type(uint).max) return type(uint).max;
        skew = SoladyMath.fullMulDiv(SoladyMath.fullMulDiv(GAMMA_WAD, sigmaSqWad, 1e18), qBar, 1e18);
        // §E79 — CAP-TO-BASE INVERSION. `_maxWellSkew` = σ²·confFrac/8 is an EXPECTED-LOSS RATE over
        // the settlement window. Using a rate as a price CEILING was a category error, and it was
        // MEASURED crushing the whole curve: at a plausible σ²=1e16 the skew came out 4.75e-10, i.e.
        // ~0.0000005 bps (E72). **That is not a small spread — it is quoting Chainlink MID.** An AMM
        // filling at oracle with no spread is a FREE OPTION to anyone whose information is fresher
        // than the oracle (loss-versus-rebalancing): the informed trader picks the LP off on every
        // oracle lag. THE SKEW IS THE MARKET-MAKER SPREAD, and a spread of zero is the exposure.
        //   So the expected loss becomes the FLOOR — the base charge under EVERY trade, which is what
        //   an expected loss over the settlement window actually is — and the scarcity premium is
        //   free to rise above it, bounded by the ABSOLUTE ceiling `MAX_WELL_SKEW` (3%) that was
        //   always the real safety limit. The ceiling is UNCHANGED, so the maximum haircut anyone can
        //   suffer is exactly what it was; only the floor moved off zero.
        // §E89 — THE BASE **ADDS**, IT DOES NOT FLOOR. `max(size, base)` was still wrong: it lets the
        // base VANISH into the size term at high scarcity, so a big drain pays the depletion charge
        // and NOTHING for the settlement-window loss. But σ²·T/8 is incurred REGARDLESS OF SIZE — it
        // is what the position costs us over the window no matter who trades or how much. Depletion
        // risk and adverse selection are DIFFERENT costs and both are real, so they SUM. `max` under-
        // charges by exactly `min(sizeTerm, base)`, which is largest in the regime that matters most.
        // §UNIT-B-PATIENCE STEP 2 — THE KERNEL CARRIES THE VECTOR, NOT THE BASE. Correcting only the
        // base's window was MEASURED to do nothing (93.28% vs 93.27%), because on ETH the base is
        // ~0.002% of the charge: at σ²=1.19e12 it is 5.65e4 against a wellSkew of 2.7e9. The kernel
        // `Γ·σ²·qBar` is LINEAR IN σ² AND HAS NO HORIZON TERM, so a σ² collapsed by clock-stretching
        // takes the whole charge down with it.
        //   A-S's reservation premium is `q·γ·σ²·(T−t)` — it HAS a horizon. Ours folded a constant
        // horizon into Γ, which is exactly what makes it stretchable. Scaling by how much longer than
        // the nominal window the range actually carried the imbalance restores σ²·T, the quantity LVR
        // is really made of (δ²/8 for a displacement δ, independent of elapsed time).
        //   ⛔ SCALING THE KERNEL BY `idle/nominal` WAS TRIED AND MEASURED, AND IT IS WRONG AS
        // CALIBRATED — DO NOT RE-ADD IT WITHOUT SETTLING Γ's HORIZON FIRST. It DOES close the vector
        // (chopper advantage → 0 bps at every delay), but against `nominalSecs = 12` it repriced
        // ORDINARY same-block chopped flow 97× (28,829 → 2,802,810 usd6). 12s is the SETTLEMENT
        // window; it is not the inventory-holding horizon Γ folded in, and any real gap dwarfs it.
        // The principle is right and the constant is unknown, which makes this a calibration
        // question (§UNIT-B-PATIENCE-STEP2), not a patch.
        skew += _maxWellSkew(sigmaSqWad, rk);
        // §E216 — DEPLETION IS AN INVENTORY FACT, NOT A VOLATILITY RISK. Additive, σ²-free, and
        // keyed on `inv0` rather than `q`. Every clause there was learned by a failed attempt.
        //
        // WHY. The kernel is `Γ·σ²·qBar`: ONE product fusing TWO different costs, so σ²→0 kills
        // both. Adverse selection IS ∝ σ² (the range is picked off in proportion to how far price
        // travels before repair) and stays there. Depletion is not: at `inv → 0` you cannot serve,
        // you must SOURCE, and you pay settlement — true on the flattest tape there is.
        // MEASURED: the patience instrument logs σ² = **1** — real data, so the `== 0` sentinel does
        // NOT fire — with `wellSkew` = 0 at every slice. A free drain needing no patience, only calm.
        //
        // ⛔ ATTEMPT 1 FOLDED THIS INTO THE KERNEL'S RATE (`Γ·σ² + rate`, all × `qBar`) AND WAS
        // REFUTED. `qBar` is scarcity against the TARGET, so a FRESH, UNFUNDED range — `inv0 = 0`
        // against a positive target — sits at the pole and got charged the CEILING: bootstrap priced
        // out of existence. It could not tell DRAINED from NEVER FUNDED, and only the first is a
        // depletion cost — nobody depleted a range that was never filled.
        // ⇒ SO THE DISCRIMINATOR IS `inv0`, NOT `q`: charge the FALL FROM WHAT WAS ACTUALLY THERE.
        //   `inv0 == 0` ⇒ no fall ⇒ no charge ⇒ **bootstrap untouched BY CONSTRUCTION**, not by a
        //   special case. And ADDITIVE + bounded by `DEPLETION_RATE_WAD`, so unlike attempt 1 it
        //   cannot blow up at the pole.
        // ⚠️ THE `sigmaSqWad == 0` SENTINEL STAYS AND IS NOT REDUNDANT: `== 0` means NO DATA (charge
        // the ceiling, conservative); this handles data that is real and tiny. Different inputs.
        if (inv0 != 0 && inv1 < inv0) {
            // `SoladyMath`, not `FullMath` (which left with core-core) and not OZ `Math`: solady is
            // this file's convention — 32 call sites to OZ's 2.
            skew += SoladyMath.mulDiv(DEPLETION_RATE_WAD, inv0 - inv1, inv0);
        }
    }

    /// @notice The live well skew (WAD) for a pool — gathers deliverable inventory (at
    ///         the honest oracle `base`), the leverage claim, the flow EWMA and realized
    ///         variance, and runs `skewWad`. Used BOTH as the applied swap-out rate scalar AND
    ///         as the readable on-chain scarcity signal for the MMs + the LP dashboard.
    ///         `base` = getTWAPforAsset(asset) (USD18 per 1e18 raw; the WBTC anchor lifted
    ///         ×1e10 — reference-gettwapforasset-scale + BtcLevManager:161).
    /// @dev    RESERVOIR REFILL DESIGN (the "pump") -- how the native-BTC reservoir
    ///         refills, and why the skew is all that is needed:
    ///         1. PRIMARY REFILL -- LPs stake BTC ({Vault-requestDeposit}), pulled in when the
    ///            pool is scarce because scarcity => more fee capture. This mechanism already
    ///            exists; the reservoir self-refills through ordinary LP entry -- no bespoke
    ///            machinery, no keeper, no RFQ, no external-MM solicitation.
    ///         2. FAST TOP-UP -- LP entry is the ONLY refill path. (STALE DOC REMOVED 2026-07-31:
    ///            this bullet described a swap-IN skew BONUS "funded by and CLAMPED to the retained
    ///            drain premium" -- that design was REJECTED and `payRefillBonus` DELETED on
    ///            2026-07-22, as creditSwapInBody's own comment states. There is NO such clamp and no
    ///            bonus. Paying a swapper a bonus is precisely what the removal stopped -- do NOT
    ///            rebuild it. §E132 CORRECTION (2026-08-06): this bullet used to add "`skewPremium*`
    ///            has NO consumer beyond the counters + theta EWMA". That was true when written on
    ///            2026-07-31 and was FALSIFIED by §E5, which added `ISkewSink.creditSkewPremium` --
    ///            the premium now REACHES LPs via `V4.USD_FEES`, asserted by
    ///            testGrindRemoval_DrainPaysRetainedSkewPremium. The premium is NOT inert; reading
    ///            it as inert is exactly the wrong turn §E107 took.)
    ///         So the skew's whole job is to PRICE the scarcity -- making staking/refilling
    ///         attractive exactly when the reservoir needs it (the fee side already reflects
    ///         this) and the swap-in top-up lucrative. The refill is a PERMISSIONLESS response
    ///         to a public on-chain price: the skew is our reservation price, captured by
    ///         whoever refills first (a gas race), never an operator-tuned or bid mechanism.
    /// @dev The conversion prologue BOTH skews share: pool inventory and GROSS levered
    ///      collateral, each in 6-dec USD at the SAME `base/1e30` scale (one price, one unit).
    ///      `addedTok` is the not-yet-settled input a SELL adds to inventory (0 for a drain).
    ///      Extracted because the two skews duplicated it verbatim — they diverge only in how
    ///      they FEED `skewWad` (wellSkew passes these directly; sellSkew mirrors `inv` about
    ///      target first), so the prologue is the real duplication and the divergence is real
    ///      semantics that must NOT be flattened into a flag.
    /// §E68 — `lockedUsd` AND ITS `levGrossNative` CALL DELETED. E58 removed the leverage terms from
    /// the arithmetic but left the plumbing that fed them: this helper still fetched
    /// `levGrossNative(isBTC)` and BOTH callers dropped the result, so an external call ran on EVERY
    /// swap, on BOTH legs, purely to be discarded. `wellSkew` additionally called `levClaimUsd6` to
    /// fill a parameter nothing read. That is dead code (rule 1) and wasted money-path gas, but the
    /// worst part is the misdirection: a helper that visibly gathers leverage state, feeding a public
    /// function with two leverage parameters, reads as though leverage MATTERS here — the exact
    /// belief E58 exists to kill. Leaving the plumbing in place contradicted the fix at the one spot
    /// a reader would look to confirm it.
    function _skewBasis(address core, uint base, uint addedTok)
        private view returns (uint poolVolUsd)
    {
        poolVolUsd = SoladyMath.fullMulDiv(
            (ICore(core).POOLED()) + addedTok,
            base, 1e30);
    }

    /// @dev §E53 — THE SHARED-SCARCITY AMPLIFIER. Every input to the skews is `isBTC`-scoped, yet
    ///      BOTH ranges draw on ONE basket: `committedUsd18() <= haircutTvl` is the single bound they
    ///      compete for. So two SIMULTANEOUS drains stress the same backing and neither skew can see
    ///      the other — and ETH/BTC correlate hardest on exactly the days that matter, which makes
    ///      this the expected shape of a bad day rather than a tail case.
    ///
    ///      The SIZING layer already got this right — `sizeBySurplus` nets both pools so "neither can
    ///      claim the same surplus twice" — and only the PRICING layer was blind. This closes that.
    ///
    ///      ⚠️ CONSTRAINT THAT PICKS THE FORM: the natural measure is utilisation, `committed/TVL`.
    ///      **TVL is NOT reachable here** — `Aux.get_deposits`, `checkBacking` and `tryCheckBacking`
    ///      are all NON-VIEW, and these skews are `view`. So the term is RELATIVE (how much of the
    ///      shared commitment belongs to the OTHER range) rather than absolute, built only from
    ///      `committedUsd18()` and `rangeEquityUsd18()`, both of which are view.
    ///
    ///      Returns a WAD multiplier in [1e18, 2e18): 1× when this range is the only claimant, →2× as
    ///      the other range's equity dominates the shared bound. Bounded by construction — it can
    ///      never invent scarcity, only reflect that the shared backing is already spoken for.

    /// @dev §E89b — THE ONE PLACE THE PRICE IS COMPOSED, for BOTH legs. `_maxWellSkew` is two unlike
    ///      things summed, and only one of them rides E53's shared-scarcity amplifier:
    ///        • `σ²·confFrac/8` — capital AT RISK while locked through settlement. When the other range
    ///          has claimed the shared backing the SAME exposure is dearer to carry, exactly as the
    ///          shed kernel is, so it IS amplified.
    ///        • `SPLICE_FLOOR` — a FIXED on-chain splice FEE. An external price does not rise because
    ///          our other range is busy, so it is NEVER amplified.
    ///      Its own frame for two reasons: it frees stack in the tight `sellSkew` (no `via_ir`), and
    ///      having ONE composer means the two legs cannot drift apart again — they already did once
    ///      (E68b: the sell leg priced at the endpoint for a whole session after the drain leg was
    ///      fixed). Callers pass the bare kernel; everything else is decided here.
    /// §E275 — **THE DECLINE LIVES AT THE PRODUCER, WHICH IS WHY IT IS ONE ROUTINE AND NOT THREE
    /// GUARDS** (standing rule 17). Deleting the cap exposed THREE consumers that apply the rate by
    /// checked arithmetic — `retainSkewPremium` (`amount -= premium`), `Core.sol:1241`
    /// (`out -= out·skew/1e18`) and `_applySkew:140` (`base - base·skew/1e18`) — so
    /// §E273's "one choke point" was WRONG (verified by enumeration, 2026-08-21). Guarding each
    /// consumer would be three bounds for one class of thing; refusing to PRODUCE an unfillable rate
    /// is the state fix, and every consumer inherits it including any added later.
    /// ⚠️ Reverting here means a QUOTE read can revert (`Aux:690`, `SwapLib:113/127`). That is
    /// intended: at this scarcity there is no fillable price, and a solver that asked for one needs
    /// to route that leg elsewhere rather than receive a number it cannot trade on.
    /// §E300 — **THE SKEW PATH NEVER REVERTS** (owner, 2026-08-22: *"dont revert at the pole"*, and
    /// *"any rfq engine [must] smoothly work with us and not fail on the multihop"*).
    /// §E275 declined past 100%; §E298 showed that was the wrong primitive — a revert hands the
    /// counterparty NOTHING, so there is no remainder for a solver to route, and it can fail their
    /// whole multi-hop bundle rather than just our leg. **We would be most hostile to route through
    /// exactly when we are scarce.**
    /// ⇒ A rate haircut cannot exceed 100% — that is the DEFINITION of taking a fraction of an amount,
    /// not a policy ceiling — so the value is bounded there and the trade proceeds. At the bound the
    /// premium equals the input, `out` is 0, and the EXISTING guard in `_finishSwap`
    /// (`if (max == 0 || max < r.minOut) revert SlippageMaxS()`) rolls back **to a clean refund** —
    /// the right layer, an error that already exists, and no new failure mode for a router.
    /// ⚠️ NOT the deleted `MAX_WELL_SKEW`: that was a POLICY cap at 3% that suppressed 51% of the
    /// integral's premium (§E286-integral) and pinned the curve flat from q≈0.6 (§E274). This binds
    /// only where the arithmetic stops meaning anything — 33× higher.
    function _boundToFullHaircut(uint skew) private pure returns (uint) {
        return skew > SKEW_UNFILLABLE ? SKEW_UNFILLABLE : skew;
    }

    /// §E295 — **THE ONE AMPLIFIER BOTH LEGS USE.** `wellSkew`'s tail and `_composePrice` computed the
    /// same expression — `(X − splice)·scarcity + splice`, then decline — differing only in what `X`
    /// was: `wellSkew` passed `raw` (which `skewWad` had already summed) while `_composePrice` re-added
    /// the base itself. Substituting shows the same algebra, so it is written ONCE here.
    /// 🔴 **THE DUPLICATION WAS THE DRIFT RISK, AND THIS FILE ALREADY RECORDED IT HAPPENING:** §E89b —
    /// *"written here so both legs compose their price identically; **they had already drifted apart
    /// once (E68b)**."* Two copies of one formula is how that recurs.
    /// ⚠️ **THE `> splice` GUARD IS LOAD-BEARING, WHICH IS WHY THE FLOOR IS A PARAMETER.** `skewWad`
    /// has early returns (`target == 0`, the flush branch) that never add the base, leaving `X == 0`;
    /// assuming `X >= splice` underflowed on a BALANCED range — the common case — and cost **782
    /// failures**. It is a no-op on the sell leg (whose `X` always contains `_maxWellSkew`, which
    /// includes the floor) and essential on the drain leg.
    /// ⚠️ **DEPLETION STAYS DRAIN-ONLY.** It reaches this frame only inside `wellSkew`'s `raw`, because
    /// `skewWad` adds it there; the sell leg never forms it. Selling INTO the range cannot deplete it,
    /// so a shared AMPLIFIER must not be read as a shared KERNEL.
    function _amplify(address core, uint preAmp, uint splice) private view returns (uint) {
        // §E275 — the sentinel must not reach checked arithmetic; see the pole comment in `skewWad`.
        preAmp = _boundToFullHaircut(preAmp);
        uint out = preAmp > splice
            ? SoladyMath.fullMulDiv(preAmp - splice, _sharedScarcityWad(core), 1e18) + splice
            : preAmp;
        // §E79: no re-cap after the amplifier. The expected-loss FLOOR was applied inside `skewWad`,
        // and re-clamping to it here would undo the inversion by pulling an amplified premium back
        // down to the base charge.
        return _boundToFullHaircut(out);   // uncapped; declined at the producer
    }

    function _composePrice(address core, uint kernel, uint sigmaSqWad)
        private view returns (uint) {
        // §E275 — DECLINE BEFORE THE ARITHMETIC, NOT AFTER. `kernel` may carry `skewWad`'s pole
        // sentinel, and `kernel + risk` below is a checked ADD: reaching it panics 0x11 with no
        // name, four frames down (MEASURED — see the pole comment in `skewWad`). The exit guard
        // cannot help, because the overflow happens before any value reaches it.
        // §E275 — DECLINE BEFORE THE ADD BELOW, not only inside `_amplify`. `kernel` may carry
        // `skewWad`'s pole sentinel, and `kernel + base` is a checked ADD: reaching it panics 0x11
        // with no name. `_amplify` declines too, but by then the overflow has already happened.
        kernel = _boundToFullHaircut(kernel);
        // §ISBTC-SPLIT: derived HERE, not threaded in. Dropping the parameter CUTS a live value from
        // two stack-tight call sites rather than adding one; `sellSkew` does not compile otherwise.
        // §UNIT-B-PATIENCE: the exposure clock is read here rather than threaded in — this frame
        // exists to RELIEVE stack pressure (no via_ir), so a fifth parameter would work against it.
        Risk memory rk = _risk(core);
        // §E295 — the sell leg carries the kernel ALONE, so the base is added here; the drain leg's
        // `raw` already contains it. **That difference is the ONLY thing that kept these two apart.**
        return _amplify(core, kernel + _maxWellSkew(sigmaSqWad, rk), rk.spliceFloor);
    }

    function _sharedScarcityWad(address core) private view returns (uint) {
        uint both = ICore(core).committedUsd18();
        if (both == 0) return 1e18;
        // §ISBTC-SPLIT — THE TERNARY WAS THE FUSED `Core` DECIDING WHICH HALF WAS "MINE". It read
        // `isBTC ? both - btc : btc` because ONE contract held BOTH ranges and `rangeEquityUsd18()`
        // named the BTC one either way. Under instances that question does not arise:
        // `rangeEquityUsd18()` IS this instance's own equity, so the other side is the remainder,
        // unconditionally. Same denominator (`committedUsd18`) as the solvency bound, by
        // subtraction — computing it independently is how two views of one quantity drift apart.
        uint mine = ICore(core).rangeEquityUsd18();
        uint other = both > mine ? both - mine : 0;
        return 1e18 + SoladyMath.fullMulDiv(other, 1e18, both);
    }

    /// §E300 — **THE LARGEST DRAIN WHOSE RATE IS STILL FILLABLE. CLOSED FORM, NO SEARCH.**
    /// An RFQ engine must route through us without its multi-hop failing on our leg. Pricing the
    /// REQUESTED size drives `q → 1` and yields a rate no trade can carry; pricing what we can SERVE
    /// yields a steep but usable quote, and `routeSwap`'s inventory bound plus `_refundExcess` (#105)
    /// hand back the rest. **That remainder is what a solver routes elsewhere — a revert gives them
    /// nothing (§E298).**
    ///     point rate `Γ·σ²·q/(1−q)` = LIMIT ⇒ `R = LIMIT/(Γ·σ²)`, `q* = R/(1+R)`, `inv1* = target/(1+R)`
    /// **VERIFIED against §E274's independent measurements:** Γ=3e16, σ²=1e18 ⇒ q*=0.9709 (measured
    /// 0.97087); σ²=4e18 ⇒ q*=0.8929 (measured 0.89286).
    /// ⚠️ **CONSERVATIVE FOR A SIZED DRAIN:** the integral's average over `[q0,q1]` never exceeds its
    /// endpoint rate, so bounding on the endpoint serves slightly LESS than the curve allows. It errs
    /// toward filling less, never toward an unfillable quote.
    /// ⚠️ **NOT A CLAMP ON A PRICE (rule 3):** it bounds the QUANTITY we quote for and leaves the curve
    /// free. The alternative is asking the curve to price a delivery that cannot happen.
    function _fillableDrain(uint inv0, uint target, uint sigmaSqWad, uint wanted)
        private pure returns (uint) {
        // Both branches return a finished skew without reaching the pole: σ²==0 gives
        // UNKNOWN_VARIANCE_SKEW, target==0 gives the base. Nothing to bound.
        if (sigmaSqWad == 0 || target == 0) return wanted;
        uint gs = SoladyMath.fullMulDiv(GAMMA_WAD, sigmaSqWad, 1e18);       // Γ·σ²
        if (gs == 0) return wanted;                                         // σ² too small to bind
        uint r = SoladyMath.fullMulDiv(SKEW_UNFILLABLE, 1e18, gs);          // R, in WAD
        uint invFloor = SoladyMath.fullMulDiv(target, 1e18, 1e18 + r);      // target/(1+R)
        // At or below the floor the range cannot serve at ANY size: pass `wanted` through, let the pole
        // report itself, and `_boundToFullHaircut` makes it a 100% haircut ⇒ `out` 0 ⇒ clean refund.
        if (inv0 <= invFloor) return wanted;
        uint maxDrain = inv0 - invFloor;
        return wanted > maxDrain ? maxDrain : wanted;
    }

    /// @param drainUsd6 The volatile-OUT this swap is about to take, in 6-dec USD — the SAME unit
    ///        `_skewBasis` returns, which is why both call sites can pass their existing
    ///        buy-driving amount unconverted. **Pass 0 for a read-only quote**: that is the Δ→0
    ///        limit and yields the instantaneous rate, which is what the MM/dashboard signal wants.
    ///        §E68: before this parameter existed the drain leg was size-BLIND while the sell leg
    ///        already took `addedTok` — backwards, since the drain is the side bounded by physical
    ///        deliverability. The two legs are now symmetric in size-awareness.
    function wellSkew(address core, uint base, uint drainUsd6)
        public view returns (uint)
    {
        // §ISBTC-SPLIT — identity comes FROM THE INSTANCE, not from a caller's flag. The remaining
        // uses below are REAL per-asset facts (BTC's confirmation window and on-chain splice fee),
        // which is an argument for the instance knowing what it is, not for threading a boolean.
        Risk memory rk = _risk(core);
        uint poolVolUsd = _skewBasis(core, base, 0);
        // UNIFORM sats/wei → 6-dec USD: `poolVol · base / 1e30`. Authoritative (NOT
        // BasketLib.convert, which now uses the SAME flat scale (the /1e8 variant over-valued
        // 8-dec BTC by 1e10 and was removed) —
        // the WBTC ×1e10 price-lift already closes the 8↔18-dec gap, so a flat /1e30 is
        // correct for BOTH pools and keeps poolVolUsd in the same 6-dec unit as flow + lev.

        // lockedUsd = GROSS levered collateral, converted with the SAME base/1e30 scale as poolVol
        // (one price, one unit) — the locked-inventory basis for `inv` (#6/F3). committedUsd = DEBT.

        // §E300 — price what we can SERVE, not what was asked for. The swap path bounds the fill to
        // inventory ~20 lines after this call (`routeSwap` → `consumed`) and refunds the remainder
        // (`_refundExcess`), so an oversized request is a PARTIAL FILL by design, not a refusal.
        uint target = ICore(core).flowEwmaUsd();
        uint sigmaSq = ICore(core).realizedVarianceWad();
        uint raw = skewWad(
            poolVolUsd, target, sigmaSq, rk,
            _fillableDrain(poolVolUsd, target, sigmaSq, drainUsd6));
        // §E295 — the decline that stood here is now `_amplify`'s first statement, and nothing
        // between here and the call touches `raw`. One guard, at the frame that does the arithmetic.
        // §E53: amplify by how much of the SHARED bound the other range already holds, then re-cap —
        // the amplifier must never lift the skew past the same ceiling the raw curve obeys.
        // §E89b — THE AMPLIFIER SCALES RISK, NOT FEES. E89 made the base additive, which silently put
        // it INSIDE the amplifier (while it was a CEILING applied after, that was impossible). The
        // right split is not "kernel vs base" but RISK vs FEE, because `_maxWellSkew` is two unlike
        // things added together:
        //   • `σ²·confFrac/8` — capital AT RISK while locked through settlement. E53's amplifier says
        //     the other range has already claimed the shared backing, so the SAME dollar of exposure
        //     is dearer to carry. That applies to this term exactly as it does to the shed kernel,
        //     so it IS amplified. (I first claimed it should not be; that was wrong.)
        //   • `SPLICE_FLOOR` — a FIXED on-chain splice FEE. An external price does not rise because
        //     our other range is busy, so it is NEVER amplified.
        //   ⚠️ `raw >= splice` is NOT guaranteed: `skewWad` has EARLY RETURNS (`target == 0`, and the
        // FLUSH branch `inv1 >= target`) that never add the base, leaving `raw == 0`. Assuming
        // otherwise underflowed on a BALANCED range — the common case — and cost 782 failures.
        // §E295 — ONE composer, both legs. `raw` already carries kernel + base + depletion from
        // `skewWad`, so it IS the pre-amplifier value; the sell leg sums its own inside
        // `_composePrice`. The `> splice` guard and both declines now live in `_amplify`.
        return _amplify(core, raw, rk.spliceFloor);
    }

    /// @notice SYMMETRIC A-S skew for a volatile-IN SELL (the self-funded short's
    ///         range-leg shed). Where `wellSkew` prices the SCARCE side (volatile-OUT drain,
    ///         inv<target), this prices the ABUNDANT side: a sell that pushes the pool's
    ///         volatile inventory PAST target grows the pool's inventory risk, so A-S skews
    ///         the reservation price AGAINST it (`skew = Γ·σ²·q` with q = overshoot). A sell
    ///         that REFILLS a scarce/near-target reservoir REDUCES imbalance and is EXEMPT
    ///         (skew 0). Both are the SAME A-S kernel: it REFLECTS the post-add inventory
    ///         about the neutral `target` (q ↦ 2·target−q) and calls `skewWad`, whose
    ///         scarce-side formula then prices the overshoot and whose flush guard
    ///         (mirror ≥ target ⇒ 0) auto-exempts refills. `addedTok` = the volatile just
    ///         deposited (POOLED not yet bumped — the swap settles in _finishSwap), added so
    ///         the sell is judged on inv AFTER its own contribution (a pool sitting at target
    ///         would otherwise never charge any sell, however large).
    /// @dev PUBLIC so the imbalance charge is QUOTABLE BEFORE settlement, matching `wellSkew`. Under the
    ///      intent design (#28) the swapper is priced for the imbalance THEY create at quote time —
    ///      pre-committed, not discovered by a curve — so both directions must be readable from
    ///      outside. `wellSkew` (the drain side) already was; this is the fill side, and it being
    ///      `internal` was the only reason a quote could price one direction and not the other.
    ///      ⚠️ Still a VIEW over live `Core` state, so a quote is only as fresh as the block it was
    ///      taken in. Whatever binds a quote to a settlement must carry its own staleness bound.
    function sellSkew(address core, uint base, uint addedTok)
        public view returns (uint)
    {
        // §E58: `target` is FLOW alone — the leverage DEBT is not a constraint on shedding (see
        // skewWad's note). One term, one meaning.
        uint flow = ICore(core).flowEwmaUsd();
        uint target = flow;
        if (target == 0) return 0;
        // inv = poolVolUsd − GROSS locked inventory (same base/1e30 scale as poolVol, #6/F3). Scope the two
        // transient conversion locals so they free their stack slots before the skewWad call (no via_ir).
        uint inv;
        {
            uint poolVolUsd = _skewBasis(core, base, addedTok);
            inv = poolVolUsd;                                 // §E58: levered depth IS range depth
        }
        // A-S inventory-sign flip: reflect inv about target. inv≤target (refill) ⇒
        // mirror≥target ⇒ skewWad flush ⇒ 0 (EXEMPT); inv>target (inventory-increasing
        // sell) ⇒ mirror<target ⇒ skewWad prices (inv−target)/target; inv>2·target
        // (extreme surplus) ⇒ mirror 0 ⇒ capped. Re-passed so skewWad's inner inv == mirror
        // (lockedUsd=committed, poolVolUsd=committed+mirror), target=flow+committed unchanged.
        // §E54 — THE ABUNDANT SIDE IS LINEAR. NO POLE, AND NO MIRROR.
        //
        // This used to reflect `inv` about `target` (`mirror = 2·target − inv`) purely to reuse
        // `skewWad`. Reuse was the goal; the SINGULARITY came along with it. `skewWad`'s kernel is
        // `Γσ²·q/(1−q)`, and that simple pole is A&S's infinite-horizon reservation price for the
        // SCARCE side — it blows up because you can RUN OUT of inventory and the last unit is
        // priceless. On the ABUNDANT side there is no such wall: YOU CANNOT RUN OUT OF SURPLUS.
        // Mirroring imported a barrier with no referent, so an ordinary sell into a heavy pool was
        // charged on a convex curve derived from a constraint it can never hit.
        //
        // What is left is the linear A-S term the pole was multiplying: `Γσ²·q`, with q the
        // OVERSHOOT as a fraction of target — and `target = flow + committed`, so the denominator is
        // FLOW. That is the derived basis (E54): the only real cost of taking volatile we did not
        // want is that we must SHED it, shedding happens INTO FLOW, and the holding time is q/flow.
        // A refill (inv ≤ target) stays exempt, exactly as the mirror's flush branch made it.
        uint over = inv > target ? inv - target : 0;
        if (over == 0) return 0;                          // refill / at-target ⇒ EXEMPT
        // §E56 REFUSAL — WITH THE LIVENESS DISCRIMINATOR THAT THE FIRST ATTEMPT LACKED.
        //
        // `tau = q/flow` is UNDEFINED at flow == 0, not merely large, so the honest response is to
        // refuse rather than clamp. But refusing on `flow == 0` ALONE is wrong and was MEASURED
        // wrong (644 failures): a zero EWMA is AMBIGUOUS between "the market is dead" and "we just
        // started", and a brand-new range has no flow HISTORY — refusing there bricks the pool at
        // genesis. No threshold on that one number can separate the two; it is an identifiability
        // problem, not a tuning one.
        //
        // `skewPremium*` resolves it at zero storage cost, and this is exactly why those counters
        // were kept when they looked redundant: they are MONOTONIC. A pool that has NEVER traded
        // cannot have accrued any, so `premium == 0` means NEW (permit, as before) and `premium > 0`
        // with no flow means TRADED-THEN-DIED (refuse). The counters' value is not their magnitude,
        // it is that they never decay — which is precisely what the EWMA cannot tell us.
        //
        // Errs PERMISSIVE by construction: a pool that has only ever seen SELLS accrues no drain
        // premium and so still reads NEW. That is the safe direction — a mis-priced trade beats a
        // bricked pool.
        if (flow == 0) {
            if (ICore(core).skewPremiumCum() > 0) revert NoShedPath();
        }
        // §E68b — THE SELL LEG NOW INTEGRATES TOO. E68 fixed only the DRAIN leg and left this one
        // pricing at the ENDPOINT, which is the OTHER HALF of the same defect the owner originally
        // identified — and the half that OVERCHARGES.
        //
        // `inv` already includes `addedTok` (see _skewBasis), so `over` is the POST-swap overshoot
        // and `q` was q1: the sell was billed at the scarcity its LAST unit created, applied to
        // EVERY unit. A seller arriving at a balanced range and pushing it to 2× target paid the
        // 2×-target rate on the whole ticket, including the first units that landed while the range
        // was still at target. Symmetrically to the drain leg, each unit must be billed at the
        // overshoot IT sees.
        //
        // The drain leg needed a logarithm because its kernel is the pole q/(1−q). This kernel is
        // LINEAR (E54: you cannot run out of surplus, so there is no barrier to integrate against),
        // and the mean of a linear function over an interval is its MIDPOINT:
        //     (1/Δ)·∫[q0→q1] q dq = (q0 + q1)/2
        // No `lnWad`, no new import, no branch for Δ=0 — the midpoint of a degenerate interval is
        // the point itself, so a zero-size read still returns the instantaneous rate exactly as
        // before. E54's linearity is PRESERVED, not replaced: this is the same line, averaged.
        // Every intermediate is SCOPED so it frees its stack slot before `_sharedScarcityWad` below
        // — the same idiom this function already uses on its conversion locals. Adding them
        // unscoped overflows the stack (MEASURED: `Stack too deep` at the `_sharedScarcityWad`
        // call). `via_ir` stays false, deliberately (CLAUDE.md): shed stack, do not switch pipeline.
        uint q;
        {
            uint q1 = SoladyMath.fullMulDiv(over, 1e18, target);
            if (q1 > 1e18) q1 = 1e18;                     // ≥2× target: linear term saturates
            // Pre-swap overshoot: strip this sell's own contribution back out of `inv`. A sell that
            // STARTED at/below target has q0 = 0 and pays only for the part that crossed above it.
            uint addedUsd = SoladyMath.fullMulDiv(addedTok, base, 1e30);
            uint invBefore = inv > addedUsd ? inv - addedUsd : 0;
            uint q0 = invBefore > target ? SoladyMath.fullMulDiv(invBefore - target, 1e18, target) : 0;
            if (q0 > 1e18) q0 = 1e18;
            q = (q0 + q1) / 2;                            // the integral's mean over THIS sell
        }
        uint sigmaSqWad = ICore(core).realizedVarianceWad();
        // §E54-r REMOVED (owner, 2026-08-04: *"avgYield has nothing to do with the range. it's a
        // dollar only thing. your skew shouldnt even consider it"*). I had added an opportunity-cost
        // term `r = Aux.avgYield()`, reasoning that the premium should equal what a counterparty
        // foregoes by taking this inventory off us. **`avgYield` does not measure that.** It is the
        // return on the BASKET's STABLE reserve — AAVE, the 4626 vaults, the Stability Pool — i.e.
        // the yield on DOLLARS. This skew prices the cost of carrying VOLATILE we did not want, and
        // the counterparty who takes ETH off us is not foregoing our stablecoin yield. Two different
        // assets, two different returns; I imported the number because it was conveniently in-system,
        // not because it measured the quantity. Same error as valuing the USD increment at the range's
        // leg ratio (§E28): a number that is *available* is not thereby the *right* one.
        // §E59: same σ²-zeroes-the-kernel hole as the drain leg — an UNMEASURED variance must not
        // price an inventory-increasing sell at nothing. Scarcity is real (q > 0) by this point.
        // §E79: with the inversion, `_maxWellSkew(0)` is now a FLOOR of ~0 — returning it here would
        // re-open the free-drain hole E59 closed. UNMEASURED variance must price at the CEILING,
        // which is the conservative reading E59 intended and now says so in the right units.
        uint skew = SoladyMath.fullMulDiv(
            SoladyMath.fullMulDiv(GAMMA_WAD, sigmaSqWad, 1e18), q, 1e18);
        // §E53: the SAME shared-scarcity amplifier the drain leg carries — a sell that grows our
        // inventory is dearer to shed when the OTHER range has already spoken for the shared backing.
        // §E89b: and the SAME risk-vs-fee split — the settlement-window risk term rides the amplifier
        // with the kernel; only `SPLICE_FLOOR` stays outside it. Written here so both legs compose
        // their price identically; they had already drifted apart once (E68b).
        return _composePrice(core, skew, sigmaSqWad);
        // SAME dynamic cap as the drain leg — one ceiling, both legs (`_maxWellSkew`).
        // §E79 — SAME CAP-TO-BASE INVERSION AS THE DRAIN LEG. One rule, both legs.

    }

    /// @notice Body of Aux.creditSwapOut — Swap-OUT (USD→BTC), the on-curve
    ///         MIRROR of creditSwapIn. See Aux's wrapper docblock for the full
    ///         semantics.
    function creditSwapOutBody(address swapper, address token, uint usdAmount, uint minSats,
        address core, address aux) external returns (uint sats, uint usd6) {
        if (usdAmount == 0) return (0, 0);
        _requireStable(aux, token);
        // Two OWN frames so the body stays trivially within the legacy stack (no via_ir): PREP does
        // deposit + oracle + drain-skew + route-params; SETTLE does the buy + proceeds-cap + swapper refund.
        // core (the BtcVault) == address(this) and wbtc is read from aux INSIDE prep, so neither this body nor
        // its Vault caller carries them as params — that's what frees the stack for the refund call.
        (Types.AuxContext memory ctx, Types.RouteParams memory rp) =
            _swapOutPrep(swapper, token, usdAmount, core, aux);
        (sats, usd6) = _swapOutSettle(ctx, rp, swapper, token, minSats);
    }

    /// @dev creditSwapOutBody PHASE 1 (own frame): pull the swapper's full stable into the basket, resolve
    ///      the oracle price, apply the drain scarcity skew (the withheld premium stays in Aux as fungible
    ///      backing, tracked by recordSkewPremium — it NEVER enters POOLED), and return the fully-built route
    ///      params. core == address(this) (this lib body is delegatecalled from the BtcVault); wbtc via aux.
    function _swapOutPrep(address swapper, address token, uint usdAmount, address core, address aux)
        private returns (Types.AuxContext memory ctx, Types.RouteParams memory rp) {
        address wbtc = address(IAux(aux).WBTC());
        // The normalized 6-dec USD pulled in — exactly what enters POOLED_USD (exact-input curve buy)
        // and thus the exact proceeds owed to the delivering LP (returned so requestSwapOutOnchain records it).
        // §A.50/C1: `deposit` returns TOKEN-NATIVE; this comment long claimed 6-dec. `scaleTo6` is
        // native→6, which is exactly the conversion needed, and it is a NO-OP for the 6-dec stables
        // (USDC/USDT/PYUSD/USDG/AUSD). It bites only for the seven 18-dec stables, which no test
        // currently exercises — see the mixed-decimal Echidna target (§A.70).
        uint amount = scaleTo6(IAux(aux).deposit(swapper, token, usdAmount), token);
        ctx.asset = wbtc; ctx.core = core;
        // Reuse the repack-resolved oracle price (5th return); live-read only if priceHint==0.
        // §E9 — packed range ticks, not a price (see creditSwapInBody). Block-scoped for stack.
        uint priceHint;
        {
            (,,,, uint p_) = ICore(address(this)).repack();
            priceHint = p_;
        }
        rp.inputIsUsd   = true;    // USD→BTC buy: USD is the INPUT (mirror of the sell)
        rp.token        = address(0);                       // volatile (BTC) output
        rp.pooled       = ICore(core).POOLED();      // BTC inventory bounds the fill
        uint basePrice  = _priceOr(priceHint, aux, wbtc);
        rp.fillPrice      = basePrice;                         // HONEST oracle — manip-guard stays unskewed
        // Effective-rate scarcity skew on the drain: scale the buy-driving USD DOWN by (1−skew) so a
        // BTC-scarce pool hands the swapper FEWER sats per USD; the withheld premium stays as backing. The
        // swap still executes at basePrice through routeSwap ⇒ NO manip-guard exemption (separate scalar).
        // `amount` here is ALREADY 6-dec USD (scaleTo6 in _swapOutPrep), so px=0 declares "no conversion":
        // this leg's recorded premium was always in the right unit and stays that way.
        SwapReq memory sr; sr.amount = amount; sr.px = 0;
        retainSkewPremium(core, sr, wellSkew(core, basePrice, amount), false);  // audit + RFQ-drawable
        amount = sr.amount;
        rp.amount    = amount;                               // reduced buy drives the fill
        rp.recipient = address(this);                       // obligation → pool; LN delivers
    }

    /// @dev creditSwapOutBody PHASE 2 (own frame): execute the buy, CAP the LP's owed proceeds to the USD
    ///      that actually drove the fill (`consumed`) so an inventory-bounded partial never over-owes the LP,
    ///      REFUND the swapper's unfilled remainder (amount − consumed) via Core.refundUnfilled → AUX.take
    ///      (checkBacking = solvency; the retained scarcity premium is NOT refunded), then enforce minSats.
    ///      Mirror of the vBTC partial-burn: serve/charge EXACTLY what filled.
    function _swapOutSettle(Types.AuxContext memory ctx, Types.RouteParams memory rp,
        address swapper, address token, uint minSats) private returns (uint sats, uint usd6) {
        uint amount = rp.amount;
        usd6 = amount;                                       // = obligation proceeds (premium already retained)
        uint consumed;
        (sats,, consumed) = BasketLib.routeSwap(ctx, rp);
        if (consumed < usd6) usd6 = consumed;               // proceeds == fill (no over-owe on a partial)
        if (amount > consumed) ICore(ctx.core).refundUnfilled(token, amount - consumed, swapper);
        if (sats < minSats) revert SwapOutShort();
    }

    // ════════════════════════════════════════════════════════════════════
    // LP ENGINE — the shared masterchef LP engine for both vaults, folded in
    // from the former imports/LpEngine.sol (an internal-only library). Its
    // callers (Vault, Quid) already import SwapLib, so this adds no new
    // deployed-library dependency; and SwapLib's own external functions never
    // call these, so they are NOT included in SwapLib's deployed bytecode —
    // they inline into Vault/Quid exactly as they did from LpEngine. Quid
    // (ETH side) and Vault (BTC side) once carried verbatim copies of this
    // logic; this is the ONE engine, parameterized by `isBTC`.
    //
    // STORAGE MODEL: holds NO storage. Where it operates on the LP's own struct
    // it takes `Types.Deposit storage` (legal — a mapping value). The vault's
    // flat value-type accumulators are taken BY VALUE and the new value/increment
    // RETURNED; the thin vault wrapper writes the slot back.
    // ════════════════════════════════════════════════════════════════════
    // Curve-reseat fires only when the spot is off the oracle by more than this
    // (matches routeSwap's execution guard — within it, swaps work, so no reseat).
    uint constant RESEAT_MIN_BPS = 50;

    // ── Fee bookmarks / pending ───────────────────────────────────────

    /// @dev Refresh LP's fee bookmarks against current per-share accumulators.
    ///      `weight` is the LP's fee-earning depth (GROSS: net `pooled` + the
    ///      debt-funded levered buffer). For a plain LP weight == pooled; for a
    ///      levered LP weight == pooled + levBuf so the buffer keeps earning its
    ///      leverage yield even though it is not equity (net) share depth.
    function refreshBookmarks(Types.Deposit storage LP, uint weight, uint tokAccum, uint usdAccum) internal {
        LP.fees_tok = SoladyMath.fullMulDiv(weight, tokAccum, WAD);
        LP.fees_usd = SoladyMath.fullMulDiv(weight, usdAccum, WAD);
    }

    /// @dev Pending (tok, usd) rewards for an LP against the supplied
    ///      per-share accumulators. `weight` is the GROSS fee depth (see
    ///      refreshBookmarks): pooled (net) + levered buffer.
    function pendingFor(Types.Deposit storage LP, uint weight, uint feePerShareTok, uint feePerShareUsd)
        internal view returns (uint tokReward, uint usdReward) {
        if (weight == 0) return (0, 0);
        uint tokOwed = SoladyMath.fullMulDiv(weight, feePerShareTok, WAD);
        uint usdOwed = SoladyMath.fullMulDiv(weight, feePerShareUsd, WAD);
        tokReward = tokOwed > LP.fees_tok ? tokOwed - LP.fees_tok : 0;
        usdReward = usdOwed > LP.fees_usd ? usdOwed - LP.fees_usd : 0;
    }

    /// @dev Per-share increments for a fee distribution. Returns the amounts to
    ///      ADD to the caller's (feesPerShareTok, feesPerShareUsd) accumulators.
    ///      Idempotent at fees=0 or no shares (returns 0,0). The caller applies:
    ///        feesPerShare += tokInc;  USD_FEES += usdInc;
    function feeIncrements(uint fees, uint usd_fees, uint totalShares)
        internal pure returns (uint tokInc, uint usdInc) {
        if (totalShares == 0) return (0, 0);
        if (fees > 0)     tokInc = SoladyMath.fullMulDiv(fees, WAD, totalShares);
        if (usd_fees > 0) usdInc = SoladyMath.fullMulDiv(usd_fees, WAD, totalShares);
    }

    // ── Delivery-side de-lever (partial-burn vBTC deliverability) ─────────────────────────────────

    /// @notice Runs at the head of a native swap-out settlement (Vault._resize) when the delivering LP's
    ///   slice draws PAST its FREE channel range into the LEVERED slice — the "stranded volatile" state
    ///   (`shrinkSats > funded = pooled − levPooled`). The delivery's OWN proceeds de-lever the shortfall
    ///   `want = min(shrinkSats−funded, levPooled)`: source the venue's debt stable from the basket, repay the
    ///   LP's debt (the manager burns the freed vBTC + un-encumbers the channel BTC, lev→funded, so the clamp in
    ///   resize then delivers the full shrink), and DRAW the retired-debt share out of POOLED_USD + clear
    ///   its obligation. The Vault hands resize `exactUsd − deLeverUsd6`, so `settleDelivered` mints QUI for
    ///   the FUNDED (+ any pure-equity) remainder only — the de-levered slice is paid ONCE (debt-reduction, not a
    ///   QUI mint). VALUE-NEUTRAL: −BTC −debt of equal oracle value ⇒ net-equity preserved, LTV IMPROVES. The
    ///   levered slice's V4 depth was already consumed by the curve at REQUEST (it sold against the full
    ///   POOLED), so this only reconciles the per-LP accounting — no second burnInRange. DELEGATECALL'd by the
    ///   Vault (address(this)==Vault): AUX/CORE see msg.sender==Vault (onlyUs), the manager sees Vault (==its
    ///   RANGE gate), and the manager's unexpose callback arrives as msg.sender==manager (==LEV_MANAGER).
    ///   Returns the 6-dec debt-share withheld from the QUI mint.
    function deleverOnDelivery(
        address core, address aux, address mgr,
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        address lp, uint shrinkSats, uint lpPayoutSats, uint exactUsd6
    ) public returns (uint deLeverUsd6) {
        uint lev = levPooled[lp];
        if (lev == 0) return 0;                                    // not levered — nothing to de-lever
        uint funded;
        { uint pooled = autoManaged[lp].pooled; funded = pooled > lev ? pooled - lev : 0; }
        if (shrinkSats <= funded) return 0;                       // free channel range covers the shrink
        uint deliveredRaw = shrinkSats > lpPayoutSats ? shrinkSats - lpPayoutSats : 0;
        if (deliveredRaw == 0) return 0;
        uint want = shrinkSats - funded;                          // levered sats this delivery must un-encumber
        if (want > lev) want = lev;
        uint wantUsd6 = exactUsd6 * want / deliveredRaw;          // proceeds share for the levered sats (6-dec)
        if (wantUsd6 == 0) return 0;
        return _sourceRepayFree(core, aux, mgr, lp, want, wantUsd6, exactUsd6); // own frame (legacy stack, no via_ir)
    }

    /// @dev Source→repay→free→draw body of deleverOnDelivery in its OWN frame. Sources the venue debt stable from
    ///   the basket (cherry-pick, held-clamped so `takeToSettle` never falls to the pro-rata leg — which would
    ///   deliver OTHER stables the venue can't repay with), repays min(wantUsd,debt) + un-encumbers `want` sats
    ///   (manager burns the vBTC), and draws the retired-debt share out of POOLED_USD + clears its obligation.
    function _sourceRepayFree(address core, address aux, address mgr, address lp, uint want, uint wantUsd6, uint exactUsd6)
        private returns (uint deLeverUsd6) {
        (address venue, address stable, uint amtNative) =
            ILevManagerDeliver(mgr).swapOutDeleverAmt(lp, wantUsd6 * 1e12);  // amtNative clamped to LIVE debt
        if (venue == address(0)) return 0;
        uint takeUsd18 = LevMath._toUsd18(aux,stable, amtNative);
        { uint held = _heldUsd18(aux, stable); if (takeUsd18 > held) takeUsd18 = held; } // stay on the cherry-pick leg
        if (takeUsd18 == 0) {
            // #13/H2: the channel BTC has ALREADY physically left to the swapper (splice-proven), so we must not
            // silently `return 0` — that truncates the position shrink to `funded` while settleDelivered draws +
            // mints the FULL exactUsd, leaving an UNBACKED vBTC debt (QUI backing overstated).
            //   amtNative>0 ⇒ real debt the basket holds NONE of the venue's stable to repay → fail-safe REVERT;
            //     the hop/keeper retries after topping the basket up (blocking beats settling unbacked).
            //   amtNative==0 ⇒ pure-equity levered slice (no debt) → free `want` sats with a zero-repay call
            //     (swapOutDelever amt==0 skips repay, still un-encumbers), deLeverUsd6=0 → full exactUsd mints (correct).
            if (amtNative > 0) revert DeleverStableUnavailable();
            ILevManagerDeliver(mgr).swapOutDelever(lp, 0, want);
            return 0;
        }
        deLeverUsd6 = (takeUsd18 + 1e12 - 1) / 1e12;             // 18→6 dec, round UP (never over-mint QUI)
        if (deLeverUsd6 > exactUsd6) deLeverUsd6 = exactUsd6;
        // Draw the retired-debt share out of POOLED_USD BEFORE the drain: takeToSettle uses the SOFT backing
        // check (its mid-drain instant is offset by the repay below), and drawing first keeps committed and liquid
        // moving together. The debt-buffer's stale POOLED_USD is reconciled by the keeper's async syncLev.
        ICore(core).drawPooledUsdBtc(deLeverUsd6);          // retired-debt share leaves POOLED_USD
        ICore(core).subPendingSwapOut(deLeverUsd6);        // obligation share cleared (matched at request)
        uint got;
        {
            uint bal0 = IERC20(stable).balanceOf(venue);
            // §A.55: `takeToSettle` routes to the SWAP branch of `_takePreferred`, which takes NATIVE
            // units — passing USD 1e18 was a 1e12x over-request that drained the basket's stable. Masked
            // because `got` measures the OUTCOME, so the repay was sized off the full drain. Converted
            // HERE, at the call site: the shared helper serves two unit conventions (§A.50).
            IAux(aux).takeToSettle(venue, BasketLib.scaleTokenAmount(takeUsd18, stable, false), stable); // basket → venue (soft backing = final-state solvency)
            got = IERC20(stable).balanceOf(venue) - bal0;        // venue-stable actually sourced (native units)
        }
        // Repay `got` (0 if the position had no debt — a pure-equity levered slice) and free `want` sats regardless.
        ILevManagerDeliver(mgr).swapOutDelever(lp, LevMath._toUsd18(aux,stable, got), want);
    }

    /// @dev Held USD (18-dec) of a single basket stable = its get_deposits slot. In the uint[15] vector,
    ///   `amounts[i+1] = balance` is the depeg-adjusted per-stable hold (BasketLib:247; BOLD → [11]), while
    ///   `amounts[0]` is the yield-weighted aggregate and `amounts[14]` the TVL total. So a real stable's
    ///   `toIndex` is in [1,11]; reject the aggregate (0), the total (12), and unknown stables (toIndex 0).
    function _heldUsd18(address aux, address stable) private returns (uint) {
        uint idx = IAux(aux).toIndex(stable);
        if (idx == 0 || idx >= 12) return 0;
        (uint[15] memory amts,,,) = IAux(aux).get_deposits();
        return amts[idx];
    }

    /// @notice §M.1 ETH swap-out DELIVERY-SIDE de-lever ORCHESTRATOR (aggregate; the ETH mirror of BTC
    ///   `deleverOnDelivery`). DELEGATECALL'd by Quid (address(this)==Quid==the LevManager's `RANGE`) from
    ///   `_sendETH` when the venue base (deliverableETH) can't cover a swap-out delivery. Walks the open lev book;
    ///   per LP: sources the swap's OWN proceeds into the venue via `Aux.takeToSettle` DIRECTLY (Quid==address(this)
    ///   IS authorized — `V4==Quid` in `Aux._requireUs`) and repays that LP's debt, delivering the freed collateral
    ///   as WETH to `recipient` (Quid, which unwraps + sends). VALUE-NEUTRAL per LP (the swapper's input de-levers
    ///   the delivering LP; the keeper re-levers next tick). 0-debt (unlevered net-equity) LPs take the no-repay
    ///   `swapOutDeliverUnlevered` branch instead. Stops once `shortfallEth` (WETH 1e18) is covered; fault-tolerant
    ///   (a stuck LP is skipped → residual #105 partial-fill). @param px USD 1e18/WETH. @return deliveredEth to recipient.
    ///   🔴 UNVERIFIED (forge OOM): fork-test the (1) gating chain, (2) Σbacking invariant (QD-burn: takeToSettle
    ///   draws basket stable to repay — needs `DeleverEthBackingProbe`), (3) non-toxicity, before trusting.
    function deleverEthOnDelivery(address mgr, address aux, uint px, uint shortfallEth, address recipient)
        public returns (uint deliveredEth) {
        if (px == 0 || shortfallEth == 0) return 0;
        // §AUDIT-OPENLPS-DOS — `n` IS BOUNDED NOW, AND NOT BY ANYTHING WRITTEN HERE. This loop ran
        // `i < openLevCount()` with no outer limit over a book anyone could grow, and it is the
        // most expensive walk of that book (several external calls per LP). The bound is
        // `RangeLib.MAX_OPEN_LPS`, enforced at the two sites that PUSH to `_openLps`, because a
        // limit applied here would just truncate the sweep and leave the shortfall unfilled while
        // the Σ-views stayed unbounded. Do NOT add a second clamp here: read that note first — it
        // records why the cap is at the writer and why the cap is temporary.
        uint n = ILevEthDeliver(mgr).openLevCount();
        for (uint i; i < n && deliveredEth < shortfallEth; i++) {
            address lp = ILevEthDeliver(mgr).openLpAt(i);
            uint needUsd = SoladyMath.fullMulDiv(shortfallEth - deliveredEth, px, 1e18);   // remaining WETH → USD 1e18
            (address venue, address stable, uint amtNative) = ILevEthDeliver(mgr).swapOutDeleverAmt(lp, needUsd);
            if (venue == address(0)) continue;
            if (amtNative == 0) {
                // 0-debt UNLEVERED net-equity (the HODL slice) — no repay/takeToSettle, just withdraw+deliver.
                try ILevEthDeliver(mgr).swapOutDeliverUnlevered(lp, shortfallEth - deliveredEth, recipient, 0)
                    returns (uint w) { deliveredEth += w; } catch {}
                continue;
            }
            uint fundUsd = LevMath._toUsd18(aux,stable, amtNative);      // USD the clamped debt-repay represents
            if (fundUsd > needUsd) fundUsd = needUsd;
            if (fundUsd == 0) continue;
            // Route the swap's OWN proceeds → venue directly (Quid==address(this) IS `takeToSettle`-authorized),
            // then repay+free+deliver. try/catch: a stuck LP (illiquid collateral / venue revert) is skipped,
            // leaving the residual to the #105 partial-fill.
            // §A.55: native units for the take (see above). `fundUsd` stays 18-dec for `swapOutDelever`
            // below, so ONLY the argument is converted — not the variable.
            try IAux(aux).takeToSettle(venue, BasketLib.scaleTokenAmount(fundUsd, stable, false), stable) returns (uint) {
                try ILevEthDeliver(mgr).swapOutDelever(lp, fundUsd, recipient, 0) returns (uint, uint w) {
                    deliveredEth += w;
                } catch {}
            } catch {}
        }
    }

    // ── In-range burn ─────────────────────────────────────────────────

    /// @dev Burn `amount` of in-range virtual liquidity (capped at the pool's
    ///      active slice) and return what was actually delivered. ETH passes
    ///      the LP's recipient; BTC passes address(0) (native sats return via
    ///      the cooperative-close tx — only the mockBTC is burned).
    /// §V4-RESIDUE (2026-08-18) — `spotPrice`, `loPrice` and `upPrice` DELETED: solc reported all three
    /// unused here, and they were the core position's price bounds. A burn against our own inventory takes
    /// an AMOUNT; there is no range to burn out of and no spot to price it at. They were still being
    /// computed and threaded through two frames to be discarded at the leaf.
    function burnInRange(address core, uint amount, address recipient)   // §ISBTC-SPLIT: the `isBTC` param was never read
        internal returns (uint sent) {
        uint pooled = ICore(core).POOLED();
        uint pulled = Math.min(amount, pooled);
        if (pulled == 0) return 0;
        (, uint posLiquidity) = ICore(core).poolStats();
        if (posLiquidity > 0) {
            sent = ICore(core).modLP(int256(pulled), 0, recipient);   // LEAVES ⇒ positive: delivers to `recipient`
        }
    }

    // ── BTC allocation cap REMOVED (§H, 2026-07): the btcShareBps median-vote cap is gone; BTC now sizes by
    //    SOLVENCY-surplus only. The ≤TVL invariant + `committedBoth` (shared-mirror, so neither pool double-claims
    //    surplus) remain the bounds — no policy cap, no `btcCapClamp`.

    /// @dev Shared solvency sizer for Quid.addLiq (ETH) + Vault._addLiqChannel
    ///      (BTC). From the SHARED free backing (`liquidTotal − committedBoth`,
    ///      where committedBoth nets BOTH pools' committed USD so neither can claim
    ///      the same surplus twice), optionally apply the BTC policy cap, then
    ///      back-solve the token amount whose USD value == surplus (pin USD to free
    ///      backing; the unpaired token stays in IL-free retention). Callers fetch
    ///      `liquidTotal` (get_deposits[14]) + `committedBoth` (committedUsd18)
    ///      themselves — keeps the large get_deposits ABI decode in the contract,
    ///      off the legacy-pipeline headStart path. `surplus == 0` ⇒ caller
    ///      early-returns. Every mulDiv floors → commits ≤ requested, never more.
    /// @notice §E270 — THE ONE token→USD conversion at a range price. Three sites had it inline:
    ///         `sizeBySurplus` below and the post-theta-clamp recompute on EACH range. The BTC range had
    ///         drifted to `targetUSD*capped/deltaTok`, which computes the SAME quantity with two
    ///         compounded roundings and an unguarded `*`/`/`. Classified DRIFT and unified here.
    /// @dev    `internal pure` ⇒ inlines. No new bytecode, no delegatecall.
    function usdForTok(uint tok, uint price) internal pure returns (uint) {
        return SoladyMath.fullMulDiv(tok, price, WAD);
    }

    function sizeBySurplus(
        uint liquidTotal, uint committedBoth,
        uint deltaTok, uint price
    ) internal pure returns (uint deltaOut, uint targetUSD, uint surplus) {
        // #67 note: the levered net-equity is NOT paired against surplus (that would spend surplus making the
        // equity earn range fees on de-lever-backed / phantom USD, and make the levered backing withdrawable at
        // will). Surplus is reserved for the borrow cost + QU!D redemption; the levered net-equity is REDEMPTION
        // backing (already in committedUsd18 / rangeETH/BTC), de-leverable only by a redemption. Its debt-funded
        // BUFFER leg already earns range fees without touching surplus. So this stays REAL-surplus-only.
        surplus = liquidTotal > committedBoth ? liquidTotal - committedBoth : 0;
        if (surplus == 0) return (0, 0, 0);
        deltaOut  = deltaTok;
        targetUSD = usdForTok(deltaTok, price);
        if (targetUSD > surplus) {
            targetUSD = surplus;
            deltaOut  = SoladyMath.fullMulDiv(surplus, WAD, price);
        }
    }

    /// @notice theta risk-budget clamp on a range add: cap post-add `pooled` at `thetaEff * rangeAvail`
    ///         (WAD), so the IL-bearing range never holds more than the live yield/vol tradeoff prescribes.
    ///         `thetaEff >= 1e18` (fail-open / calm) is a no-op. Shared by BOTH sizing paths -- ETH
    ///         (`QuidLib.addLiq`) and BTC (`BtcLib.addLiqChannel`) -- so the throttle is identical
    ///         across assets (a volatile-asset range bears IL the same way regardless of which asset).
    function applyTheta(uint thetaEff, uint rangeAvail, uint pooled, uint available)
        internal pure returns (uint)
    {
        if (thetaEff >= 1e18) return available;
        uint thetaCap   = SoladyMath.fullMulDiv(rangeAvail, thetaEff, 1e18);
        uint thetaAvail = thetaCap > pooled ? thetaCap - pooled : 0;
        return available > thetaAvail ? thetaAvail : available;
    }

    /// @notice Backing-bounded theta clamp — the ONE principle for EVERY range add (ETH range, BTC LP-add, BTC
    ///         reseat). Permit `want` new in-range depth, but never past two bounds:
    ///           • HEADROOM = `backing − pooled` — the physical room the IL-bearing capital leaves ABOVE the
    ///             current in-range depth. `backing` = that capital (ETH: rangeETH venue principal + gross
    ///             buffer; BTC: lpShares + gross buffer, +this add's sats); `pooled` = current in-range range
    ///             depth (POOLED/BTC). The range can never exceed what backs it.
    ///           • THETA budget = `θ·backing − pooled` (via applyTheta) — θ = avgYield/(K·σ²) (Merton), the
    ///             fraction of backing it is optimal to RISK in-range given yield vs realized variance; θ≥1
    ///             fails open (calm/unmeasured) → only HEADROOM binds.
    ///         Returns `min(want, HEADROOM, THETA budget)`. Dedups the former divergence where the BTC LP-add
    ///         skipped HEADROOM (harmless — its `want=deltaTok ≤ that add's own sats ≤ backing−pooled` — but now
    ///         every path stays bounded at the real backing even when θ fails open).
    /// @notice Withhold the A-S scarcity premium `amount·skew` from a drained/sold `amount`, record it as
    ///         retained backing (`recordSkewPremium` — the drainer's full USD entered the pool, they just take
    ///         less out), and return the reduced amount. ONE definition for all three retain sites (swap-out
    ///         drain, sell-in, BtcVault drain). The retained premium stays in the basket as LP backing (the
    ///         refiller-payout side was removed — the fleet self-funds the refill). skew==0 no-op.
    /// @notice Plain (unlevered) net range equity = gross `pooled` minus the levered slice `lev`, zero-floored.
    ///         ONE definition for the hedge-E0 base (rangeOf/rangeOf), the venue-yield fee weight, and the
    ///         withdraw/transfer free-balance cap — a drifted copy (dropped floor / wrong slice) would make
    ///         levered depth withdrawable or double-earn venue yield.
    function plainNet(uint pooled, uint lev) internal pure returns (uint) {
        return pooled > lev ? pooled - lev : 0;
    }

    /// @dev Takes the `SwapReq` (ONE memory pointer) rather than `amount`+`price` as separate stack
    ///      values — `swapToBody` is stack-tight and passing them individually overflows it. Mutates
    ///      `r.amount` in place; there is no return.
    ///      `r.px` DECLARES the unit `r.amount` is in, so one recording path serves both legs:
    ///        • `r.px != 0` -> `r.amount` is NATIVE (wei/sats). `recordSkewPremium` wants 6-dec USD, so
    ///                         convert with the flat /1e30 that is correct for BOTH assets (the WBTC
    ///                         price carries the x1e10 lift — same rule as `poolVolUsd` below).
    ///        • `r.px == 0` -> `r.amount` is ALREADY 6-dec USD (the drain leg, whose input came through
    ///                         `scaleTo6`); record verbatim. That leg was always correct — this keeps it so.
    ///      The premium SUBTRACTED from `r.amount` stays in the caller's own unit; only the RECORDED
    ///      value converts. Before this fix the native legs recorded wei/sats into a USD register: ETH
    ///      over-reported (theta throttle never bound) and BTC under-reported ~1e3 (over-throttled).
    function retainSkewPremium(address core, SwapReq memory r, uint skew, bool nativeAmount)   // §ISBTC-SPLIT: the `isBTC` param was never read
        internal {
        if (skew == 0) return;
        // §E275 — NO GUARD HERE BY DESIGN. `skew` reaches this function only from `wellSkew` /
        // `sellSkew`, both of which decline an unfillable rate at the producer, so a second bound
        // would be the clamp standing rule 17 warns about rather than a defence.
        uint premium = SoladyMath.fullMulDiv(r.amount, skew, 1e18);
        // ONLY the sell leg holds a NATIVE amount. The two drain legs hold the BUY-DRIVING USD, already
        // 6-dec — converting those (attempt 2) collapsed the recorded premium to 0. `r.px` cannot serve as
        // the discriminator: it is non-zero on BOTH swapToBody legs, so the caller states the unit.
        ICore(core).recordSkewPremium(
            nativeAmount ? SoladyMath.fullMulDiv(premium, r.px, 1e30) : premium);
        r.amount -= premium;
    }

    function clampByBacking(uint thetaEff, uint backing, uint pooled, uint want)
        internal pure returns (uint)
    {
        uint available = backing > pooled ? backing - pooled : 0;
        available = applyTheta(thetaEff, backing, pooled, available);
        return want < available ? want : available;
    }

    // ── Tick math (pure/view) ─────────────────────────────────────────


    function paddedSqrtPrice(uint spotPrice, bool up, uint delta)
        internal pure returns (uint160) {
        uint factor = up ? FixedPointMathLib.sqrt((10000 + delta) * 1e18 / 10000)
                         : FixedPointMathLib.sqrt((10000 - delta) * 1e18 / 10000);
        return uint160(FixedPointMathLib.mulDivDown(spotPrice, factor, 1e9));
    }

    /// @notice (B — IL-protect) The range's ACTUAL sold-volatile fraction (WAD) between `syncKeyPx` and the
    ///         current `spotPrice`, straight from the concentrated-position geometry — the ground-truth IL the
    ///         hedge must cancel, reflecting the real (drifting) α with NO sqrt/pow and NO α parameter. Held
    ///         volatile amount is ∝ (√P − √Pa) when the volatile is token1 (sold as √P FALLS — volatile
    ///         appreciates ⇒ pool price down) or ∝ (√Pb − √P)/(√P·√Pb) when it's token0 (sold as √P RISES);
    ///         soldFrac = 1 − amount_now/amount_entry. Returns 0 on the non-IL side (up-side-only, matching the
    ///         current target) or a degenerate range. VALID WITHIN ONE TICK-CONFIG ONLY — a reseat recenters the
    ///         ticks and realizes IL, so the CALLER must re-anchor `syncKeyPx` on a reseat. Shared verbatim by
    ///         the ETH range (Quid, `token1isVol`) and the BTC range (Vault, `token1isVol`).
    /// @notice held-volatile amount NOW / held-volatile amount AT ENTRY (WAD), straight from the
    ///         concentrated-range geometry, clamped to the live range. `1e18` = at entry. `>1e18` ⇒ the range
    ///         BOUGHT the volatile (price fell — the OVER-hold the short cancels); `<1e18` ⇒ it SOLD (price
    ///         rose — the UNDER-hold the long cancels). Reflects the real (drifting) α with NO α parameter and
    ///         NO sqrt/pow — the single ground-truth primitive both hedge legs size from. VALID WITHIN ONE
    ///         TICK-CONFIG ONLY: a reseat recenters + realizes IL, so the caller MUST re-anchor `syncKeyPx`.
    /// @notice Fraction of the range's ORIGINAL volatile still held, WAD. Same quantity as before,
    ///         computed in USD-PER-VOLATILE space instead of spotPrice space.
    ///
    /// @dev DERIVATION, because this is hedge-sizing math and the equivalence must be checkable.
    ///      Volatile held over a range is `V(P) ∝ 1/√P − 1/√P_up`. So
    ///          ratio = (1/√P − 1/√P_up) / (1/√P₀ − 1/√P_up)
    ///                = √P₀·(√P_up − √P) / ( √P·(√P_up − √P₀) )
    ///      which is EXACTLY the old `(s0/s)·(sb−s)/(sb−s0)` branch with `s = √P`.
    ///
    /// 🔑 AND THE `token1Volatile` BRANCH DISAPPEARS, which is a real simplification rather than a
    ///      translation. Two branches existed because `spotPrice` INVERTS meaning with token
    ///      ordering: when USD is token0, price ∝ 1/sqrtP², so the same holding needed the mirrored
    ///      formula. USD-PER-VOLATILE DOES NOT INVERT — it is the same number whichever token got
    ///      the lower address — so one expression now serves both ranges. The ordering flag was
    ///      never about economics; it was about core's encoding.
    ///
    ///      √ SURVIVES AS AN OPERATION, NOT A REPRESENTATION. The root is mathematically required
    ///      (holdings are √-shaped in price), but nothing is STORED or PASSED as a sqrt price any
    ///      more — which was the actual coupling to core.
    ///      Roots are taken on WAD prices via `sqrt(P·1e18)`, so every term carries the same 1e18
    ///      scale and the ratios cancel it exactly.
    function holdingRatioWad(uint syncKeyPx, uint price, uint loPrice, uint upPrice)
        internal pure returns (uint) {
        if (syncKeyPx == 0 || loPrice >= upPrice) return 1e18;
        // Clamp in PRICE space; `sqrt` is monotonic so clamping before or after the root is
        // identical, and price-space clamping is the one a reader can check against the range edges.
        uint pc  = price      < loPrice ? loPrice : (price      > upPrice ? upPrice : price);
        uint p0c = syncKeyPx < loPrice ? loPrice : (syncKeyPx > upPrice ? upPrice : syncKeyPx);
        uint a = FixedPointMathLib.sqrt(pc  * 1e18);   // √P
        uint b = FixedPointMathLib.sqrt(p0c * 1e18);   // √P₀
        uint c = FixedPointMathLib.sqrt(upPrice * 1e18);
        if (c <= b || a == 0) return 1e18;             // degenerate: entry at/above the upper edge
        return SoladyMath.fullMulDiv(SoladyMath.fullMulDiv(b, 1e18, a), c - a, c - b);
    }

    /// @notice The range's ACTUAL sold-volatile fraction (WAD) since entry = `1 − holdingRatio` when the range
    ///         under-holds (price rose). The LONG hedge re-adds exactly this. Ground truth; 0 on the non-sold side.
    function soldFractionWad(uint syncKeyPx, uint price, uint loPrice, uint upPrice)
        internal pure returns (uint) {
        uint r = holdingRatioWad(syncKeyPx, price, loPrice, upPrice);
        return r < 1e18 ? 1e18 - r : 0;
    }




    /// Rescale a just-deposited stable amount to 6-dec USD by its own decimals.
    /// Shared verbatim by the ETH (QuidLib) and BTC (BtcLib) OOR paths.
    function scaleTo6(uint amount, address token) internal view returns (uint) {
        uint8 dec = IERC20(token).decimals();
        if (dec == 6) return amount;
        return dec > 6 ? amount / 10 ** (dec - 6) : amount * 10 ** (6 - dec);
    }

    /// Shared param validation for the out-of-range boundary order (ETH+BTC):
    /// range 100–1000 step 50, distance ±5000 step 100 (non-zero). Custom error (no
    /// string-revert bytecode — the two long strings were the fattest revert sites in the OOR path).
    error BadOorParam();
    function validateOorParams(uint range, int distance) internal pure {
        if (!(range >= 100 && range <= 1000 && range % 50 == 0)) revert BadOorParam();
        if (!(distance % 100 == 0 && distance != 0 && distance >= -5000 && distance <= 5000)) revert BadOorParam();
    }

    // ─── Self-managed (out-of-range / boundary-order) geometry ────────────────
    // Shared by the ETH (Quid) and BTC (Vault) single-sided position paths so
    // BOTH compute ticks + single-sided liquidity by the SAME rules — only the
    // pool + token ordering differ (token1is). Ported verbatim from the original
    // Quid `_outOfRangeTicks` / `_sizeOutOfRange` USD branch.
    struct Oor { uint newLo; uint newUp; uint curLo; uint curUp; }

    /// The boundary order's tick range, fully outside the current [curLo,curUp].
    /// `distance` is caller-signed (positive = below the price); `token1is` flips
    /// it for the pool's token ordering. `width` is the tick-alignment (10).
    /// §DE-TICK — THE BOUNDARY ORDER'S RANGE IS A PRICE OFFSET. A tick is 1 bp by construction
    /// (1.0001^i), so a `distance`/`range` expressed in ticks IS an offset in basis points — the grid
    /// was only ever a way to index them. `alignTick` goes with it: alignment existed because core can
    /// place liquidity only on grid boundaries, and we hold inventory at a price bound.
    /// ⇒ THIS DELETES THE #46 OFF-BY-ONE OUTRIGHT. That defect existed because a tick was derived
    /// from a sqrt price and `getTickAtSqrtRatio(spotPrice) == currentTick` does not always hold;
    /// with no tick derived, there is nothing to be off by one about — the root is gone, not guarded.
    /// §DE-TICK — NO ORDERING FLAG. `if (!token1is) distance = -distance` flipped which side of
    /// spot a POSITIVE `distance` meant. That flip belongs to TICK space, where direction inverts
    /// with token ordering; in price space (USD per volatile) it does not, so the flip was applying
    /// an inversion to a quantity that has none. The sign of `distance` now says the side directly:
    /// NEGATIVE = above spot, POSITIVE = below spot, the same convention the arithmetic below
    /// already encodes.
    function oorBounds(uint price, uint range, int distance,
        uint curLo, uint curUp) internal pure returns (Oor memory t) {
        t.curLo = curLo; t.curUp = curUp;
        // `distance` bps away from spot, `range` bps wide.
        uint target = distance < 0
            ? price * (10000 + uint(-distance)) / 10000
            : price * (10000 - uint(distance))  / 10000;
        if (distance < 0) { t.newLo = target; t.newUp = target * (10000 + range) / 10000; }
        else              { t.newUp = target; t.newLo = target * (10000 - range) / 10000; }
    }

    /// Size a USD-funded single-sided boundary order (`amount6` in 6-dec USD).
    /// Asserts the new range sits fully outside the current one and provides the
    /// USD on the side the ordering dictates.
    function sizeOorUsd(uint amount6, Oor memory t)
        internal pure returns (uint placeable) {
        // §DE-TICK — WHAT SURVIVES IS THE OUTSIDE-NESS GUARD; the liquidity encoding does not.
        // This used to convert both bounds to sqrt prices and ask `LiquidityAmounts` for a core
        // liquidity figure. Callers now STORE AND PASS THE AMOUNT (see `Types.SelfManaged.amt`), so
        // the only thing the return was still doing was answering "can this range hold anything" —
        // a validity check, which the guards below already are.
        // ⚠️ THE STRICT COMPARISONS ARE UNCHANGED, INCLUDING THEIR DIRECTION. A boundary order must
        // sit FULLY outside the active range; `>=` / `<=` (not `>` / `<`) is what makes a range that
        // merely touches the range edge invalid.
        // 🔴 SYMMETRIC, AND DELIBERATELY SO. This was two branches picked by the ordering flag,
        // and that flag derives from the lex order of freshly-deployed MOCK addresses -- so WHICH
        // SIDE a boundary order was allowed to sit on varied with deployment nonce. The comment on
        // the first branch ("above current") also contradicted its own guard, which requires the
        // range to be BELOW. There was no stable behaviour to preserve, so this enforces the
        // requirement the docblock states and both branches were separately approximating: the new
        // range must lie WHOLLY outside the active range, on either side. The side itself is the
        // caller's choice, carried by the sign of `distance`.
        // The strict comparisons are unchanged: a range that merely TOUCHES an edge is invalid.
        if (!(t.newUp < t.curLo || t.newLo > t.curUp)) revert RangeNotOutside();
        if (t.newLo >= t.newUp) revert RangeNotOutside();       // degenerate range holds nothing
        placeable = amount6;
    }

    // (event InstantRedeemSkipped removed 2026-08-09 — it announced a degradation from the instant-redeem
    //  rung to the wait-NFT, and that rung was deleted 2026-08-05/06. It was never emitted after that, so it
    //  was an ABI entry promising a signal that could not fire. ⚠️ The degradation it covered is now
    //  UNANNOUNCED: rung 1 failing its 0.5% floor drops the withdrawer into the multi-day queue with no
    //  event. If that signal is wanted back it must be re-armed on the rung-1 catch in
    //  `QuidLib.offrampBody`, not here — see QUEUE §E152-nerve.)

    /// §DE-TICK COMPLETION (owner, 2026-08-17: *"there should be no tickmath"*) — was
    /// `TickOutOfRange`, the LAST tick identifier left in code anywhere in `evm/src`. It never
    /// guarded a tick: both call sites compare PRICES (`t.newUp < t.curLo`, `t.newLo >= t.newUp`).
    /// The name outlived the grid by seven commits and would have read as evidence that tick math
    /// survives the core cut. No client decodes it — zero hits in `spa/src`, `quid-ln`, `tools` — so
    /// the selector change costs nothing.
    error RangeNotOutside();
    /// §DE-TICK — THE RANGE IS ±δ AROUND THE PRICE, AND THAT IS THE WHOLE COMPUTATION.
    /// This used to pad in SQRT space (`spotPrice · √((10000±δ)/10000)`), then look the result up in the
    /// tick grid and align to a spacing of 10. In price space the root cancels — padding a price by
    /// a ratio is a multiplication — so TWO square roots and TWO tick lookups become two multiplies.
    /// ⚠️ THE ALIGNMENT AND THE RANGE GUARDS GO WITH THEM, and nothing is lost: `alignTick` existed
    /// because core can only place liquidity on grid boundaries, and MIN/MAX_SQRT_PRICE bounded the
    /// tick representation. We hold inventory at a price bound — there is no grid to land on and no
    /// representable range to fall out of. This also deletes the off-by-one class described in #46,
    /// which existed ONLY because a tick was being derived from a sqrt price.
    function updateBounds(uint price, uint delta)
        internal pure returns (uint lower, uint upper) {
        lower = price * (10000 - delta) / 10000;
        upper = price * (10000 + delta) / 10000;
    }

    // ── Shared repack skeleton ────────────────────────────────────────

    /// Raw output of `rebalanceCore` so callers can run a pool-specific
    /// fee-distribution / yield-metric after the shared work.
    struct Rebalanced {
        uint spotPrice;   // §DE-TICK: carries the PRICE now, not a sqrt price
        uint    loPrice;     // §DE-TICK: post-repack range bounds, as PRICES
        uint    upPrice;
        uint    myLiquidity;
        bool    didRepack;     // true → a range move happened; fees0/1/delta0/1/price valid
        uint    price;
        uint    fees0;
        uint    fees1;
        uint    delta0;
        uint    delta1;
        // JIT-defense (in-range) branch produces canonical (USD,tok) fees to
        // distribute directly; signalled by jitFees.
        bool    jitFees;
        uint    jitFeesUsd;
        uint    jitFeesTok;
        // The resolved oracle price (Chainlink when stale, else internal TWAP)
        // read here for the staleness/reseat check — exported so the swap path
        // (_finishSwap) REUSES it as fillPrice instead of reading the
        // internal `observe` ring a second time per swap. 0 ⇒ caller live-reads.
        uint    resolvedTwap;
    }

    /// @dev SHARED body of _rebalance (the parts identical for ETH and BTC):
    ///      read poolStats for the current range, and if the price drifted out
    ///      of range run the manipulation guard + V4.repack; else (in range)
    ///      force a JIT-defense fee collect. Writes the NEW range into the
    ///      caller's tick slots is NOT done here (value-type storage) — the
    ///      caller writes them from the returned struct. `aux`/`asset` give the
    ///      TWAP feed for the manipulation guard.
    /// §ISBTC-SPLIT — THE `isBTC` PARAMETER IS GONE, AND IT WAS USED NOWHERE. It threaded from
    /// `repack(bool)` through `_rebalance` -> `rebalanceBody` -> here -> `_reseatIfStale` ->
    /// `_doReseat`, whose signature already read `bool /*isBTC*/`. Six frames carrying a value the
    /// bottom one had stopped reading; each call site picks the CONTRACT, which is what actually
    /// identifies the range.
    function rebalanceCore(
        address core, address aux, address asset,
        uint upPrice, uint loPrice
    ) internal returns (Rebalanced memory r) {
        r.upPrice = upPrice;
        r.loPrice = loPrice;
        // §DE-TICK — `currentTick` is gone. It was core's index of where spot sat on the grid; the
        // price it encoded is now read directly, so keeping a tick would mean deriving an index into
        // a grid nothing consults.
        (r.spotPrice, r.myLiquidity) = ICore(core).poolStats();

        // Resolved oracle price + staleness. try/catch so a bootstrap pre-history
        // / dead-feed read NEVER bricks the op (falls through to legacy handling).
        uint twap; bool stale;
        try IAux(aux).resolvedTwap(asset, 1800) returns (uint p, bool s) {
            twap = p; stale = s;
        } catch {}
        r.resolvedTwap = twap; // export for the swap path to reuse (no 2nd read)

        // AUTO-HEAL (deadlock recovery): when the internal TWAP is >5% off
        // Chainlink (`stale` ⇒ resolved price IS Chainlink), the curve spot may be
        // stuck far from the real price and the 50-bps swap guard blocks every
        // swap → the spot can't move → frozen. Move slot0 onto Chainlink + re-range
        // so swaps resume at the real price. Fires ONLY in this dislocation regime
        // (never on normal drift, and never when no feed is wired ⇒ stale=false,
        // so it can't churn or perturb existing behavior); no-op if already
        // aligned. Both pools route here (Quid + BtcVault).
        if (stale && _reseatIfStale(core, r, twap)) return r;

        // HALF-OPEN RANGE (T1), NOW IN PRICE SPACE. The range is ACTIVE iff `lower <= P < upper`, so
        // it is OUT of range at `P >= upper` — NOT `>`. With `>`, at exactly `P == upper` the range
        // is inactive (fully in one token, earning nothing) yet this returned "still in range" and
        // did not re-centre, leaving it stranded. The asymmetry is the tell: a half-open range needs
        // `>=` upper and `<` lower.
        // ⚠️ THE COMPARISON IS PRESERVED EXACTLY — only its units changed. Ticks were monotonic in
        // price, so `tick >= upPrice` and `P >= upper` are the same predicate; and the off-by-one
        // that made this delicate (#46) is gone with the tick derivation, not papered over.
        if (r.spotPrice >= upPrice || r.spotPrice < loPrice) {
            // Don't repack to a manipulated spot — need the oracle. If unavailable
            // (twap==0, e.g. bootstrap) or spot deviates >300bps, keep the range.
            if (twap == 0) return r; // didRepack stays false → keep current range
            uint spot = r.spotPrice;   // §DE-TICK: already a PRICE; no sqrt to decode
            // Repack TOLERANCE (300 bps = 3%) — looser than the 50-bps swap
            // guard so normal volatility doesn't block re-centering.
            if (BasketLib.isManipulated(spot, twap, 300)) {
                return r;
            }
            // §ONE-ANCHOR — hand the engine the ANCHOR; the bounds it implies are derived here and
            // wherever else they are wanted, from that one number.
            if (r.myLiquidity > 0) {
                r.price = ICore(core).repack(r.spotPrice);
                r.didRepack = true;
            }
            (r.loPrice, r.upPrice) = updateBounds(r.spotPrice, RANGE_DELTA);
        } else if (r.myLiquidity > 0) {
            // JIT-snipe defense: force a fee-only collect so accrued fees land
            // in the accumulators BEFORE the caller's bookmark advances.
            // collectFees ALREADY reorders internally and returns canonical
            // (feesUSD, feesTok) — USD first.
            (r.jitFeesUsd, r.jitFeesTok) = ICore(core).collectFees();
            r.jitFees = true;
        }
    }

    /// @dev Move the curve spot onto the (Chainlink) target `twap` + re-range.
    ///      Own frame so rebalanceCore stays within the legacy stack (no via_ir).
    ///      Returns true if it moved the spot. No-op (false) when already aligned.
    function _reseatIfStale(address core, Rebalanced memory r, uint twap)
        private returns (bool) {
        // §DE-TICK — `spot` IS `r.spotPrice` now; there is no sqrt to decode and no token
        // ordering to resolve, because a USD-per-volatile price does not flip with ordering.
        uint spot = r.spotPrice;
        if (spot == 0 || twap == 0) return false;
        // Only move the spot when it's off the oracle by more than the 50-bps
        // routeSwap guard — i.e. enough to actually BLOCK swaps. Within 50bps swaps
        // execute fine, so reseating would just churn (and a sub-tick move is
        // degenerate). This keeps reseat firing once per dislocation, not per op.
        if (!BasketLib.isManipulated(spot, twap, RESEAT_MIN_BPS)) return false;
        // §DE-TICK — THE TARGET IS THE TWAP. `targetSqrtForPrice` existed to encode a desired price
        // back into a sqrt price without an absolute price→sqrt conversion. In price space the
        // target simply IS the price, so the whole encoding step disappears.
        if (twap == r.spotPrice) return false;   // already aligned
        _doReseat(core, r, twap);
        return true;
    }

    /// @dev Burn+move+re-range to `targetSqrt` — own frame so the reseat's 5-tuple
    ///      return doesn't pin _reseatIfStale's stack (legacy pipeline, no via_ir).
    function _doReseat(address core, Rebalanced memory r, uint targetPrice)
        private {
        if (r.myLiquidity > 0) {
            r.price = ICore(core).repack(targetPrice);   // §ONE-ANCHOR: the anchor, not the pair
            r.didRepack = true;
        }
        (r.loPrice, r.upPrice) = updateBounds(targetPrice, RANGE_DELTA);
        r.spotPrice = targetPrice;
    }


    // ═══ §E310 — `SwapLib` FOLDED IN; the file is deleted ═══
    // 270 lines whose only live consumers were its own test plus one `_applySkew` reference.
    // ⚠️ FOLDED, NOT DELETED. Measured: `quoteFill`, `quoteDrain`, `enforce`, `of` and
    //    `assertConserved` have ZERO callers — but this is the PARKED firm-quote surface the
    //    design depends on, awaiting the 'paid against 1inch' decision, not dead code. Rule 1
    //    removes UNREACHABLE code; it does not remove a maintained primitive awaiting a wiring,
    //    which is the mistake this repo has already reverted twice (`create_sweep_tx`).
    //    It imported `SwapLib`; folding it here dissolves that edge.
    /// @notice THE FIXED-RATE FILL PRIMITIVE (was `FixedRateFill`'s @title). It describes THIS
    ///         SECTION, not `SwapLib` as a whole -- the §E310 fold carried the header across and the
    ///         rename made it read as a title for the whole library, which it is not.
    ///
    /// @notice ONE PRICE, NO TRAVERSAL. The swapper is quoted a SINGLE rate for a SINGLE size, bounded by
    ///         inventory, and that rate is what settles. There is no curve to walk, no tick to cross, and
    ///         no average-execution-across-a-range — which is precisely why √P and the tick grid leave in
    ///         the same cut (owner, 2026-08-15: "work around geometric means").
    ///
    ///         WHY THIS IS NOT AN AMM. An AMM DISCOVERS the price by moving along a curve as the trade
    ///         executes, so the marginal price at the end differs from the start and the average is a
    ///         geometric mean of the two. Here the price is COMMITTED BEFORE EXECUTION and does not move
    ///         during it. The imbalance the trade creates is priced INTO the quote via the skew, rather
    ///         than being expressed as slippage discovered on the way through.
    ///
    ///         ⇒ THE SKEW IS NOT A SPREAD PAID TO ARBERS. IT IS THE ATTRIBUTION KEY FOR A REBALANCE WE
    ///         PERFORM OURSELVES (owner, 2026-08-15). An AMM's spread exists to PAY EXTERNAL
    ///         ARBITRAGEURS to push the pool back to target — that is the entire economic function of
    ///         the curve. We restore 1:1 from the INSIDE via Curve, so there are no arbers to
    ///         compensate and nothing the spread would be funding.
    ///
    ///         WHAT REMAINS IS A REAL COST, AND IT IS NOT FREE: curving back to target pays Curve's fee
    ///         plus slippage, and it is incurred BECAUSE someone pushed the range off target.
    ///         ⇒ **THE COST SPLITS ACROSS ALL THREE** (owner, 2026-08-15, correcting an earlier
    ///         causer-pays-only reading). A range trade has **TWO SUPPLIERS, NOT ONE**: the volatile leg
    ///         is LP INVENTORY, the USD leg is BASKET CAPITAL (at rest ~246k of basket dollars against a
    ///         739k ETH deposit). The rebalance cost is therefore incurred against capital supplied by
    ///         both, and CAUSATION IS ONLY ONE AXIS. Each pure answer is a corner solution:
    ///           • swapper-only — ignores that LPs earn the fee lane *precisely for* carrying inventory
    ///             risk, so they are being paid for a cost they are not bearing;
    ///           • LP-only — socialises a large swapper's imbalance onto LPs who did not create it;
    ///           • basket-only — makes the basket fund a rebalance of depth it ALREADY supplied, paying
    ///             twice for one trade.
    ///         The split must be weighted by WHO TOOK THE RISK ON EACH LEG, which is the same test that
    ///         resolves the corner solutions.
    ///
    /// 🔴 THIS IS THE SAME QUESTION AS #12 (count-once) AND MUST BE SETTLED WITH IT.
    ///         #12 cannot be evaluated without stating who owns the PROCEEDS of a range→basket sale —
    ///         two suppliers, both corners wrong, the survivor being "credit the LP its inventory's
    ///         proceeds MINUS a depth fee". That is this split seen from the other side: one asks who
    ///         pays a cost, the other who receives a proceed, and both answer "apportion between the
    ///         two suppliers". Settle them together or they WILL drift apart.
    ///
    /// 🔴 OUT-OF-RANGE IS A FOURTH STATE AND IT BREAKS THE TWO-SUPPLIER SYMMETRY.
    ///         When the range is OOR it holds a SINGLE asset — the two legs have collapsed into one, so
    ///         "who supplied what" has a different answer entirely. The operation is also different: not
    ///         *restore 1:1* but *RE-ENTER RANGE*, a different cost with a different beneficiary. **A
    ///         split calibrated on an in-range range is simply WRONG when applied out of range**, and it
    ///         will not announce itself — it produces a plausible apportionment against the wrong basis.
    ///         ⚠️ NOT SOLVED HERE. Any split rule must state its OOR behaviour explicitly rather than
    ///         inheriting the in-range weights by default.
    ///
    ///         SO THE SKEW SURVIVES, WITH A DIFFERENT JOB. `wellSkew` measures the SCARCE side
    ///         (volatile-OUT drain — A&S's reservation price with the `q/(1−q)` pole, because you CAN
    ///         run out and the last unit is priceless); `sellSkew` measures the ABUNDANT side
    ///         (volatile-IN, LINEAR `Γσ²·q`, no pole, because YOU CANNOT RUN OUT OF SURPLUS — §E54).
    ///         Both are `public view`, so both directions are readable before settlement.
    ///
    /// 🔴 THE OPEN PIECE — BATCHING MAKES THE COST JOINT, SO ATTRIBUTION NEEDS A RULE.
    ///         The keeper rebalances in BATCHES so gas is amortised (#28). That means the actual Curve
    ///         cost is incurred PER BATCH and is not known at any individual swap's settlement time.
    ///         The shape that follows from "the causer pays": charge the measured skew at settlement
    ///         into a pot, pay the keeper's rebalance OUT of that pot, and let surplus/deficit accrue
    ///         to the fee lane — with each swapper's share of a batch's joint cost being PRO-RATA BY
    ///         THE SKEW THEY CONTRIBUTED. That reuses the skew for what it is actually good at: a
    ///         relative measure of who created how much imbalance.
    ///         ⚠️ NOT YET DECIDED, AND IT MATTERS: whether the settlement charge is a FINAL price or an
    ///         ESTIMATE trued up against realised cost. A final charge is a model (A-S) standing in for
    ///         a measurable fact (what Curve actually cost), which is the kind of substitution this repo
    ///         has been burned by. An estimate-plus-true-up is honest but needs somewhere to hold the
    ///         difference. DECIDE BEFORE WIRING `_applySkew` INTO A LIVE PATH.
    ///
    /// @dev    ⚠️ A QUOTE IS ONLY AS FRESH AS THE BLOCK IT WAS TAKEN IN. `sellSkew`'s own docblock says
    ///         so and says the binding must carry its own staleness bound — so `Quote.deadline` is NOT
    ///         optional garnish, it is the thing that stops a quote taken in a calm block from settling
    ///         in a violent one. A committed rate with no expiry is a FREE OPTION written to the swapper,
    ///         and the range is the counterparty who paid for it.
    /// A rate committed before execution, with the two bounds that make committing safe.
    /// @param rateWad     volatile↔USD rate INCLUSIVE of the skew charge. What settles.
    /// @param maxSizeIn   inventory bound — the largest input this quote is valid for.
    /// @param skewWad     the imbalance charge folded into `rateWad`, surfaced so the swapper can
    ///                    see what they are being charged for the imbalance THEY create.
    /// @param deadline    unix seconds after which this quote is void. See the staleness note above.
    struct Quote {
        uint256 rateWad;
        uint256 maxSizeIn;
        uint256 skewWad;
        uint64  deadline;
    }

    error QuoteExpired();
    error SizeExceedsInventory();
    error ConservationViolated();
    error NoQuote();

    /// @notice Quote a DRAIN — volatile out of the range, the scarce direction.
    /// @param  core     the Core holding the pooled accumulators the skew reads.
    /// @param  base     the oracle price (the SAME base `wellSkew` takes; the WBTC ×1e10 lift already
    ///                  closes the 8↔18 gap, so one flat scale serves both assets — do NOT add a
    ///                  second ×1e10 "to fix BTC", it double-counts).
    /// @param  wantUsd6 the volatile-out this swap will take, 6-dec USD. Size-AWARE deliberately:
    ///                  passing 0 gives the Δ→0 instantaneous rate, which is a DASHBOARD signal and
    ///                  NOT a settlement quote. A settlement quote must pass its real size, or the
    ///                  swapper is charged for an imbalance smaller than the one they create.
    function quoteDrain(address core, uint base, uint wantUsd6, uint64 ttl)
        internal view returns (Quote memory q)
    {
        if (wantUsd6 == 0) revert NoQuote();          // a zero-size settlement quote is a category error
        q.skewWad   = wellSkew(core, base, wantUsd6);
        q.rateWad   = _applySkew(base, q.skewWad, true);
        q.maxSizeIn = wantUsd6;                        // the quote is valid for THIS size, not more
        q.deadline  = uint64(block.timestamp) + ttl;
    }

    /// @notice Quote a FILL — volatile into the range, the abundant direction.
    /// @param  addedTok the volatile being deposited. Passed so the sell is judged on inventory AFTER
    ///         its own contribution — a pool sitting exactly at target would otherwise never charge
    ///         any sell, however large (the §E54 note on `sellSkew`).
    function quoteFill(address core, uint base, uint addedTok, uint64 ttl)
        internal view returns (Quote memory q)
    {
        if (addedTok == 0) revert NoQuote();
        q.skewWad   = sellSkew(core, base, addedTok);
        q.rateWad   = _applySkew(base, q.skewWad, false);
        q.maxSizeIn = addedTok;
        q.deadline  = uint64(block.timestamp) + ttl;
    }

    /// @dev The skew moves the rate AGAINST the swapper in both directions — it is a spread, not a
    ///      directional view. On a drain the range parts with scarce inventory and charges MORE per
    ///      unit; on a fill the range absorbs unwanted inventory and pays LESS per unit. Symmetric by
    ///      construction, which is what makes it a spread rather than a fee with a sign bug.
    function _applySkew(uint base, uint skewAmt, bool draining) private pure returns (uint) {
        return draining
            ? base + (base * skewAmt) / 1e18
            : base - (base * skewAmt) / 1e18;
    }

    /// @notice Enforce a quote at settlement time. Both bounds, or the commitment is not a commitment.
    function enforce(Quote memory q, uint sizeIn) internal view {
        if (block.timestamp > q.deadline) revert QuoteExpired();
        if (sizeIn > q.maxSizeIn)         revert SizeExceedsInventory();
    }

    // §E304 — THE THREE-WAY SPLIT IS DELETED: `Split`, `splitCost`, `requireNonAbusable` and their
    // three errors, ~95 lines, plus `FillAndBatch.t.sol` which tested nothing else.
    // §E301 settled that **the swapper pays** and that *"the question 'who affords the restoration'
    // … has no referent. There is no restoration we perform."* `splitCost` apportioned a
    // `realisedCost` — "measured cost of the rebalance" — three ways, and `requireNonAbusable` guarded
    // that split's weights. **With no rebalance there is no `realisedCost` to split and nothing to
    // guard.** Both were `internal pure` with ZERO production callers, so this frees no deployed
    // bytecode from any contract; it removes a mechanism the design retired and a test that pinned it.
    // ⚠️ The anti-grinding bound `w >= 1 - fee/C` lived HERE and nowhere else. §E226 cited it as a
    // reason to keep the flat 420 ppm; it gated nothing on the fill path then and is gone now
    // (`Core.sol:1179` records that). Do not re-derive it from that comment.

    // ─────────────────────────────────────────────────────────────────────────────
    // CONSERVATION — the ONE property worth keeping from v4's `unlockCallback`
    // ─────────────────────────────────────────────────────────────────────────────
    /// @notice v4's flash accounting reverts unless every delta nets to zero. That is a CONSERVATION
    ///         PROOF, and it is SEPARABLE from the two things it was bundled with: PRICING (ticks,
    ///         √P) and CUSTODY (the PoolManager holding the funds). We keep the proof and drop the
    ///         other two — the accumulators it protects (`POOLED_*`) live in `Core`, never in v4, so
    ///         nothing about them changes when the AMM leaves.
    ///
    ///         SHAPE: snapshot our own balances → run the settlement → assert the deltas net. Same
    ///         guarantee, no external singleton, no callback re-entry surface.
    ///
    /// @dev    ⚠️ THIS EARNS ITS PLACE UNDER STANDING RULE 3 PRECISELY BECAUSE THE FAILURE IS SILENT.
    ///         A settlement that moves the wrong amount does not announce itself: it produces a
    ///         plausible balance and a wrong `POOLED_*`, and the error compounds into share pricing
    ///         where nobody can attribute it later. That is the discriminator the rule names — a
    ///         check is justified when violating it would be silent and produce plausible-but-wrong
    ///         output. It is NOT a clamp on a reachable bad state; it is a proof obligation.
    /// @param  expectedOut what the quote committed to deliver.
    /// @param  actualOut   what the settlement actually moved, measured as a BALANCE DELTA — never a
    ///                     number reported by the code under test, or the check reads its own output.
    function assertConserved(uint expectedIn, uint actualIn, uint expectedOut, uint actualOut)
        internal pure
    {
        // EXACT. No tolerance: a tolerance here is the thing that makes a real defect pass, and the
        // amounts are integers under our own control on both legs — there is no rounding source that
        // a correct settlement would produce.
        if (actualIn != expectedIn || actualOut != expectedOut) revert ConservationViolated();
    }

}




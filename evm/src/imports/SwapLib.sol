// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
// §A.52: the canonical view (was a file-local `IBasketTurn2`).
import {IBasketTurn} from "./Interfaces.sol";   // §rule-2: Interfaces.sol is the canonical declaration site
                                                     // (BasketLib only RE-imports it, so importing from there does not resolve)
// §A.52: the canonical Core view (was a file-local variant).
import {ICore} from "./Interfaces.sol";
import {ILevManagerDeliver, ILevEthDeliver} from "./Interfaces.sol";
import {IBTCChannels} from "./Interfaces.sol";
import {IEthVenue, IBandManager} from "./Interfaces.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
// §A.52: the SHARED WETH view (was a file-local `IWethDeposit` declaring just `deposit()`).
import {IWETH9} from "./ILevVenue.sol";
// §A.52: canonical shared views — these were file-local `IWeEth_L`/`IRedeem_L`/`ILiq_L`.
import {IWeETH, IEtherFiLiquidityPool, ICurvePool} from "./Interfaces.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
// §E68 — `lnWad` for the drain kernel's INTEGRAL (solmate has no lnWad; solady does, and is
// already remapped). Aliased so it cannot be confused with solmate's same-named library above.
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {BasketLib} from "./BasketLib.sol";
import {FeeLib} from "./FeeLib.sol";
import {ShareMath} from "./ShareMath.sol";
import {SOR} from "./SOR.sol";
import {Types} from "./Types.sol";
import {LevMath} from "./LevMath.sol";
import {IAux} from "./Interfaces.sol";
import {IAggregatorV3} from "./Interfaces.sol";

// ether.fi offramp interfaces (suffixed `_L` to avoid clashing with Aux's own
// copies, since Aux imports SwapLib). Same signatures as Aux's.
// outputToken ∈ {0xEeee…EEeE native-ETH sentinel, stETH} — else InvalidOutputToken.
/// Chainlink-style USD feed — the external anchor for the TWAP cross-check.


/// @notice V4 (Vogue) repack. 5th return = the resolved oracle price (Chainlink-when-stale, else internal
///         TWAP) computed during the repack-first; the swap reuses it as v4Price so it doesn't read the
///         internal `observe` ring a 2nd time. 0 ⇒ live-read fallback. (Was two identical decls
///         IVogueRepack2/IVogueRepackRet — now collapsed onto the CANONICAL `IEthVenue.repack`
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

    // REMOVED: arbBody — the shared ETH/BTC shortfall buy from basket free surplus
    // (the "arbETH"/"arbBTC" body). Both callers were removed as the toxic surplus-
    // funded make-whole: spending the SHARED safety margin to patch a usually-
    // impermanent inventory shortfall compensates the flow at every claimholder's
    // expense. ETH-pool IL is borne fairly via the share price; BTC settles only via
    // the hop (real BTC, no basket stables). Frees library bytecode (helps EIP-170).

    /// @notice Body of Aux.getTWAPforAsset — moved here to free Aux
    /// bytecode. `core` is Core; reads its observation ring.
    function twapBody(address core, address weth, address asset, uint32 period)
        external view returns (uint price) {
        bool isETH = asset == weth;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period == 0 ? 1800 : period;
        secondsAgos[1] = 0;
        uint192[] memory pc = ICore(core).observe(secondsAgos, !isETH);  // §E63: one dispatched observe
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
        // the band could never be re-paired (measured: 8 repacks during the crash, 0 addLiq, with
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
    /// Returns (vbtcDelta, swept): caller adds vbtcDelta to vogueBTC and
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
            return (swept, swept); // caller adds to vogueBTC inventory
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

    /// @notice Body of Aux.vogueOp. Wrapper enforces `msg.sender == V4`
    ///         BEFORE delegating; library trusts that gate. State
    ///         mutations route via supplySelf / withdrawSelf (self-gated).
    ///
    ///         The `weth` / `wbtc` immutables come from Aux's storage; we
    ///         pass them as args rather than re-fetching to avoid extra
    ///         external calls back. `vogueBTC` and `_vogueETHPrincipal`
    ///         are touched ONLY indirectly: vogueBTC via Aux's storage
    ///         pointer (passed by ref), principal via supplySelf's
    ///         internal _supply which updates it.
    /// @notice ETH-side Vogue↔Vault op body. The BTC ops that once shared this
    ///         entry (op==1 native/Lightning out, op==3 WBTC ERC20 delivery, and
    ///         the isBTC branches of op 0/2) were DEAD — every caller passes
    ///         isBTC=false and vogueBTCNow=0 (Vogue routes BTC through BTCChannels,
    ///         not here). Removed along with the now-redundant result struct and
    ///         the isBTC/wbtc/ctx/vogueBTCNow params. op 0=deposit, 1=take, 2=read.
    function vogueOpBody(uint amount, uint8 op, WETH9 weth, uint vogueETHLive)
        external returns (uint sent) {
        IAux aux = IAux(address(this));
        // op == 1: take ETH, capped at the live vogueETH claim.
        if (op == 1) {
            amount = Math.min(amount, vogueETHLive);
            sent = aux.withdrawSelf(address(weth), amount, address(this));
            weth.transfer(msg.sender, sent);
            return sent;
        }
        // op == 2: read current ETH claim.
        if (op == 2) return vogueETHLive;
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

    /// @dev Resolve the execution price: the repack-provided v4 mark if non-zero, else the live oracle TWAP.
    ///      Factored from the 5 swap-body sites — no-optimizer build ⇒ ONE shared body (jump target), not 5
    ///      inlined copies of the getTWAPforAsset call, so it genuinely reclaims deployed bytecode (EIP-170).
    ///      §D3 (2026-07-31): this claim was ASPIRATIONAL until now — two verbatim inline copies survived
    ///      in `swapToBody`, tagged "stack-tight", because a CALL in argument position blew the no-`via_ir`
    ///      stack. Fixed by resolving once into the `SwapReq.px` STRUCT FIELD (no new stack slot) and
    ///      SEQUENCING the call out of argument position. Freed 197 bytes. `Stack too deep` is a code-shape
    ///      problem, never a licence to duplicate.
    function _priceOr(uint v4p, address aux, address asset) internal view returns (uint) {
        return v4p != 0 ? v4p : IAux(aux).getTWAPforAsset(asset, 1800);
    }
    /// @dev Revert unless `token` is a real basket stable (toIndex>0). Factored from creditSwapIn/OutBody (dedup).
    function _requireStable(address aux, address token) internal view {
        if (IAux(aux).toIndex(token) == 0) revert StableMissing();
    }

    error BadAsset();
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
        address v4; address btcVault; address btcChannels;
    }

    /// @notice Body of Aux.swapTo — delegatecall'd (address(this)==Aux), so the
    ///         IAux callbacks (deposit/_depositVol/_tipSelf/withdrawSelf/
    ///         get_deposits/getTWAPforAsset/tokens/toIndex/bumpVogueBTC) and the
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
        address inToken;   // #105: the actual INPUT token (set inside swapToBody) for the partial-fill refund
        uint px;           // §D3: resolved oracle price, set inside swapToBody. A STRUCT FIELD, not a
                           // local, so both skew branches share `_priceOr` WITHOUT adding a stack slot —
                           // that is what makes the dedup fit under the no-`via_ir` stack budget.
    }

    function swapToBody(SwapReq memory r, SwapToCfg memory c, address[] memory stables)
        external returns (uint max) {
        if (r.asset != c.weth && r.asset != c.wbtc) revert BadAsset();
        bool isBTC = r.asset == c.wbtc;
        if (!r.forVolatile && isBTC) revert BtcInflowsViaChannels();
        IAux aux = IAux(address(this));
        bool stable = aux.toIndex(r.token) > 0;
        // #105: capture the actual INPUT token for the partial-fill refund BEFORE the forVolatile branch
        // zeros r.token — volatile-in = the asset, stable-in = the token, QD-in = 0 (burned => unrefundable).
        r.inToken = r.forVolatile ? (r.token == c.quid ? address(0) : r.token) : r.asset;
        if (r.forVolatile && isBTC && r.recipient != address(this)) {
            if (IBTCChannels(c.btcChannels).btcRecipientOf(r.recipient) == bytes32(0)) revert NoBtcRecipient();
        }
        // _buildContext(asset): ETH-side vault always address(0) (dispatched to
        // GALAXY via the venue); nativeWETH on ETH.
        Types.AuxContext memory ctx = Types.AuxContext({
            asset: r.asset, vault: address(0), core: c.core,
            nativeWETH: !isBTC
        });
        // E9: capture the band's OWN tick range from the repack we already run. These were
        // discarded before, and `sqrtPriceX96` was then handed to `Core.swap` only to be thrown
        // away in `_handleSwap` — so the swap ran to the TICK EXTREME. Measured consequence
        // (`PooledUsdRepackMatrix::testMatrix_S6`): a swap crossing `tickUpper` with input left
        // drove the spot to `MAX_SQRT_PRICE - 1` moving ZERO tokens, which corrupts every price
        // read (`getPrice` truncates to 0) and bricks the band. The edge is the honest limit.
        // Block-scoped so `lo`/`hi`/`p` are freed at its end: `swapToBody` is stack-tight by
        // design (`via_ir = false`), and carrying the two ticks as function-scope locals is
        // stack-too-deep. Net locals are UNCHANGED from before — `bandTicks` simply replaces the
        // old `sqrtPriceX96` carrier, which was assigned, reassigned and passed, never read.
        uint160 bandTicks; uint v4p;
        {
            (, int24 lo, int24 hi,, uint p) = isBTC
                ? IBandManager(c.btcVault).repack(true)
                : IBandManager(c.v4).repack(false);
            v4p = p;
            bandTicks = _packBandTicks(lo, hi);
        }
        {
            // Drain-side backing gate counts standing holdings at PAR (NOT the depeg haircut): the mint/issuance
            // side haircuts depeg (Core band-add + mint-headroom) to block over-mint, but the drain side stays at
            // par so a transient depeg can't brick redeems/swaps for existing holders (intentional asymmetry;
            // redeem VALUE is separately haircut in _redeemQuote). See DepegBackingProbe.
            (uint[15] memory _deposits,,,) = aux.get_deposits();
            if (ICore(c.core).committedUsd18() > _deposits[14]) revert UnderBackedS();
        }
        // token1is inlined per-branch (not a local) — frees a stack slot so
        // swapToBody stays within the legacy pipeline (no via_ir) after threading
        // the reused v4 price `v4p`. One executed branch ⇒ still one token1is call.
        bool zeroForOne;
        if (!r.forVolatile) {
            if (r.token != c.quid && !stable) revert StableMissingS();
            r.amount = aux._depositVol{value: msg.value}(isBTC, msg.sender, r.amount);
            zeroForOne = !ICore(c.core).token1is(isBTC);
            max = ICore(c.core).POOLED_USD();
            // JIT-DEPTH-GUARANTEE.md §2 hook site (DEFERRED — design gap, NOT built): this is the
            // volatile→USD leg whose fill is bounded by the band's in-range USD depth (`max`), so a
            // large sell can exhaust it / partial-fill → uncertain impact → sandwich room. The
            // guarantee would, before executing, top USD depth up to what `r.amount` needs within a
            // target impact bound (tryPair: idle band USD → unwindForRedeem-inverse → redeem mature
            // QUID→addLiq) then unwind it post-swap. Three unresolved blockers keep it out for now:
            //   (1) NO impact formula: the spec's "USD depth needed within a target impact bound" is
            //       "a pure function of size + current in-range depth" but gives neither the function
            //       nor the target bound value;
            //   (2) place+unwind-in-ONE-tx is INCOMPATIBLE with the existing outOfRange/pull
            //       primitive — pull() enforces `block.number >= created + 47`, so an outOfRange
            //       position cannot be unwound in the same block (Vogue.sol pull());
            //   (3) this body runs DELEGATECALL'd in Aux context; a mid-swap re-entry into Vogue's
            //       onlyUs addLiq/unwindForRedeem on the SHARED band needs its reentrancy + price-
            //       impact interaction with the V4 unlock callback worked out.
            // SYMMETRIC A-S skew (its own frame ⇒ no via_ir): a sell that pushes the pool's
            // volatile inventory PAST target is inventory-INCREASING (the self-funded short's
            // band-leg shed) ⇒ charge the same A-S premium the drain does; a sell that REFILLS
            // a scarce reservoir REDUCES imbalance ⇒ sellSkew's mirror+flush yields 0 (EXEMPT).
            // Scale the volatile input DOWN by the premium ⇒ less USD credited out; the
            // withheld input stays as basket backing (same mechanism as the drain leg).
            {
                r.px = _priceOr(v4p, address(aux), r.asset);
                uint skew = sellSkew(c.core, r.px, isBTC, r.amount); // inline (swapToBody stack-tight)
                retainSkewPremium(c.core, isBTC, r, skew, true);   // NATIVE volatile input ⇒ convert   // mutates r.amount; r.px declares NATIVE
            }
        } else { max = ICore(c.core).POOLED();
            zeroForOne = ICore(c.core).token1is(isBTC);
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
            // the honest oracle (v4p) through routeSwap ⇒ no manip-guard exemption.
            {
                r.px = _priceOr(v4p, address(aux), r.asset);
                uint skew = wellSkew(c.core, r.px, isBTC, r.amount); // §E68: r.amount IS the 6-dec drain size
                retainSkewPremium(c.core, isBTC, r, skew, false);  // buy-driving USD ⇒ already 6-dec   // mutates r.amount; r.px declares NATIVE
            }
        }
        max = _finishSwap(ctx, aux, r, bandTicks, zeroForOne, max, isBTC, v4p);
    }

    /// @dev routeSwap (8-field RouteParams build) + bumpVogueBTC + slippage guard
    ///      in its own frame so swapToBody stays within the legacy stack — no
    ///      via_ir crutch.
    /// @dev Pack the band's tick range into one word. Two int24 function-scope locals are
    ///      stack-too-deep in `swapToBody`; one packed carrier is not. int24→uint24→int24 is
    ///      bit-preserving, so negative ticks round-trip exactly.
    function _packBandTicks(int24 lo, int24 hi) private pure returns (uint160) {
        return uint160((uint(uint24(lo)) << 24) | uint(uint24(hi)));
    }

    function _finishSwap(Types.AuxContext memory ctx, IAux aux, SwapReq memory r,
        uint160 bandTicks, bool zeroForOne, uint pooled, bool isBTC, uint v4p) private returns (uint max) {
        uint poolSupplied;
        // Reuse the resolved oracle price from the repack-first (v4p) instead of
        // re-reading the internal `observe` ring + Chainlink a 2nd time per swap;
        // fall back to a live read only if the repack couldn't resolve it (v4p==0,
        // e.g. a bootstrap pre-history read that try/catch'd to 0).
        uint v4Price = _priceOr(v4p, address(aux), r.asset);
        uint consumed;
        (max, poolSupplied, consumed) = BasketLib.routeSwap(ctx, Types.RouteParams({
            sqrtPriceX96: bandTicks, zeroForOne: zeroForOne, token: r.token,
            amount: r.amount, pooled: pooled,
            v4Price: v4Price,
            recipient: r.recipient, isBTC: isBTC
        }));
        if (poolSupplied > 0 && isBTC) aux.bumpVogueBTC(poolSupplied);
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
    ///      SCALE (CRITICAL): ShareMath.qdShareValue returns 18-dec USD (redeem feeds it to 18-dec take()), but
    ///      the SWAP pipeline (routeSwap→convert→POOLED_USD_*→Core.swap) is 6-dec. Feeding the 18-dec value
    ///      straight in made `min(amount, poolCap6)` always pick the 6-dec pool cap → ~1e12x over-delivery of
    ///      pool volatile for dust QD burned (a drain). Down-scale to 6-dec here so the swap sizes on the true
    ///      USD value; the dropped ≤1e12 sub-unit dust is immaterial to a USD amount.
    function _consumeQdIn(IAux aux, address quid, uint amount, address[] memory stables)
        private returns (uint) {
        (uint burned, uint seedBurned) = IBasketTurn(quid).turn(msg.sender, amount);
        uint solvent;
        {   (uint[15] memory d, uint[15] memory yW,, uint dl) = aux.get_deposits();
            // yW[0] = Σ balance×rate (the annualised-rate numerator), NOT d[0] = Σ yieldWeighted.
            (solvent,) = aux.get_metricsWith(d[14], yW[0]);
            solvent = solvent > dl ? solvent - dl : 0; }
        amount = ShareMath.qdShareValue(burned, solvent, IBasketTurn(quid).matureSupply() + burned) / 1e12;
        if (seedBurned > 0) {
            uint n = stables.length;
            for (uint i = 0; i < n; i++) {
                address s = stables[i];
                aux.tipSelf(FullMath.mulDiv(aux.tranche(s), seedBurned, burned), s, -1);
            }
        }
        return amount;
    }

    // ─── ether.fi offramp (extracted from Aux to free bytecode) ──────────────
    // Immutables/consts passed in via OfframpCfg (the library can't read Aux's
    // immutables). The msg.sender==V4 gate stays in the Aux wrapper; these bodies
    // run via DELEGATECALL so address(this)==Aux (its weETH, its caller id).
    // (ETHFI_NATIVE_ETH removed 2026-08-09 — it was the RedemptionManager output-token sentinel for the
    //  instant-redeem rung deleted 2026-08-05/06, and had no use site after that.)

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
        uint fairWeth = FullMath.mulDiv(want, weethIn, weethFull);
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
    /// @param bandVault THE BTC VAULT, not Vogue. It was named `v4` — which means Vogue/ETH everywhere
///        else — while `Vault.creditSwapIn` passes `address(this)`. That is why `repack(true)` below
///        is CORRECT and must not be "fixed" to false during the isBTC fold.
    function creditSwapInBody(address seller, uint sats, address token, uint minDeliveredUsd,
        address core, address bandVault, address wbtc, address aux) external returns (uint consumedSats) {
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
        // added v4p reuse fits this body's legacy stack without via_ir — the literal
        // construction peak is what overflowed. vault=0 / nativeWETH=false are the
        // zero-defaults of a fresh memory struct.
        Types.AuxContext memory ctx;
        ctx.asset = wbtc; ctx.core = core;
        // Reuse the repack-resolved oracle price (5th return); live-read only if
        // v4p==0 — same as _finishSwap. POOLED_USD is passed RAW: `convert` now uses a flat
        // 1e18 for both assets, so the reserve converts to its true sats-equivalent directly. The
        // former ×1e10 pre-scale here CANCELLED convert's 1e18/1e8 under-scaling — two wrongs that
        // agreed on this path only; both are removed together, leaving this path unit-neutral.
        // §E9 — this field now carries the BAND'S PACKED TICKS, not a price. `Core._handleSwap`
        // unpacks it into the swap's `sqrtPriceLimitX96`. ALL THREE producers must agree: this one,
        // `_swapOutPrep` below, and `_finishSwap`. Passing a real sqrtPriceX96 here is what broke
        // 132 tests (`InvalidTick` / `PriceLimitAlreadyExceeded`) when only one was converted.
        // Block-scoped: these bodies are stack-tight by design (`via_ir = false`).
        uint v4p;
        Types.RouteParams memory rp;
        {
            (, int24 lo, int24 hi,, uint p_) = IBandManager(bandVault).repack(true);
            v4p = p_;
            rp.sqrtPriceX96 = _packBandTicks(lo, hi);
        }
        rp.zeroForOne   = !ICore(core).token1is(true);   // BTC→USD (mirror of the buy)
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
        // (`Vault.registerBtcLp`) as the PRIMARY, self-funding path, plus the still-unbuilt ACTIVE
        // flash-serve (#100 / J.3) — flash the scarce asset, serve the opposite flow, repay, premium
        // stays with LPs. A flash-and-repay, never a subsidy to whoever swaps in first.
        rp.v4Price = _priceOr(v4p, aux, wbtc);
        rp.recipient    = seller;
        rp.isBTC        = true;
        // routeSwap + both gates + the refill bonus run in their OWN frame (_swapInSettle) so
        // creditSwapInBody stays within the legacy stack (no via_ir). Returns the sats actually converted so
        // the hop can refund any inventory-bounded remainder.
        consumedSats = _swapInSettle(ctx, rp, minDeliveredUsd);
    }

    /// @dev Own-frame tail of creditSwapInBody: base swap + minDeliveredUsd floor + solvency gate. NO refill
    ///      BONUS (removed 2026-07-22): the refill is a self-funding fleet op (JIT Morpho-flash BTC →
    ///      creditSwapIn → repay, gas via #87), so the drainer's retained skew premium accrues to LPs as
    ///      backing (recordSkewPremium) rather than being paid out to the refiller — the refill settles at the
    ///      honest v4Price. Serves the creditSwapIn rail
    ///      (JIT sell-to-pool reward); registerBtcLp (become-LP, pooled fees) never reaches here.
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

    // Skew curve bounds. MAX_WELL_SKEW is the hard TWAP-anchor cap: the
    // effective-rate premium can never exceed this regardless of how scarce/volatile the
    // pool gets, so oracle-lag can't be amplified into a toxic overpay at the edge. Sized to
    // cover a native-BTC MM's real drain-edge cost (splice fee + capital-through-confirmation
    // ~ a few %).
    /// §E62 — NO LONGER A CAP ON THE DERIVED CURVE. Its ONE remaining job is to price the case we
    /// cannot measure: `_maxWellSkew` returns it when `σ² == 0` (unknown, not calm — §E59), and the
    /// kernel uses it as the Γ scale. The derived path (`σ²·confFrac/8`) is now UNCLAMPED, because
    /// clamping a measured expected cost at an asserted number could only make us UNDER-charge, and
    /// it bound precisely in the high-vol regime where the skew matters most.
    uint internal constant MAX_WELL_SKEW = 3e16;   // 3% — the UNKNOWN-variance value
    // Avellaneda–Stoikov calibration. `realizedVarianceWad` is ANNUALIZED realized
    // variance in WAD (VogueLib:294-318: tickVar·(SECS_PER_YEAR/THETA_STEP)·1e10 ⇒ a
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
    // Volatile band half-width, in bps of price (paddedSqrtPrice reads it as (10000±delta)/10000).
    // THIN band (±0.2%). Vogue SERVES swaps and RESEATS, so it can't go to a literal one-tick like a static
    // static position: at delta=10 the reseat re-add (updateTicks(targetSqrt,10)) collapses lower==upper and V4
    // reverts. 0.2% is the thinnest that keeps the reseat re-add non-degenerate while staying maximally thin
    // (near-zero natural slippage, whale-friendly). Frequent repacks are covered by repack-first (swapper-paid)
    // + the self-funded reseat keeper — no separate gas budget needed.
    uint internal constant BAND_DELTA = 20;

    // DYNAMIC CAP calibration. Instead of a fixed 3%, the ceiling tracks the native-BTC MM's
    // REAL drain-edge cost, which is dominated by the BTC-price risk while its capital is
    // locked from committing sats until the swap-in settles + it holds the USD (~6 confs ≈ 1
    // hour). That cost ≈ σ over the confirmation window · a safety multiple + the splice fee.
    uint internal constant CONF_FRAC_WAD = 114_000_000_000_000; // ≈ 1hr / 1yr (WAD) — confirmation-window fraction of a year
    uint internal constant SPLICE_FLOOR  = 2e15;                // 0.2% — on-chain splice-fee floor (the feerate term)
    // ETH settles in ~one block — NO ~1hr confirmation-capital lock and NO splice — so its cap uses a
    // one-block settlement window and a zero splice floor. Charging ETH the BTC 1hr window over-priced its cap.
    uint internal constant ETH_CONF_FRAC_WAD = 380_000_000_000; // ≈ 12s / 1yr (WAD) — one-block settlement window

    /// @notice DYNAMIC skew cap — the MM's real refill cost DERIVED from live volatility, not a
    ///         fixed 3%: √(σ²_annual · T_confs/yr) (the price σ over the window the MM's capital
    ///         is at risk) · CAP_SAFETY + SPLICE_FLOOR, hard-capped at MAX_WELL_SKEW (the
    ///         TWAP-anchor safety ceiling). Low vol ⇒ low cap (don't overpay refill); high vol ⇒
    ///         higher cap (real cost is higher); never above 3%. `pure`; reuses
    ///         FixedPointMathLib.sqrt (a WAD variance → WAD std needs the ×1e18 inside the root).
    function _maxWellSkew(uint sigmaSqWad, bool isBTC) internal pure returns (uint) {
        // PER-ASSET settlement window: BTC locks capital through ~1hr of confirmations (CONF_FRAC_WAD) + an
        // on-chain splice-fee floor; ETH settles in ~one block with no confirmation lock and no splice.
        uint confFrac = isBTC ? CONF_FRAC_WAD : ETH_CONF_FRAC_WAD;
        // §UNIT-B-PATIENCE — σ² IS ATTACKER-STRETCHABLE AND THIS WINDOW DOES NOT DEFEND IT.
        // σ² is a per-unit-time rate whose ring advances only on swaps, so spacing slices collapses it
        // (MEASURED: 4h gaps → σ² 24× down, charge 93.3% down). Pricing this base over the ACTUAL idle
        // window was built and measured: it moves the charge ~1% because the base is ~0.002% of it, and
        // it cost 378 bytes + 2 staticcalls/swap, so it was REVERTED. The vector sits in the KERNEL's
        // σ² linearity. See §UNIT-B-PATIENCE / §UNIT-B-PATIENCE-STEP2 before attempting either again.
        // LVR = σ²/8 per unit time (Milionis-Moallemi-Roughgarden-Zhang arXiv:2208.06046 eq.16: for a
        // constant-product pool the loss per unit time as a fraction of pool value is exactly σ²/8).
        // This is the EXPECTED cost of the displacement being arbitrageable over the settlement
        // window. CAP_SAFETY (=2) was a 2σ WORST-CASE multiple — a risk-aversion choice, i.e. γ under
        // another name, and the only reason a BTC swap capped near 127bps rather than its measured
        // expected cost. The /8 is constant-product geometry, derived; the window is chain physics.
        // §E59 — UNKNOWN VARIANCE MUST NOT PRICE AS ZERO VARIANCE.
        //
        // `sigmaSqWad == 0` is overwhelmingly the "we could not measure it" sentinel, not a reading
        // of a genuinely still market: `realizedVarianceWad` samples `observe` on a WALL-CLOCK grid
        // while the observation ring only advances ON A SWAP, and `observe` LINEARLY INTERPOLATES
        // between stored points — so any stretch quieter than the sample interval has zero second
        // difference and yields EXACTLY 0. MEASURED: a drain that took POOLED from 400 to
        // 0.00097 ETH — a total inventory wipe — reported variance 0.
        //
        // Feeding that 0 through the formula gave `cap = 0` on ETH (which, unlike BTC, has no
        // SPLICE_FLOOR), and a zero cap means **a fully drained band charges NOTHING at maximum
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
        return FullMath.mulDiv(sigmaSqWad, confFrac, 8e18) + (isBTC ? SPLICE_FLOOR : 0);
    }

    /// @notice The convex inventory-skew CURVE — returns a WAD skew FRACTION
    ///         (0..MAX_WELL_SKEW), not a price. Applied as an effective-rate scalar on the
    ///         swap-OUT (drain) leg: a scarce pool hands out less volatile per unit input, so
    ///         the imbalance-causer pays a scarcity premium and the withheld input stays as
    ///         basket backing (funding the pool's ability to pay a refill). Re-admits the
    ///         benign inventory-rebalancing arber WITHOUT the toxic LVR one: the swap itself
    ///         still executes at the honest oracle through routeSwap (the manip-guard sees an
    ///         UNSKEWED price ⇒ no exemption needed) — the skew is a separate output scalar,
    ///         which is precisely what lets it exceed the band's ±50-bps ceiling in a genuine
    ///         drought (the band + in-window benign arb own the near-target regime; the skew
    ///         is a TAIL layer that only bites past what the band can express).
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
    ///         steepening term). The flush guard (inv≥target ⇒ 0, band owns the common case)
    ///         and the MAX_WELL_SKEW hard cap are preserved.
    function skewWad(uint poolVolUsd, uint flowUsd, uint sigmaSqWad, bool isBTC, uint drainUsd6)
        public pure returns (uint skew)
    {
        // §E68 — `lockedUsd` and `committedUsd` DELETED FROM THE SIGNATURE, not merely unused. E58
        // removed both from the arithmetic and left the parameters behind; they appeared nowhere but
        // this line and the note below, so they were dead surface costing stack at a call site that
        // is annotated stack-tight. Removing them is behaviour-neutral BY CONSTRUCTION (an unread
        // argument cannot change a pure function's output), so it does not confound the one real
        // change in this run — the `drainUsd6` size thread.
        // §E58 — BOTH LEVERAGE TERMS DELETED (owner: *"leverage shouldn't be perceived by this skew
        // at all… whether levered or not, in the band is in the band alike"*). They entered TWICE and
        // both inflated scarcity: `inv` SUBTRACTED `lockedUsd` (levered GROSS collateral — which IS
        // band depth), and `target` ADDED `committedUsd` (the leverage DEBT). Together they made the
        // band read scarcer than it is by an amount that SCALES WITH THE LEV BOOK.
        //   The skew prices the cost of SHEDDING volatile the band holds. How an LP FINANCED its
        //   participation is not a property of that inventory: it is in the band either way, and a
        //   levered position is collateralised and unwindable (`closeLev` repays debt and returns
        //   collateral), so it never consumes the band's shed capacity. Nothing about a levered LP
        //   changes how hard it is to sell the band's ETH.
        //   What remains IS the E54 derivation: scarcity is inventory against the flow we shed into.
        uint target = flowUsd;
        // §UNIT-A — RETURN THE BASE, NOT ZERO. This sat ABOVE `_maxWellSkew`, so a fresh OR idle
        // band charged NOTHING: not the kernel, not `σ²·confFrac/8`, not `SPLICE_FLOOR`. §E98
        // measured BTC's floor never applying on a fresh band; §E99 measured a 30-day-old imbalance
        // pricing at 0; and `wellSkew` read 0 at σ² = 4.09 on a violent tape, proving the base is
        // unreachable INDEPENDENT of variance.
        if (target == 0) return _maxWellSkew(sigmaSqWad, isBTC);
        // §E68 — THE DRAIN IS NOW SIZE-AWARE, AND THIS IS WHERE THE LEAK WAS.
        //
        // `inv` used to be read PRE-swap and the flush test used to be `inv >= target ⇒ 0`. Two
        // separate defects fell out of that, both MEASURED as present:
        //   1. SIZE-BLINDNESS. `q` was the pre-swap LEVEL, so a $1 drain and a drain-the-reservoir
        //      quoted the IDENTICAL premium. Nothing about the swap's own magnitude reached the
        //      kernel — the rate was a property of the pool alone.
        //   2. THE FLUSH HOLE, which is the worse of the two. If the band sat AT OR ABOVE target,
        //      the pre-swap test returned 0 for EVERY size, so a single trade could convert the
        //      WHOLE inventory and pay NO skew at all — it only ever paid the band's ~10 bps
        //      cushion. The premium began only on the NEXT trade, by which time the inventory was
        //      already gone. That is the "one trade converts the band for ~10 bps" leak.
        // Both die the same way: evaluate scarcity on the inventory this swap LEAVES BEHIND, and
        // charge the average rate along the path from where it started to where it ends.
        uint inv0 = poolVolUsd;                           // pre-swap deliverable inventory
        uint inv1 = drainUsd6 >= inv0 ? 0 : inv0 - drainUsd6;   // what the drain LEAVES
        // Flush now means flush AFTER the drain. A swap that ends at/above target created no
        // scarcity and is genuinely free; a swap that ENDS below it is charged for the crossing,
        // however flush the band looked before it. Size-blindness cannot survive this test.
        // §UNIT-A — THE FLUSH OWES THE BASE TOO. A well-stocked band is not an UNEXPOSED one: the
        // settlement-window loss accrues whether or not inventory is scarce, so only the DEPLETION
        // (kernel) term flushes away, never the adverse-selection floor.
        if (inv1 >= target) return _maxWellSkew(sigmaSqWad, isBTC);
        uint q1 = (target - inv1) * 1e18 / target;        // post-swap scarcity ∈ (0, 1e18]
        uint q0 = inv0 >= target ? 0 : (target - inv0) * 1e18 / target;  // pre-swap, 0 if flush
        uint oneMinusQ = 1e18 - q1;                       // pole is on the ENDING inventory
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
        // `skew = Γ·σ²·qBar` is 0 whenever σ² is 0, no matter how scarce the band is, so flooring
        // only `_maxWellSkew` left a drained band still charging nothing (MEASURED: the fix went in,
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
        uint qBar;
        if (oneMinusQ == 0) {
            qBar = type(uint).max;                        // ends at inv=0 ⇒ pole → ∞ ⇒ pinned to the cap
        } else if (q1 == q0) {
            // Δ = 0. Either a zero-size READ (the Aux/MM signal, which wants the instantaneous
            // rate) or a drain too small to move q. The integral's limit as Δ→0 IS the point rate,
            // so this branch is the formula's own limit, not a special case bolted beside it.
            qBar = FullMath.mulDiv(q0, 1e18, 1e18 - q0);
        } else {
            uint d = q1 - q0;
            // ln(u0/u1) in WAD. u0 > u1 > 0 here, so the ratio exceeds 1e18 and the log is positive.
            uint lnTerm = uint(SoladyMath.lnWad(int(FullMath.mulDiv(1e18 - q0, 1e18, oneMinusQ))));
            qBar = lnTerm > d ? FullMath.mulDiv(lnTerm - d, 1e18, d) : 0;
        }
        // §E104 — CLAMP THE KERNEL *BEFORE* THE BASE IS ADDED. E89 made the base additive and left
        // the pole sentinel as `type(uint).max`, so a drain that EMPTIES the band produced
        // `type(uint).max + base` and PANICKED (`0x11`) — a full drain REVERTED instead of charging
        // the 3% ceiling, which is the exact case the ceiling exists for. The suite never caught it
        // because it never drains a band to zero: 4,308 green, a pinned controlled comparison,
        // `--sizes` and `check-client-abis` all passed over an UNREACHED state.
        //   The pole means "charge the maximum", so resolve it to `MAX_WELL_SKEW` directly rather
        // than to a sentinel that must survive arithmetic. The finite branch is clamped too: near
        // the pole `qBar` is large and the product can exceed the ceiling on its own, which would
        // overflow the same way once the base is summed.
        if (qBar == type(uint).max) {
            skew = MAX_WELL_SKEW;
        } else {
            skew = FullMath.mulDiv(FullMath.mulDiv(MAX_WELL_SKEW, sigmaSqWad, 1e18), qBar, 1e18);
            if (skew > MAX_WELL_SKEW) skew = MAX_WELL_SKEW;
        }
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
        // the nominal window the band actually carried the imbalance restores σ²·T, the quantity LVR
        // is really made of (δ²/8 for a displacement δ, independent of elapsed time).
        //   ⛔ SCALING THE KERNEL BY `idle/nominal` WAS TRIED AND MEASURED, AND IT IS WRONG AS
        // CALIBRATED — DO NOT RE-ADD IT WITHOUT SETTLING Γ's HORIZON FIRST. It DOES close the vector
        // (chopper advantage → 0 bps at every delay), but against `nominalSecs = 12` it repriced
        // ORDINARY same-block chopped flow 97× (28,829 → 2,802,810 usd6). 12s is the SETTLEMENT
        // window; it is not the inventory-holding horizon Γ folded in, and any real gap dwarfs it.
        // The principle is right and the constant is unknown, which makes this a calibration
        // question (§UNIT-B-PATIENCE-STEP2), not a patch.
        skew += _maxWellSkew(sigmaSqWad, isBTC);
        if (skew > MAX_WELL_SKEW) skew = MAX_WELL_SKEW;
    }

    /// @notice The live well skew (WAD) for a pool — gathers deliverable inventory (at
    ///         the honest oracle `base`), the leverage claim, the flow EWMA and realized
    ///         variance, and runs `skewWad`. Used BOTH as the applied swap-out rate scalar AND
    ///         as the readable on-chain scarcity signal for the MMs + the LP dashboard.
    ///         `base` = getTWAPforAsset(asset) (USD18 per 1e18 raw; the WBTC anchor lifted
    ///         ×1e10 — reference-gettwapforasset-scale + BtcLevManager:161).
    /// @dev    RESERVOIR REFILL DESIGN (the "pump") -- how the native-BTC reservoir
    ///         refills, and why the skew is all that is needed:
    ///         1. PRIMARY REFILL -- LPs stake BTC ({Vault-registerBtcLp}), pulled in when the
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
    function _skewBasis(address core, uint base, bool isBTC, uint addedTok)
        private view returns (uint poolVolUsd)
    {
        poolVolUsd = FullMath.mulDiv(
            (ICore(core).POOLED()) + addedTok,
            base, 1e30);
    }

    /// @dev §E53 — THE SHARED-SCARCITY AMPLIFIER. Every input to the skews is `isBTC`-scoped, yet
    ///      BOTH bands draw on ONE basket: `committedUsd18() <= haircutTvl` is the single bound they
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
    ///      shared commitment belongs to the OTHER band) rather than absolute, built only from
    ///      `committedUsd18()` and `bandEquityUsd18()`, both of which are view.
    ///
    ///      Returns a WAD multiplier in [1e18, 2e18): 1× when this band is the only claimant, →2× as
    ///      the other band's equity dominates the shared bound. Bounded by construction — it can
    ///      never invent scarcity, only reflect that the shared backing is already spoken for.

    /// @dev §E89b — THE ONE PLACE THE PRICE IS COMPOSED, for BOTH legs. `_maxWellSkew` is two unlike
    ///      things summed, and only one of them rides E53's shared-scarcity amplifier:
    ///        • `σ²·confFrac/8` — capital AT RISK while locked through settlement. When the other band
    ///          has claimed the shared backing the SAME exposure is dearer to carry, exactly as the
    ///          shed kernel is, so it IS amplified.
    ///        • `SPLICE_FLOOR` — a FIXED on-chain splice FEE. An external price does not rise because
    ///          our other band is busy, so it is NEVER amplified.
    ///      Its own frame for two reasons: it frees stack in the tight `sellSkew` (no `via_ir`), and
    ///      having ONE composer means the two legs cannot drift apart again — they already did once
    ///      (E68b: the sell leg priced at the endpoint for a whole session after the drain leg was
    ///      fixed). Callers pass the bare kernel; everything else is decided here.
    function _composePrice(address core, uint kernel, uint sigmaSqWad, bool isBTC)
        private view returns (uint) {
        uint splice = isBTC ? SPLICE_FLOOR : 0;
        // §UNIT-B-PATIENCE: read the exposure clock here rather than threading it in — this frame
        // exists to RELIEVE stack pressure (no via_ir), so a fifth parameter would work against it.
        uint risk = _maxWellSkew(sigmaSqWad, isBTC) - splice;
        uint out = FullMath.mulDiv(kernel + risk, _sharedScarcityWad(core, isBTC), 1e18) + splice;
        return out > MAX_WELL_SKEW ? MAX_WELL_SKEW : out;
    }

    function _sharedScarcityWad(address core, bool isBTC) private view returns (uint) {
        uint both = ICore(core).committedUsd18();
        if (both == 0) return 1e18;
        uint btc = ICore(core).bandEquityUsd18();
        uint other = isBTC ? (both > btc ? both - btc : 0) : btc;
        return 1e18 + FullMath.mulDiv(other, 1e18, both);
    }

    /// @param drainUsd6 The volatile-OUT this swap is about to take, in 6-dec USD — the SAME unit
    ///        `_skewBasis` returns, which is why both call sites can pass their existing
    ///        buy-driving amount unconverted. **Pass 0 for a read-only quote**: that is the Δ→0
    ///        limit and yields the instantaneous rate, which is what the MM/dashboard signal wants.
    ///        §E68: before this parameter existed the drain leg was size-BLIND while the sell leg
    ///        already took `addedTok` — backwards, since the drain is the side bounded by physical
    ///        deliverability. The two legs are now symmetric in size-awareness.
    function wellSkew(address core, uint base, bool isBTC, uint drainUsd6)
        public view returns (uint)
    {
        uint poolVolUsd = _skewBasis(core, base, isBTC, 0);
        // UNIFORM sats/wei → 6-dec USD: `poolVol · base / 1e30`. Authoritative (NOT
        // BasketLib.convert, which now uses the SAME flat scale (the /1e8 variant over-valued
        // 8-dec BTC by 1e10 and was removed) —
        // the WBTC ×1e10 price-lift already closes the 8↔18-dec gap, so a flat /1e30 is
        // correct for BOTH pools and keeps poolVolUsd in the same 6-dec unit as flow + lev.

        // lockedUsd = GROSS levered collateral, converted with the SAME base/1e30 scale as poolVol
        // (one price, one unit) — the locked-inventory basis for `inv` (#6/F3). committedUsd = DEBT.

        uint raw = skewWad(
            poolVolUsd,
            ICore(core).flowEwmaUsd(isBTC),
            ICore(core).realizedVarianceWad(), isBTC, drainUsd6);
        // §E53: amplify by how much of the SHARED bound the other band already holds, then re-cap —
        // the amplifier must never lift the skew past the same ceiling the raw curve obeys.
        // §E89b — THE AMPLIFIER SCALES RISK, NOT FEES. E89 made the base additive, which silently put
        // it INSIDE the amplifier (while it was a CEILING applied after, that was impossible). The
        // right split is not "kernel vs base" but RISK vs FEE, because `_maxWellSkew` is two unlike
        // things added together:
        //   • `σ²·confFrac/8` — capital AT RISK while locked through settlement. E53's amplifier says
        //     the other band has already claimed the shared backing, so the SAME dollar of exposure
        //     is dearer to carry. That applies to this term exactly as it does to the shed kernel,
        //     so it IS amplified. (I first claimed it should not be; that was wrong.)
        //   • `SPLICE_FLOOR` — a FIXED on-chain splice FEE. An external price does not rise because
        //     our other band is busy, so it is NEVER amplified.
        //   ⚠️ `raw >= splice` is NOT guaranteed: `skewWad` has EARLY RETURNS (`target == 0`, and the
        // FLUSH branch `inv1 >= target`) that never add the base, leaving `raw == 0`. Assuming
        // otherwise underflowed on a BALANCED band — the common case — and cost 782 failures.
        uint splice = isBTC ? SPLICE_FLOOR : 0;
        uint amp = raw > splice
            ? FullMath.mulDiv(raw - splice, _sharedScarcityWad(core, isBTC), 1e18) + splice
            : raw;
        // §E79: the re-cap after the amplifier is now the ABSOLUTE ceiling. The expected-loss FLOOR
        // was already applied inside `skewWad`, and re-clamping to it here would undo the inversion
        // by pulling an amplified premium straight back down to the base charge.
        return amp > MAX_WELL_SKEW ? MAX_WELL_SKEW : amp;
    }

    /// @notice SYMMETRIC A-S skew for a volatile-IN SELL (the self-funded short's
    ///         band-leg shed). Where `wellSkew` prices the SCARCE side (volatile-OUT drain,
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
    function sellSkew(address core, uint base, bool isBTC, uint addedTok)
        public view returns (uint)
    {
        // §E58: `target` is FLOW alone — the leverage DEBT is not a constraint on shedding (see
        // skewWad's note). One term, one meaning.
        uint flow = ICore(core).flowEwmaUsd(isBTC);
        uint target = flow;
        if (target == 0) return 0;
        // inv = poolVolUsd − GROSS locked inventory (same base/1e30 scale as poolVol, #6/F3). Scope the two
        // transient conversion locals so they free their stack slots before the skewWad call (no via_ir).
        uint inv;
        {
            uint poolVolUsd = _skewBasis(core, base, isBTC, addedTok);
            inv = poolVolUsd;                                 // §E58: levered depth IS band depth
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
        // started", and a brand-new band has no flow HISTORY — refusing there bricks the pool at
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
            if (ICore(core).skewPremiumCum(isBTC) > 0) revert NoShedPath();
        }
        // §E68b — THE SELL LEG NOW INTEGRATES TOO. E68 fixed only the DRAIN leg and left this one
        // pricing at the ENDPOINT, which is the OTHER HALF of the same defect the owner originally
        // identified — and the half that OVERCHARGES.
        //
        // `inv` already includes `addedTok` (see _skewBasis), so `over` is the POST-swap overshoot
        // and `q` was q1: the sell was billed at the scarcity its LAST unit created, applied to
        // EVERY unit. A seller arriving at a balanced band and pushing it to 2× target paid the
        // 2×-target rate on the whole ticket, including the first units that landed while the band
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
            uint q1 = FullMath.mulDiv(over, 1e18, target);
            if (q1 > 1e18) q1 = 1e18;                     // ≥2× target: linear term saturates
            // Pre-swap overshoot: strip this sell's own contribution back out of `inv`. A sell that
            // STARTED at/below target has q0 = 0 and pays only for the part that crossed above it.
            uint addedUsd = FullMath.mulDiv(addedTok, base, 1e30);
            uint invBefore = inv > addedUsd ? inv - addedUsd : 0;
            uint q0 = invBefore > target ? FullMath.mulDiv(invBefore - target, 1e18, target) : 0;
            if (q0 > 1e18) q0 = 1e18;
            q = (q0 + q1) / 2;                            // the integral's mean over THIS sell
        }
        uint sigmaSqWad = ICore(core).realizedVarianceWad();
        // §E54-r REMOVED (owner, 2026-08-04: *"avgYield has nothing to do with the band. it's a
        // dollar only thing. your skew shouldnt even consider it"*). I had added an opportunity-cost
        // term `r = Aux.avgYield()`, reasoning that the premium should equal what a counterparty
        // foregoes by taking this inventory off us. **`avgYield` does not measure that.** It is the
        // return on the BASKET's STABLE reserve — AAVE, the 4626 vaults, the Stability Pool — i.e.
        // the yield on DOLLARS. This skew prices the cost of carrying VOLATILE we did not want, and
        // the counterparty who takes ETH off us is not foregoing our stablecoin yield. Two different
        // assets, two different returns; I imported the number because it was conveniently in-system,
        // not because it measured the quantity. Same error as valuing the USD increment at the band's
        // leg ratio (§E28): a number that is *available* is not thereby the *right* one.
        // §E59: same σ²-zeroes-the-kernel hole as the drain leg — an UNMEASURED variance must not
        // price an inventory-increasing sell at nothing. Scarcity is real (q > 0) by this point.
        // §E79: with the inversion, `_maxWellSkew(0)` is now a FLOOR of ~0 — returning it here would
        // re-open the free-drain hole E59 closed. UNMEASURED variance must price at the CEILING,
        // which is the conservative reading E59 intended and now says so in the right units.
        uint skew = FullMath.mulDiv(
            FullMath.mulDiv(MAX_WELL_SKEW, sigmaSqWad, 1e18), q, 1e18);
        // §E53: the SAME shared-scarcity amplifier the drain leg carries — a sell that grows our
        // inventory is dearer to shed when the OTHER band has already spoken for the shared backing.
        // §E89b: and the SAME risk-vs-fee split — the settlement-window risk term rides the amplifier
        // with the kernel; only `SPLICE_FLOOR` stays outside it. Written here so both legs compose
        // their price identically; they had already drifted apart once (E68b).
        return _composePrice(core, skew, sigmaSqWad, isBTC);
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
        // v4 (the BtcVault) == address(this) and wbtc is read from aux INSIDE prep, so neither this body nor
        // its Vault caller carries them as params — that's what frees the stack for the refund call.
        (Types.AuxContext memory ctx, Types.RouteParams memory rp) =
            _swapOutPrep(swapper, token, usdAmount, core, aux);
        (sats, usd6) = _swapOutSettle(ctx, rp, swapper, token, minSats);
    }

    /// @dev creditSwapOutBody PHASE 1 (own frame): pull the swapper's full stable into the basket, resolve
    ///      the oracle price, apply the drain scarcity skew (the withheld premium stays in Aux as fungible
    ///      backing, tracked by recordSkewPremium — it NEVER enters POOLED), and return the fully-built route
    ///      params. v4 == address(this) (this lib body is delegatecalled from the BtcVault); wbtc via aux.
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
        // Reuse the repack-resolved oracle price (5th return); live-read only if v4p==0.
        // §E9 — packed band ticks, not a price (see creditSwapInBody). Block-scoped for stack.
        uint v4p;
        {
            (, int24 lo, int24 hi,, uint p_) = IBandManager(address(this)).repack(true);
            v4p = p_;
            rp.sqrtPriceX96 = _packBandTicks(lo, hi);
        }
        rp.zeroForOne   = ICore(core).token1is(true);    // USD→BTC buy (mirror of the sell)
        rp.token        = address(0);                       // volatile (BTC) output
        rp.pooled       = ICore(core).POOLED();      // BTC inventory bounds the fill
        uint basePrice  = _priceOr(v4p, aux, wbtc);
        rp.v4Price      = basePrice;                         // HONEST oracle — manip-guard stays unskewed
        // Effective-rate scarcity skew on the drain: scale the buy-driving USD DOWN by (1−skew) so a
        // BTC-scarce pool hands the swapper FEWER sats per USD; the withheld premium stays as backing. The
        // swap still executes at basePrice through routeSwap ⇒ NO manip-guard exemption (separate scalar).
        // `amount` here is ALREADY 6-dec USD (scaleTo6 in _swapOutPrep), so px=0 declares "no conversion":
        // this leg's recorded premium was always in the right unit and stays that way.
        SwapReq memory sr; sr.amount = amount; sr.px = 0;
        retainSkewPremium(core, true, sr, wellSkew(core, basePrice, true, amount), false);  // audit + RFQ-drawable
        amount = sr.amount;
        rp.amount    = amount;                               // reduced buy drives the fill
        rp.recipient = address(this);                       // obligation → pool; LN delivers
        rp.isBTC     = true;
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
    // callers (Vault, Vogue) already import SwapLib, so this adds no new
    // deployed-library dependency; and SwapLib's own external functions never
    // call these, so they are NOT included in SwapLib's deployed bytecode —
    // they inline into Vault/Vogue exactly as they did from LpEngine. Vogue
    // (ETH side) and Vault (BTC side) once carried verbatim copies of this
    // logic; this is the ONE engine, parameterized by `isBTC`.
    //
    // STORAGE MODEL: holds NO storage. Where it operates on the LP's own struct
    // it takes `Types.Deposit storage` (legal — a mapping value). The vault's
    // flat value-type accumulators are taken BY VALUE and the new value/increment
    // RETURNED; the thin vault wrapper writes the slot back.
    // ════════════════════════════════════════════════════════════════════
    uint constant WAD = 1e18;
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
        LP.fees_tok = FullMath.mulDiv(weight, tokAccum, WAD);
        LP.fees_usd = FullMath.mulDiv(weight, usdAccum, WAD);
    }

    /// @dev Pending (tok, usd) rewards for an LP against the supplied
    ///      per-share accumulators. `weight` is the GROSS fee depth (see
    ///      refreshBookmarks): pooled (net) + levered buffer.
    function pendingFor(Types.Deposit storage LP, uint weight, uint feePerShareTok, uint feePerShareUsd)
        internal view returns (uint tokReward, uint usdReward) {
        if (weight == 0) return (0, 0);
        uint tokOwed = FullMath.mulDiv(weight, feePerShareTok, WAD);
        uint usdOwed = FullMath.mulDiv(weight, feePerShareUsd, WAD);
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
        if (fees > 0)     tokInc = FullMath.mulDiv(fees, WAD, totalShares);
        if (usd_fees > 0) usdInc = FullMath.mulDiv(usd_fees, WAD, totalShares);
    }

    // ── Delivery-side de-lever (partial-burn vBTC deliverability) ─────────────────────────────────

    /// @notice Runs at the head of a native swap-out settlement (Vault._resizeBtcLp) when the delivering LP's
    ///   slice draws PAST its FREE channel band into the LEVERED slice — the "stranded volatile" state
    ///   (`shrinkSats > funded = pooled − levPooled`). The delivery's OWN proceeds de-lever the shortfall
    ///   `want = min(shrinkSats−funded, levPooled)`: source the venue's debt stable from the basket, repay the
    ///   LP's debt (the manager burns the freed vBTC + un-encumbers the channel BTC, lev→funded, so the clamp in
    ///   resizeBtcLp then delivers the full shrink), and DRAW the retired-debt share out of POOLED_USD + clear
    ///   its obligation. The Vault hands resizeBtcLp `exactUsd − deLeverUsd6`, so `settleDelivered` mints QUI for
    ///   the FUNDED (+ any pure-equity) remainder only — the de-levered slice is paid ONCE (debt-reduction, not a
    ///   QUI mint). VALUE-NEUTRAL: −BTC −debt of equal oracle value ⇒ net-equity preserved, LTV IMPROVES. The
    ///   levered slice's V4 depth was already consumed by the curve at REQUEST (it sold against the full
    ///   POOLED), so this only reconciles the per-LP accounting — no second burnInRange. DELEGATECALL'd by the
    ///   Vault (address(this)==Vault): AUX/CORE see msg.sender==Vault (onlyUs), the manager sees Vault (==its
    ///   vogueSyncHook gate), and the manager's unexpose callback arrives as msg.sender==manager (==LEV_MANAGER_BTC).
    ///   Returns the 6-dec debt-share withheld from the QUI mint.
    function deleverOnDelivery(
        address core, address aux, address mgr,
        mapping(address => Types.Deposit) storage autoManagedBTC,
        mapping(address => uint) storage levPooledBTC,
        address lp, uint shrinkSats, uint lpPayoutSats, uint exactUsd6
    ) public returns (uint deLeverUsd6) {
        uint lev = levPooledBTC[lp];
        if (lev == 0) return 0;                                    // not levered — nothing to de-lever
        uint funded;
        { uint pooled = autoManagedBTC[lp].pooled; funded = pooled > lev ? pooled - lev : 0; }
        if (shrinkSats <= funded) return 0;                       // free channel band covers the shrink
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
        // moving together. The debt-buffer's stale POOLED_USD is reconciled by the keeper's async syncLevBTC.
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
    ///   `deleverOnDelivery`). DELEGATECALL'd by Vogue (address(this)==Vogue==the LevManager's `vogueSyncHook`) from
    ///   `_sendETH` when the venue base (deliverableETH) can't cover a swap-out delivery. Walks the open lev book;
    ///   per LP: sources the swap's OWN proceeds into the venue via `Aux.takeToSettle` DIRECTLY (Vogue==address(this)
    ///   IS authorized — `V4==Vogue` in `Aux._requireUs`) and repays that LP's debt, delivering the freed collateral
    ///   as WETH to `recipient` (Vogue, which unwraps + sends). VALUE-NEUTRAL per LP (the swapper's input de-levers
    ///   the delivering LP; the keeper re-levers next tick). 0-debt (unlevered net-equity) LPs take the no-repay
    ///   `swapOutDeliverUnlevered` branch instead. Stops once `shortfallEth` (WETH 1e18) is covered; fault-tolerant
    ///   (a stuck LP is skipped → residual #105 partial-fill). @param px USD 1e18/WETH. @return deliveredEth to recipient.
    ///   🔴 UNVERIFIED (forge OOM): fork-test the (1) gating chain, (2) Σbacking invariant (QD-burn: takeToSettle
    ///   draws basket stable to repay — needs `DeleverEthBackingProbe`), (3) non-toxicity, before trusting.
    function deleverEthOnDelivery(address mgr, address aux, uint px, uint shortfallEth, address recipient)
        public returns (uint deliveredEth) {
        if (px == 0 || shortfallEth == 0) return 0;
        uint n = ILevEthDeliver(mgr).openLevCount();
        for (uint i; i < n && deliveredEth < shortfallEth; i++) {
            address lp = ILevEthDeliver(mgr).openLpAt(i);
            uint needUsd = FullMath.mulDiv(shortfallEth - deliveredEth, px, 1e18);   // remaining WETH → USD 1e18
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
            // Route the swap's OWN proceeds → venue directly (Vogue==address(this) IS `takeToSettle`-authorized),
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
    function burnInRange(address v4, bool isBTC, uint160 sqrtPriceX96, uint amount,
        int24 tickLower, int24 tickUpper, address recipient)
        internal returns (uint sent) {
        uint pooled = ICore(v4).POOLED();
        uint pulled = Math.min(amount, pooled);
        if (pulled == 0) return 0;
        (,, uint128 posLiquidity) = ICore(v4).poolStats(tickLower, tickUpper);
        if (posLiquidity > 0) {
            sent = ICore(v4).modLP(sqrtPriceX96, pulled, 0,
                            tickLower, tickUpper, recipient);
        }
    }

    // ── BTC allocation cap REMOVED (§H, 2026-07): the btcShareBps median-vote cap is gone; BTC now sizes by
    //    SOLVENCY-surplus only. The ≤TVL invariant + `committedBoth` (shared-mirror, so neither pool double-claims
    //    surplus) remain the bounds — no policy cap, no `btcCapClamp`.

    /// @dev Shared solvency sizer for Vogue.addLiq (ETH) + Vault._addLiqChannel
    ///      (BTC). From the SHARED free backing (`liquidTotal − committedBoth`,
    ///      where committedBoth nets BOTH pools' committed USD so neither can claim
    ///      the same surplus twice), optionally apply the BTC policy cap, then
    ///      back-solve the token amount whose USD value == surplus (pin USD to free
    ///      backing; the unpaired token stays in IL-free retention). Callers fetch
    ///      `liquidTotal` (get_deposits[14]) + `committedBoth` (committedUsd18)
    ///      themselves — keeps the large get_deposits ABI decode in the contract,
    ///      off the legacy-pipeline headStart path. `surplus == 0` ⇒ caller
    ///      early-returns. Every mulDiv floors → commits ≤ requested, never more.
    function sizeBySurplus(
        uint liquidTotal, uint committedBoth,
        uint deltaTok, uint price
    ) internal pure returns (uint deltaOut, uint targetUSD, uint surplus) {
        // #67 note: the levered net-equity is NOT paired against surplus (that would spend surplus making the
        // equity earn band fees on de-lever-backed / phantom USD, and make the levered backing withdrawable at
        // will). Surplus is reserved for the borrow cost + QU!D redemption; the levered net-equity is REDEMPTION
        // backing (already in committedUsd18 / vogueETH/BTC), de-leverable only by a redemption. Its debt-funded
        // BUFFER leg already earns band fees without touching surplus. So this stays REAL-surplus-only.
        surplus = liquidTotal > committedBoth ? liquidTotal - committedBoth : 0;
        if (surplus == 0) return (0, 0, 0);
        deltaOut  = deltaTok;
        targetUSD = FullMath.mulDiv(deltaTok, price, WAD);
        if (targetUSD > surplus) {
            targetUSD = surplus;
            deltaOut  = FullMath.mulDiv(surplus, WAD, price);
        }
    }

    /// @notice theta risk-budget clamp on a band add: cap post-add `pooled` at `thetaEff * vogueAvail`
    ///         (WAD), so the IL-bearing band never holds more than the live yield/vol tradeoff prescribes.
    ///         `thetaEff >= 1e18` (fail-open / calm) is a no-op. Shared by BOTH sizing paths -- ETH
    ///         (`VogueLib.addLiq`) and BTC (`BtcVaultLib.addLiqChannel`) -- so the throttle is identical
    ///         across assets (a volatile-asset band bears IL the same way regardless of which asset).
    function applyTheta(uint thetaEff, uint vogueAvail, uint pooled, uint available)
        internal pure returns (uint)
    {
        if (thetaEff >= 1e18) return available;
        uint thetaCap   = FullMath.mulDiv(vogueAvail, thetaEff, 1e18);
        uint thetaAvail = thetaCap > pooled ? thetaCap - pooled : 0;
        return available > thetaAvail ? thetaAvail : available;
    }

    /// @notice Backing-bounded theta clamp — the ONE principle for EVERY band add (ETH band, BTC LP-add, BTC
    ///         reseat). Permit `want` new in-range depth, but never past two bounds:
    ///           • HEADROOM = `backing − pooled` — the physical room the IL-bearing capital leaves ABOVE the
    ///             current in-range depth. `backing` = that capital (ETH: vogueETH venue principal + gross
    ///             buffer; BTC: lpSharesBTC + gross buffer, +this add's sats); `pooled` = current in-range band
    ///             depth (POOLED/BTC). The band can never exceed what backs it.
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
    /// @notice Plain (unlevered) net band equity = gross `pooled` minus the levered slice `lev`, zero-floored.
    ///         ONE definition for the hedge-E0 base (bandEthOf/bandBtcOf), the venue-yield fee weight, and the
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
    function retainSkewPremium(address core, bool isBTC, SwapReq memory r, uint skew, bool nativeAmount)
        internal {
        if (skew == 0) return;
        uint premium = FullMath.mulDiv(r.amount, skew, 1e18);
        // ONLY the sell leg holds a NATIVE amount. The two drain legs hold the BUY-DRIVING USD, already
        // 6-dec — converting those (attempt 2) collapsed the recorded premium to 0. `r.px` cannot serve as
        // the discriminator: it is non-zero on BOTH swapToBody legs, so the caller states the unit.
        ICore(core).recordSkewPremium(isBTC,
            nativeAmount ? FullMath.mulDiv(premium, r.px, 1e30) : premium);
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

    function paddedSqrtPrice(uint160 sqrtPriceX96, bool up, uint delta)
        internal pure returns (uint160) {
        uint factor = up ? FixedPointMathLib.sqrt((10000 + delta) * 1e18 / 10000)
                         : FixedPointMathLib.sqrt((10000 - delta) * 1e18 / 10000);
        return uint160(FixedPointMathLib.mulDivDown(sqrtPriceX96, factor, 1e9));
    }

    /// @notice (B — IL-protect) The band's ACTUAL sold-volatile fraction (WAD) between `entrySqrtP` and the
    ///         current `sqrtP`, straight from the concentrated-position geometry — the ground-truth IL the
    ///         hedge must cancel, reflecting the real (drifting) α with NO sqrt/pow and NO α parameter. Held
    ///         volatile amount is ∝ (√P − √Pa) when the volatile is token1 (sold as √P FALLS — volatile
    ///         appreciates ⇒ pool price down) or ∝ (√Pb − √P)/(√P·√Pb) when it's token0 (sold as √P RISES);
    ///         soldFrac = 1 − amount_now/amount_entry. Returns 0 on the non-IL side (up-side-only, matching the
    ///         current target) or a degenerate band. VALID WITHIN ONE TICK-CONFIG ONLY — a reseat recenters the
    ///         ticks and realizes IL, so the CALLER must re-anchor `entrySqrtP` on a reseat. Shared verbatim by
    ///         the ETH band (Vogue, `token1isVol`) and the BTC band (Vault, `token1isVol`).
    /// @notice held-volatile amount NOW / held-volatile amount AT ENTRY (WAD), straight from the
    ///         concentrated-band geometry, clamped to the live band. `1e18` = at entry. `>1e18` ⇒ the band
    ///         BOUGHT the volatile (price fell — the OVER-hold the short cancels); `<1e18` ⇒ it SOLD (price
    ///         rose — the UNDER-hold the long cancels). Reflects the real (drifting) α with NO α parameter and
    ///         NO sqrt/pow — the single ground-truth primitive both hedge legs size from. VALID WITHIN ONE
    ///         TICK-CONFIG ONLY: a reseat recenters + realizes IL, so the caller MUST re-anchor `entrySqrtP`.
    function holdingRatioWad(uint160 entrySqrtP, uint160 sqrtP, int24 lo, int24 up, bool token1Volatile)
        internal pure returns (uint) {
        if (entrySqrtP == 0 || lo >= up) return 1e18;
        uint sa = TickMath.getSqrtPriceAtTick(lo);
        uint sb = TickMath.getSqrtPriceAtTick(up);
        uint s  = sqrtP      < sa ? sa : (sqrtP      > sb ? sb : uint(sqrtP));
        uint s0 = entrySqrtP < sa ? sa : (entrySqrtP > sb ? sb : uint(entrySqrtP));
        if (token1Volatile) {
            if (s0 <= sa) return 1e18;                       // degenerate: entry at/below the lower tick
            return FullMath.mulDiv(s - sa, 1e18, s0 - sa);   // (s−sa)/(s0−sa)
        }
        if (sb <= s0 || s == 0) return 1e18;                 // degenerate
        uint ratio = FullMath.mulDiv(s0, 1e18, s);
        return FullMath.mulDiv(ratio, sb - s, sb - s0);      // (s0/s)·(sb−s)/(sb−s0)
    }

    /// @notice The band's ACTUAL sold-volatile fraction (WAD) since entry = `1 − holdingRatio` when the band
    ///         under-holds (price rose). The LONG hedge re-adds exactly this. Ground truth; 0 on the non-sold side.
    function soldFractionWad(uint160 entrySqrtP, uint160 sqrtP, int24 lo, int24 up, bool token1Volatile)
        internal pure returns (uint) {
        uint r = holdingRatioWad(entrySqrtP, sqrtP, lo, up, token1Volatile);
        return r < 1e18 ? 1e18 - r : 0;
    }

    // boughtFractionWad REMOVED (2026-07-24): it fed the below-entry SHORT hedge (its sole consumer), which was
    // removed as an LVR leak (see docs §J.4). `soldFractionWad`/`holdingRatioWad` stay — the UP-SIDE overlay reads them.

    /// @dev Target sqrtPriceX96 for a desired `targetPrice` (USD18 per 1e18 raw
    ///      asset), given the current sqrtPrice and its implied `currentPrice`.
    ///      RELATIVE scaling — reuses the paddedSqrtPrice pattern (sqrtP × √ratio,
    ///      √ scaled by 1e9 == √1e18) so there is NO absolute price→sqrt encoding
    ///      to get wrong. getPrice: when USD is token0, price ∝ 1/sqrtP² ⇒
    ///      sqrtP ∝ 1/√price (ratio = current/target); else price ∝ sqrtP² ⇒
    ///      sqrtP ∝ √price (ratio = target/current). Used by the curve-reseat to
    ///      move the mock pool's spot onto the Chainlink-resolved price.
    function targetSqrtForPrice(uint160 currentSqrt, uint currentPrice,
        uint targetPrice, bool token0isUSD) internal pure returns (uint160) {
        if (currentPrice == 0 || targetPrice == 0) return currentSqrt;
        (uint num, uint den) = token0isUSD ? (currentPrice, targetPrice)
                                           : (targetPrice, currentPrice);
        uint factor = FixedPointMathLib.sqrt(FullMath.mulDiv(num, 1e18, den));
        uint160 t = uint160(FixedPointMathLib.mulDivDown(currentSqrt, factor, 1e9));
        if (t < TickMath.MIN_SQRT_PRICE + 1 || t > TickMath.MAX_SQRT_PRICE - 1)
            return currentSqrt; // out of representable range → leave spot put
        return t;
    }

    function alignTick(int24 tick, int24 width) internal pure returns (int24) {
        if (tick < 0 && tick % width != 0) {
            return ((tick - width + 1) / width) * width;
        }   return (tick / width) * width;
    }

    /// Rescale a just-deposited stable amount to 6-dec USD by its own decimals.
    /// Shared verbatim by the ETH (VogueLib) and BTC (BtcVaultLib) OOR paths.
    function scaleTo6(uint amount, address token) internal view returns (uint) {
        uint8 dec = IERC20(token).decimals();
        if (dec == 6) return amount;
        return dec > 6 ? amount / 10 ** (dec - 6) : amount * 10 ** (6 - dec);
    }

    /// Shared param validation for the out-of-range boundary order (ETH+BTC):
    /// range 100–1000 step 50, distance ±5000 step 100 (non-zero). Custom error (no
    /// string-revert bytecode — the two long strings were the fattest revert sites in the OOR path).
    error BadOorParam();
    function validateOorParams(int24 range, int24 distance) internal pure {
        if (!(range >= 100 && range <= 1000 && range % 50 == 0)) revert BadOorParam();
        if (!(distance % 100 == 0 && distance != 0 && distance >= -5000 && distance <= 5000)) revert BadOorParam();
    }

    // ─── Self-managed (out-of-range / boundary-order) geometry ────────────────
    // Shared by the ETH (Vogue) and BTC (Vault) single-sided position paths so
    // BOTH compute ticks + single-sided liquidity by the SAME rules — only the
    // pool + token ordering differ (token1is). Ported verbatim from the original
    // Vogue `_outOfRangeTicks` / `_sizeOutOfRange` USD branch.
    struct Oor { int24 newLo; int24 newUp; int24 curLo; int24 curUp; }

    /// The boundary order's tick range, fully outside the current [curLo,curUp].
    /// `distance` is caller-signed (positive = below the price); `token1is` flips
    /// it for the pool's token ordering. `width` is the tick-alignment (10).
    function oorTicks(uint160 sqrtPrice, int24 range, int24 distance, bool token1is,
        int24 curLo, int24 curUp) internal pure returns (Oor memory t) {
        t.curLo = curLo; t.curUp = curUp;
        if (!token1is) distance = -distance;
        int24 targetTick = TickMath.getTickAtSqrtPrice(sqrtPrice) - distance;
        if (distance < 0) { // above the current price
            t.newLo = alignTick(targetTick, int24(10));
            t.newUp = alignTick(targetTick + range, int24(10));
        } else {
            t.newUp = alignTick(targetTick, int24(10));
            t.newLo = alignTick(targetTick - range, int24(10));
        }
    }

    /// Size a USD-funded single-sided boundary order (`amount6` in 6-dec USD).
    /// Asserts the new range sits fully outside the current one and provides the
    /// USD on the side the ordering dictates.
    function sizeOorUsd(uint amount6, Oor memory t, bool token1is)
        internal pure returns (uint128 liquidity) {
        if (token1is) {
            // Above current = buy the asset with USD (provide $). Reuses the lib's TickOutOfRange error (no string).
            if (t.newUp >= t.curLo) revert TickOutOfRange();
            liquidity = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(t.newLo), TickMath.getSqrtPriceAtTick(t.newUp), amount6);
        } else {
            if (t.newLo <= t.curUp) revert TickOutOfRange();
            liquidity = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(t.newLo), TickMath.getSqrtPriceAtTick(t.newUp), amount6);
        }
    }

    // (event InstantRedeemSkipped removed 2026-08-09 — it announced a degradation from the instant-redeem
    //  rung to the wait-NFT, and that rung was deleted 2026-08-05/06. It was never emitted after that, so it
    //  was an ABI entry promising a signal that could not fire. ⚠️ The degradation it covered is now
    //  UNANNOUNCED: rung 1 failing its 0.5% floor drops the withdrawer into the multi-day queue with no
    //  event. If that signal is wanted back it must be re-armed on the rung-1 catch in
    //  `VaultLib.offrampBody`, not here — see QUEUE §E152-nerve.)

    error TickOutOfRange();
    function updateTicks(uint160 sqrtPriceX96, uint delta)
        internal pure returns (int24 tickLower, uint160 lower,
                             int24 tickUpper, uint160 upper) {
        lower = paddedSqrtPrice(sqrtPriceX96, false, delta);
        upper = paddedSqrtPrice(sqrtPriceX96, true, delta);
        if (lower < TickMath.MIN_SQRT_PRICE + 1) revert TickOutOfRange();
        if (upper > TickMath.MAX_SQRT_PRICE - 1) revert TickOutOfRange();
        tickLower = alignTick(TickMath.getTickAtSqrtPrice(lower), int24(10));
        tickUpper = alignTick(TickMath.getTickAtSqrtPrice(upper), int24(10));
    }

    // ── Shared repack skeleton ────────────────────────────────────────

    /// Raw output of `rebalanceCore` so callers can run a pool-specific
    /// fee-distribution / yield-metric after the shared work.
    struct Rebalanced {
        uint160 sqrtPriceX96;
        int24   tickLower;     // post-repack range (== input range if no repack)
        int24   tickUpper;
        uint128 myLiquidity;
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
        // (SwapLib._finishSwap) REUSES it as v4Price instead of reading the
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
    function rebalanceCore(
        address v4, address aux, address asset, bool isBTC,
        int24 tickUpper, int24 tickLower
    ) internal returns (Rebalanced memory r) {
        r.tickUpper = tickUpper;
        r.tickLower = tickLower;
        int24 currentTick;
        (r.sqrtPriceX96, currentTick, r.myLiquidity) =
            ICore(v4).poolStats(tickLower, tickUpper);

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
        // aligned. Both pools route here (Vogue + BtcVault).
        if (stale && _reseatIfStale(v4, isBTC, r, twap)) return r;

        // HALF-OPEN RANGE (T1). A Uniswap position over [tickLower, tickUpper) is ACTIVE iff
        // `tickLower <= tick < tickUpper`, so it is OUT of range at `tick >= tickUpper` — NOT `>`.
        // With `>`, at exactly `tick == tickUpper` the band is inactive (earning no fees, fully in
        // one token) yet this returned "still in range" and did NOT re-centre, leaving the band
        // stranded until the tick moved one more step. The lower bound was already correct (`<`,
        // strictly below), and that asymmetry is the tell: a half-open range needs `>=` upper and
        // `<` lower; `>` here treated it as CLOSED. Sole in-range comparison in `src/`.
        if (currentTick >= tickUpper || currentTick < tickLower) {
            // Don't repack to a manipulated spot — need the oracle. If unavailable
            // (twap==0, e.g. bootstrap) or spot deviates >300bps, keep the range.
            if (twap == 0) return r; // didRepack stays false → keep current range
            uint spot = BasketLib.getPrice(r.sqrtPriceX96, ICore(v4).token1is(isBTC));
            // Repack TOLERANCE (300 bps = 3%) — looser than the 50-bps swap
            // guard so normal volatility doesn't block re-centering.
            if (BasketLib.isManipulated(spot, twap, 300)) {
                return r;
            }
            (int24 newTickLower,, int24 newTickUpper,) = updateTicks(r.sqrtPriceX96, BAND_DELTA);
            if (r.myLiquidity > 0) {
                (r.price, r.fees0, r.fees1, r.delta0, r.delta1) =
                    ICore(v4).repack(r.myLiquidity, r.sqrtPriceX96,
                        tickLower, tickUpper, newTickLower, newTickUpper);
                r.didRepack = true;
            }
            r.tickLower = newTickLower;
            r.tickUpper = newTickUpper;
        } else if (r.myLiquidity > 0) {
            // JIT-snipe defense: force a fee-only collect so accrued fees land
            // in the accumulators BEFORE the caller's bookmark advances.
            // collectFees ALREADY reorders internally and returns canonical
            // (feesUSD, feesTok) — USD first.
            (r.jitFeesUsd, r.jitFeesTok) = ICore(v4).collectFees(tickLower, tickUpper, isBTC);
            r.jitFees = true;
        }
    }

    /// @dev Move the curve spot onto the (Chainlink) target `twap` + re-range.
    ///      Own frame so rebalanceCore stays within the legacy stack (no via_ir).
    ///      Returns true if it moved the spot. No-op (false) when already aligned.
    function _reseatIfStale(address v4, bool isBTC, Rebalanced memory r, uint twap)
        private returns (bool) {
        bool t1isVol = ICore(v4).token1is(isBTC);
        uint spot = BasketLib.getPrice(r.sqrtPriceX96, t1isVol);
        if (spot == 0 || twap == 0) return false;
        // Only move the spot when it's off the oracle by more than the 50-bps
        // routeSwap guard — i.e. enough to actually BLOCK swaps. Within 50bps swaps
        // execute fine, so reseating would just churn (and a sub-tick move is
        // degenerate). This keeps reseat firing once per dislocation, not per op.
        if (!BasketLib.isManipulated(spot, twap, RESEAT_MIN_BPS)) return false;
        uint160 targetSqrt = targetSqrtForPrice(r.sqrtPriceX96, spot, twap, t1isVol);
        if (targetSqrt == r.sqrtPriceX96) return false; // already aligned
        _doReseat(v4, isBTC, r, targetSqrt);
        return true;
    }

    /// @dev Burn+move+re-range to `targetSqrt` — own frame so the reseat's 5-tuple
    ///      return doesn't pin _reseatIfStale's stack (legacy pipeline, no via_ir).
    function _doReseat(address v4, bool isBTC, Rebalanced memory r, uint160 targetSqrt)
        private {
        (int24 nlo,, int24 nhi,) = updateTicks(targetSqrt, BAND_DELTA);
        if (r.myLiquidity > 0) {
            (r.price, r.fees0, r.fees1, r.delta0, r.delta1) = ICore(v4).reseat(
                isBTC, r.myLiquidity, r.sqrtPriceX96, targetSqrt,
                r.tickLower, r.tickUpper, nlo, nhi);
            r.didRepack = true;
        }
        r.tickLower = nlo; r.tickUpper = nhi; r.sqrtPriceX96 = targetSqrt;
    }

}




// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WAD, FLOW_HALFLIFE, BadAsset} from "./Types.sol";
// §A.52: the canonical view (was a file-local `IBasketTurn2`).
import {IBasket} from "./Interfaces.sol";   // §rule-2: Interfaces.sol is the canonical declaration site
                                                     // (BasketLib only RE-imports it, so importing from there does not resolve)
// §A.52: the canonical Core view (was a file-local variant).
import {ICore} from "./Interfaces.sol";
import {ILevManagerDeliver, ILevEthDeliver} from "./Interfaces.sol";
import {ILevPooled, ILevVenue} from "./Interfaces.sol";   // §POOL-VENUE
import {IBTCChannels} from "./Interfaces.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// §A.52: the SHARED WETH view (was a file-local `IWethDeposit` declaring just `deposit()`).
import {IWETH9} from "./Interfaces.sol";
// §A.52: canonical shared views — these were file-local `IWeEth_L`/`IRedeem_L`/`ILiq_L`.
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
// ether.fi offramp interfaces (suffixed `_L` to avoid clashing with Aux's own
// copies, since Aux imports SwapLib). Same signatures as Aux's.
// outputToken ∈ {0xEeee…EEeE native-ETH sentinel, stETH} — else InvalidOutputToken.
/// Chainlink-style USD feed — the external anchor for the TWAP cross-check.


/// @notice V4 (Quid) repack. 5th return = the resolved oracle price (Chainlink-when-stale, else internal
///         TWAP) computed during the repack-first; the swap reuses it as fillPrice so it doesn't read the
///         internal `observe` ring a 2nd time. 0 ⇒ live-read fallback. (Was two identical decls
///         IQuidRepack2/IQuidRepackRet — now collapsed onto the CANONICAL `IEthVenue.repack`
///         in `Interfaces.sol` (rule 2), which already declared this exact signature.)

/// @title  SwapLib — swap/settlement bodies extracted from Aux to free bytecode under the EIP-170
///         limit. The extraction reason is unchanged and still binding; the V4 framing around it is
///         not.
/// ⛔ CORRECTED — THE TITLE DEFINED THIS LIBRARY BY ITS RELATION TO A CALLBACK THAT NO LONGER EXISTS.
///     It read *"non-V4-callback bodies … unlockCallback itself stays in Aux directly (PoolManager
///     calls Aux.unlockCallback by interface; the DELEGATECALL-to-library pattern doesn't compose
///     with V4's unlock semantics)"*. MEASURED: **`unlockCallback` appears ZERO times in `Aux.sol`**,
///     and the only `unlockCallback` left in `evm/src` is one comment in `BasketLib`. There is no
///     PoolManager and no unlock semantics to fail to compose with. ⇒ "non-V4-callback" no longer
///     names a subset of anything — the exclusion it drew is now the whole file.
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
    error BadOp();          // `rangeOpBody` op ∉ {1,2} (custom error — no string-revert bytecode, EIP-170)
    /// @notice Body of Aux.sweep (delegatecall, address(this)==Aux).
    /// Returns (vbtcDelta, swept): caller adds vbtcDelta to rangeBTC and
    /// emits Swept(token, swept).
    function sweepBody(address token, address weth, address wbtc, address gho, address usdg)
        external returns (uint vbtcDelta, uint swept) {
        // §EIP-170 fold: the native-ETH arm and the stable arm ran the SAME tail —
        // `supplySelf(token, swept)` then `return (0, swept)` — and differed only in where `swept`
        // comes from and in the wrap that precedes it. The ETH arm re-points `token` at WETH (the
        // thing it now holds) and falls through to the shared tail, so there is one supply call
        // site instead of two. WBTC still returns early: it is the only arm with a non-zero
        // `vbtcDelta` and it does NOT supply.
        if (token == address(0)) {
            swept = address(this).balance;
            if (swept == 0) return (0, 0);
            WETH9(payable(weth)).deposit{value: swept}();
            token = weth;
        } else if (token == wbtc) {
            swept = IERC20(wbtc).balanceOf(address(this));
            return (swept, swept); // caller adds to rangeBTC inventory
        } else if (token == weth || IAux(address(this)).toIndex(token) != 0
            || token == gho || token == usdg) {
            swept = IERC20(token).balanceOf(address(this));
            if (swept == 0) return (0, 0);
        } else revert UnknownStableSweep();
        IAux(address(this)).supplySelf(token, swept);
    }

    error ZeroAddress();
    error NotBasketStable();
    error SameToken();
    error ZeroAmount();
    error SlippageExceeded();

    /// @notice Body of Aux.auxSwap. Aux wraps this, pre-passing cheap state
    ///         (`toIndex[tokenIn]`/`toIndex[tokenOut]`) and DELEGATECALL'ing here.
    ///         ⚠️ NO `stables` ARRAY IS PASSED, AND `linkAddr` IS NOT LINK. This line named both.
    ///         MEASURED: `Aux.auxSwap` passes `address(this)` for that last parameter, and `_convert`
    ///         hands it to `FeeLib.applyFeeAndHaircut`'s `range` argument — Aux's own address, so the
    ///         depeg severity is read back off Aux (the wrapper's own comment says exactly this). The
    ///         parameter NAME is the stale half; the value has always been Aux.
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
        // §SESS-122 — the `get_deposits()` that used to stand here fed `amounts`/`yieldW` into
        // parameters `applyFeeAndHaircut` never read. Deleting them deletes a whole 16-slot basket
        // read per call on this path.
        uint usdIn  = BasketLib.scaleTokenAmount(pulled, tokenIn, true);
        uint usdOut = FeeLib.applyFeeAndHaircut(tokenOut, usdIn, linkAddr);
        return BasketLib.scaleTokenAmount(usdOut, tokenOut, false);
    }

    /// @notice Body of `Quid.rangeOp` — the `IEthVenue` venue-op selector — delegatecall'd, so
    ///         `address(this)` is Quid and the `withdrawSelf` callback lands on Quid's own
    ///         self-gated entry (`msg.sender == address(this)` ⇒ the `NotSelf` gate passes).
    ///         `weth` is passed as an arg rather than re-fetched, to avoid an extra external
    ///         call back; `rangeETHLive` is the caller's `rangeETH()` read, which is what
    ///         bounds the take.
    /// 🔴 THERE IS NO CALLER GATE, AND THIS DOCBLOCK USED TO CLAIM ONE. It read *"Wrapper
    ///     enforces `msg.sender == V4` BEFORE delegating; library trusts that gate."*
    ///     MEASURED: `Quid.rangeOp` is plain `public` with no modifier, and the only in-tree
    ///     callers are `QuidLib.sendEth:429` (op 1) and `QuidLib._venueBalanceLib:296` (op 2),
    ///     both reached as `IEthVenue(ev).rangeOp(...)` with `ev == Quid` — i.e. Quid calling
    ///     itself. Anything else that calls op 1 is served too, capped at `rangeETHLive`, and
    ///     the WETH goes to `msg.sender`. **Do not add a bound here to paper over it** (rule 3):
    ///     a caller gate belongs on the wrapper, which is the frame that knows who may call.
    /// @notice ETH-side venue op body. The BTC ops that once shared this entry (native/Lightning
    ///         out, WBTC ERC20 delivery, and the isBTC branches) were DEAD — Quid routes BTC
    ///         through BTCChannels, not here. Removed along with the now-redundant result struct
    ///         and the isBTC/wbtc/ctx/rangeBTCNow params.
    ///         LIVE OPS: 1 = take ETH (capped at the live claim), 2 = read the claim. EVERY other
    ///         value reverts `BadOp` — `op == 0` INCLUDED; there is no deposit op on this entry.
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
    ///         nothing moved — the Aux wrapper reverts `ZeroSent`, selector preserved). `Aux._deposit` is now a
    ///         two-line wrapper around this call, so there is no second copy of the body to keep in step.
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

    /// @dev REPACK-FIRST, then keep ONLY the 5th return — the resolved oracle price. Every swap body
    ///      in this file opens by rebalancing its own range and then pricing off that rebalance, and
    ///      all three wrote the SAME five-element tuple destructure inline, discarding four returns:
    ///      `swapToBody` (`c.range`), `creditSwapInBody` (`rangeVault`) and `_swapOutPrep`
    ///      (`address(this)`). ⭐ RULE 23: nothing in the tree held this shape — `_priceOr` resolves a
    ///      hint that is ALREADY in hand and cannot produce one — and rule 8c's exception applies
    ///      exactly (N inlined bodies folded into ONE routine). **MEASURED: −201 bytes on `SwapLib`,
    ///      the binding contract.** The `range` argument stays a parameter and is NOT derived here:
    ///      the three callers repack three different instances, and which one is the caller's fact.
    /// ⚠️  NOT `view`. `repack()` MUTATES the range; this frame is the mutation, not a read of it.
    ///      It also preserves the stack property the inline blocks were written for: the four
    ///      discarded returns die with this frame, which is why they were block-scoped (`via_ir` is
    ///      off by policy). @return the repack's resolved price, 0 if it could not resolve one — the
    ///      sentinel `_priceOr` reads as "live-read instead".
    function _repackPx(address range) private returns (uint) {
        (,,,, uint p) = ICore(range).repack();
        return p;
    }
    /// @dev Resolve the execution price: the repack-provided core mark if non-zero, else the live oracle TWAP.
    ///      Factored from the swap-body sites — no-optimizer build ⇒ ONE shared body (jump target), not N
    ///      inlined copies of the getTWAPforAsset call, so it genuinely reclaims deployed bytecode (EIP-170).
    ///      §D3 (2026-07-31): this claim was ASPIRATIONAL until then — two verbatim inline copies survived
    ///      in `swapToBody`, tagged "stack-tight", because a CALL in argument position blew the no-`via_ir`
    ///      stack. Fixed by resolving once into the `SwapReq.px` STRUCT FIELD (no new stack slot) and
    ///      SEQUENCING the call out of argument position. Freed 197 bytes. `Stack too deep` is a code-shape
    ///      problem, never a licence to duplicate.
    ///      ⚠️ **THREE CALL SITES REMAIN, NOT FIVE — `swapToBody`, `creditSwapInBody` and
    ///      `_swapOutPrep`, ONE EACH.** The §EIP-170 pass folded `swapToBody`'s two legs into one
    ///      shared resolve, and `_finishSwap` stopped re-resolving what its caller had already put
    ///      in `r.px`. Do not read the "5" this line used to carry as a reason to expect more.
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
                           // local, so the swap body resolves `_priceOr` ONCE without adding a stack
                           // slot — that is what makes the dedup fit under the no-`via_ir` stack budget.
                           // §EIP-170: it now carries that price ACROSS the frame too — `_finishSwap`
                           // reads `r.px` as its `fillPrice` instead of re-resolving the same
                           // expression, and `retainSkewPremium` reads it as the sell leg's conversion
                           // rate. ⛔ It is NOT a discriminator: `px` is non-zero on BOTH legs, so
                           // nothing may branch on it (that is `nativeAmount`'s job).
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
        // REPACK-FIRST: run the range's own rebalance before pricing, and keep only its FIFTH
        // return — the resolved oracle price. That is what `_priceOr` feeds to both skew legs and to
        // `_finishSwap`'s `fillPrice`, so the internal `observe` ring is read at most once per swap.
        // §DE-TICK — what this block captured before was `rangeTicks`, a packed range-edge PRICE
        // LIMIT for the swap. Settlement is at oracle bounded by inventory, so there is no limit to
        // pack and no edge to run to; `sqrtPriceLimitX96`, `InvalidTick` and `PriceLimitAlreadyExceeded`
        // have ZERO code references in `evm/src`. ⛔ Do not reintroduce a price-limit carrier here:
        // `Core.swap` states the replacement (*"the inventory bound in `_fillDelta` is a PHYSICAL
        // limit instead, and an edge that does not exist cannot be crossed"*).
        // §EIP-170 — the block-scoped `(,,,, uint p) = repack()` destructure is now `_repackPx`, ONE
        // routine shared with `_swapOutPrep` rather than two inlined five-element tuple decodes. The
        // stack reasoning it replaces is unchanged and still binds: `swapToBody` is stack-tight by
        // design (`via_ir = false`), a CALL in argument position is what overflowed it (§D3), and a
        // separate frame frees the four discarded returns at its end exactly as the block did.
        uint priceHint = _repackPx(c.range);   // 0 ⇒ `_priceOr` live-reads instead
        {
            // Drain-side backing gate counts standing holdings at PAR (NOT the depeg haircut): the mint/issuance
            // side haircuts depeg (Core range-add + mint-headroom) to block over-mint, but the drain side stays at
            // par so a transient depeg can't brick redeems/swaps for existing holders (intentional asymmetry;
            // redeem VALUE is separately haircut in _redeemQuote). See DepegBackingProbe.
            (uint[16] memory _deposits,,,) = aux.get_deposits();
            if (ICore(c.core).committedUsd18() > _deposits[15]) revert UnderBackedS();
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
            // §AUXIDLE — `_depositVol` PLACES what it takes (it composes `_supply(asset, _deposit(…))`),
            // so this line no longer leaves the swapper's WETH idle at Aux for a later drain to sweep.
            // The return is unchanged (`supplyVenueBody` returns its argument verbatim). ⛔ Do not
            // add a placement call here as well — it would double-supply. See `Aux._depositVol`.
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
            //   (2) ✅ **RETIRED 2026-08-29 — THIS BLOCKER IS GONE.** It read: "place+unwind-in-ONE-tx
            //       is INCOMPATIBLE with the existing outOfRange/pull primitive — pull() enforces
            //       `block.number >= created + 47`". §OOR-BOOK-DELETED removed `outOfRange`, `pull`
            //       and the 47-block rule; there is no placement transaction left to be
            //       incompatible with. ⚠️ Blockers (1) and (3) are UNTOUCHED and still bind, so this
            //       does not unblock the idea — it removes one of its three reasons.
            //       ⛔ Do NOT read the deletion as permission: a resting intent is not a placement,
            //          and the tryPair idea would need one.  (numbering kept so (1)/(3) still refer)
            //   (3) this body runs DELEGATECALL'd in Aux context; a mid-swap re-entry into Quid's
            //       onlyUs addLiq/unwindForRedeem on the SHARED range needs its reentrancy + price-
            //       impact interaction with the V4 unlock callback worked out.
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
        }
        // SYMMETRIC A-S skew, ONE SITE FOR BOTH LEGS (§EIP-170 fold): the two branches ran the
        // IDENTICAL three statements and differed only in WHICH skew producer they read and in the
        // `nativeAmount` flag, both of which are `r.forVolatile`. Each branch ended with this block,
        // so hoisting it below the `if` preserves the order exactly — `r.amount`/`r.token` are already
        // in their post-consume state either way, which is what both producers must see.
        //   • sell leg (`!forVolatile`, volatile IN): a sell that pushes the pool's volatile inventory
        //     PAST target is inventory-INCREASING (the self-funded short's range-leg shed) ⇒ charge the
        //     same A-S premium the drain does; a sell that REFILLS a scarce reservoir REDUCES imbalance
        //     ⇒ sellSkew's mirror+flush yields 0 (EXEMPT). Scale the volatile input DOWN by the premium
        //     ⇒ less USD credited out; the withheld input stays as basket backing. `nativeAmount = true`
        //     ⇒ NATIVE volatile input, so the flag says convert.
        //   • drain leg (`forVolatile`, volatile OUT): the same effective-rate scarcity skew as the
        //     native-BTC well (creditSwapOutBody). ETH reuses the IDENTICAL surface (SOR depth isn't
        //     guaranteed); WBTC swap-out drains the same POOLED, so it's skewed too (else arbers route
        //     around the premium). Scale the buy DOWN so a scarce pool hands out less volatile; the
        //     withheld input stays as backing. `nativeAmount = false` ⇒ buy-driving USD, already 6-dec,
        //     recorded verbatim. `r.amount` IS the 6-dec drain size here (§E68).
        // Both producers execute at the honest oracle (priceHint) through routeSwap ⇒ no manip-guard
        // exemption. `retainSkewPremium` mutates `r.amount` in both cases.
        {
            r.px = _priceOr(priceHint, address(aux), r.asset);
            uint skew = r.forVolatile ? wellSkew(c.core, r.px, r.amount)
                                      : sellSkew(c.core, r.px, r.amount);
            retainSkewPremium(c.core, r, skew, !r.forVolatile);
        }
        max = _finishSwap(ctx, aux, r, r.forVolatile, max);
    }

    /// @dev routeSwap (7-field `Types.RouteParams` build) + bumpQuidBTC + the slippage/zero-fill
    ///      guard + the #105 refund, in its own frame so swapToBody stays within the legacy stack —
    ///      no via_ir crutch.

    function _finishSwap(Types.AuxContext memory ctx, IAux aux, SwapReq memory r,
        bool inputIsUsd, uint pooled) private returns (uint max) {
        uint poolSupplied;
        // §EIP-170 — READ THE PRICE THE CALLER ALREADY RESOLVED. This re-ran `_priceOr(priceHint, …)`
        // for the SAME asset in the same transaction; `swapToBody` sets `r.px` from that exact
        // expression on both legs before it calls here, so the second call could only ever return
        // the same number (the repack mark if non-zero, else the live TWAP — and `getTWAPforAsset`
        // is a view over state neither leg has touched in between). `SwapReq.px` is a struct field,
        // not a stack slot (§D3), so carrying it costs nothing the frame was not already paying.
        uint fillPrice = r.px;
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
    /// 🔴 §AUXIDLE — **THE VOLATILE-IN REFUND NOW SOURCES FROM THE VENUE, NOT FROM THE INPUT THAT IS
    ///      STILL SITTING AT AUX.** `_depositVol` used to leave the swapper's WETH idle at Aux for
    ///      the whole frame, so this `withdrawSelf` was served by `QuidLib.withdrawETH`'s Aux-sweep
    ///      rung out of the swapper's OWN deposit — exact, to the wei. It now places into the venue
    ///      in its own call, so `withdrawETH` finds no Aux idle, falls through to the
    ///      `LevMath.sourceWeth` Curve rung, and serves `min(amount, wethBal)` — a PARTIAL FILL, no
    ///      revert. ⇒ On a partial-fill volatile-in swap the refund can be short by the Curve
    ///      round trip (`sourceWeth` sells at a 0.5% floor; measured honest slippage 1.4–3.5 bps),
    ///      and the shortfall stays at `Quid` as idle WETH, which `_rangeETH` counts — so it is a
    ///      swapper-vs-LP transfer, NOT a leak, and Σbacking is unchanged.
    ///      ⚠️ THE SIZING DOES NOT MOVE HERE, AND MOVING THE PLACEMENT LATER WOULD NOT FIX IT: the
    ///      retained skew premium (`retainSkewPremium` decrements `r.amount` and transfers nothing)
    ///      also stays as WETH at Aux, so a post-refund placement sized by `consumed` would leave
    ///      the premium unparked — the same defect, smaller. Place all of it at the deposit.
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
            amount = LevMath.scaleTo6(aux.deposit(msg.sender, token, amount), token);
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
        {   (uint[16] memory d, uint[16] memory yW,, uint dl) = aux.get_deposits();
            // yW[0] = Σ balance×rate (the annualised-rate numerator), NOT d[0] = Σ yieldWeighted.
            (solvent,) = aux.get_metricsWith(d[15], yW[0]);
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
    // §ONE-WEETH-HOP — `curveSellWeeth` is DELETED. It had become a one-line wrapper over
    // `LevMath.sellWeethOnCurve` once the duplicate body was folded, and a wrapper that only
    // forwards is bytecode this contract cannot afford: SwapLib went 44 bytes OVER EIP-170 and
    // this is what bought the headroom back. Both callers now name the one body directly.

    /// @notice Body of Aux._sourceWethFromEtherfi — opportunistic, non-blocking.
    // §SIZE — `sourceWethBody` MOVED TO `LevMath.sourceWeth`. It is weETH-offramp code and the one
    // body it swaps through (`sellWeethOnCurve`) already lives there, so cohesion and headroom
    // pointed the same way: SwapLib was 32 bytes OVER EIP-170 after the OOR additions and this is
    // what bought it back. It takes the two fields directly rather than `OfframpCfg`, because
    // SwapLib imports LevMath and the reverse would be a cycle.

    // ─── BTC swap-IN / swap-OUT bodies (extracted to free bytecode) ──
    // ⛔ THE WRAPPER IS `Vault`, NOT `Aux`. This header said the gate *"stays in Aux's wrapper"* and
    // that the handles are *"Aux immutables"*; MEASURED: `Aux` declares neither `creditSwapIn` nor
    // `creditSwapOut`, and `Vault.sol:679`/`:691` do, both `onlyBTCChannels`, both passing
    // `address(CORE)`, `address(this)` and `address(AUX)` in. `Aux` has NO BTCChannels-gated
    // entrypoint at all (its own note says so).
    // DELEGATECALL'd → address(this)==the Vault, msg.sender==the Vault's original caller. The
    // `onlyBTCChannels` gate stays in that wrapper (rogue-mirror defense: a rogue contract must not
    // drive these by delegatecalling the library), and CORE / the range vault / WBTC / AUX arrive as
    // args because a library cannot read the caller's immutables. The AuxContext is built
    // field-by-field rather than as a literal (stack), leaving vault==0 and nativeWETH==false as the
    // zero-defaults of a fresh memory struct — which is what the BTC rail needs.
    error StableMissing();
    error SwapOutShort();
    error SwapInShort();
    error SwapInDrainsProceeds();

    /// @notice Body of `Vault.creditSwapIn` — settle a BTC→USD swap-IN. See that
    ///         wrapper's docblock for the full semantics.
    /// @param rangeVault THE BTC VAULT, not Quid. It was named `core` — which means Quid/ETH everywhere
///        else — while `Vault.creditSwapIn:684` passes `address(this)`. ⛔ It is `rangeVault`, NOT
///        `core`, that the `repack()` below is called on: that no-arg overload is the BTC range's own
///        rebalance (`Interfaces.sol:641`), and `Vault`'s own comment at the call site says so. Pointing
///        it at `core` would repack the wrong instance.
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
        // ⛔ §E9's NOTE IS REVERSED BY §DE-TICK, AND IT SAT ON THE LIVE BTC SWAP-IN MONEY PATH.
        // It read *"this field now carries the RANGE'S PACKED TICKS, not a price. `Core._handleSwap`
        // unpacks it into the swap's `sqrtPriceLimitX96`"*, and warned that *"passing a real
        // spotPrice here is what broke 132 tests (`InvalidTick` / `PriceLimitAlreadyExceeded`)"*.
        // **A real spotPrice is now the ONLY correct thing to pass.** `priceHint` takes `repack`'s
        // 5th return — the resolved oracle price (`:40`) — and lands in `rp.fillPrice` below via
        // `_priceOr`. MEASURED: `sqrtPriceLimitX96`, `InvalidTick`, `PriceLimitAlreadyExceeded` and
        // `rangeTicks` have ZERO code references in `evm/src`; the surviving hits are comments, and
        // `:374` records `rangeTicks` being deleted because it *"packed a range-edge PRICE LIMIT"*.
        // ⇒ A reader who trusted this would have converted a price to a tick that nothing unpacks.
        // The "all three producers must agree" instruction survives INTACT, with the subject
        // inverted: this one, `_swapOutPrep` and `_finishSwap` must all pass the PRICE.
        // Block-scoped: these bodies are stack-tight by design (`via_ir = false`). §EIP-170 turned
        // that block into `_repackPx`, the ONE frame all three producers share — same stack effect,
        // one copy of the five-element tuple decode instead of three.
        uint priceHint = _repackPx(rangeVault);
        Types.RouteParams memory rp;
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
        // and the rail it names is live: `BTCChannels` calls `btc.creditSwapIn(...)` →
        // `Vault.creditSwapIn:679` → `creditSwapInBody` here, driven off-chain by the hop daemon.
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

    /// §MIN-SWAP-FEE — **EVERY SWAP PAYS THIS, INCLUDING A BALANCE-RESTORING ONE.** 420 ppm, the
    /// exact flat tier §E311 deleted. Owner, 2026-09-08: *"the minimum swap fee was just the fact
    /// that all swaps even balance restoring must pay at least the minimum."*
    /// 🔑 **WHY THE DELETION LOST A PROPERTY NOBODY NOTICED.** §E311 removed the flat 420 arguing
    /// `_depletion` *"already WAS that charge, in inventory-proportional form"* — true **on the drain
    /// direction only**. `_depletion` returns 0 when `inv1 >= inv0`, which is precisely a swap that
    /// does NOT deplete inventory; `sellSkew` returns 0 for the refill leg; and `retainSkewPremium`
    /// opens `if (skew == 0) return;`. ⇒ a balance-restoring swap paid **exactly zero**, on both
    /// assets. The substitution was justified against drains and applied to everything.
    /// ⚠️ **THIS IS NOT THE SCARCITY PREMIUM, AND IT DOES NOT CONTRADICT §SESS-18's *"the refill
    /// direction ... is the direction we want free"*.** Free of the PREMIUM is right — a refill
    /// relieves scarcity and must not be charged for relieving it. This is the FLOOR every swap pays
    /// for consuming the venue at all. Two quantities that happened to share one number.
    /// ⛔ APPLIED AT THE PRODUCERS, NOT AT `retainSkewPremium`, so the published QUOTE carries it —
    /// flooring only at the fill would quote 0 and then charge 420 ppm.
    uint public constant MIN_SWAP_SKEW_WAD = 4.2e14;    // 420 ppm — the floor, on every swap
    // Avellaneda–Stoikov calibration. `realizedVarianceWad` is ANNUALIZED realized variance in WAD:
    // a fraction² scaled 1e18, e.g. 80%-annualized vol ⇒ σ² ≈ 0.64 ⇒ ~6.4e17. Γ folds the
    // risk-aversion γ and the horizon (T−t) into ONE coefficient (the horizon is already carried by
    // the FLOW_DECAY-smoothed flow/scarcity).
    // ⛔ Do not restore the old calibration *"Γ fixed so skew(q=1, σ²=SIGMA_REF) = MAX_WELL_SKEW"*
    //    or the `tickVar·(SECS_PER_YEAR/THETA_STEP)·1e10` unit derivation. `SIGMA_REF`,
    //    `MAX_WELL_SKEW` and `tickVar` have ZERO CODE references in `evm/src` (every hit is a
    //    comment), the ×1e10 died with the ticks (a tick was 1 bp ⇒ 1e-8 × 1e18 = 1e10;
    //    `ringVariance` now returns WAD relative variance directly), and the calibration was
    //    CIRCULAR anyway: `SIGMA_REF = 1e18` made Γ ≡ MAX_WELL_SKEW, the cap under a second name.
    //    Γ now stands alone as the inherited 3e16 its own docblock flags as unchosen (§E274).
    // ⇒ **A constant explained by pointing at a symbol becomes unexplained when the symbol goes** —
    //    `DEPLETION_RATE_WAD`'s header records that same loss twice. State units, do not cite them.
    // STABLENESS = ρ, the DEPLETION-BARRIER ORDER (derived, NOT a fit exponent). The skew is
    // Γ·σ²·q / (1−q)^ρ: the A-S linear reservation premium Γσ²q amplified by the shadow price of the
    // last inventory units. Derived from the HJB with a HARD inv≥0 constraint — a −log(inv) barrier
    // (the LP physically cannot serve at inv=0) whose marginal ∝ 1/inv makes depletion convexly
    // costly. ρ=1 = the log-barrier (constraint exactly at inv=0); ρ=0 recovers plain linear A-S;
    // ρ>1 = a harder barrier. Calculus-derived — the one parameter is a barrier order, not a curve fit.
    // ⚠️ READ THAT AS THE DERIVATION OF WHY THE EXPONENT IS 1, NOT AS A LIVE DIAL. `STABLENESS` has
    // ZERO code references in `evm/src`; it was deleted with `SIGMA_REF` and the old `GAMMA_WAD`
    // definition, byte-identically, because ρ was 1 and its loop
    // (`for (i = 1; i < 1; …)`) never executed. The kernel below is the simple pole written out —
    // which is what A&S §2.3 derives anyway, the exponent fixed at 1 by the CARA value function
    // rather than fitted. The tunable that DID survive is `KAPPA_WAD`, the pole's LOCATION (§E289).
    // Volatile range half-width, in bps of price. `updateBounds(price, delta)` reads it as
    // `price·(10000∓delta)/10000` — the ONLY consumer, and it works in absolute PRICES.
    // Quid SERVES swaps and RESEATS, so it cannot sit at a degenerate half-width like a static
    // position: at delta = 0 the reseat re-add collapses `lower == upper`. ⚠️ **THE ±0.2% THAT USED
    // TO BE ASSERTED HERE AS THE LIVE WIDTH IS HISTORY — see the §WIDENED block below: the constant
    // is 200 (±2%) since 2026-09-08.** The "thinnest non-degenerate half-width" argument is why 20
    // was CHOSEN, not a property of the value in force; the degeneracy bound it appeals to is δ = 0
    // and binds at neither width. Frequent repacks are covered by repack-first (swapper-paid) + the
    // self-funded reseat crank — no separate gas budget needed.
    // ⛔ CORRECTED — THIS NAMED TWO DEAD SYMBOLS AND A DEAD ENGINE. It read *"paddedSqrtPrice reads
    // it as …"* and *"at delta=10 the reseat re-add (updateTicks(targetSqrt,10)) collapses
    // lower==upper and V4 reverts"*. `paddedSqrtPrice` is deleted (§E347/§E347b); `updateTicks` and
    // `targetSqrt` have ZERO code references in `evm/src` — every remaining hit is a comment; and
    // there is no V4 to revert. **The delta=10 figure went with them**: it described a TICK-SPACING
    // degeneracy, not a price one, and `updateBounds` is degenerate only at delta = 0. Quoting a
    // measured-looking threshold that no live code can produce is how a comment becomes the premise
    // of a re-tune (§E18 at `:690`).
    /// 🔴 **WIDENED 20 → 200 (±0.2% → ±2%) ON 2026-09-08 (owner: *"widen the range delta, K is too
    /// high"*). THIS IS THE ONLY LEVER ON `K`, AND THAT IS ARITHMETIC, NOT PREFERENCE.**
    /// `QuidLib.kLvrWad` is the LVR-to-VALUE ratio of a v3 position — derived from scratch and
    /// confirmed exact: for `V(P) = L(2√P − √Pa − P/√Pb)`, `V'' = −L/(2P^1.5)`, so
    /// `LVR/V = σ²/(4(2 − √(Pa/P) − √(P/Pb)))`, which reduces to **`K = 1/(4δ)`**.
    ///     δ = 20 bps ⇒ K = 125.06        δ = 200 bps ⇒ K = 12.56
    /// ⇒ The formula was never wrong; K was large because the RANGE was tight. Nothing else in the
    /// tree can move K — there is no coefficient to re-tune, only this width.
    /// ⭐ **±2% IS NOT A NEW NUMBER, IT IS THE ONE THE REST OF THE SYSTEM ALREADY ASSUMED.** Every
    /// θ/K figure in `IL-CERTIFICATION.md` is keyed to ±2%, and the BTC range's own seed used
    /// `delta=200` until §ONE-ANCHOR unified it (the note at `Vault.setup` calls that gap "an
    /// unexplained 10x"). Widening closes the drift rather than introducing a choice.
    /// ⚠️ **WHAT IT DOES NOT FIX, STATED SO NOBODY READS MORE INTO IT: θ IS STILL SMALL.**
    /// `θ = feeYield/(K·σ²)`, so at σ=80% and a 5%/yr realised yield this moves θ from ~0.0006 to
    /// ~0.0062 — `applyTheta` still caps pooled near 0.6% of backing. **A 10× improvement that does
    /// not change the regime.** Reaching θ ≈ 0.1 needs K ≈ 0.8, i.e. δ ≈ 32%, i.e. essentially
    /// full-range. ⇒ the remaining question is θ's TIME BASE (an annual yield over an instantaneous
    /// in-range rate — §K-IS-A-SAMPLING-ARTEFACT), not this constant.
    /// ⛔ **DEGENERACY BOUND: `updateBounds` is degenerate only at δ = 0** — the old "delta=10
    /// collapses lower==upper" figure described a TICK-SPACING degeneracy that left with v4, per the
    /// paragraph above. Widening has no lower-bound hazard; it is `soldFraction` and every 20-bps
    /// assertion that move (see `LevMath`'s worked example and `Alles.t.sol`'s TWAP-deviation cap).
    uint internal constant RANGE_DELTA = 200;









    // ═══ §OOR-AS-INTENT — THE OUT-OF-RANGE BOOK, REPLACED BY A SIGNATURE ═══
    // ⭐ **IT LIVES HERE BECAUSE IT IS SWAP LOGIC AND BECAUSE THIS LIBRARY IS ALREADY LINKED.**
    //    `SwapLib` is deployed ONCE and delegatecalled, so the body costs `Quid` — the tightest
    //    contract in the tree — only the call. Inlined in `Quid` the same code measured **2,629
    //    bytes**, taking its EIP-170 headroom from 2,902 to 273. A separate `OorIntentLib.sol` would
    //    have fixed the bytes and added a file; owner: *"we need as few files on solidity as
    //    possible"*, and this is swap logic sitting next to the swap logic.
    //
    // 🔒 **WHY THERE IS NO ON-CHAIN BOOK AT ALL.** The chain stores exactly two things: P&L
    //    attribution and deposit withdrawability. A resting order is NEITHER until it fills, and it
    //    changes neither while it rests. The old book stored `selfManaged[id].owner` and
    //    `positions[owner]` — a public, permanent link from an address to its intentions, for orders
    //    that may never fill. All principal goes to the yield venue with no opt-in precisely so a
    //    withdrawer's anonymity set is "it could be anyone"; publishing resting orders per address
    //    shrinks that set for no accounting benefit. An intent reveals NOTHING until it fills, and at
    //    the fill the owner appears only where settlement reveals them anyway.
    //
    // ⚠️ **WHAT THE v4 BOOK DID BETTER, STATED HONESTLY:** an out-of-range order there was REAL v4
    //    liquidity at its own ticks, so any swap whose price traversed them filled it inside the
    //    PoolManager, in the swapper's own transaction — no separate execution, which is the
    //    strongest MEV protection there is. That property left with §V4-CUT ("one price and no
    //    traversal"), not with this change: `sweepOor` was already only an emulation, capped at four
    //    fills per swap with a poke for the rest. ⇒ The trade is a relayer transaction in exchange
    //    for capital that keeps earning, an oracle bound the relayer cannot fake, and no published
    //    linkage. It is NOT a trade against v4's automaticity, which was spent already.
    struct OorIntent {
        address owner;
        bool    buyVolatile;   // spend basket dollars for volatile once price falls to `limitPx`
        uint256 size;          // the funded side (usd6 buying, volatile selling)
        uint256 limitPx;       // USD18 per 1e18 volatile — the price the ORACLE must have reached
        uint64  expiry;
        uint64  nonce;         // one consumed bit per (owner, nonce); not signing is the cancel
        bool    loadBalance;   // §E308 consent, carried to the fill as an in-range swap carries it
        /// @dev §FILL-PAYS-LESS-NOT-DIFFERENT — the stable a SELL maker wants to be paid in, SIGNED so
        ///      the relayer cannot choose it. `AUX.take` serves this token FIRST (`_takePreferred`),
        ///      and the fill takes what it ACTUALLY delivered as the proceeds — so a basket short of
        ///      it pays LESS of the right token rather than more of the wrong one. Ignored on a buy.
        address payoutToken;
    }
    bytes32 internal constant OOR_TYPEHASH = keccak256(
        "OorIntent(address owner,bool buyVolatile,uint256 size,uint256 limitPx,uint64 expiry,uint64 nonce,bool loadBalance,address payoutToken)");
    /// @dev `internal` so the range manager can build its own cached separator from it — the domain's
    ///      two inputs are fixed at deploy, so it is computed ONCE there rather than per fill.
    bytes32 internal constant OOR_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev OWN FRAME, DELIBERATELY — the EIGHT `OorIntent` fields plus the typehash overflow the
    ///      legacy stack inside `fillIntentBody` ("Stack too deep" at the `abi.encode`, measured).
    ///      `via_ir` is off here by policy, and the standing remedy is to shed locals into another
    ///      frame; `rebalanceCore`'s `_reseatIfStale` split is the same move for the same reason.
    function _oorDigest(OorIntent calldata i, bytes32 domainSep)
        private pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSep,
            keccak256(abi.encode(OOR_TYPEHASH, i.owner, i.buyVolatile, i.size,
                i.limitPx, i.expiry, i.nonce, i.loadBalance, i.payoutToken))));
    }

    /// @dev FOUR CHECKS, AND NONE OF THEM CAN MOVE OFF-CHAIN:
    ///      1. `expiry` — an intent is not immortal.
    ///      2. the consumed bit — one fill per `(owner, nonce)`, set BEFORE settlement. ⚠️ THE ONLY
    ///         STORAGE, AND IT IS WRITTEN AT FILL, NEVER AT REST.
    ///      3. the SIGNATURE — the OWNER authorises, so a fully-compromised keeper holds no key that
    ///         moves funds. Plain `ecrecover`, NOT `SignatureCheckerLib`: §B7 records that `lpEth`
    ///         is derived from the channel key, so an LP is necessarily that key's EOA and a
    ///         smart-wallet LP is not expressible. ERC-1271 would cost ~2 KB for a ruled-out case.
    ///         If §B7 is ever un-ratified, this is where it comes back.
    ///      4. ⭐ THE ORACLE — OUR read, the same source settlement uses. The relayer picks WHEN and
    ///         nothing else; a keeper that lies about the price is refused by the contract that owns
    ///         it. §C2.1's discipline (the keeper names a venue, never a rate) applied to time.
    ///      ⭐ THE DELTAS ARE AT THE LIMIT, NOT SPOT — the maker is owed the price they signed.
    ///      Sign rule is `_handleDelta`'s, which is v4's caller-perspective `BalanceDelta` one layer
    ///      up: POSITIVE leaves the pool (the PM owes us, we take), NEGATIVE enters it (we owe the
    ///      PM, we settle) — a credit must exist before a debit can. Verified against
    ///      `Core._settleUsdSide`: `usdDelta > 0` takes `_poolUsdInRange(..., mint=false)`, a BURN,
    ///      and then pays out. Positive is value LEAVING.
    function fillIntentBody(
        mapping(address => mapping(uint64 => bool)) storage used,
        OorIntent calldata i, bytes calldata sig,
        address core, address aux, address asset, bytes32 domainSep
    ) external returns (int usdDelta, int volDelta, uint wantUsd6) {
        if (block.timestamp >= i.expiry) revert IntentExpired();
        if (used[i.owner][i.nonce]) revert IntentUsed();
        if (sig.length != 65) revert IntentBadSig();
        if (ecrecover(_oorDigest(i, domainSep),
                uint8(sig[64]), bytes32(sig[0:32]), bytes32(sig[32:64])) != i.owner)
            revert IntentBadSig();
        // ORACLE BINDS: a bid fills only once the price has fallen TO OR THROUGH its limit.
        uint px = IAux(aux).getTWAPforAsset(asset, 1800);
        if (i.buyVolatile ? px > i.limitPx : px < i.limitPx) revert IntentNotCrossed();
        used[i.owner][i.nonce] = true;
        if (i.buyVolatile) {
            // ⭐ **THE FUNDING LEG — AND ITS POSITION IS THE FIX.** Everything above VERIFIES; this
            //    is the first line that MOVES anything, and it moves the maker's side FIRST. That is
            //    the convention every other settlement in this tree follows and this one did not:
            //    `auxSwapBody` `safeTransferFrom`s the swapper's stable before `Core.swap` records
            //    it, and the deleted OOR book ran `AUX.deposit` before `CORE.outOfRange`.
            //    §INTENT-HAS-NO-FUNDING-LEG measured what its absence cost: an address holding no
            //    ether, no dollars and no LP position was paid $1,000 of real ether.
            // ⚠️ **AFTER THE SIGNATURE, NECESSARILY.** `spendClaim` takes `owner` as a parameter and
            //    burns their QU!D; the EIP-712 check above is the only thing that authorises it.
            //    Move this earlier and it becomes the same defect wearing a debit.
            // ⭐ **AND THE CREDIT IS DERIVED FROM THE DEBIT, NEVER FROM `i.size`.** `spendClaim`
            //    CAPS at the maker's mature claim (redeem's rule — a short holder is served, not
            //    refused), so `funded` is what the burn actually realised. Settling `i.size` would
            //    reintroduce the unbalanced entry in a quieter form: the maker funds part and the
            //    range credits all of it.
            uint funded = IAux(aux).spendClaim(i.owner, i.size);
            if (funded == 0) revert IntentUnfunded();
            uint volOut = BasketLib.convert(funded, i.limitPx, true);
            // `volOut > POOLED()` is now a floor rather than the mechanism: the fill is bounded by
            // the maker's own claim, so it cannot ask the range for more than that claim funds
            // (§INTENT-WHAT-IS-THE-PROBLEM).
            if (volOut == 0 || volOut > ICore(core).POOLED()) revert IntentUnfillable();
            usdDelta = -int(funded); volDelta = int(volOut);
        } else {
            // 🔴 **THE SELL LEG IS NOT MERELY UNFUNDED — ITS SETTLEMENT IS WRONG FOR AN LP MAKER,
            //    WHICH IS WHY IT IS GATED RATHER THAN GIVEN THE SAME TREATMENT.** A sell spends the
            //    maker's IN-RANGE ETH, and an in-range LP's ether is ALREADY in `POOLED`. The old
            //    line here was `volDelta = -int(i.size)` ⇒ `POOLED += size`, i.e. the range GAINING
            //    ether it already held. The debit is not a missing call here; the settlement shape
            //    is `_withdraw`'s rather than `settleOor`'s, and it must cap at
            //    `plainNet(pooled, levPooled)` — never `pooled` — because "a levered claim can never
            //    pull deliverable ETH that backs unlevered LPs". See §INTENT-HAS-NO-FUNDING-LEG.
            // ⭐ THE SELL SETTLES IN `Quid`, NOT HERE, AND THAT IS THE POINT. Its legs touch per-LP
            //    share state (`autoManaged`) and pay a basket token — neither reachable from this
            //    library — while everything ABOVE this line (expiry, replay, signature, oracle) is
            //    direction-agnostic and stays in one place. Returning `wantUsd6` rather than
            //    settling keeps the verification single-sourced and the settlement where the state is.
            //    ⚠️ `volDelta` STAYS ZERO: an in-range maker's ether is ALREADY in `POOLED`, so
            //    `Core._handleDelta` must neither pay it out (`> 0`) nor book it in (`< 0`).
            wantUsd6 = i.size;
        }
    }

    /// @notice The maker's basket claim funded nothing — no mature QU!D, or a fully depegged basket.
    error IntentUnfunded();
    error IntentExpired();
    error IntentUsed();
    error IntentBadSig();
    error IntentNotCrossed();
    error IntentUnfillable();



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
    ///      Returns a WAD multiplier in [1e18, 2e18]: 1× when this range is the only claimant, and
    ///      exactly 2× at the endpoint `rangeEquityUsd18() == 0` with `committedUsd18() > 0`, i.e. the
    ///      whole shared commitment belongs to the other range. Bounded by construction — it can
    ///      never invent scarcity, only reflect that the shared backing is already spoken for.




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


    /// @notice §FLAT-FEE — THE SWAP-OUT CHARGE IS A CONSTANT. See docs/actionable/TARGET-DESIGN.md.
    ///         The scarcity kernel it replaced priced inventory risk against a flow forecast; under
    ///         balance-sheet absorption the imbalance is carried by the lever, not by the swapper, so
    ///         there is nothing size- or scarcity-dependent left to price on this leg.
    /// ⭐ WHY A CONSTANT IS SAFER THAN A MEASUREMENT HERE, not merely simpler: both measured
    ///    manipulation vectors -- PATIENCE (let the flow EWMA decay, then drain a small target) and
    ///    CLOCK-STRETCHING (space slices 4h, sigma^2 falls 24x, charge falls 93.3%) -- worked because
    ///    the charge depended on STARVABLE MEASURED STATE. A constant cannot be starved, so both
    ///    become unconstructible rather than defended against.
    /// ⚠️ THE LEVEL IS A CALIBRATION, AND ITS DERIVATION MUST BE KEPT CURRENT: it has to exceed
    ///    adverse selection (sigma^2*T_settle/8, worst case ~2.3 bps on BTC at ~400% vol) and stay
    ///    under the competing venue's all-in cost. That band is what makes a constant viable; if it
    ///    ever closes, this stops being a constant question.
    /// @dev `core`, `base` and `drainUsd6` are retained: five call sites pass them and the sell-in
    ///      capacity term (TARGET-DESIGN §3) will read the first of them.
    function wellSkew(address, uint, uint)
        public pure returns (uint)
    {
        return MIN_SWAP_SKEW_WAD;
    }

    /// @notice SYMMETRIC A-S skew for a volatile-IN SELL (the self-funded short's
    ///         range-leg shed). Where `wellSkew` prices the SCARCE side (volatile-OUT drain,
    ///         inv<target), this prices the ABUNDANT side: a sell that pushes the pool's
    ///         volatile inventory PAST target grows the pool's inventory risk, so A-S skews
    ///         the reservation price AGAINST it (`skew = Γ·σ²·q` with q = overshoot). A sell
    ///         that REFILLS a scarce/near-target reservoir REDUCES imbalance and is EXEMPT
    ///         (skew 0). ⛔ **IT DOES NOT CALL `skewWad`, AND THERE IS NO MIRROR.** This docblock
    ///         used to say it *"REFLECTS the post-add inventory about the neutral `target`
    ///         (q ↦ 2·target−q) and calls `skewWad`"*; §E54 deleted both. MEASURED: `skewWad` has
    ///         exactly ONE caller in the tree and it is `wellSkew`. The body below computes its own
    ///         `over = inv − target`, midpoint-averages q over the sell (§E68b), multiplies
    ///         `Γ·σ²·qBar` and hands the bare kernel to `_composePrice`. The exemption is the
    ///         `over == 0` early return, not a borrowed flush guard, and the two legs share the
    ///         COMPOSER (`_composePrice`/`_amplify`), never the kernel. `addedTok` = the volatile just
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
    /// @notice §FLAT-FEE — the sell-in leg, same constant for now.
    /// 🔴 THIS IS THE LEG THAT WILL REGAIN A TERM, AND IT IS NOT THE ONE THAT HAD THE POLE.
    ///    TARGET-DESIGN §3: a sell-in is the CONSTRAINED direction, because borrowing against newly
    ///    supplied collateral only re-dollarises `L` of it, so `(1 - L)` of every sell-in permanently
    ///    backs a dollar claim with volatile. The charge on this leg must rise as that
    ///    re-dollarisation capacity is consumed. It is flat only until the balance-sheet target exists.
    function sellSkew(address, uint, uint)
        internal pure returns (uint)
    {
        return MIN_SWAP_SKEW_WAD;
    }

    /// @notice Body of `Vault.creditSwapOut` — Swap-OUT (USD→BTC), the on-curve
    ///         MIRROR of creditSwapIn. See that wrapper's docblock for the full
    ///         semantics.
    function creditSwapOutBody(address swapper, address token, uint usdAmount, uint minSats,
        address core, address aux) external returns (uint sats, uint usd6) {
        if (usdAmount == 0) return (0, 0);
        _requireStable(aux, token);
        // Two OWN frames so the body stays trivially within the legacy stack (no via_ir): PREP does
        // deposit + oracle + drain-skew + route-params; SETTLE does the buy + proceeds-cap + swapper refund.
        // ⛔ `core` IS **NOT** `address(this)` — this line said it was. `Vault.creditSwapOut:693` passes
        // `address(CORE)`, while `address(this)` is the Vault itself under delegatecall. Both are used,
        // for DIFFERENT things: `ICore(core)` reads `POOLED()` and `refundUnfilled`, `ICore(address(this))`
        // drives the range's own no-arg `repack()` (`Vault.sol:665`). `wbtc` is read from aux INSIDE prep,
        // so neither this body nor its Vault caller carries it as a param — that's what frees the stack
        // for the refund call.
        (Types.AuxContext memory ctx, Types.RouteParams memory rp) =
            _swapOutPrep(swapper, token, usdAmount, core, aux);
        (sats, usd6) = _swapOutSettle(ctx, rp, swapper, token, minSats);
    }

    /// @dev creditSwapOutBody PHASE 1 (own frame): pull the swapper's full stable into the basket, resolve
    ///      the oracle price, apply the drain scarcity skew (the withheld premium stays in Aux as fungible
    ///      backing, tracked by recordSkewPremium — it NEVER enters POOLED), and return the fully-built route
    ///      params. `core` is the Core instance (`address(CORE)`); `address(this)` is the BTC range Vault
    ///      this body is delegatecalled from, and it is that one — NOT `core` — whose no-arg `repack()`
    ///      runs below. `wbtc` via aux.
    function _swapOutPrep(address swapper, address token, uint usdAmount, address core, address aux)
        private returns (Types.AuxContext memory ctx, Types.RouteParams memory rp) {
        address wbtc = address(IAux(aux).WBTC());
        // The normalized 6-dec USD pulled in — exactly what enters POOLED_USD (exact-input curve buy)
        // and thus the exact proceeds owed to the delivering LP (returned so requestSwapOutOnchain records it).
        // §A.50/C1: `deposit` returns TOKEN-NATIVE; this comment long claimed 6-dec. `scaleTo6` is
        // native→6, which is exactly the conversion needed, and it is a NO-OP for the 6-dec stables
        // (USDC/USDT/PYUSD/USDG/AUSD). It bites only for the seven 18-dec stables, which no test
        // currently exercises — see the mixed-decimal Echidna target (§A.70).
        uint amount = LevMath.scaleTo6(IAux(aux).deposit(swapper, token, usdAmount), token);
        ctx.asset = wbtc; ctx.core = core;
        // Reuse the repack-resolved oracle price (5th return); live-read only if priceHint==0.
        // ⛔ IT IS A PRICE, NOT PACKED TICKS — this line said *"§E9 — packed range ticks, not a
        // price"*, which §DE-TICK reversed and `creditSwapInBody`'s own §E9 block already records:
        // `rangeTicks`/`sqrtPriceLimitX96` have ZERO code references and nothing unpacks a tick.
        // It flows straight into `rp.fillPrice` below via `_priceOr`. `_repackPx` is the shared
        // frame (§EIP-170) that the block scope used to be — same stack effect, one copy of the decode.
        uint priceHint = _repackPx(address(this));
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
    // Curve-reseat fires only when the spot is off the oracle by more than this (50 bps).
    // ⛔ IT DOES NOT "MATCH `routeSwap`'S EXECUTION GUARD" — THAT GUARD DOES NOT EXIST. §V4-CUT left
    // `BasketLib.routeSwap` with no deviation check and `Core.swap` settling at the oracle bounded
    // by inventory (`Core.sol:1008`: *"THERE IS NO PRICE LIMIT ARGUMENT, AND NOTHING IS MISSING"*).
    // MEASURED: `BasketLib.isManipulated` has exactly TWO call sites and both are in this file —
    // this one and `rebalanceCore`'s 300-bps repack tolerance. So 50 is the reseat's OWN threshold,
    // and the reason to have one is churn: below it, moving the spot is a no-op nobody needs.
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
    ///   the basket (cherry-pick, held-clamped to keep it on the preferred leg — ⚠️ the clamp is NOT
    ///   sufficient: `held` is accounting, not withdrawable, so a PAUSED vault still reaches pro-rata
    ///   and pays stables the venue cannot repay with. §HELD-IS-NOT-WITHDRAWABLE below is the gate), repays min(wantUsd,debt) + un-encumbers `want` sats
    ///   (manager burns the vBTC), and draws the retired-debt share out of POOLED_USD + clears its obligation.
    function _sourceRepayFree(address core, address aux, address mgr, address lp, uint want, uint wantUsd6, uint exactUsd6)
        private returns (uint deLeverUsd6) {
        (address venue, address stable, uint amtNative) =
            // ✅ §UNCLAMPED-AMTNATIVE — **THE DEBT CLAMP HAS LANDED.** `LevBase.swapOutDeleverAmt`
            //    now reads `p.venue.debtOf(lp)` and caps `amtNative` at it, in the SAME native units,
            //    so the quote and `swapOutDelever`'s own re-clamp at execution agree by construction.
            //    For a long time the docblock claimed that clamp and the code did not have it: the
            //    quote returned `_fromUsd(AUX, stable, maxUsd18)` — the FULL requested size, whatever
            //    the position owed — with the only real clamps being `held` (what the basket has) and
            //    `exactUsd6` (the delivery's own proceeds), NEITHER of which is the debt.
            //    ⛔ **KEEP THE MEASUREMENT BELOW. IT REFUTED A SCARIER READING AND MUST NOT BE LOST.**
            //      The open question was an over-draw of POOLED_USD at LOW LTV, where a slice's
            //      proceeds share exceeds what it owes. Measured against a control changing ONE
            //      variable, the LTV:
            //        10% LTV  DRAWN 4,989,994,049  RETIRED 4,196,608,646
            //        50% LTV  DRAWN 9,989,999,999  RETIRED 4,196,608,646   ← identical retirement
            //      ⇒ RETIRED IS BYTE-IDENTICAL ACROSS BOTH: retirement is bounded by the DELIVERY
            //        SIZE (`want` sats), not by the debt, so the missing clamp never produced an
            //        LTV-dependent retirement shortfall. And the gap is LARGER at HIGH LTV — the
            //        OPPOSITE direction from the over-draw hypothesis. `DRAWN` tracks delivery size.
            //      ⇒ The ~793,39x,xxx that looked like an over-draw is the DEBT-BUFFER RESIZE, and
            //        `syncLev` restores it (+793,391,943 measured in the 50% control). The async
            //        reconcile promised below is REAL.
            //    ⇒ WHAT THE MISSING CLAMP ACTUALLY COST was not retirement and not an over-draw: it
            //      was **STRANDED STABLE AT THE VENUE** — the gap between the quoted take and what
            //      `repay` would approve sat on the adapter, off the basket's books. That is the leak
            //      the clamp closes. Do NOT re-derive an over-draw from this history; it was measured
            //      and refuted, and the clamp was landed for the stranding, not for the over-draw.
            ILevManagerDeliver(mgr).swapOutDeleverAmt(lp, wantUsd6 * 1e12);
        if (venue == address(0)) return 0;
        uint takeUsd18 = LevMath._toUsd18(aux,stable, amtNative);
        { uint held = _heldUsd18(aux, stable); if (takeUsd18 > held) takeUsd18 = held; } // stay on the cherry-pick leg
        // 🔴 §REFILL-HEADROOM — ONLY DOLLARS ABOVE WHAT THE BASKET ALREADY OWES (owner, 2026-09-08:
        //    *"if you fund by basket you can only use dollars over the supply of what is redeemable
        //    now"*). `takeToSettle` passes `softBacking = true`, so its terminal check is
        //    `tryCheckBacking()` — which REPACKS AND RETURNS REGARDLESS. Every user-facing drain gets
        //    the STRICT `checkBacking()` that reverts on `committed > liquid`; this path alone was
        //    permitted to leave the invariant violated, on the stated ground that "its mid-drain
        //    instant is offset by an in-tx debt-repay".
        //    ⚠️ MEASURED, AND THE STATED OFFSET DOES NOT HAPPEN: across a delivery, committed moved
        //      by ZERO (it is a PUSHED value this path never re-pushes) while liquid fell by the full
        //      repay. There is no offset on either side. The pool is not worse off — obligations fall
        //      ~2.4x faster than liquidity — but nothing ENFORCES that, and a level check that never
        //      reverts is not enforcement.
        //    ⇒ Bound the DRAW by the headroom instead: a refill may consume only what the basket
        //      holds ABOVE its committed claim. Fail-SAFE — it can only ever REDUCE the take, and a
        //      smaller take is the same partial de-lever the `held` clamp already produces (the sats
        //      are freed regardless; see `swapOutDelever` below).
        //    ⛔ Do NOT "restore" this to the soft check alone: a non-reverting solvency probe sizes
        //       nothing, and this is the ONLY drain in the tree without a hard bound.
        //    📌 READS THE SAME TWO QUANTITIES `Core._poolUsdInRange`'s gate compares — `_d[15]`
        //       (18-dec TVL) less `depegLoss`, against `committedUsd18()` — so the bound and the gate
        //       cannot disagree about what "backed" means.
        {   (uint[16] memory amts,,, uint depeg) = IAux(aux).get_deposits();
            uint liquid = amts[15] > depeg ? amts[15] - depeg : 0;
            uint committed = ICore(core).committedUsd18();
            uint headroom = liquid > committed ? liquid - committed : 0;
            if (takeUsd18 > headroom) takeUsd18 = headroom;
        }
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
            // 🔴 §PAUSED-VAULT-REROUTE — **THE TAKE LANDS AT THE MANAGER, NOT THE VENUE, AND THAT MOVE
            //    IS THE WHOLE FIX.** `takeToSettle` cannot always serve the venue's own loan token: a
            //    PAUSED vault sends `Aux`'s PRO-RATA leg down a different stable (measured: DAI at a
            //    USDC-debt venue). Paid straight to the venue that value is unreachable — `LevVenueBase`
            //    only ever moves its own `STABLE` — so the old code could only `revert`, which is a
            //    denial of service on an LP whose channel BTC has ALREADY left.
            //    ⇒ Landing it at the manager puts it where `LevMath._consolidateTo` can convert it
            //      (`stable → USDC → target` on the keyless `_hubRowOf` Curve rows), then the manager
            //      pays the venue. The happy path is UNCHANGED in effect: when `Aux` serves the venue's
            //      own stable, consolidation skips it (`s == target ⇒ continue`) and the same amount
            //      arrives at the same place.
            //    🔴 §REFUND-TO-AUX — **REFUND DESTINATION IS `aux`, AND THE VAULT WAS A ONE-WAY DOOR.**
            //      The rule this argument encodes is right and unchanged: these stables are the
            //      BASKET's, so the LP-refund that is correct in `protectFromQuid` would be a leak
            //      here. What was WRONG is the destination that rule was resolved to. This passed
            //      `address(this)` — under the Vault's delegatecall that IS the Vault — and
            //      **`grep -c "IERC20\|safeTransfer" evm/src/Vault.sol` returns 0**: the Vault has no
            //      code that can move an ERC20, and `Aux.sweep` operates on `balanceOf(Aux)` under
            //      Aux's OWN delegatecall, so it cannot reach a balance parked at the Vault.
            //      ⇒ Every refunded slice was PERMANENTLY STRANDED and INVISIBLE to `get_deposits`
            //        — pool value deleted, silently, ON THE ORDINARY PATH RATHER THAN AN EXOTIC ONE.
            //        A refund is not a rare event: `_consolidateTo` skips-and-refunds any slice with
            //        no `_hubRowOf` row (**GHO has none at any roster size**) AND, since §SESS-121's
            //        `q >= floor` gate, any slice whose pool is merely THIN at the size being
            //        traded. That gate deliberately converts a would-be revert into a refund, so it
            //        makes this destination MORE load-bearing, not less — a liveness win upstream is
            //        a bigger leak downstream until the refund lands somewhere that can spend it.
            //      ⇒ `aux` IS THE DESTINATION THE RULE ALREADY IMPLIED: these stables came FROM the
            //        basket, so they belong back at the basket. At Aux the PERMISSIONLESS
            //        `Aux.sweep(stable)` → `supplySelf` puts them back in a vault AND back on the
            //        books (`sweepBody` covers every `toIndex != 0` stable plus GHO and USDG
            //        explicitly), so the value is recoverable by anyone and visible to
            //        `get_deposits`. ⛔ Do NOT "restore" the Vault here, and do NOT reach for the LP:
            //        the LP arm is the leak this comment always warned about; the Vault arm was a
            //        DIFFERENT leak that the same sentence hid.
            IAux(aux).takeToSettle(mgr, BasketLib.scaleTokenAmount(takeUsd18, stable, false), stable); // basket → manager
            ILevManagerDeliver(mgr).consolidateForRepay(lp, aux);                                     // → venue's own token → venue; unroutable → back to the basket
            got = IERC20(stable).balanceOf(venue) - bal0;        // venue-stable actually sourced (native units)
        }
        // 🔴 §HELD-IS-NOT-WITHDRAWABLE — THE SAME FAIL-SAFE AS THE `takeUsd18 == 0` BRANCH ABOVE, ON
        //    THE QUANTITY THAT ACTUALLY BINDS. That branch refuses to settle unbacked when the basket
        //    holds none of the venue's stable, but `_heldUsd18` is an ACCOUNTING figure: a PAUSED
        //    vault reports the stable held while nothing can be withdrawn. The guard then reads "we
        //    have it", `_takePreferred`'s try/catch turns the paused withdrawal into `sent = 0`, and
        //    the whole request falls to the PRO-RATA leg — which pays OTHER stables this venue cannot
        //    repay with. `_sourceRepayFree`'s own docblock claims the held-clamp prevents that.
        //    MEASURED, it does not (`testReal_MEASURE_ProRataFallback_VenueStableVaultPaused`, USDC
        //    vault paused): delivery SUCCEEDED, debt retired ZERO — 23,673,988,759 before AND after —
        //    basket liquid −1,377,974,721,301,924,123,211, and 1,377,974,721,301,924,123,210 of
        //    **DAI** left sitting at the venue, off by one wei. The sats were freed against no repay.
        //    ⇒ `got` IS the withdrawable test, empirically: what actually arrived in the venue's OWN
        //      stable. A `maxWithdraw` probe would be a SECOND accounting figure that can lie the
        //      same way `held` does; this one cannot. The revert unwinds the mis-sent stable with the
        //      rest of the tx, so nothing strands.
        //    ⛔ STILL THE FAIL-SAFE, BUT NO LONGER THE FIRST ANSWER. The reroute above runs BEFORE this
        //       line, so reaching it now means the basket paid nothing the hub table could convert —
        //       not merely that the venue's own vault was paused. Blocking still beats settling
        //       unbacked (the splice already paid the swapper, and a revert re-tries the EVM leg
        //       against a still-valid SPV proof), but it is now the LAST resort rather than the only
        //       one, which is what the owner asked for: *"no denial.of service"*.
        if (got == 0 && amtNative > 0) revert DeleverStableUnavailable();
        // Repay `got` (0 if the position had no debt — a pure-equity levered slice) and free `want` sats regardless.
        ILevManagerDeliver(mgr).swapOutDelever(lp, LevMath._toUsd18(aux,stable, got), want);
    }

    /// @dev Held USD (18-dec) of a single basket stable = its get_deposits slot. In the uint[16] vector,
    ///   `amounts[i+1] = balance` is the depeg-adjusted per-stable hold (BasketLib:173), `amounts[0]` is
    ///   the yield-weighted aggregate and `amounts[15]` the TVL total. BOLD is `stables[nStables-1]` and
    ///   Aux writes its SP leg to `amounts[nStables]`, so a real stable's `toIndex` is in `[1, nStables]`.
    /// 🔴 §ROSTER-ALIGN — THE BOUND IS DERIVED, AND THE LITERAL IT REPLACES WAS A LIVE FAIL-CLOSED DoS.
    ///   This read `idx >= 12` and its docblock justified the 12 by citing the **11**-stable
    ///   `DriverE2E.s.sol` roster. The SHIPPED roster is 14 (`DeployL1_s.sol` asserts it), so on
    ///   mainnet crvUSD (12), frxUSD (13) and BOLD (14) all tripped the guard and returned 0 held —
    ///   not "no holdings", but "this stable does not exist". The caller reads that as nothing to
    ///   draw and refuses the delivery, so a levered swap-out denominated in any of the three was
    ///   dead on arrival while the basket held them. A NEW literal would re-arm the same trap on the
    ///   next roster change, so the roster answers for itself.
    /// ⚠️ Slots above `nStables` (up to 14) and slot 15 are still rejected: unused slots read 0 and
    ///   the total is not a per-stable hold.
    function _heldUsd18(address aux, address stable) private returns (uint) {
        uint idx = IAux(aux).toIndex(stable);
        if (idx == 0 || idx > IAux(aux).getStables().length) return 0;
        (uint[16] memory amts,,,) = IAux(aux).get_deposits();
        return amts[idx];
    }

    /// @notice §SILENT-SKIP — A STUCK LP ON THE DELIVERY PATH IS NOW ANNOUNCED. Its twin already was:
    ///         `LevManager.cascadeDelever:369` and `BtcLevManager:271` both do
    ///         `catch { emit DeleverFailed(lp, getCurrentLtvBps(lp)); }`, while the two catches below
    ///         were bare. The SKIP is intended on all three (this function's own docblock: *"a stuck
    ///         LP is skipped, leaving the residual to the #105 partial-fill"*); being UNOBSERVABLE was
    ///         not. This is the path reached when a swap-out cannot be covered, so a stuck LP here
    ///         silently becomes a partial fill whose only trace is a shortfall the caller must infer —
    ///         standing rule 3's case exactly, a failure that is silent and produces plausible-but-
    ///         wrong output.
    /// ⚠️      DELIBERATELY **NOT** `DeleverFailed`, AND THE REASON IS THE EMITTER, NOT THE NAME.
    ///         `DeleverFailed` is declared on `LevBase` and fires from a MANAGER's address. This
    ///         function is delegatecalled by `Quid`, so anything emitted here comes from **Quid's**
    ///         address — an indexer filtering `DeleverFailed` by the LevManager would never see it,
    ///         and one filtering by topic alone would attribute a delivery-side skip to the LTV
    ///         cascade. Two different faults, two different emitters ⇒ two different events.
    /// @param  takeFailed `true` = the basket draw (`takeToSettle`) reverted, so NOTHING was moved.
    /// ⛔ **`false` IS NOW UNREACHABLE, AND THE PARAMETER STAYS ANYWAY.** It used to mean "the draw
    ///    SUCCEEDED and the repay/deliver reverted, which means stable has already left the basket"
    ///    — and this docblock was right that *"they are not the same incident"*. §PAUSED-VAULT-REROUTE
    ///    (ETH) settled the second one differently: a sourced-but-unrepayable delivery no longer
    ///    EMITS, it REVERTS, so the take unwinds with the tx and there is no state left to reconcile.
    ///    The field is kept because the event's ABI is indexed against, and because a future emitter
    ///    that can move money before failing would need exactly this flag again. ⇒ Any consumer may
    ///    read `takeFailed == false` as "never happens"; none may read it as "cannot happen".
    /// @notice A de-lever leg was skipped. ⚠️ **NO `lp` TOPIC, ON PURPOSE.** It had one, and both
    ///         emit sites passed `venue` for it — so the topic was permanently the venue address
    ///         and an indexer filtering by LP got nothing meaningful. §POOL-VENUE left no per-LP
    ///         identity on this path to emit, so the honest event is the one without it.
    event DeliverDeleverSkipped(address indexed venue, uint fundUsd, bool takeFailed);

    /// @notice §M.1 ETH swap-out DELIVERY-SIDE de-lever ORCHESTRATOR (aggregate; the ETH mirror of BTC
    ///   `deleverOnDelivery`). DELEGATECALL'd by Quid (address(this)==Quid==the LevManager's `RANGE`) from
    ///   `_sendETH` when the venue base (deliverableETH) can't cover a swap-out delivery. ⛔ IT DOES NOT
    ///   WALK THE LEV BOOK — this line said *"Walks the open lev book; per LP: … repays that LP's debt"*
    ///   and §POOL-VENUE collapsed that walk to ONE call before the sentence was updated. The body reads
    ///   the pinned `poolVenue()`, sizes the repay against `ILevPooled(venue).totalDebt()` bounded by the
    ///   shortfall, sources the swap's OWN proceeds via `Aux.takeToSettle` (Quid==address(this) IS
    ///   authorized — `V4==Quid` in `Aux._requireUs`), and calls
    ///   `swapOutDeleverPooled` ONCE, which delivers the freed collateral as WETH to `recipient` (Quid,
    ///   which unwraps + sends). There is no loop and no per-LP iteration, so nothing "stops once the
    ///   shortfall is covered" — the single repay is pre-bounded by `ask`. VALUE-NEUTRAL (the
    ///   swapper's input de-levers the pooled position; the keeper re-levers next tick).
    /// ⛔ **THE TAKE NO LONGER LANDS AT THE VENUE, AND THERE IS NO LONGER A SECOND `try/catch`.** This
    ///   read *"sources … into the venue DIRECTLY"* and *"both `try/catch`es … return a partial fill"*;
    ///   §PAUSED-VAULT-REROUTE (ETH) in the body replaced both. The take lands at the RANGE, is
    ///   consolidated into the venue's own loan token and forwarded; the ONE remaining catch covers
    ///   "cannot source" (partial fill, #105, announced). "Sourced but cannot repay" now REVERTS, so
    ///   the take unwinds with the tx instead of standing against zero retired debt.
    ///   @param px USD 1e18/WETH. @return deliveredEth to recipient.
    ///   🔴 UNVERIFIED (forge OOM): fork-test the (1) gating chain, (2) Σbacking invariant (QD-burn: takeToSettle
    ///   draws basket stable to repay — needs `DeleverEthBackingProbe`), (3) non-toxicity, before trusting.
    function deleverEthOnDelivery(address mgr, address aux, uint px, uint shortfallEth, address recipient)
        public returns (uint deliveredEth) {
        if (px == 0 || shortfallEth == 0) return 0;
        // 🔴 §STALE-BRANCH (2026-09-01) — THE DOCBLOCK ABOVE USED TO PROMISE A BRANCH THIS BODY DOES
        //    NOT HAVE, AND THAT SENTENCE IS WHY NOBODY NOTICED. It read *"0-debt (unlevered
        //    net-equity) LPs take the no-repay `swapOutDeliverUnlevered` branch instead"* — true of
        //    the PER-LP WALK this replaced, which could test `debtOf(lp) == 0` per LP. The collapse
        //    to one pooled call took the branch with it and left the sentence.
        //    ⇒ `LevManager.swapOutDeliverUnlevered` now has ZERO callers and ZERO tests
        //      (`tools/check-orphans.py` is what surfaced it). If the pooled position has no debt,
        //      `swapOutDeleverPooled` no-ops and the unlevered net-equity stays PHANTOM — priced in
        //      POOLED, undeliverable because its collateral sits in the venue. That is exactly the
        //      hole `swapOutDeliverUnlevered` was written to close.
        //    ⚠️ NOT FIXED HERE, and deliberately not: whether the 0-debt case is still reachable
        //      under §POOL-VENUE (per-LP debt still exists via `debtOf`/`positionOf`, but the repay
        //      is pool-wide) is a money-path question that needs a fork test, not a guess. Booked in
        //      SPRINT.md §M.1 alongside the `DeleverEthBackingProbe` this path already needed.
        // §POOL-VENUE — ONE CALL, NOT A WALK. This body used to loop `openLevCount()` LPs, doing a
        // basket draw plus a venue repay PER LP, so the swap it served was capped by how many repays
        // fit in a block and the cap tightened as the book grew (§E342). The venue holds ONE position
        // now, so the whole shortfall is sourced and repaid once and the ceiling is liquidity, not
        // cardinality.
        // ⛔ AND THE BOOK IS NOT WALKED AT ALL ANY MORE, NOT EVEN TO PICK THE VENUE. A note here read
        // *"THE BOOK IS STILL WALKED FOR *ONE* THING — picking the venue … the FIRST open LP's venue
        // is the pool's venue"*; the line below replaced that walk with `poolVenue()` and the note
        // outlived it by one edit. There is no `openLevCount`/`openLpAt` call in this body.
        // §POOL-VENUE — READ THE PINNED VENUE, NOT THE BOOK. This gated on `openLevCount() == 0` and
        // took the venue from `openLpAt(0)`, which is correct only while the book is NON-EMPTY. A pool
        // can still hold collateral and debt after its last position closes (a rounding remainder, or
        // a close mid-de-lever), and this then returned 0 — refusing to de-lever a pool that was not
        // empty, silently, exactly when a swap-out needed it. `poolVenue` is the pool's identity and
        // cannot go stale that way.
        address venue = ILevEthDeliver(mgr).poolVenue();
        if (venue == address(0)) return 0;
        // ⛔ NOT `swapOutDeleverAmt(venue, …)` — THAT FUNCTION TAKES AN **LP**, AND BOTH ARE `address`,
        // SO THE COMPILER CANNOT TELL THEM APART. Passing the venue where an LP is expected reads a
        // position that does not exist and returns zeros: a silent no-de-lever, not a revert. This is
        // the same class as the `btcVault`/`ethVenue` mix-up that shipped once here — MERGE ON WHAT
        // THINGS ARE, never on what type they share.
        // ⇒ The pooled amounts come from the POOL directly: the stable is the venue's, and the
        //   repayable size is the shortfall bounded by what the pool actually owes.
        address stable = ILevVenue(venue).stable();
        uint ask = SoladyMath.fullMulDiv(shortfallEth, px, 1e18);      // WETH → USD 1e18
        uint fundUsd;
        // §STACK-SCOPE — `poolDebtUsd`/`amtNative` are BLOCK-scoped, not new. Both are dead the
        // instant `fundUsd` exists, and function-body scope kept their slots alive to the end of the
        // frame — which is the budget §STACK-REUSE below is spending. Scoping them (no new name, no
        // new value) is what pays for `bal0` in the `try` body without via_ir.
        {   uint poolDebtUsd = LevMath._toUsd18(aux, stable, ILevPooled(venue).totalDebt());
            uint amtNative = poolDebtUsd == 0 ? 0 : LevMath._fromUsd(aux, stable,
                                ask > poolDebtUsd ? poolDebtUsd : ask);
            if (amtNative == 0) return 0;   // venue == 0 already returned above
            fundUsd = LevMath._toUsd18(aux, stable, amtNative);
        }
        if (fundUsd > ask) fundUsd = ask;   // `ask` is still USD here — the take is sized off this
        if (fundUsd == 0) return 0;
        // 🔴 §PAUSED-VAULT-REROUTE (ETH) — **THE TWIN OF THE FIX `_sourceRepayFree` ALREADY CARRIES,
        //    AND IT LANDED THERE ONLY AFTER 1,377,974,721,301,924,123,210 OF DAI WAS MEASURED SITTING
        //    AT A VENUE.** Two defects, one shape:
        //    (a) `takeToSettle` names `stable` only as PREFERRED. `BasketLib._takePreferred` wraps
        //        `withdrawSelf` in try/catch, so a PAUSED vault yields `sent = 0` and the whole
        //        request falls to `_takeProRata`, which pays EVERY basket stable to `who`. With
        //        `who == venue` that value is unrecoverable on arrival: `LevVenueBase` has no
        //        `sweep`, no `rescue`, no `onlyOwner` — it moves `STABLE` and `COLLATERAL` and
        //        nothing else, ever.
        //    (b) the inner `try` around `swapOutDeleverPooled` swallowed AFTER `takeToSettle` had
        //        already moved money, so the take STOOD with zero debt retired — a basket drain
        //        against nothing. Two catches read as "twice as fault-tolerant"; they were
        //        "fault-tolerant about sourcing" plus "silent about spending".
        // ⇒ SAME THREE MOVES AS THE BTC RAIL. **THE TAKE LANDS HERE** (`address(this)` is the RANGE
        //   under `QuidLib.sendEth`'s delegatecall, and `Aux._requireUs` authorises it), where
        //   `LevMath._consolidateTo` — `public` precisely so the reroute could gain callers — turns
        //   whatever the basket actually paid into the venue's OWN loan token over the keyless
        //   `_hubRowOf` Curve rows. The happy path is unchanged in effect: when Aux serves the
        //   venue's stable, consolidation skips it (`s == target ⇒ continue`).
        //   ⚠️ `refundTo` IS `aux` (§REFUND-TO-AUX): an unroutable slice is BASKET value, so it goes
        //     back to the basket, where the permissionless `Aux.sweep` re-supplies it. Never the LP
        //     (a leak), and never a holder that cannot move an ERC20 (a shredder).
        //   📌 Sends its WHOLE `stable` balance, on the same premise `_consolidateTo` is written on:
        //     the range custodies no basket stable in the normal course (`Quid.sol` touches WETH and
        //     eETH only). Any residue that did exist goes to retiring debt, which cannot be a loss.
        // ⛔ AND ONLY THE OUTER `try` SURVIVES. It covers "the basket CANNOT SOURCE", which must
        //   leave a partial fill (#105) and never revert the settle — announced via §SILENT-SKIP. The
        //   inner one covered "sourced but cannot repay", and that case MUST revert: the take has
        //   already happened, and unwinding it with the tx is the only thing that puts the dollars
        //   back. A `revert` in a `try` BODY is not caught by its own `catch`, which is exactly the
        //   split we want. ⇒ Do NOT restore it "for symmetry"; the asymmetry is the correctness.
        try IAux(aux).takeToSettle(address(this), BasketLib.scaleTokenAmount(fundUsd, stable, false), stable) returns (uint) {
            {   // 🔑 THE REPAY IS SIZED OFF A MEASURED BALANCE DELTA AT THE VENUE, NOT OFF THE ASK.
                //    What the basket QUOTED, what it PAID, and what SURVIVED consolidation are three
                //    different numbers; only the third can retire debt. Sizing off the ask is what
                //    produced the recorded `ERC20: transfer amount exceeds balance` inside
                //    `swapOutDeleverPooled` — the venue was told to repay more than it held.
                uint bal0 = IERC20(stable).balanceOf(venue);
                LevMath._consolidateTo(aux, stable, aux);                    // wrong-denomination slices → the venue's own token
                IERC20OZ(stable).safeTransfer(venue, IERC20OZ(stable).balanceOf(address(this)));
                fundUsd = LevMath._toUsd18(aux, stable, IERC20(stable).balanceOf(venue) - bal0);
            }
            // Fail-safe, and now the LAST resort rather than the only one: reaching it means the
            // basket paid nothing the hub table could convert into this venue's loan token. The
            // revert unwinds the take with the tx, so nothing strands anywhere.
            if (fundUsd == 0) revert DeleverStableUnavailable();
            if (fundUsd > ask) fundUsd = ask;   // re-apply the shortfall bound to the RE-DERIVED size
            // §STACK-REUSE — `ask` CHANGES UNITS HERE: USD-1e18 above this line, ETH WEI below it. The
            // slot is reused deliberately and the reuse is FORCED. This file compiles with
            // `via_ir = false`, and computing `shortfallEth · fundUsd / ask` inline at the call below
            // puts `shortfallEth` out of reach — `Stack too deep`, which is exactly how this line came
            // to exist. ⛔ Do not "clean this up" into a fresh variable — that is the change that does
            // not compile, and it looks like an improvement right up until you build.
            // ⚠️ IT MOVED BELOW THE MEASUREMENT, AND IT HAD TO. `swapOutDeleverPooled` frees
            //   `askNative · usedUsd / stableUsd` of collateral, so `ask` and `fundUsd` are a MATCHED
            //   PAIR at one price. Scaling `ask` off the REQUESTED size and then repaying the
            //   MEASURED (smaller) one would inflate that ratio and free MORE collateral per dollar
            //   retired — a real over-withdraw, silently. Deriving both from the same measured number
            //   keeps the pair exact, and the scale is strictly DOWN (`fundUsd <= ask` one line up).
            ask = SoladyMath.fullMulDiv(shortfallEth, fundUsd, ask);
            (, deliveredEth) = ILevEthDeliver(mgr).swapOutDeleverPooled(venue, fundUsd, recipient, 0, ask);
        } catch { emit DeliverDeleverSkipped(venue, fundUsd, true); }
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
            // 🔴 §BURN-RELEASES-NO-USD — HISTORY, AND THE `← here` MARKER IT CARRIED IS STALE.
            //   Three arms were measured on `ChopIsBenign` (LP exit residual) plus the two residual
            //   tests, each a control run at a real commit:
            //     • `0`                            → **0.990 ETH**, both residual tests PASS
            //     • `basketUsd · pulled / POOLED`  → 9.42 ETH (a **9.5x regression**), both pass
            //     • `POOLED_USD · pulled / POOLED` → 9.46 ETH, and BOTH residual tests FAIL
            //   ⛔ **THE BODY PASSES THE SECOND ARM, NOT `0`.** The `← here` sat on `0` and the
            //     conclusion below it read *"0 is the only value that does not take value from the
            //     LP"*; `839f3655` (*"BURN-RELEASE-CONFLICT resolved: two callers were sharing one
            //     arm"*) landed `basketUsd · pulled / pooled` and reports `ChopIsBenign residual
            //     0.990 → 0.988, no regression`. What changed underneath is `Core`: `modLP` sets
            //     `basketLeg = true`, and the burn arm now caps a withdrawal at `min(basketUsd,
            //     usdAmount)` while leaving the SWAP arm (`basketLeg == false`) proportional — so
            //     `POOLED_USD` and `basketUsd` fall by the SAME amount and the 9.5× exit regression
            //     the table records is not what this arm does today.
            // ⚠️ THE HAZARD THE ROW EXISTS FOR IS STILL OPEN, so it is kept: `modLP` hardcodes
            //   `token = address(0)`, so `_settleUsdSide`'s payout `AUX.take(who, ...)` is
            //   UNREACHABLE from this path. A positive `usdOut` RETIRES dollars (`POOLED_USD` and
            //   `basketUsd` both fall) and DELIVERS THEM TO NOBODY. The release is not the missing
            //   half; the DELIVERY is, and it is still not built.
            // ⇒ THE FIX BELONGS AT THE DELIVERY SITE, NOT THE RELEASE SIZE.
            // The BASKET's own share of the depth being burned. `pooled > 0` here (`pulled` is
            // `min(amount, pooled)` and a zero `pulled` already returned), and `fullMulDiv(0, …)` is
            // 0, so neither a divide-by-zero guard nor a `basketUsd == 0` branch is needed.
            uint usdOut = SoladyMath.fullMulDiv(ICore(core).basketUsd(), pulled, pooled);
            sent = ICore(core).modLP(int256(pulled), int256(usdOut), recipient);   // LEAVES ⇒ positive
        }
    }

    // ── BTC allocation cap REMOVED (§H, 2026-07): the btcShareBps median-vote cap is gone; BTC now sizes by
    //    SOLVENCY-surplus only. The ≤TVL invariant + `committedBoth` (shared-mirror, so neither pool double-claims
    //    surplus) remain the bounds — no policy cap, no `btcCapClamp`.

    /// @dev Shared solvency sizer, reached only from `addLiqBody` below (which both `QuidLib.addLiq`
    ///      and `BtcLib.addLiqChannel` delegate to). From the SHARED free backing
    ///      (`liquidTotal − committedBoth`, where committedBoth nets BOTH pools' committed USD so
    ///      neither can claim the same surplus twice), back-solve the token amount whose USD value ==
    ///      surplus (pin USD to free backing; the unpaired token stays in IL-free retention).
    ///      ⛔ THERE IS NO BTC POLICY CAP IN THIS BODY — this said *"optionally apply the BTC policy
    ///      cap"*, and §H deleted `btcShareBps`/`btcCapClamp` (the note above records it). The only
    ///      bounds are the surplus here and `clampByBacking`'s headroom/θ pair at the call site.
    ///      ⚠️ `liquidTotal` (`get_deposits[15]`) and `committedBoth` (`committedUsd18`) are now read
    ///      by `addLiqBody`, NOT by its callers — the §DELTATOK-FOLD moved that read in, which is what
    ///      let both ranges lose their copies. `surplus == 0` ⇒ `addLiqBody` early-returns. Every
    ///      mulDiv floors → commits ≤ requested, never more.
    /// @notice §E270 — THE ONE token→USD conversion at a range price. It had been inline at three
    ///         sites: `sizeBySurplus` below and the post-theta-clamp recompute on EACH range (both of
    ///         those recomputes are now the single one in `addLiqBody`). The BTC range had drifted to
    ///         `targetUSD*capped/deltaTok`, which computes the SAME quantity with two compounded
    ///         roundings and an unguarded `*`/`/`. Classified DRIFT and unified here.
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
    ///         `thetaEff >= 1e18` (fail-open / calm) is a no-op. Reached from `clampByBacking` inside
    ///         `addLiqBody`, so BOTH sizing paths -- ETH (`QuidLib.addLiq`) and BTC
    ///         (`BtcLib.addLiqChannel`) -- run this one body and the throttle is identical
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
    ///         drain, sell-in, BtcVault drain). The refiller-payout side was removed — the fleet
    ///         self-funds the refill. skew==0 no-op.
    /// ⛔ The premium is an LP **CLAIM**, not undifferentiated basket NAV: `Core.recordSkewPremium`
    ///     ends in `RANGE.creditSkewPremium(premiumUsd)`, implemented on BOTH ranges
    ///     (`Quid.creditSkewPremium`, `Vault.creditSkewPremium`), and §E42-netting moves its BACKING
    ///     into the POOLED mirror to match. ⛔ Do not restore *"stays in the basket as LP backing"* —
    ///     that wording is pre-§E5 and IS the §E42 leak. `Core`'s copy of this warning was fixed
    ///     first and this one was not, which left the wrong copy authoritative for whoever read this
    ///     file first.
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
    ///      ⛔ THE DISCRIMINATOR IS THE `nativeAmount` PARAMETER, NOT `r.px`. This block used to
    ///      key both bullets on `r.px != 0` / `== 0`; the body's own comment refutes it and the call
    ///      sites confirm it — `r.px` is non-zero on BOTH `swapToBody` legs, so it cannot separate
    ///      them. `r.px` only supplies the RATE for the conversion the flag selects:
    ///        • `nativeAmount == true` (the sell leg, `swapToBody`'s `!forVolatile` arm) -> `r.amount`
    ///                         is NATIVE (wei/sats). `recordSkewPremium` wants 6-dec USD, so convert
    ///                         with `premium·r.px/1e30`, the flat scale correct for BOTH assets (the
    ///                         WBTC price carries the ×1e10 lift — same rule as `_skewBasis`).
    ///        • `nativeAmount == false` (both drain legs: `swapToBody`'s `forVolatile` arm and
    ///                         `_swapOutPrep`, whose input came through `scaleTo6`) -> `r.amount` is
    ///                         ALREADY 6-dec USD; record verbatim.
    ///      The premium SUBTRACTED from `r.amount` stays in the caller's own unit; only the RECORDED
    ///      value converts. Before this fix the native legs recorded wei/sats into a USD register: ETH
    ///      over-reported (theta throttle never bound) and BTC under-reported ~1e3 (over-throttled).
    function retainSkewPremium(address core, SwapReq memory r, uint skew, bool nativeAmount)   // §ISBTC-SPLIT: the `isBTC` param was never read
        internal {
        if (skew == 0) return;
        // §E275/§E300 — NO GUARD HERE BY DESIGN, AND THE REASON HAS CHANGED WHILE THE CONCLUSION
        // HELD. This said `wellSkew`/`sellSkew` *"DECLINE an unfillable rate at the producer"*. They
        // no longer decline: §E298 showed a revert hands a solver nothing, and §E300 replaced the
        // refusal with `_boundToFullHaircut`, which SATURATES at `SKEW_UNFILLABLE == 1e18`.
        // ⇒ The guarantee this frame relies on is now ARITHMETIC rather than a promise
        // about the caller: `skew <= 1e18` makes `premium = amount·skew/1e18 <= amount`, so the
        // `r.amount -= premium` below cannot underflow even at a 100% haircut. A second bound here
        // would still be the clamp standing rule 17 warns about — but note the reason a reader must
        // check has moved from "the producer refuses" to "the producer saturates".
        uint premium = SoladyMath.fullMulDiv(r.amount, skew, 1e18);
        // ONLY the sell leg holds a NATIVE amount. The two drain legs hold the BUY-DRIVING USD, already
        // 6-dec — converting those (attempt 2) collapsed the recorded premium to 0. `r.px` cannot serve as
        // the discriminator: it is non-zero on BOTH swapToBody legs, so the caller states the unit.
        // §PREMIUM-READABLE — hand Core the USD figure it books AND, on the sell leg only, the premium
        // as actually retained in wei. The second argument feeds a COUNTER; no mirror changes.
        ICore(core).recordSkewPremium(
            nativeAmount ? SoladyMath.fullMulDiv(premium, r.px, 1e30) : premium,
            nativeAmount ? premium : 0);
        r.amount -= premium;
    }

    /// @notice §DELTATOK-FOLD — THE ONE `addLiq` BODY. `QuidLib.addLiq` and `BtcLib.addLiqChannel`
    ///         were the same seven statements twice, and the ONLY thing that differed was two
    ///         SCALARS: the live θ and the native `backing` the clamp is measured against. Everything
    ///         else — the `get_deposits` read, `committedUsd18`, `sizeBySurplus`, the surplus early
    ///         exit, the clamp, the §E270 `targetUSD` RECOMPUTE, the `/1e12` and the zero exit — was
    ///         byte-for-byte identical, down to the comment explaining the recompute.
    /// ⭐ WHY IT IS A `public` BODY AND NOT AN `internal` HELPER, WHICH IS THE WHOLE SIZE ARGUMENT:
    ///         an `internal` library function is CODE-COPIED into every calling contract, so
    ///         `sizeBySurplus`, `clampByBacking` and `usdForTok` each existed twice in deployed
    ///         bytecode — once inside `QuidLib`'s copy and once inside `BtcLib`'s. A `public` one is
    ///         DELEGATECALLED, so this body is deployed once in `SwapLib` and both callers lose
    ///         their copies. Same trade §E346 made with modifier bodies, one level up.
    /// ⚠️ θ AND `backing` ARE COMPUTED BY THE CALLER, DELIBERATELY, AND MUST STAY THERE. Both θ reads
    ///         go through `address(this)` — `ICore(address(this)).derivedThetaWad()` on the ETH side,
    ///         `ICore(address(this)).derivedThetaWad()` on the BTC side — and `address(this)` is the
    ///         RANGE only because these libraries run under its delegatecall. Moving either read in
    ///         here would still resolve, which is exactly what makes it dangerous: it would work now
    ///         and silently bind to the wrong identity the first time this is called from anywhere
    ///         else. The asymmetry is real (`rangeETH() + grossBuffer` vs `btcThetaBacking() + sats`)
    ///         and it is the ONLY real one — passing it as two numbers is what proves that.
    /// @param  want    the REQUEST (wei on ETH, sats on BTC). Never written — §E270: the parameter used
    ///                 to be overwritten, so past `sizeBySurplus` the requested amount existed nowhere.
    /// @param  backing the IL-bearing capital the θ budget is measured against, in the range's NATIVE
    ///                 unit. ETH: `rangeETH()` (net venue principal) + the gross buffer. BTC:
    ///                 `btcThetaBacking()` (lpShares net + gross buffer) + THIS add's `sats`, which is
    ///                 not yet credited to `lpShares` at clamp time.
    function addLiqBody(address core, address aux, uint want, uint price,
        uint thetaWad, uint backing) public returns (uint usdOut, uint outDelta)
    {
        (uint[16] memory deposits,,,) = IAux(aux).get_deposits();
        (uint deltaTok, uint targetUSD, uint surplus) =
            sizeBySurplus(deposits[15], ICore(core).committedUsd18(), want, price);
        if (surplus == 0) return (0, 0);
        // ONE principle: bound by the physical backing HEADROOM (backing − pooled) AND the θ
        // risk-budget (θ·backing − pooled). Shared verbatim by both ranges — it always was, via two
        // copies of this call; now via one.
        uint capped = clampByBacking(thetaWad, backing, ICore(core).POOLED(), deltaTok);
        // §E270 — RECOMPUTE rather than rescaling by the clamp ratio. `sizeBySurplus` maintains
        // `targetUSD == deltaOut·price/WAD` on BOTH exits, so the two forms are the same quantity, and
        // recomputing has ONE rounding instead of compounding the earlier one and dividing by a
        // `deltaTok` that is itself rounded in the clamped case.
        if (capped < deltaTok) { deltaTok = capped; targetUSD = usdForTok(deltaTok, price); }
        usdOut = targetUSD / 1e12;
        if (usdOut == 0) return (0, 0);
        outDelta = deltaTok;
    }

    function clampByBacking(uint thetaEff, uint backing, uint pooled, uint want)
        internal pure returns (uint)
    {
        uint available = backing > pooled ? backing - pooled : 0;
        available = applyTheta(thetaEff, backing, pooled, available);
        return want < available ? want : available;
    }

    // §E347b — `paddedSqrtPrice` DELETED, and with it the last "Tick math" section in this file
    // (rule 1: unreachable code goes). It returned a `uint160` — a v4 `sqrtPriceX96` — from two
    // `FixedPointMathLib.sqrt` expansions, which is §DE-TICK residue: the band is a PRICE range now
    // (`updateBounds(targetPrice, RANGE_DELTA)`), so nothing needs a padded SQRT price.
    // ⚠️ THE create_sweep_tx CHECK WAS RUN AND ANSWERED, NOT WAIVED. §E347 deleted `Quid`'s
    // `public pure` forwarder one commit earlier on an exhaustive census (`evm/src|test|script`,
    // `spa/`, `quid-ln/`, `tools/`, plus the raw selector `0x60fd0b8d` to catch a call-by-selector),
    // leaving this body at ZERO references. Discriminator: an asymmetric §DE-TICK leftover (`Vault`
    // never had a counterpart), i.e. a RETIRED design — not a gap nobody has built yet, which is the
    // one distinction separating rule 1 from the deletion this repo has reverted twice.
    // It was `internal`, so inlined and never deployed: this frees no bytecode from anything.

    /// @notice (B — IL-protect) Fraction of the range's ORIGINAL volatile still held, WAD: held-volatile
    ///         amount NOW / held-volatile amount AT ENTRY, straight from the concentrated-range geometry,
    ///         clamped to the live range. Computed in USD-PER-VOLATILE space, so there is no token
    ///         ordering and no `spotPrice` to invert.
    ///         RETURN SHAPE: `1e18` = at entry. `>1e18` ⇒ the range BOUGHT the volatile (price fell — the
    ///         OVER-hold the short cancels); `<1e18` ⇒ it SOLD (price rose — the UNDER-hold the long
    ///         cancels). `1e18` is also the degenerate answer: `syncKeyPx == 0`, `loPrice >= upPrice`, or
    ///         an entry at/above the upper edge. Reflects the real (drifting) α with NO α parameter — the
    ///         single ground-truth primitive both hedge legs size from.
    ///         ⚠️ VALID WITHIN ONE RANGE CONFIG ONLY: a reseat recentres the bounds and REALIZES the IL,
    ///         so the caller MUST re-anchor `syncKeyPx` on a reseat. Shared by both ranges.
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
        bool    didRepack;     // true → a range move happened; `price` valid
        uint    price;
        // §V4-CUT-RESIDUE — `fees0`, `fees1`, `delta0`, `delta1` DELETED 2026-08-28. They were
        // DECLARED AND NEVER ASSIGNED anywhere in the tree: v4 collected the fees and reported the
        // deltas, and with v4 gone `repack`/`reseat` report nothing. `fees0/1` were still READ by
        // `BtcLib` and `QuidLib`, which fed two guaranteed zeros into `feeIncrements` and added the
        // resulting zeros to the accumulators; `delta0/1` were not even read. Struct fields that
        // only ever hold their zero-value are not a seam for restoring the fee lane — restoring it
        // means assigning something, which means touching these call sites regardless.
        // ⇒ Whether per-share accrual returns is still the OPEN owner decision (§BTC-LEG-FEE);
        //   deleting dead fields does not decide it, and `feesPerShare`/`USD_FEES` are untouched.
        // The resolved oracle price (Chainlink when stale, else internal TWAP)
        // read here for the staleness/reseat check — exported so the swap path
        // (_finishSwap) REUSES it as fillPrice instead of reading the
        // internal `observe` ring a second time per swap. 0 ⇒ caller live-reads.
        uint    resolvedTwap;
    }

    /// @dev SHARED body of _rebalance (the parts identical for ETH and BTC), in the order the body
    ///      runs them: read `poolStats` for the current spot + liquidity; read `resolvedTwap` under
    ///      try/catch; if it came back STALE, reseat onto it and RETURN EARLY; otherwise, if the spot
    ///      has drifted out of the half-open range, run the 300-bps manipulation guard and
    ///      `ICore.repack(anchor)`. ⛔ THERE IS NO IN-RANGE ARM — this said *"else (in range) force a
    ///      JIT-defense fee collect"* and §V4-CUT deleted that branch; the note at the tail of the
    ///      body records what replaced it. In range, this function reads and returns.
    ///      Writing the NEW range into the caller's price slots is NOT done here (value-type
    ///      storage) — the caller writes them from the returned struct. `aux`/`asset` give the
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

        // AUTO-HEAL (deadlock recovery): when the internal TWAP is >5% off Chainlink
        // (`stale` ⇒ resolved price IS Chainlink; the 5% is `Aux.TWAP_MAX_DEVIATION_BPS = 500`,
        // `Aux.sol:221`, which `resolvedTwap` passes into `twapResolve`), the curve spot may be stuck
        // far from the real price. Move the spot onto Chainlink + re-range so swaps price at the real
        // price. ⛔ THE OLD JUSTIFICATION IS GONE: this read *"the 50-bps swap guard blocks every swap
        // → the spot can't move → frozen"*, and there IS no swap guard — §V4-CUT left `Core.swap`
        // settling at the oracle bounded by inventory, with no deviation check anywhere on the fill
        // path. So a dislocation no longer FREEZES swaps; what it does is leave the range's own
        // bounds centred somewhere the oracle is not. Fires ONLY in this dislocation regime
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
            // Repack TOLERANCE (300 bps = 3%) — deliberately 6× looser than `RESEAT_MIN_BPS`, the
            // only other `isManipulated` threshold in the tree, so normal volatility that would
            // trigger a reseat does not also block a re-centre.
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
        }
        // ⛔ (§V4-CUT) THE JIT-SNIPE ARM IS DELETED, AND THE DEFENCE IT RAN IS NOT LOST — IT MOVED
        // INTO THE STRUCTURE. It forced a fee-only `collectFees()` so accrued fees landed in the
        // accumulators BEFORE the caller's bookmark advanced, because v4 fees sat OUTSIDE `POOLED_*`
        // and a depositor arriving in the same block as a large swap captured fees it had not
        // earned. Both halves are now covered without it: the skew premium lands in `POOLED_*` AT
        // SWAP TIME so `_pricingBacking()` already includes it, and `USD_FEES` is claimed through a
        // per-LP bookmark (`pendingFor`'s `LP.fees_usd`), so a new depositor can only ever earn from
        // its own deposit forward. **A pre-mint drain defends a window that no longer opens.**
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
        // Only move the spot when it's off the oracle by more than `RESEAT_MIN_BPS` (50). ⛔ That is
        // the reseat's OWN threshold — this said *"the 50-bps routeSwap guard … enough to actually
        // BLOCK swaps"*, and `routeSwap` has no guard to be off by (see the constant's declaration).
        // Within 50 bps the re-range would land essentially where it already is, so reseating would
        // just churn. This keeps reseat firing once per dislocation, not per op.
        if (!BasketLib.isManipulated(spot, twap, RESEAT_MIN_BPS)) return false;
        // §DE-TICK — THE TARGET IS THE TWAP. `targetSqrtForPrice` existed to encode a desired price
        // back into a sqrt price without an absolute price→sqrt conversion. In price space the
        // target simply IS the price, so the whole encoding step disappears.
        if (twap == r.spotPrice) return false;   // already aligned
        _doReseat(core, r, twap);
        return true;
    }

    /// @dev Move the anchor to `targetPrice` + re-range — own frame so `_reseatIfStale`'s stack is
    ///      not pinned by the repack call (legacy pipeline, no via_ir). It writes `r.price`,
    ///      `r.didRepack`, both bounds and `r.spotPrice`; `ICore.repack(uint)` returns ONE `uint`.
    function _doReseat(address core, Rebalanced memory r, uint targetPrice)
        private {
        if (r.myLiquidity > 0) {
            r.price = ICore(core).repack(targetPrice);   // §ONE-ANCHOR: the anchor, not the pair
            r.didRepack = true;
        }
        (r.loPrice, r.upPrice) = updateBounds(targetPrice, RANGE_DELTA);
        r.spotPrice = targetPrice;
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
    // (`Core._handleDelta`'s clamp note records that). Do not re-derive it from that comment.

    // ─────────────────────────────────────────────────────────────────────────────
    // CONSERVATION — the ONE property worth keeping from v4's `unlockCallback`
    // ─────────────────────────────────────────────────────────────────────────────



}




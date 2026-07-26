// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {BasketLib} from "./BasketLib.sol";
import {FeeLib} from "./FeeLib.sol";
import {ShareMath} from "./ShareMath.sol";
import {SOR} from "./SOR.sol";
import {Types} from "./Types.sol";
import {LevMath} from "../libraries/LevMath.sol";
import {IV3SwapRouter} from "./v3/IV3SwapRouter.sol";

// ether.fi offramp interfaces (suffixed `_L` to avoid clashing with Aux's own
// copies, since Aux imports SwapLib). Same signatures as Aux's.
interface IWeEth_L { function getWeETHByeETH(uint a) external view returns (uint); function unwrap(uint a) external returns (uint); }
interface IRover_L { function take(uint amount) external returns (uint); }
// EtherFiRedemptionManager.redeemWeEth(weEthAmount, receiver, outputToken);
// outputToken ∈ {0xEeee…EEeE native-ETH sentinel, stETH} — else InvalidOutputToken.
interface IRedeem_L { function redeemWeEth(uint weEthAmount, address receiver, address outputToken) external; }
interface ILiq_L { function requestWithdraw(address r, uint a) external returns (uint); }
/// Chainlink-style USD feed — the external anchor for the TWAP cross-check.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Subset of Aux's public surface that SwapLib calls back into
///         via DELEGATECALL → external self-CALL pattern. See Aux's
///         supplySelf / withdrawSelf docblock for the security invariants
///         that gate these entries.
interface IWethDeposit { function deposit() external payable; }
interface IAuxSwap {
    function supplySelf(address token, uint amount) external returns (uint);
    function withdrawSelf(address token, uint amount, address to) external returns (uint);
    function get_deposits() external returns (uint[15] memory amounts, uint[15] memory yieldW, uint avgYield, uint depegLoss);
    function checkBacking() external returns (uint committedSum, uint totalLiquid);
    function _tryPath(bytes calldata encodedPath, uint amountIn,
        address output, address recipient, uint minOut) external returns (uint);
    function toIndex(address token) external view returns (uint);
    function takeToSettle(address who, uint amount, address token) external returns (uint); // soft-backing settle drain
    function getTWAPforAsset(address asset, uint32 period) external view returns (uint);
    function auxSwap(uint amountIn, address output, address recipient, uint minOut)
        external returns (uint);
    function deposit(address from, address token, uint amount) external returns (uint usd);
    function WBTC() external view returns (address);
    // ── merged from the former IAuxSwap (same Aux self-delegatecall target) ──
    function tokens(address vault) external view returns (address);
    function tranche(address token) external view returns (uint);
    function get_metricsWith(uint raw, uint yieldWeighted) external returns (uint total, uint avgYield);
    function illiquidLoss() external view returns (uint);
    function _depositVol(bool isBTC, address sender, uint amount) external payable returns (uint sent);
    function tipSelf(uint cut, address token, int sign) external;
    function bumpVogueBTC(uint amount) external;
}

interface ICoreObs {
    function observe(uint32[] memory secondsAgos) external view returns (int56[] memory);
    function observeBTC(uint32[] memory secondsAgos) external view returns (int56[] memory);
    function token1is(bool isBTC) external view returns (bool);
    function POOLED_BTC() external view returns (uint);
    function POOLED_USD_BTC() external view returns (uint);
    function POOLED_ETH() external view returns (uint);
    function POOLED_USD_ETH() external view returns (uint);
    function committedUsd18() external view returns (uint);
    function pendingSwapOutUsd() external view returns (uint);
    function levClaimUsd6(bool isBTC) external view returns (uint);
    function levGrossNative(bool isBTC) external view returns (uint);
    function flowEwmaUsd(bool isBTC) external view returns (uint);
    function realizedVarianceWad(bool isBTC) external view returns (uint);
    function recordSkewPremium(bool isBTC, uint256 premiumUsd) external;
    function refundUnfilled(address token, uint amount, address to) external;
    function drawPooledUsdBtc(uint usd6) external;         // delivery-side de-lever: retired-debt share out
    function subPendingSwapOut(uint usd6) external;        // delivery-side de-lever: obligation share cleared
}
/// Delivery-side de-lever: the BtcLevManager reads/mutations for the swap-out settle de-lever.
interface ILevManagerDeliver {
    function swapOutDeleverAmt(address lp, uint maxUsd18)
        external view returns (address venue, address stable, uint amtNative);
    function swapOutDelever(address lp, uint stableUsd, uint freeSats)
        external returns (uint usedUsd, uint freedSats);
}
/// §M.1 ETH delivery-side de-lever: the LevManager (ETH) reads/mutations for the swap-out `_sendETH` de-lever.
/// Distinct from BTC's `swapOutDelever` (ETH DELIVERS WETH to a recipient; BTC un-encumbers spliced sats), and
/// ETH is POOLED so it walks the book (`openLevCount`/`openLpAt`) vs BTC's single delivering-LP.
interface ILevEthDeliver {
    function openLevCount() external view returns (uint);
    function openLpAt(uint i) external view returns (address);
    function swapOutDeleverAmt(address lp, uint maxUsd18)
        external view returns (address venue, address stable, uint amtNative);
    function swapOutDelever(address lp, uint stableUsd, address recipient, uint minWethOut)
        external returns (uint usedUsd, uint wethDelivered);
    function swapOutDeliverUnlevered(address lp, uint wethWanted, address recipient, uint minWethOut)
        external returns (uint wethDelivered);
}

interface IBasketTurn2 {
    function turn(address from, uint value) external returns (uint sent, uint seedBurned);
    function matureSupply() external view returns (uint);
}
/// @notice V4 (Vogue) repack. 5th return = the resolved oracle price (Chainlink-when-stale, else internal
///         TWAP) computed during the repack-first; the swap reuses it as v4Price so it doesn't read the
///         internal `observe` ring a 2nd time. 0 ⇒ live-read fallback. (Was two identical decls
///         IVogueRepack2/IVogueRepackRet — collapsed to one.)
interface IVogueRepack2 {
    function repack(bool isBTC) external returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity, uint resolvedTwap);
}
interface IBtcChan2 {
    function btcRecipientOf(address user) external view returns (bytes32);
}

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
        int56[] memory tc = isETH ? ICoreObs(core).observe(secondsAgos)
                                  : ICoreObs(core).observeBTC(secondsAgos);
        bool token0isUSD = ICoreObs(core).token1is(!isETH);
        price = BasketLib.ticksToPrice(tc[0], tc[1], secondsAgos[0], token0isUSD);
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
        if (feed == address(0) || price == 0) return (price, false);
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
            IAuxSwap(address(this)).supplySelf(weth, swept);
            return (0, swept);
        }
        if (token == wbtc) {
            swept = IERC20(wbtc).balanceOf(address(this));
            return (swept, swept); // caller adds to vogueBTC inventory
        }
        if (token == weth || IAuxSwap(address(this)).toIndex(token) != 0
            || token == gho || token == usdg) {
            swept = IERC20(token).balanceOf(address(this));
            if (swept == 0) return (0, 0);
            IAuxSwap(address(this)).supplySelf(token, swept);
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
    ///         user. State mutations route back via IAuxSwap's self-gated
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

        IAuxSwap aux = IAuxSwap(address(this));

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
    function _convert(IAuxSwap aux, address tokenIn, address tokenOut, uint pulled,
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
        IAuxSwap aux = IAuxSwap(address(this));
        // op == 0: LP deposit — WETH → supplySelf.
        if (op == 0) {
            weth.transferFrom(msg.sender, address(this), amount);
            aux.supplySelf(address(weth), amount);
            return amount;
        }
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
            IWethDeposit(weth).deposit{value: msg.value}();
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
    function _priceOr(uint v4p, address aux, address asset) internal view returns (uint) {
        return v4p != 0 ? v4p : IAuxSwap(aux).getTWAPforAsset(asset, 1800);
    }
    /// @dev Revert unless `token` is a real basket stable (toIndex>0). Factored from creditSwapIn/OutBody (dedup).
    function _requireStable(address aux, address token) internal view {
        if (IAuxSwap(aux).toIndex(token) == 0) revert StableMissing();
    }

    error BadAsset();
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
    ///         IAuxSwap callbacks (deposit/_depositVol/_tipSelf/withdrawSelf/
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
    }

    function swapToBody(SwapReq memory r, SwapToCfg memory c, address[] memory stables)
        external returns (uint max) {
        if (r.asset != c.weth && r.asset != c.wbtc) revert BadAsset();
        bool isBTC = r.asset == c.wbtc;
        if (!r.forVolatile && isBTC) revert BtcInflowsViaChannels();
        IAuxSwap aux = IAuxSwap(address(this));
        bool stable = aux.toIndex(r.token) > 0;
        // #105: capture the actual INPUT token for the partial-fill refund BEFORE the forVolatile branch
        // zeros r.token — volatile-in = the asset, stable-in = the token, QD-in = 0 (burned => unrefundable).
        r.inToken = r.forVolatile ? (r.token == c.quid ? address(0) : r.token) : r.asset;
        if (r.forVolatile && isBTC && r.recipient != address(this)) {
            if (IBtcChan2(c.btcChannels).btcRecipientOf(r.recipient) == bytes32(0)) revert NoBtcRecipient();
        }
        // _buildContext(asset): ETH-side vault always address(0) (dispatched to
        // GALAXY via the venue); volScale 1e18 WETH / 1e8 WBTC; nativeWETH on ETH.
        Types.AuxContext memory ctx = Types.AuxContext({
            asset: r.asset, vault: address(0), core: c.core,
            nativeWETH: !isBTC, volScale: isBTC ? 1e8 : 1e18
        });
        (uint160 sqrtPriceX96,,,, uint v4p) = isBTC
            ? IVogueRepack2(c.btcVault).repack(true)
            : IVogueRepack2(c.v4).repack(false);
        {
            // Drain-side backing gate counts standing holdings at PAR (NOT the depeg haircut): the mint/issuance
            // side haircuts depeg (Core band-add + mint-headroom) to block over-mint, but the drain side stays at
            // par so a transient depeg can't brick redeems/swaps for existing holders (intentional asymmetry;
            // redeem VALUE is separately haircut in _redeemQuote). See DepegBackingProbe.
            (uint[15] memory _deposits,,,) = aux.get_deposits();
            if (ICoreObs(c.core).committedUsd18() > _deposits[14]) revert UnderBackedS();
        }
        // token1is inlined per-branch (not a local) — frees a stack slot so
        // swapToBody stays within the legacy pipeline (no via_ir) after threading
        // the reused v4 price `v4p`. One executed branch ⇒ still one token1is call.
        bool zeroForOne;
        if (!r.forVolatile) {
            if (r.token != c.quid && !stable) revert StableMissingS();
            r.amount = aux._depositVol{value: msg.value}(isBTC, msg.sender, r.amount);
            zeroForOne = !ICoreObs(c.core).token1is(isBTC);
            max = isBTC ? ICoreObs(c.core).POOLED_USD_BTC() : ICoreObs(c.core).POOLED_USD_ETH();
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
                uint skew = sellSkew(c.core, v4p != 0 ? v4p : aux.getTWAPforAsset(r.asset, 1800), isBTC, r.amount); // inline (swapToBody stack-tight)
                r.amount = retainSkewPremium(c.core, isBTC, r.amount, skew);
            }
        } else { max = isBTC ? ICoreObs(c.core).POOLED_BTC() : ICoreObs(c.core).POOLED_ETH();
            zeroForOne = ICoreObs(c.core).token1is(isBTC);
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
            // isn't guaranteed); WBTC swap-out drains the same POOLED_BTC, so it's skewed too
            // (else arbers route around the premium). Scale the buy DOWN so a scarce pool hands
            // out less volatile; the withheld input stays as backing. The swap still executes at
            // the honest oracle (v4p) through routeSwap ⇒ no manip-guard exemption.
            {
                uint skew = wellSkew(c.core, v4p != 0 ? v4p : aux.getTWAPforAsset(r.asset, 1800), isBTC); // inline (swapToBody stack-tight)
                r.amount = retainSkewPremium(c.core, isBTC, r.amount, skew);
            }
        }
        max = _finishSwap(ctx, aux, r, sqrtPriceX96, zeroForOne, max, isBTC, v4p);
    }

    /// @dev routeSwap (8-field RouteParams build) + bumpVogueBTC + slippage guard
    ///      in its own frame so swapToBody stays within the legacy stack — no
    ///      via_ir crutch.
    function _finishSwap(Types.AuxContext memory ctx, IAuxSwap aux, SwapReq memory r,
        uint160 sqrtPriceX96, bool zeroForOne, uint pooled, bool isBTC, uint v4p) private returns (uint max) {
        uint poolSupplied;
        // Reuse the resolved oracle price from the repack-first (v4p) instead of
        // re-reading the internal `observe` ring + Chainlink a 2nd time per swap;
        // fall back to a live read only if the repack couldn't resolve it (v4p==0,
        // e.g. a bootstrap pre-history read that try/catch'd to 0).
        uint v4Price = _priceOr(v4p, address(aux), r.asset);
        uint consumed;
        (max, poolSupplied, consumed) = BasketLib.routeSwap(ctx, Types.RouteParams({
            sqrtPriceX96: sqrtPriceX96, zeroForOne: zeroForOne, token: r.token,
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
    function _refundExcess(IAuxSwap aux, SwapReq memory r, uint consumed) private {
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
        IAuxSwap aux, address token, uint amount, address quid, bool stable,
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
            amount = aux.deposit(msg.sender, token, amount);
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
    function _consumeQdIn(IAuxSwap aux, address quid, uint amount, address[] memory stables)
        private returns (uint) {
        (uint burned, uint seedBurned) = IBasketTurn2(quid).turn(msg.sender, amount);
        uint solvent;
        {   (uint[15] memory d,,, uint dl) = aux.get_deposits();
            (solvent,) = aux.get_metricsWith(d[14], d[0]);
            solvent = solvent > dl ? solvent - dl : 0; }
        amount = ShareMath.qdShareValue(burned, solvent, IBasketTurn2(quid).matureSupply() + burned) / 1e12;
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
    // run via DELEGATECALL so address(this)==Aux (its weETH, its Rover-caller id).
    /// ether.fi RedemptionManager's "pay me native ETH" output-token sentinel.
    address constant ETHFI_NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct OfframpCfg {
        address weeth; address rover; address weth; address v3router;
        address redeemer; address lp; uint24 poolFee; uint24 poolFee2;
    }

    /// @notice Body of Aux.offrampEtherFi — the 4-rung exit ladder.
    ///         HONEST SERVING: when the held weETH covers less than `amount`
    ///         (clamped balance), the weETH-consuming rungs (1/3/4) report the
    ///         pro-rata `covered` slice, never the full ask — so the caller's
    ///         position accounting only decrements what was actually served.
    function offrampBody(uint amount, address recipient, bool instant, OfframpCfg memory c)
        external returns (uint) {
        if (amount == 0 || c.weeth == address(0)) return 0;
        uint weethFull = IWeEth_L(c.weeth).getWeETHByeETH(amount);
        uint weethIn = weethFull;
        uint bal = IERC20(c.weeth).balanceOf(address(this));
        if (weethIn > bal) weethIn = bal;
        uint covered = (weethFull == 0 || weethIn == weethFull)
            ? amount : FullMath.mulDiv(amount, weethIn, weethFull);
        // Rung 1 — v3 pool (only if Aux holds weETH; the Rover rung needs none).
        if (weethIn > 0) {
            uint24[2] memory fees = [c.poolFee, c.poolFee2];
            for (uint i; i < 2; i++) {
                if (fees[i] == 0) continue;
                try IV3SwapRouter(c.v3router).exactInput(IV3SwapRouter.ExactInputParams({
                    path: abi.encodePacked(c.weeth, fees[i], c.weth),
                    recipient: recipient, amountIn: weethIn,
                    amountOutMinimum: (covered * 995) / 1000   // 0.5% slippage cap
                })) returns (uint) { return covered; }
                catch {}
            }
        }
        // Rung 2 — Rover unwind (no Aux weETH needed) + NAV-neutral weETH absorb.
        if (c.rover != address(0)) {
            try IRover_L(c.rover).take(amount) returns (uint got) {
                if (got > 0) {
                    IERC20(c.weth).transfer(recipient, got);
                    uint absorbed = got >= amount ? weethIn
                                                  : FullMath.mulDiv(weethIn, got, amount);
                    if (absorbed > bal) absorbed = bal;
                    if (absorbed > 0) IERC20(c.weeth).transfer(c.rover, absorbed);
                    if (got >= (amount * 995) / 1000) return amount;
                    return got;
                }
            } catch {}
        }
        // Rung 3 — 0.3% instant-redeem (pool-independent floor). VERIFIED ABI
        // (EtherFiRedemptionManager impl 0x6bD1…91F7): redeemWeEth(weEthAmount,
        // receiver, outputToken) where outputToken MUST be the 0xEeee…EEeE
        // native-ETH sentinel or stETH — anything else reverts
        // InvalidOutputToken. (The old code passed WETH here, so this rung
        // SILENTLY FAILED on every call.) The recipient receives NATIVE ETH.
        if (weethIn > 0 && instant && c.redeemer != address(0)) {
            try IRedeem_L(c.redeemer).redeemWeEth(weethIn, recipient, ETHFI_NATIVE_ETH) { return covered; }
            catch {}
        }
        // Rung 4 — last-resort no-fee withdrawal NFT.
        return waitNft(covered, recipient, c);
    }

    /// @notice Rung-4 wait-NFT, standalone: unwrap up to `amount`-worth of the
    ///         held idle weETH → eETH → LiquidityPool withdraw-request NFT
    ///         minted to `recipient`. Returns the ETH-worth actually covered
    ///         (honest: a clamped weETH balance covers proportionally less).
    ///         Used by offrampBody — the LP-exit down-leg fallback when the
    ///         ether.fi instant-redeem buffer is exhausted (the redemption-side
    ///         wrapper was removed: redemption is stables-only).
    function waitNft(uint amount, address recipient, OfframpCfg memory c)
        internal returns (uint) {
        if (amount == 0 || c.weeth == address(0) || c.lp == address(0)) return 0;
        uint weethFull = IWeEth_L(c.weeth).getWeETHByeETH(amount);
        if (weethFull == 0) return 0;
        uint bal = IERC20(c.weeth).balanceOf(address(this));
        uint weethIn = weethFull > bal ? bal : weethFull;
        if (weethIn == 0) return 0;
        try IWeEth_L(c.weeth).unwrap(weethIn) returns (uint eeth) {
            if (eeth > 0) {
                try ILiq_L(c.lp).requestWithdraw(recipient, eeth) returns (uint) {
                    return weethIn == weethFull
                        ? amount : FullMath.mulDiv(amount, weethIn, weethFull);
                } catch {}
            }
        } catch {}
        return 0;
    }

    /// @notice Body of Aux._sourceWethFromEtherfi — opportunistic, non-blocking.
    function sourceWethBody(uint want, OfframpCfg memory c) external returns (uint) {
        if (want == 0 || c.weeth == address(0) || c.v3router == address(0)) return 0;
        uint idle = IERC20(c.weeth).balanceOf(address(this));
        if (idle == 0) return 0;
        uint weethFull = IWeEth_L(c.weeth).getWeETHByeETH(want);
        if (weethFull == 0) return 0;
        uint weethIn = weethFull > idle ? idle : weethFull;
        if (weethIn == 0) return 0;
        uint fairWeth = FullMath.mulDiv(want, weethIn, weethFull);
        uint minOut = (fairWeth * 995) / 1000;            // 0.5% slippage cap
        uint24[2] memory fees = [c.poolFee, c.poolFee2];
        for (uint i; i < 2; i++) {
            if (fees[i] == 0) continue;
            try IV3SwapRouter(c.v3router).exactInput(IV3SwapRouter.ExactInputParams({
                path: abi.encodePacked(c.weeth, fees[i], c.weth),
                recipient: address(this), amountIn: weethIn,
                amountOutMinimum: minOut
            })) returns (uint out) { return out; }
            catch {}
        }
        return 0;
    }

    // ─── BTC swap-IN / swap-OUT bodies (extracted from Aux to free bytecode) ──
    // DELEGATECALL'd → address(this)==Aux, msg.sender==Aux's original caller.
    // The `onlyBTCChannels` gate stays in Aux's wrapper (rogue-mirror defense:
    // a rogue contract must not drive these by delegatecalling the library).
    // CORE / V4 / WBTC are Aux immutables, passed in as args (the library
    // can't read Aux's immutables). The AuxContext is reconstructed inline,
    // matching Aux._buildContext(WBTC) exactly: vault address(0), nativeWETH
    // false, volScale 1e8.
    error StableMissing();
    error SwapOutShort();
    error SwapInShort();
    error SwapInDrainsProceeds();

    /// @notice Body of Aux.creditSwapIn — settle a BTC→USD swap-IN. See Aux's
    ///         wrapper docblock for the full semantics.
    function creditSwapInBody(address seller, uint sats, address token, uint minDeliveredUsd,
        address core, address v4, address wbtc, address aux) external returns (uint consumedSats) {
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
        //   • the curve (POOLED_USD_BTC liquidity) bounds the payout — the old
        //     BtcInflowCap is gone; over-supply just slips / partial-fills;
        //   • netDeliveredBtc / swapUsdBtc decrement from the swap DELTA in
        //     Core._handleSwap (the symmetric `-=`), so per-channel exit
        //     attribution stays honest with no manual draw/dec calls here;
        //   • `token == QUID` reverts inside take (QUID is not a basket stable),
        //     so a swap-IN can NEVER mint QUI — settlement is always existing
        //     pooled dollars, exactly like the ETH side.
        // `sats` are 8-dec (== mockBTC), so they are the exact BTC input; the
        // USD-side cap (POOLED_USD_BTC) converts to sats via the same volScale
        // swap-OUT uses, keeping units coherent.
        // ctx + RouteParams built field-by-field (not an inline literal) so the
        // added v4p reuse fits this body's legacy stack without via_ir — the literal
        // construction peak is what overflowed. vault=0 / nativeWETH=false are the
        // zero-defaults of a fresh memory struct.
        Types.AuxContext memory ctx;
        ctx.asset = wbtc; ctx.core = core; ctx.volScale = 1e8;
        // Reuse the repack-resolved oracle price (5th return); live-read only if
        // v4p==0 — same as _finishSwap. POOLED_USD_BTC pre-scaled ×1e10: convert(toVol)
        // under-scales the 8-dec WBTC cap by 1e18/1e8, ×1e10 cancels it → the true
        // sats-equivalent of the USD reserve to pay out. (BTC-local; ETH untouched.)
        (uint160 sqrtPriceX96,,,, uint v4p) = IVogueRepack2(v4).repack(true);
        Types.RouteParams memory rp;
        rp.sqrtPriceX96 = sqrtPriceX96;
        rp.zeroForOne   = !ICoreObs(core).token1is(true);   // BTC→USD (mirror of the buy)
        rp.token        = token;                            // USD-side output stable → seller
        rp.amount       = sats;                             // exact BTC input
        rp.pooled       = ICoreObs(core).POOLED_USD_BTC() * 1e10;
        // SWAP-IN REFILL PRICING (see {SwapLib-wellSkew} RESERVOIR REFILL DESIGN). Today this
        // leg settles FLAT at the honest oracle. The corrected design -- the SYMMETRIC skew
        // bonus, mirror of the swap-OUT drain penalty (creditSwapOutBody) -- lands with the
        // on-chain refill change once the EIP-170 slimming frees room in this library: a swap-in
        // that refills a SCARCE pool earns a bonus applied as a SEPARATE output scalar (routeSwap
        // stays at the honest v4Price, so the manip-guard stays unskewed), paid from and CLAMPED
        // to the retained drain premium (Core.skewPremiumBTC) so the pool never pays out more
        // refill bonus than it collected (conserves; flat when the pot is empty). It is the FAST
        // transient top-up; LP staking (Vault.registerBtcLp) is the PRIMARY refill. Permissionless:
        // a public reservation price captured by whoever swaps in first (a gas race), NOT an
        // RFQ / external-MM subsidy (the discarded model this comment previously described).
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
        // `consumedSats` = the seller's BTC actually converted (routeSwap caps input at the POOLED_USD_BTC USD
        // inventory). On an inventory-bounded partial it is < the `sats` sent, and the caller signals the hop to
        // refund the `sats − consumedSats` remainder (the seller's BTC is held off-chain over the deposit/HTLC).
        uint deliveredUsd;
        (deliveredUsd,, consumedSats) = BasketLib.routeSwap(ctx, rp);
        if (deliveredUsd < minDeliveredUsd) revert SwapInShort();
        if (ICoreObs(core).POOLED_USD_BTC() < ICoreObs(core).pendingSwapOutUsd())
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
    uint internal constant MAX_WELL_SKEW = 3e16;   // 3% — hard cap (TWAP-anchor bound)
    // Avellaneda–Stoikov calibration. `realizedVarianceWad` is ANNUALIZED realized
    // variance in WAD (VogueLib:294-318: tickVar·(SECS_PER_YEAR/THETA_STEP)·1e10 ⇒ a
    // fraction² scaled 1e18; e.g. 80%-annualized vol ⇒ σ²≈0.64 ⇒ ~6.4e17). SIGMA_REF is
    // the REFERENCE variance = 1e18 (variance 1.0 = 100% annualized vol) at which full
    // scarcity saturates the cap — picking the per-interval-scale 1e16 instead would peg
    // skew at the cap for any real crypto vol (>10% ann), so the annualized 1e18 is the
    // unit-correct anchor. Γ folds the risk-aversion γ and the horizon (T−t) into ONE
    // coefficient (the horizon is already carried by the FLOW_DECAY-smoothed flow/scarcity),
    // fixed so skew(q=1, σ²=SIGMA_REF)=Γ·SIGMA_REF=MAX_WELL_SKEW.
    uint internal constant SIGMA_REF = 1e18;                                 // reference σ² (100% ann. vol)
    uint internal constant GAMMA_WAD = MAX_WELL_SKEW * 1e18 / SIGMA_REF;     // Γ = γ·(T−t) folded ⇒ 3e16
    // STABLENESS = ρ, the DEPLETION-BARRIER ORDER (derived, NOT a fit exponent). The skew is
    // Γ·σ²·q / (1−q)^ρ: the A-S linear reservation premium Γσ²q amplified by the shadow price of the
    // last inventory units. Derived from the HJB with a HARD inv≥0 constraint — a −log(inv) barrier
    // (the LP physically cannot serve at inv=0) whose marginal ∝ 1/inv makes depletion convexly
    // costly. ρ=1 = the log-barrier (constraint exactly at inv=0); ρ=0 recovers plain linear A-S;
    // ρ>1 = a harder barrier. Calculus-derived — the one parameter is a barrier order, not a curve fit.
    uint internal constant STABLENESS = 1;
    // Volatile band half-width, in bps of price (paddedSqrtPrice reads it as (10000±delta)/10000).
    // THIN band (±0.2%). Vogue SERVES swaps and RESEATS, so it can't go to a literal one-tick like a static
    // Rover position: at delta=10 the reseat re-add (updateTicks(targetSqrt,10)) collapses lower==upper and V4
    // reverts. 0.2% is the thinnest that keeps the reseat re-add non-degenerate while staying maximally thin
    // (near-zero natural slippage, whale-friendly). Frequent repacks are covered by repack-first (swapper-paid)
    // + the self-funded reseat keeper — no separate gas budget needed.
    uint internal constant BAND_DELTA = 20;

    // DYNAMIC CAP calibration. Instead of a fixed 3%, the ceiling tracks the native-BTC MM's
    // REAL drain-edge cost, which is dominated by the BTC-price risk while its capital is
    // locked from committing sats until the swap-in settles + it holds the USD (~6 confs ≈ 1
    // hour). That cost ≈ σ over the confirmation window · a safety multiple + the splice fee.
    uint internal constant CONF_FRAC_WAD = 114_000_000_000_000; // ≈ 1hr / 1yr (WAD) — confirmation-window fraction of a year
    uint internal constant CAP_SAFETY    = 2;                   // ~2σ coverage of the confirmation-window move
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
        uint confVarWad = FullMath.mulDiv(sigmaSqWad, confFrac, 1e18);       // σ² over the settlement window (WAD)
        uint confStdWad = FixedPointMathLib.sqrt(confVarWad * 1e18);         // → σ over the window (WAD)
        uint cap = confStdWad * CAP_SAFETY + (isBTC ? SPLICE_FLOOR : 0);
        return cap < MAX_WELL_SKEW ? cap : MAX_WELL_SKEW;
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
    function skewWad(uint poolVolUsd, uint lockedUsd, uint committedUsd, uint flowUsd, uint sigmaSqWad, bool isBTC)
        public pure returns (uint skew)
    {
        uint target = flowUsd + committedUsd;
        if (target == 0) return 0;
        uint inv = poolVolUsd > lockedUsd ? poolVolUsd - lockedUsd : 0;
        if (inv >= target) return 0;                     // flush ⇒ ~oracle (band owns it)
        uint q = (target - inv) * 1e18 / target;         // scarcity q ∈ (0, 1e18]
        uint oneMinusQ = 1e18 - q;                        // = inv/target ∈ [0, 1e18)
        // DEPLETION-BARRIER skew = Γ·σ²·q / (1−q)^ρ, ρ = STABLENESS (see the constant's derivation):
        // the A-S linear premium Γσ²q amplified by the log-barrier shadow price 1/(1−q)^ρ of the last
        // inventory units. Blows up convexly as inv→0 (oneMinusQ→0), bounded by the cap below.
        uint skewRaw;
        if (oneMinusQ == 0) {
            skewRaw = type(uint).max;                     // inv=0 ⇒ barrier → ∞ ⇒ pinned to the cap
        } else {
            uint denom = oneMinusQ;                       // (1−q)^ρ
            for (uint i = 1; i < STABLENESS; ++i) denom = FullMath.mulDiv(denom, oneMinusQ, 1e18);
            uint qBar = FullMath.mulDiv(q, 1e18, denom);  // q / (1−q)^ρ  (= q for ρ=0, q/(1−q) for ρ=1)
            skewRaw = FullMath.mulDiv(FullMath.mulDiv(GAMMA_WAD, sigmaSqWad, 1e18), qBar, 1e18);
        }
        skew = skewRaw;
        // DYNAMIC cap = the live MM refill cost (σ over the confirmation window), never above
        // the MAX_WELL_SKEW abs ceiling. Replaces the fixed 3% clamp: in calm markets the cap
        // binds LOWER (don't overpay a cheap refill), in high vol it rises toward 3%.
        uint cap = _maxWellSkew(sigmaSqWad, isBTC);
        if (skew > cap) skew = cap;
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
    ///         2. FAST TOP-UP -- the transient swap-IN refill leg earns the SYMMETRIC skew
    ///            bonus ({SwapLib-creditSwapInBody}), the mirror of the swap-OUT drain penalty,
    ///            funded by and CLAMPED to the retained drain premium ({Core-skewPremiumBTC}).
    ///            It bridges the gaps BETWEEN LP-stake arrivals.
    ///         So the skew's whole job is to PRICE the scarcity -- making staking/refilling
    ///         attractive exactly when the reservoir needs it (the fee side already reflects
    ///         this) and the swap-in top-up lucrative. The refill is a PERMISSIONLESS response
    ///         to a public on-chain price: the skew is our reservation price, captured by
    ///         whoever refills first (a gas race), never an operator-tuned or bid mechanism.
    function wellSkew(address core, uint base, bool isBTC)
        public view returns (uint)
    {
        uint poolVol = isBTC ? ICoreObs(core).POOLED_BTC() : ICoreObs(core).POOLED_ETH();
        // UNIFORM sats/wei → 6-dec USD: `poolVol · base / 1e30`. Authoritative (NOT
        // BasketLib.convert(...,volScale), which /1e8·1e12 over-values 8-dec BTC by 1e10 —
        // the WBTC ×1e10 price-lift already closes the 8↔18-dec gap, so a flat /1e30 is
        // correct for BOTH pools and keeps poolVolUsd in the same 6-dec unit as flow + lev.
        uint poolVolUsd = FullMath.mulDiv(poolVol, base, 1e30);
        // lockedUsd = GROSS levered collateral, converted with the SAME base/1e30 scale as poolVol
        // (one price, one unit) — the locked-inventory basis for `inv` (#6/F3). committedUsd = DEBT.
        uint lockedUsd = FullMath.mulDiv(ICoreObs(core).levGrossNative(isBTC), base, 1e30);
        return skewWad(
            poolVolUsd,
            lockedUsd,
            ICoreObs(core).levClaimUsd6(isBTC),
            ICoreObs(core).flowEwmaUsd(isBTC),
            ICoreObs(core).realizedVarianceWad(isBTC), isBTC);
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
    function sellSkew(address core, uint base, bool isBTC, uint addedTok)
        public view returns (uint)
    {
        uint committed = ICoreObs(core).levClaimUsd6(isBTC);      // DEBT (→ target)
        uint flow = ICoreObs(core).flowEwmaUsd(isBTC);
        uint target = flow + committed;
        if (target == 0) return 0;
        // inv = poolVolUsd − GROSS locked inventory (same base/1e30 scale as poolVol, #6/F3). Scope the two
        // transient conversion locals so they free their stack slots before the skewWad call (no via_ir).
        uint inv;
        {
            uint poolVolUsd = FullMath.mulDiv(
                (isBTC ? ICoreObs(core).POOLED_BTC() : ICoreObs(core).POOLED_ETH()) + addedTok, base, 1e30);
            uint locked = FullMath.mulDiv(ICoreObs(core).levGrossNative(isBTC), base, 1e30);
            inv = poolVolUsd > locked ? poolVolUsd - locked : 0;
        }
        // A-S inventory-sign flip: reflect inv about target. inv≤target (refill) ⇒
        // mirror≥target ⇒ skewWad flush ⇒ 0 (EXEMPT); inv>target (inventory-increasing
        // sell) ⇒ mirror<target ⇒ skewWad prices (inv−target)/target; inv>2·target
        // (extreme surplus) ⇒ mirror 0 ⇒ capped. Re-passed so skewWad's inner inv == mirror
        // (lockedUsd=committed, poolVolUsd=committed+mirror), target=flow+committed unchanged.
        uint mirror = 2 * target > inv ? 2 * target - inv : 0;
        return skewWad(committed + mirror, committed, committed, flow,
            ICoreObs(core).realizedVarianceWad(isBTC), isBTC);
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
        address wbtc = address(IAuxSwap(aux).WBTC());
        // The normalized 6-dec USD pulled in — exactly what enters POOLED_USD_BTC (exact-input curve buy)
        // and thus the exact proceeds owed to the delivering LP (returned so requestSwapOutOnchain records it).
        uint amount = IAuxSwap(aux).deposit(swapper, token, usdAmount);
        ctx.asset = wbtc; ctx.core = core; ctx.volScale = 1e8;
        // Reuse the repack-resolved oracle price (5th return); live-read only if v4p==0.
        (uint160 sqrtPriceX96,,,, uint v4p) = IVogueRepack2(address(this)).repack(true);
        rp.sqrtPriceX96 = sqrtPriceX96;
        rp.zeroForOne   = ICoreObs(core).token1is(true);    // USD→BTC buy (mirror of the sell)
        rp.token        = address(0);                       // volatile (BTC) output
        rp.pooled       = ICoreObs(core).POOLED_BTC();      // BTC inventory bounds the fill
        uint basePrice  = _priceOr(v4p, aux, wbtc);
        rp.v4Price      = basePrice;                         // HONEST oracle — manip-guard stays unskewed
        // Effective-rate scarcity skew on the drain: scale the buy-driving USD DOWN by (1−skew) so a
        // BTC-scarce pool hands the swapper FEWER sats per USD; the withheld premium stays as backing. The
        // swap still executes at basePrice through routeSwap ⇒ NO manip-guard exemption (separate scalar).
        uint skew = wellSkew(core, basePrice, true);
        amount = retainSkewPremium(core, true, amount, skew);   // audit + RFQ-drawable
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
        if (amount > consumed) ICoreObs(ctx.core).refundUnfilled(token, amount - consumed, swapper);
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
    ///   resizeBtcLp then delivers the full shrink), and DRAW the retired-debt share out of POOLED_USD_BTC + clear
    ///   its obligation. The Vault hands resizeBtcLp `exactUsd − deLeverUsd6`, so `settleDelivered` mints QUI for
    ///   the FUNDED (+ any pure-equity) remainder only — the de-levered slice is paid ONCE (debt-reduction, not a
    ///   QUI mint). VALUE-NEUTRAL: −BTC −debt of equal oracle value ⇒ net-equity preserved, LTV IMPROVES. The
    ///   levered slice's V4 depth was already consumed by the curve at REQUEST (it sold against the full
    ///   POOLED_BTC), so this only reconciles the per-LP accounting — no second burnInRange. DELEGATECALL'd by the
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
    ///   (manager burns the vBTC), and draws the retired-debt share out of POOLED_USD_BTC + clears its obligation.
    function _sourceRepayFree(address core, address aux, address mgr, address lp, uint want, uint wantUsd6, uint exactUsd6)
        private returns (uint deLeverUsd6) {
        (address venue, address stable, uint amtNative) =
            ILevManagerDeliver(mgr).swapOutDeleverAmt(lp, wantUsd6 * 1e12);  // amtNative clamped to LIVE debt
        if (venue == address(0)) return 0;
        uint takeUsd18 = LevMath._toUsd18(stable, amtNative);
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
        // Draw the retired-debt share out of POOLED_USD_BTC BEFORE the drain: takeToSettle uses the SOFT backing
        // check (its mid-drain instant is offset by the repay below), and drawing first keeps committed and liquid
        // moving together. The debt-buffer's stale POOLED_USD is reconciled by the keeper's async syncLevBTC.
        ICoreObs(core).drawPooledUsdBtc(deLeverUsd6);          // retired-debt share leaves POOLED_USD_BTC
        ICoreObs(core).subPendingSwapOut(deLeverUsd6);        // obligation share cleared (matched at request)
        uint got;
        {
            uint bal0 = IERC20(stable).balanceOf(venue);
            IAuxSwap(aux).takeToSettle(venue, takeUsd18, stable); // basket → venue (soft backing = final-state solvency)
            got = IERC20(stable).balanceOf(venue) - bal0;        // venue-stable actually sourced (native units)
        }
        // Repay `got` (0 if the position had no debt — a pure-equity levered slice) and free `want` sats regardless.
        ILevManagerDeliver(mgr).swapOutDelever(lp, LevMath._toUsd18(stable, got), want);
    }

    /// @dev Held USD (18-dec) of a single basket stable = its get_deposits slot. In the uint[15] vector,
    ///   `amounts[i+1] = balance` is the depeg-adjusted per-stable hold (BasketLib:247; BOLD → [11]), while
    ///   `amounts[0]` is the yield-weighted aggregate and `amounts[14]` the TVL total. So a real stable's
    ///   `toIndex` is in [1,11]; reject the aggregate (0), the total (12), and unknown stables (toIndex 0).
    function _heldUsd18(address aux, address stable) private returns (uint) {
        uint idx = IAuxSwap(aux).toIndex(stable);
        if (idx == 0 || idx >= 12) return 0;
        (uint[15] memory amts,,,) = IAuxSwap(aux).get_deposits();
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
            uint fundUsd = LevMath._toUsd18(stable, amtNative);      // USD the clamped debt-repay represents
            if (fundUsd > needUsd) fundUsd = needUsd;
            if (fundUsd == 0) continue;
            // Route the swap's OWN proceeds → venue directly (Vogue==address(this) IS `takeToSettle`-authorized),
            // then repay+free+deliver. try/catch: a stuck LP (illiquid collateral / venue revert) is skipped,
            // leaving the residual to the #105 partial-fill.
            try IAuxSwap(aux).takeToSettle(venue, fundUsd, stable) returns (uint) {
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
        uint pooled = isBTC ? IV4(v4).POOLED_BTC() : IV4(v4).POOLED_ETH();
        uint pulled = Math.min(amount, pooled);
        if (pulled == 0) return 0;
        (,, uint128 posLiquidity) = IV4(v4).poolStats(tickLower, tickUpper, isBTC);
        if (posLiquidity > 0) {
            sent = IV4(v4).modLP(isBTC, sqrtPriceX96, pulled, 0,
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
    ///             depth (POOLED_ETH/BTC). The band can never exceed what backs it.
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

    function retainSkewPremium(address core, bool isBTC, uint amount, uint skew) internal returns (uint) {
        if (skew == 0) return amount;
        uint premium = FullMath.mulDiv(amount, skew, 1e18);
        ICoreObs(core).recordSkewPremium(isBTC, premium);
        return amount - premium;
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
    ///         the ETH band (Vogue, `token1isETH`) and the BTC band (Vault, `token1isBTC`).
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
            IV4(v4).poolStats(tickLower, tickUpper, isBTC);

        // Resolved oracle price + staleness. try/catch so a bootstrap pre-history
        // / dead-feed read NEVER bricks the op (falls through to legacy handling).
        uint twap; bool stale;
        try IAuxTwap(aux).resolvedTwap(asset, 1800) returns (uint p, bool s) {
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

        if (currentTick > tickUpper || currentTick < tickLower) {
            // Don't repack to a manipulated spot — need the oracle. If unavailable
            // (twap==0, e.g. bootstrap) or spot deviates >300bps, keep the range.
            if (twap == 0) return r; // didRepack stays false → keep current range
            uint spot = BasketLib.getPrice(r.sqrtPriceX96, IV4(v4).token1is(isBTC));
            // Repack TOLERANCE (300 bps = 3%) — looser than the 50-bps swap
            // guard so normal volatility doesn't block re-centering.
            if (BasketLib.isManipulated(spot, twap, 300)) {
                return r;
            }
            (int24 newTickLower,, int24 newTickUpper,) = updateTicks(r.sqrtPriceX96, BAND_DELTA);
            if (r.myLiquidity > 0) {
                (r.price, r.fees0, r.fees1, r.delta0, r.delta1) =
                    IV4(v4).repack(isBTC, r.myLiquidity, r.sqrtPriceX96,
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
            (r.jitFeesUsd, r.jitFeesTok) = IV4(v4).collectFees(tickLower, tickUpper, isBTC);
            r.jitFees = true;
        }
    }

    /// @dev Move the curve spot onto the (Chainlink) target `twap` + re-range.
    ///      Own frame so rebalanceCore stays within the legacy stack (no via_ir).
    ///      Returns true if it moved the spot. No-op (false) when already aligned.
    function _reseatIfStale(address v4, bool isBTC, Rebalanced memory r, uint twap)
        private returns (bool) {
        bool t1isVol = IV4(v4).token1is(isBTC);
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
            (r.price, r.fees0, r.fees1, r.delta0, r.delta1) = IV4(v4).reseat(
                isBTC, r.myLiquidity, r.sqrtPriceX96, targetSqrt,
                r.tickLower, r.tickUpper, nlo, nhi);
            r.didRepack = true;
        }
        r.tickLower = nlo; r.tickUpper = nhi; r.sqrtPriceX96 = targetSqrt;
    }

}

interface IAuxTwap {
    function getTWAPforAsset(address asset, uint32 period) external view returns (uint);
    function resolvedTwap(address asset, uint32 period)
        external view returns (uint price, bool stale);
}

interface IV4 {
    function poolStats(int24 tickLower, int24 tickUpper, bool isBTC)
        external view returns (uint160 sqrtPriceX96, int24 currentTick, uint128 liquidity);
    function modLP(bool isBTC, uint160 sqrtPriceX96, uint delta, uint deltaUSD,
        int24 tickLower, int24 tickUpper, address recipient) external returns (uint);
    function POOLED_BTC() external view returns (uint);
    function POOLED_ETH() external view returns (uint);
    function POOLED_USD_BTC() external view returns (uint);
    function repack(bool isBTC, uint128 myLiquidity, uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, int24 newTickLower, int24 newTickUpper)
        external returns (uint price, uint fees0, uint fees1, uint delta0, uint delta1);
    function reseat(bool isBTC, uint128 myLiquidity, uint160 currentSqrt,
        uint160 targetSqrt, int24 oldTickLower, int24 oldTickUpper,
        int24 newTickLower, int24 newTickUpper)
        external returns (uint price, uint fees0, uint fees1, uint delta0, uint delta1);
    function collectFees(int24 tickLower, int24 tickUpper, bool isBTC)
        external returns (uint, uint);
    function token1is(bool isBTC) external view returns (bool);
    // Self-managed out-of-range position op (mock relocate; isBTC selects the pool).
    function outOfRange(bool isBTC, address sender, int liquidity,
        int24 tickLower, int24 tickUpper, address token) external;
    function poolTicks(bool isBTC) external view returns (bytes32, uint160, int24);
}


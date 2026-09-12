// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WAD, FLOW_HALFLIFE, BadAsset} from "./Types.sol";

import {IBasket} from "./Interfaces.sol";

import {ICore} from "./Interfaces.sol";
import {ILevManagerDeliver, ILevEthDeliver} from "./Interfaces.sol";
import {ILevPooled, ILevVenue} from "./Interfaces.sol";
import {IBTCChannels} from "./Interfaces.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWETH9} from "./Interfaces.sol";

import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {BasketLib} from "./BasketLib.sol";
import {FeeLib} from "./FeeLib.sol";
import {Types} from "./Types.sol";
import {LevMath} from "./LevMath.sol";
import {IAux} from "./Interfaces.sol";
import {IAggregatorV3} from "./Interfaces.sol";

library SwapLib {
    using SafeERC20 for IERC20OZ;

    /// @notice The settlement price IS the anchor. There is no second source and no averaging.
    /// 🔴 A MISSING OR INVALID ANCHOR REVERTS. It does NOT return zero. The first version of this
    ///    returned `(0, true)` and that is standing rule 3's silent shape: an unregistered feed
    ///    produced price 0, which produced a quote of 0, which surfaced downstream as
    ///    `SwapOutDust()` -- an error naming the wrong cause, on a path where 500 USDC had
    ///    quoted 648,282 sats the run before. **A price of zero is not a price.**
    /// ⚠️ STALENESS IS RETURNED, NOT THROWN, and that asymmetry is deliberate: a stale feed still
    ///    carries a real number and `SwapLib`'s rebalance path acts on the flag
    ///    (`if (stale && _reseatIfStale(...))`). A missing feed carries nothing.
    function anchorPrice18(address feed, bool isWbtc, uint maxAge)
        external view returns (uint price, bool stale) {
        if (feed == address(0)) revert NoAnchor();
        (, int256 ans, , uint256 updatedAt, ) = IAggregatorV3(feed).latestRoundData();
        if (ans <= 0) revert NoAnchor();
        uint8 d = IAggregatorV3(feed).decimals();
        if (d > 18) revert NoAnchor();
        price = uint(ans) * (10 ** (18 - d));
        if (isWbtc) price *= 1e10;
        stale = block.timestamp < updatedAt
             || block.timestamp - updatedAt > maxAge;
    }

    error UnknownStableSweep();
    error BadOp();

    function sweepBody(address token, address weth, address wbtc)
        external returns (uint vbtcDelta, uint swept) {

        if (token == address(0)) {
            swept = address(this).balance;
            if (swept == 0) return (0, 0);
            WETH9(payable(weth)).deposit{value: swept}();
            token = weth;
        } else if (token == wbtc) {
            swept = IERC20(wbtc).balanceOf(address(this));
            return (swept, swept);
        } else if (token == weth || IAux(address(this)).toIndex(token) != 0) {
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

        uint pulled = Math.min(amountIn,
            IERC20(tokenIn).allowance(msg.sender, address(this)));
        if (pulled == 0)                     revert ZeroAmount();
        IERC20OZ(tokenIn).safeTransferFrom(msg.sender, address(this), pulled);
        pulled = aux.supplySelf(tokenIn, pulled);

        uint requested = _convert(tokenIn, tokenOut, pulled, linkAddr);
        amountOut = aux.withdrawSelf(tokenOut, requested, recipient);
        if (amountOut < minOut)              revert SlippageExceeded();

        aux.checkBacking();
    }

    function _convert(address tokenIn, address tokenOut, uint pulled,
        address linkAddr) private returns (uint) {

        uint usdIn  = BasketLib.scaleTokenAmount(pulled, tokenIn, true);
        uint usdOut = FeeLib.applyFeeAndHaircut(tokenOut, usdIn, linkAddr);
        return BasketLib.scaleTokenAmount(usdOut, tokenOut, false);
    }

    function rangeOpBody(uint amount, uint8 op, WETH9 weth, uint rangeETHLive)
        external returns (uint sent) {
        IAux aux = IAux(address(this));

        if (op == 1) {
            amount = Math.min(amount, rangeETHLive);
            sent = aux.withdrawSelf(address(weth), amount, address(this));
            weth.transfer(msg.sender, sent);
            return sent;
        }

        if (op == 2) return rangeETHLive;
        revert BadOp();
    }

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

    function _repackPx(address range) private returns (uint) {
        (,,,, uint p) = ICore(range).repack();
        return p;
    }

    function _priceOr(uint priceHint, address aux, address asset) internal view returns (uint) {
        return priceHint != 0 ? priceHint : IAux(aux).assetPrice(asset);
    }

    function _requireStable(address aux, address token) internal view {
        if (IAux(aux).toIndex(token) == 0) revert StableMissing();
    }

    error NoShedPath();
    error BtcInflowsViaChannels();
    error NoBtcRecipient();
    error StableMissingS();
    error SlippageMaxS();
    error UnderBackedS();
    error DeleverStableUnavailable();

    struct SwapToCfg {
        address weth; address wbtc; address quid; address core;

        address range; address btcChannels;
    }

    struct SwapReq {
        address token;
        address asset;
        bool forVolatile;
        uint amount;
        uint minOut;
        address recipient;

        bool loadBalance;
        address inToken;
        uint px;

    }

    function swapToBody(SwapReq memory r, SwapToCfg memory c, address[] memory stables)
        external returns (uint max) {
        if (r.asset != c.weth && r.asset != c.wbtc) revert BadAsset();

        bool nativeWETH = r.asset != c.wbtc;
        if (!r.forVolatile && !nativeWETH) revert BtcInflowsViaChannels();
        IAux aux = IAux(address(this));
        bool stable = aux.toIndex(r.token) > 0;

        r.inToken = r.forVolatile ? (r.token == c.quid ? address(0) : r.token) : r.asset;
        if (r.forVolatile && !nativeWETH && r.recipient != address(this)) {
            if (IBTCChannels(c.btcChannels).btcRecipientOf(r.recipient) == bytes32(0)) revert NoBtcRecipient();
        }

        Types.AuxContext memory ctx = Types.AuxContext({
            asset: r.asset, vault: address(0), core: c.core,
            nativeWETH: nativeWETH
        });

        uint priceHint = _repackPx(c.range);
        {

            (uint[16] memory _deposits,,,) = aux.get_deposits();
            if (ICore(c.core).committedUsd18() > _deposits[15]) revert UnderBackedS();
        }

        if (!r.forVolatile) {
            if (r.token != c.quid && !stable) revert StableMissingS();

            r.amount = aux._depositVol{value: msg.value}(r.asset, msg.sender, r.amount);
            max = ICore(c.core).POOLED_USD();

        } else { max = ICore(c.core).POOLED();

            r.amount = _consumeVolInput(aux, r.token, r.amount, c.quid, stable, stables);
            r.token = address(0);
        }

        {
            r.px = _priceOr(priceHint, address(aux), r.asset);
            retainFee(c.core, r, !r.forVolatile);
        }
        max = _finishSwap(ctx, aux, r, r.forVolatile, max);
    }

    function _finishSwap(Types.AuxContext memory ctx, IAux aux, SwapReq memory r,
        bool inputIsUsd, uint pooled) private returns (uint max) {
        uint poolSupplied;

        uint fillPrice = r.px;
        uint consumed;
        (max, poolSupplied, consumed) = BasketLib.routeSwap(ctx, Types.RouteParams({
            inputIsUsd: inputIsUsd, token: r.token,
            amount: r.amount, pooled: pooled,
            fillPrice: fillPrice,
            recipient: r.recipient,
            loadBalance: r.loadBalance
        }));

        if (poolSupplied > 0 && !ctx.nativeWETH) aux.bumpQuidBTC(poolSupplied);

        if (max == 0 || max < r.minOut) revert SlippageMaxS();

        _refundExcess(aux, r, consumed);
    }

    function _refundExcess(IAux aux, SwapReq memory r, uint consumed) private {
        if (r.inToken == address(0) || r.amount <= consumed) return;
        uint excess = r.amount - consumed;
        aux.withdrawSelf(r.inToken,
            r.forVolatile ? BasketLib.scaleTokenAmount(excess * 1e12, r.inToken, false) : excess,
            msg.sender);
    }

    function _consumeVolInput(
        IAux aux, address token, uint amount, address quid, bool stable,
        address[] memory stables
    ) private returns (uint) {
        if (token == quid) {

            amount = _consumeQdIn(aux, quid, amount, stables);
        } else {
            address vault = aux.tokens(token);
            uint index = aux.toIndex(vault);
            if (index > 5) {
                amount = aux.withdrawSelf(vault, amount, address(this));
            } else if (!stable) revert StableMissingS();

            amount = LevMath.scaleTo6(aux.deposit(msg.sender, token, amount), token);
        }
        return amount;
    }

    function _consumeQdIn(IAux aux, address quid, uint amount, address[] memory stables)
        private returns (uint) {
        (uint burned, uint seedBurned) = IBasket(quid).turn(msg.sender, amount);
        uint solvent;
        {   (uint[16] memory d, uint[16] memory yW,, uint dl) = aux.get_deposits();

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

    struct OfframpCfg {
        address weeth; address weth; address curvePool; address lp;
    }

    error StableMissing();
    error SwapOutShort();
    error SwapInShort();
    error SwapInDrainsProceeds();

    function creditSwapInBody(address seller, uint sats, address token, uint minDeliveredUsd,
        address core, address rangeVault, address wbtc, address aux) external returns (uint consumedSats) {
        if (sats == 0) return 0;

        _requireStable(aux, token);

        Types.AuxContext memory ctx;
        ctx.asset = wbtc; ctx.core = core;

        uint priceHint = _repackPx(rangeVault);
        Types.RouteParams memory rp;
        rp.inputIsUsd   = false;
        rp.token        = token;
        rp.amount       = sats;
        rp.pooled       = ICore(core).POOLED_USD();

        rp.fillPrice = _priceOr(priceHint, aux, wbtc);
        rp.recipient    = seller;

        // §MIN-CHARGE-MISSES-THE-SWAP-IN-RAIL. The swap-OUT sibling charges through `retainFee` and
        // this rail charged NOTHING, while both fill at the same oracle — so the swap-IN was a free
        // option against our own TWAP: move inside the window, sell sats in at the stale favourable
        // price, and the basket eats it. The charge is not a fee here, it is the premium on an option
        // the oracle grants; zero is not a discount, it is an unpriced option, and whoever takes it
        // is by construction the party who knows the oracle is stale.
        // 🔴 `nativeAmount = true` — UNLIKE the swap-out sibling, which passes `false`. `r.amount` is
        // SATS, so `recordFee` needs `r.px` to convert the premium into the USD leg; passing `false`
        // would book sats as dollars.
        SwapReq memory sr; sr.amount = sats; sr.px = rp.fillPrice;
        retainFee(core, sr, true);
        rp.amount = sr.amount;

        // ⚠️ THE PREMIUM IS STILL CONSUMED FROM THE SELLER — it is retained, not refunded — so it
        // MUST be counted here. `consumedSats` is what `reverseSwapOut` compares against `so.sats`
        // under `requireFull`, and returning only the routed part would make every full reversal
        // revert `SwapInPartialRejected` the moment this charge existed.
        consumedSats = _swapInSettle(ctx, rp, minDeliveredUsd) + (sats - sr.amount);
    }

    function _swapInSettle(Types.AuxContext memory ctx, Types.RouteParams memory rp, uint minDeliveredUsd)
        private returns (uint consumedSats) {

        address core = ctx.core;

        uint deliveredUsd;
        (deliveredUsd,, consumedSats) = BasketLib.routeSwap(ctx, rp);
        if (deliveredUsd < minDeliveredUsd) revert SwapInShort();
        if (ICore(core).POOLED_USD() < ICore(core).pendingSwapOutUsd())
            revert SwapInDrainsProceeds();

    }

    uint public constant MIN_SWAP_SKEW_WAD = 4.2e14;

    uint internal constant RANGE_DELTA = 200;

    struct OorIntent {
        address owner;
        bool    buyVolatile;
        uint256 size;
        uint256 limitPx;
        uint64  expiry;
        uint64  nonce;
        bool    loadBalance;

        address payoutToken;
    }
    bytes32 internal constant OOR_TYPEHASH = keccak256(
        "OorIntent(address owner,bool buyVolatile,uint256 size,uint256 limitPx,uint64 expiry,uint64 nonce,bool loadBalance,address payoutToken)");

    bytes32 internal constant OOR_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _oorDigest(OorIntent calldata i, bytes32 domainSep)
        private pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSep,
            keccak256(abi.encode(OOR_TYPEHASH, i.owner, i.buyVolatile, i.size,
                i.limitPx, i.expiry, i.nonce, i.loadBalance, i.payoutToken))));
    }

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

        uint px = IAux(aux).assetPrice(asset);
        if (i.buyVolatile ? px > i.limitPx : px < i.limitPx) revert IntentNotCrossed();
        used[i.owner][i.nonce] = true;
        if (i.buyVolatile) {

            uint funded = IAux(aux).spendClaim(i.owner, i.size);
            if (funded == 0) revert IntentUnfunded();
            uint volOut = BasketLib.convert(funded, i.limitPx, true);

            if (volOut == 0 || volOut > ICore(core).POOLED()) revert IntentUnfillable();
            usdDelta = -int(funded); volDelta = int(volOut);
        } else {

            wantUsd6 = i.size;
        }
    }

    error IntentUnfunded();
    error IntentExpired();
    error IntentUsed();
    error NoAnchor();
    error IntentBadSig();
    error IntentNotCrossed();
    error IntentUnfillable();

    function creditSwapOutBody(address swapper, address token, uint usdAmount, uint minSats,
        address core, address aux) external returns (uint sats, uint usd6) {
        if (usdAmount == 0) return (0, 0);
        _requireStable(aux, token);

        (Types.AuxContext memory ctx, Types.RouteParams memory rp) =
            _swapOutPrep(swapper, token, usdAmount, core, aux);
        (sats, usd6) = _swapOutSettle(ctx, rp, swapper, token, minSats);
    }

    function _swapOutPrep(address swapper, address token, uint usdAmount, address core, address aux)
        private returns (Types.AuxContext memory ctx, Types.RouteParams memory rp) {
        address wbtc = address(IAux(aux).WBTC());

        uint amount = LevMath.scaleTo6(IAux(aux).deposit(swapper, token, usdAmount), token);
        ctx.asset = wbtc; ctx.core = core;

        uint priceHint = _repackPx(address(this));
        rp.inputIsUsd   = true;
        rp.token        = address(0);
        rp.pooled       = ICore(core).POOLED();
        uint basePrice  = _priceOr(priceHint, aux, wbtc);
        rp.fillPrice      = basePrice;

        SwapReq memory sr; sr.amount = amount; sr.px = 0;
        retainFee(core, sr, false);
        amount = sr.amount;
        rp.amount    = amount;
        rp.recipient = address(this);
    }

    function _swapOutSettle(Types.AuxContext memory ctx, Types.RouteParams memory rp,
        address swapper, address token, uint minSats) private returns (uint sats, uint usd6) {
        uint amount = rp.amount;
        usd6 = amount;
        uint consumed;
        (sats,, consumed) = BasketLib.routeSwap(ctx, rp);
        if (consumed < usd6) usd6 = consumed;
        if (amount > consumed) ICore(ctx.core).refundUnfilled(token, amount - consumed, swapper);
        if (sats < minSats) revert SwapOutShort();
    }

    uint constant RESEAT_MIN_BPS = 50;

    /// §BTC-10b(c). The NATIVE leg is gone. It existed because a Uniswap v4 pool pays trading fees
    /// in BOTH tokens of the pair, so an LP earned fees denominated in the range's own asset as well
    /// as in dollars. §V4-CUT removed the pool, `c4855d54` removed the now-unassigned `fees0/fees1`
    /// that fed it, and §E5 re-established fee crediting from a DIFFERENT source — the retained
    /// premium — which is *"already basket backing"* and mints through the USD leg by construction.
    /// ⇒ there is no native-denominated fee source left, and nothing to bookmark against.
    function refreshBookmarks(Types.Deposit storage LP, uint weight, uint usdAccum) internal {
        LP.fees_usd = SoladyMath.fullMulDiv(weight, usdAccum, WAD);
    }

    function pendingFor(Types.Deposit storage LP, uint weight, uint feePerShareUsd)
        internal view returns (uint usdReward) {
        if (weight == 0) return 0;
        uint usdOwed = SoladyMath.fullMulDiv(weight, feePerShareUsd, WAD);
        usdReward = usdOwed > LP.fees_usd ? usdOwed - LP.fees_usd : 0;
    }

    function feeIncrements(uint usd_fees, uint totalShares) internal pure returns (uint usdInc) {
        if (totalShares == 0) return 0;
        if (usd_fees > 0) usdInc = SoladyMath.fullMulDiv(usd_fees, WAD, totalShares);
    }

    function deleverOnDelivery(
        address core, address aux, address mgr,
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        address lp, uint shrinkSats, uint lpPayoutSats, uint exactUsd6
    ) public returns (uint deLeverUsd6) {
        uint lev = levPooled[lp];
        if (lev == 0) return 0;
        uint funded;
        { uint pooled = autoManaged[lp].pooled; funded = pooled > lev ? pooled - lev : 0; }
        if (shrinkSats <= funded) return 0;
        uint deliveredRaw = shrinkSats > lpPayoutSats ? shrinkSats - lpPayoutSats : 0;
        if (deliveredRaw == 0) return 0;
        uint want = shrinkSats - funded;
        if (want > lev) want = lev;
        uint wantUsd6 = exactUsd6 * want / deliveredRaw;
        if (wantUsd6 == 0) return 0;
        return _sourceRepayFree(core, aux, mgr, lp, want, wantUsd6, exactUsd6);
    }

    function _sourceRepayFree(address core, address aux, address mgr, address lp, uint want, uint wantUsd6, uint exactUsd6)
        private returns (uint deLeverUsd6) {
        (address venue, address stable, uint amtNative) =

            ILevManagerDeliver(mgr).swapOutDeleverAmt(lp, wantUsd6 * 1e12);
        if (venue == address(0)) return 0;
        uint takeUsd18 = LevMath._toUsd18(aux,stable, amtNative);
        { uint held = _heldUsd18(aux, stable); if (takeUsd18 > held) takeUsd18 = held; }

        {   (uint[16] memory amts,,, uint depeg) = IAux(aux).get_deposits();
            uint liquid = amts[15] > depeg ? amts[15] - depeg : 0;
            uint committed = ICore(core).committedUsd18();
            uint headroom = liquid > committed ? liquid - committed : 0;
            if (takeUsd18 > headroom) takeUsd18 = headroom;
        }
        if (takeUsd18 == 0) {

            if (amtNative > 0) revert DeleverStableUnavailable();
            ILevManagerDeliver(mgr).swapOutDelever(lp, 0, want);
            return 0;
        }
        deLeverUsd6 = (takeUsd18 + 1e12 - 1) / 1e12;
        if (deLeverUsd6 > exactUsd6) deLeverUsd6 = exactUsd6;

        ICore(core).drawPooledUsdBtc(deLeverUsd6);
        ICore(core).subPendingSwapOut(deLeverUsd6);
        uint got;
        {
            uint bal0 = IERC20(stable).balanceOf(venue);

            IAux(aux).takeToSettle(mgr, BasketLib.scaleTokenAmount(takeUsd18, stable, false), stable);
            ILevManagerDeliver(mgr).consolidateForRepay(lp, aux);
            got = IERC20(stable).balanceOf(venue) - bal0;
        }

        if (got == 0 && amtNative > 0) revert DeleverStableUnavailable();

        ILevManagerDeliver(mgr).swapOutDelever(lp, LevMath._toUsd18(aux,stable, got), want);
    }

    function _heldUsd18(address aux, address stable) private returns (uint) {
        uint idx = IAux(aux).toIndex(stable);
        if (idx == 0 || idx > IAux(aux).getStables().length) return 0;
        (uint[16] memory amts,,,) = IAux(aux).get_deposits();
        return amts[idx];
    }

    event DeliverDeleverSkipped(address indexed venue, uint fundUsd, bool takeFailed);

    function deleverEthOnDelivery(address mgr, address aux, uint px, uint shortfallEth, address recipient)
        public returns (uint deliveredEth) {
        if (px == 0 || shortfallEth == 0) return 0;

        address venue = ILevEthDeliver(mgr).poolVenue();
        if (venue == address(0)) return 0;

        address stable = ILevVenue(venue).stable();
        uint ask = SoladyMath.fullMulDiv(shortfallEth, px, 1e18);
        uint fundUsd;

        {   uint poolDebtUsd = LevMath._toUsd18(aux, stable, ILevPooled(venue).totalDebt());
            uint amtNative = poolDebtUsd == 0 ? 0 : LevMath._fromUsd(aux, stable,
                                ask > poolDebtUsd ? poolDebtUsd : ask);
            if (amtNative == 0) return 0;
            fundUsd = LevMath._toUsd18(aux, stable, amtNative);
        }
        if (fundUsd > ask) fundUsd = ask;
        if (fundUsd == 0) return 0;

        try IAux(aux).takeToSettle(address(this), BasketLib.scaleTokenAmount(fundUsd, stable, false), stable) returns (uint) {
            {

                uint bal0 = IERC20(stable).balanceOf(venue);
                LevMath._consolidateTo(aux, stable, aux);
                IERC20OZ(stable).safeTransfer(venue, IERC20OZ(stable).balanceOf(address(this)));
                fundUsd = LevMath._toUsd18(aux, stable, IERC20(stable).balanceOf(venue) - bal0);
            }

            if (fundUsd == 0) revert DeleverStableUnavailable();
            if (fundUsd > ask) fundUsd = ask;

            ask = SoladyMath.fullMulDiv(shortfallEth, fundUsd, ask);
            (, deliveredEth) = ILevEthDeliver(mgr).swapOutDeleverPooled(venue, fundUsd, recipient, 0, ask);
        } catch { emit DeliverDeleverSkipped(venue, fundUsd, true); }
    }

    function burnInRange(address core, uint amount, address recipient)
        internal returns (uint sent) {
        uint pooled = ICore(core).POOLED();
        uint pulled = Math.min(amount, pooled);
        if (pulled == 0) return 0;
        (, uint posLiquidity) = ICore(core).poolStats();
        if (posLiquidity > 0) {

            uint usdOut = SoladyMath.fullMulDiv(ICore(core).basketUsd(), pulled, pooled);
            sent = ICore(core).modLP(int256(pulled), int256(usdOut), recipient);
        }
    }

    function usdForTok(uint tok, uint price) internal pure returns (uint) {
        return SoladyMath.fullMulDiv(tok, price, WAD);
    }

    function sizeBySurplus(
        uint liquidTotal, uint committedBoth,
        uint deltaTok, uint price
    ) internal pure returns (uint deltaOut, uint targetUSD, uint surplus) {

        surplus = liquidTotal > committedBoth ? liquidTotal - committedBoth : 0;
        if (surplus == 0) return (0, 0, 0);
        deltaOut  = deltaTok;
        targetUSD = usdForTok(deltaTok, price);
        if (targetUSD > surplus) {
            targetUSD = surplus;
            deltaOut  = SoladyMath.fullMulDiv(surplus, WAD, price);
        }
    }

    function proRataShortfall(uint shortfallUsd6, uint exitShares, uint totalShares)
        internal pure returns (uint bornUsd6)
    {
        if (totalShares == 0 || exitShares == 0 || shortfallUsd6 == 0) return 0;

        if (exitShares >= totalShares) return shortfallUsd6;
        bornUsd6 = SoladyMath.mulDiv(shortfallUsd6, exitShares, totalShares);
    }

    function plainNet(uint pooled, uint lev) internal pure returns (uint) {
        return pooled > lev ? pooled - lev : 0;
    }

    /// @notice Take the flat charge off the input and credit it to the range's LPs.
    /// §TWAP-DELETED / §NO-GAMEABLE-BOUND — this used to take a `skew` argument because the charge
    /// was a function of inventory scarcity and realised variance. It is a CONSTANT now
    /// (`MIN_SWAP_SKEW_WAD`, 420 ppm), so the parameter was a constant threaded through two call
    /// sites and a `skew == 0` guard that could never fire. Both are gone; the body reads the
    /// constant it always received.
    function retainFee(address core, SwapReq memory r, bool nativeAmount)
        internal {
        uint premium = SoladyMath.fullMulDiv(r.amount, MIN_SWAP_SKEW_WAD, 1e18);

        ICore(core).recordFee(
            nativeAmount ? SoladyMath.fullMulDiv(premium, r.px, 1e30) : premium,
            nativeAmount ? premium : 0);
        r.amount -= premium;
    }

    function addLiqBody(address core, address aux, uint want, uint price,
        uint backing) public returns (uint usdOut, uint outDelta)
    {
        (uint[16] memory deposits,,,) = IAux(aux).get_deposits();
        (uint deltaTok, uint targetUSD, uint surplus) =
            sizeBySurplus(deposits[15], ICore(core).committedUsd18(), want, price);
        if (surplus == 0) return (0, 0);

        uint capped = clampByBacking(backing, ICore(core).POOLED(), deltaTok);

        if (capped < deltaTok) { deltaTok = capped; targetUSD = usdForTok(deltaTok, price); }
        usdOut = targetUSD / 1e12;
        if (usdOut == 0) return (0, 0);
        outDelta = deltaTok;
    }

    function clampByBacking(uint backing, uint pooled, uint want)
        internal pure returns (uint)
    {
        uint available = backing > pooled ? backing - pooled : 0;
        return want < available ? want : available;
    }

    function holdingRatioWad(uint syncKeyPx, uint price, uint loPrice, uint upPrice)
        internal pure returns (uint) {
        if (syncKeyPx == 0 || loPrice >= upPrice) return 1e18;

        uint pc  = price      < loPrice ? loPrice : (price      > upPrice ? upPrice : price);
        uint p0c = syncKeyPx < loPrice ? loPrice : (syncKeyPx > upPrice ? upPrice : syncKeyPx);
        uint a = FixedPointMathLib.sqrt(pc  * 1e18);
        uint b = FixedPointMathLib.sqrt(p0c * 1e18);
        uint c = FixedPointMathLib.sqrt(upPrice * 1e18);
        if (c <= b || a == 0) return 1e18;
        return SoladyMath.fullMulDiv(SoladyMath.fullMulDiv(b, 1e18, a), c - a, c - b);
    }

    function soldFractionWad(uint syncKeyPx, uint price, uint loPrice, uint upPrice)
        internal pure returns (uint) {
        uint r = holdingRatioWad(syncKeyPx, price, loPrice, upPrice);
        return r < 1e18 ? 1e18 - r : 0;
    }

    function updateBounds(uint price, uint delta)
        internal pure returns (uint lower, uint upper) {
        lower = price * (10000 - delta) / 10000;
        upper = price * (10000 + delta) / 10000;
    }

    struct Rebalanced {
        uint spotPrice;
        uint    loPrice;
        uint    upPrice;
        uint    myLiquidity;
        bool    didRepack;
        uint    price;

        uint    anchorPrice;
    }

    function rebalanceCore(
        address core, address aux, address asset,
        uint upPrice, uint loPrice
    ) internal returns (Rebalanced memory r) {
        r.upPrice = upPrice;
        r.loPrice = loPrice;

        (r.spotPrice, r.myLiquidity) = ICore(core).poolStats();

        uint twap; bool stale;
        try IAux(aux).assetPriceStale(asset) returns (uint p, bool s) {
            twap = p; stale = s;
        } catch {}
        r.anchorPrice = twap;

        if (stale && _reseatIfStale(core, r, twap)) return r;

        if (r.spotPrice >= upPrice || r.spotPrice < loPrice) {

            if (twap == 0) return r;
            uint spot = r.spotPrice;

            if (BasketLib.isManipulated(spot, twap, 300)) {
                return r;
            }

            if (r.myLiquidity > 0) {
                r.price = ICore(core).repack(r.spotPrice);
                r.didRepack = true;
            }
            (r.loPrice, r.upPrice) = updateBounds(r.spotPrice, RANGE_DELTA);
        }

    }

    function _reseatIfStale(address core, Rebalanced memory r, uint twap)
        private returns (bool) {

        uint spot = r.spotPrice;
        if (spot == 0 || twap == 0) return false;

        if (!BasketLib.isManipulated(spot, twap, RESEAT_MIN_BPS)) return false;

        if (twap == r.spotPrice) return false;
        _doReseat(core, r, twap);
        return true;
    }

    function _doReseat(address core, Rebalanced memory r, uint targetPrice)
        private {
        if (r.myLiquidity > 0) {
            r.price = ICore(core).repack(targetPrice);
            r.didRepack = true;
        }
        (r.loPrice, r.upPrice) = updateBounds(targetPrice, RANGE_DELTA);
        r.spotPrice = targetPrice;
    }

}

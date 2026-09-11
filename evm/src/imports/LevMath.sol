// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WAD, VenueNotAllowed} from "./Types.sol";

import {ICore, IAux, IWeETH, IDepositAdapter, ILevVenue, ILevPooled, TWAP_WINDOW_SECS} from "./Interfaces.sol";
import {IERC20Min, IWETH9} from "../imports/Interfaces.sol";
import {CURVE_BOLD_USDC, CRV_BOLD_IDX, CRV_BOLD_USDC_IDX, BOLD_TOKEN} from "./Interfaces.sol";
import {ONEINCH_ROUTER, UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR, SWAP_SELECTOR, PROTO_UNIV3, PROTO_UNIV2,
        ZERO_FOR_ONE, DEFAULT_UNWIND_DEX, DEFAULT_WBTC_DEX, WBTC_TOKEN, DAI_USDS, SKY_USDS_TO_DAI, SKY_DAI_TO_USDS, USDS_TOKEN, IUniV3PoolMin, ICurvePool, CURVE_USDC_RLUSD, CRV_RLUSD_IDX, CRV_RLUSD_USDC_IDX, CURVE_PYUSD_USDC, CRV_PYUSD_IDX, CRV_PYUSD_USDC_IDX, USDC, RLUSD_TOKEN, PYUSD_TOKEN, CURVE_3POOL, USDT_TOKEN, CRV_USDT_IDX, CRV_USDT_USDC_IDX, DAI_TOKEN, CRV_DAI_IDX, CRV_DAI_USDC_IDX, USDG_TOKEN, CURVE_USDG_USDC, CRV_USDG_IDX, CRV_USDG_USDC_IDX, CRVUSD_TOKEN, CURVE_CRVUSD_USDC, CRV_CRVUSD_IDX, CRV_CRVUSD_USDC_IDX} from "./Interfaces.sol";

address constant ETHERFI_CURVE_POOL = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
import {IMorphoBase as IMorphoFlash} from "../imports/Interfaces.sol";

library LevMath {
    using SafeERC20 for IERC20OZ;

    error NoPrice();

    function ltvBps(uint256 debt, uint256 collValue) internal pure returns (uint256) {
        if (collValue == 0) return 0;
        return (debt * 10_000) / collValue;
    }

    function deliverableDollars(uint256 netEquityUsd, uint256 collValueUsd, uint256 curLtvBps, uint256 lltvBps)
        internal pure returns (uint256)
    {

        if (curLtvBps == 0) return 0;
        if (lltvBps <= PROTECT_MARGIN_BPS) return 0;
        uint256 safeLtv = lltvBps - PROTECT_MARGIN_BPS;
        if (curLtvBps >= safeLtv) return 0;
        uint256 buffer = collValueUsd * (safeLtv - curLtvBps) / safeLtv;
        return netEquityUsd < buffer ? netEquityUsd : buffer;
    }

    error BadCollateral();
    error VenueBlocked();

    function ilTargetBps(uint128 ilBasisPx, uint256 pxNow, uint64 capBps)
        public pure returns (uint256)
    {

        if (ilBasisPx == 0 || pxNow <= ilBasisPx) return 0;
        uint256 ratioWad = (uint256(ilBasisPx) * WAD) / pxNow;
        uint256 sqrtWad  = FixedPointMathLib.sqrt(ratioWad * WAD);
        uint256 ilBps    = ((WAD - sqrtWad) * 10_000) / WAD;
        return ilBps > capBps ? capBps : ilBps;
    }

    function reanchorCompute(address range, uint syncKeyPx)
        public view returns (bool go, uint newPrice) {

        if (range == address(0) || syncKeyPx == 0) return (false, 0);
        try ICore(range).rangePrice() returns (uint v) { newPrice = v; } catch { return (false, 0); }
        if (newPrice == 0) return (false, 0);

        uint lo; uint hi;

        try ICore(range).rangeBounds() returns (uint l, uint u) { lo = l; hi = u; }
        catch { return (false, 0); }
        if (lo >= hi) return (false, 0);

        if (syncKeyPx >= lo && syncKeyPx <= hi) return (false, 0);
        go = true;
    }

    function deleverRepay(uint256 equityUsd, uint256 curDebt, uint256 tBps, uint256 rangeBps) public pure returns (uint256) {
        uint256 targetDebt = (equityUsd * tBps) / 10_000;
        if (curDebt <= targetDebt + (equityUsd * rangeBps) / 10_000) return 0;
        return curDebt - targetDebt;
    }

    struct WbtcCfg { address aux; address wbtc; uint32 twapWindow; uint16 slipBps; uint256 dex; uint256 dex2; bytes route; }

    function leverUpBuyWbtc(ILevVenue venue, address lp, address stable, uint256 usd, uint256 minOut, WbtcCfg memory cfg)
        public returns (uint256 borrowed, uint256 wbtcBought) {
        borrowed = venue.borrow(lp, _fromUsd(cfg.aux, stable, usd));
        if (borrowed == 0) return (0, 0);
        {
            uint256 floorWbtc = (usd * 1e18 / IAux(cfg.aux).getTWAPforAsset(cfg.wbtc, cfg.twapWindow))
                                * (10_000 - cfg.slipBps) / 10_000;
            if (minOut < floorWbtc) minOut = floorWbtc;
        }
        wbtcBought = _stableToWbtc(stable, borrowed, minOut, cfg.wbtc, cfg.route);
        IERC20Min(cfg.wbtc).transfer(address(venue), wbtcBought);
        venue.supply(lp, wbtcBought);
    }

    function flashDeleverWbtcSettle(uint256 assets, address lp, address venueAddr, address stable,
                                    uint256 minOut, address flashProvider, WbtcCfg memory cfg) public {
        ILevVenue venue = ILevVenue(venueAddr);
        IERC20OZ(stable).safeTransfer(address(venue), assets);
        uint256 pulled;
        {
            uint256 repaid = venue.repay(lp, assets);
            uint256 px = IAux(cfg.aux).getTWAPforAsset(cfg.wbtc, cfg.twapWindow);
            pulled = venue.withdraw(lp, (_toUsd18(cfg.aux, stable, repaid) * 1e18 / px)
                                        * 10_000 / (10_000 - cfg.slipBps));
            uint256 floorStable = _fromUsd(cfg.aux, stable, pulled * px / 1e18)
                                  * (10_000 - cfg.slipBps) / 10_000;
            if (minOut < floorStable) minOut = floorStable;
        }
        uint256 stableOut = _volToStable(cfg.wbtc, stable, pulled, minOut, cfg.route);
        IERC20OZ(stable).forceApprove(flashProvider, assets);
        if (stableOut > assets) IERC20OZ(stable).safeTransfer(lp, stableOut - assets);
    }

    function netEquityBase(uint256 collBase, uint256 debtUsd, uint256 price)
        internal pure returns (uint256)
    {
        if (debtUsd == 0) return collBase;
        if (price == 0) return 0;
        uint256 debtBase = (debtUsd * WAD) / price;
        return collBase > debtBase ? collBase - debtBase : 0;
    }

    function entryEquityUsd(uint256 entryEquity, uint256 price) internal pure returns (uint256) {
        return (entryEquity * price) / WAD;
    }

    function capBufferUsd(uint256 bufBase, uint256 price, uint256 debtUsd) internal pure returns (uint256 bufUsd) {
        bufUsd = ((bufBase * price) / WAD) / 1e12;
        uint256 dCap = debtUsd / 1e12;
        if (bufUsd > dCap) bufUsd = dCap;
    }

    function vetVenue(address v, address base, address c0, address c1) public view returns (bool isShort) {
        address coll = ILevVenue(v).COLLATERAL();
        if (coll != c0 && coll != c1) revert BadCollateral();
        return ILevVenue(v).stable() == base;
    }

    function requireOpenable(bool allowed, address aux, address venue) public view {
        if (!allowed) revert VenueNotAllowed();
        if (IAux(aux).vaultBlocked(venue)) revert VenueBlocked();
    }

    error NoStableRoute();
    error NoOptIn();
    error Slippage();

    error RouteTookAndGaveNothing();

    event LegSkipped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 minLeg);

    error BadRoute();
    error NotNearLiq();
    error NoDebt();

    uint256 internal constant PROTECT_MARGIN_BPS = 1500;

    address internal constant ETHERFI_ADAPTER_M  = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;

    uint256 private constant USD_PX = 1e18;

    function loanPxUsd18(address aux, address loan) internal view returns (uint256 px) {
        if (IAux(aux).assetPriceFeed(loan) == address(0)) return USD_PX;
        px = IAux(aux).getTWAPforAsset(loan, TWAP_WIN_M);
        if (px == 0) revert NoPrice();
    }

    uint32  internal constant TWAP_WIN_M         = TWAP_WINDOW_SECS;

    uint256 internal constant SELL_SLIP_BPS      = 100;

    uint256 internal constant ROUTE_GAS_CAP      = 3_000_000;

    uint256 internal constant SLIP_BASE_BPS      = 25;
    uint256 internal constant SLIP_PER_MM_BPS    = 25;

    function _pxUsd18(address aux, address t) internal view returns (uint256) {
        try IAux(aux).getTWAPforAsset(t, TWAP_WIN_M) returns (uint256 p) {
            if (p != 0) return p;
        } catch {}
        return USD_PX;
    }

    function swapFloor(address aux, address give, uint256 amtIn, address want, uint256 slipBps)
        internal view returns (uint256) {
        uint256 usd18 = (amtIn * _pxUsd18(aux, give)) / (10 ** IERC20Min(give).decimals());
        uint256 raw   = (usd18 * (10 ** IERC20Min(want).decimals())) / _pxUsd18(aux, want);
        return (raw * (10_000 - slipBps)) / 10_000;
    }

    function _slipBps(uint256 usd18) internal pure returns (uint256 bps) {
        bps = SLIP_BASE_BPS + (usd18 / 1e24) * SLIP_PER_MM_BPS;
        if (bps > SELL_SLIP_BPS) bps = SELL_SLIP_BPS;
    }
    uint256 internal constant DELEVER_GAS        = 400_000;
    uint256 internal constant KEEPER_MAX_GASPRICE = 200 gwei;

    struct SellCtx { address weth; address weeth; address aux; address keeper; uint256 reserveIn; uint256 dex; uint256 dex2; bytes route; }

    function sellColl(SellCtx memory c, address stable, uint256 pulled, uint256 minOut, uint256 assets)
        public returns (uint256 stableOut, uint256 reserveOut)
    {
        return sellWeeth(c, stable, pulled, minOut, assets);
    }

    function sellWeeth(SellCtx memory c, address stable, uint256 pulled, uint256 minOut, uint256 assets)
        internal returns (uint256 stableOut, uint256 reserveOut)
    {
        reserveOut = c.reserveIn;
        uint256 wethGot = _weethToWeth(c, pulled);
        {
            uint256 need = _wethForAssets(c, stable, assets);
            uint256 skimmed;
            (skimmed, reserveOut) = _reimburse(c.weth, c.keeper, wethGot > need ? wethGot - need : 0, reserveOut);
            wethGot -= skimmed;
        }

        uint256 floorOut = _wethStableFloor(c, stable, wethGot);
        stableOut = _wethToStableDex(c, stable, wethGot, minOut > floorOut ? minOut : floorOut);
    }

    function _weethToWeth(SellCtx memory c, uint256 pulled) internal returns (uint256 wethGot) {
        if (pulled > 0) wethGot = _weethToWethDex(c, pulled);
    }

    function _poolToken(address pool, bool one) private view returns (address t) {
        (bool ok, bytes memory r) = pool.staticcall(abi.encodeWithSelector(
            one ? IUniV3PoolMin.token1.selector : IUniV3PoolMin.token0.selector));
        if (ok && r.length >= 32) t = abi.decode(r, (address));
    }

    function _startsAt(bytes memory route, address token) private view returns (bool) {
        bytes4 sel;
        assembly { sel := mload(add(route, 0x20)) }
        if (sel != UNOSWAP_SELECTOR && sel != UNOSWAP2_SELECTOR) return true;
        uint256 w;
        assembly { w := mload(add(route, 0x84)) }
        uint256 proto = w >> 253;
        if (proto != PROTO_UNIV3 && proto != PROTO_UNIV2) return true;
        address p = address(uint160(w));
        address t0 = _poolToken(p, false);
        if (t0 == address(0)) return true;
        return t0 == token || _poolToken(p, true) == token;
    }

    function _deriveBit(bytes memory route, uint256 off, address token, bool matchIsZero) private view {
        uint256 w;
        assembly { w := mload(add(route, off)) }

        uint256 proto = w >> 253;
        if (proto != PROTO_UNIV3 && proto != PROTO_UNIV2) return;
        address t0 = _poolToken(address(uint160(w)), false);
        if (t0 == address(0)) return;
        w &= ~ZERO_FOR_ONE;
        if (matchIsZero ? token == t0 : token != t0) w |= ZERO_FOR_ONE;
        assembly { mstore(add(route, off), w) }
    }

    function _noteSkip(address tokenIn, address tokenOut, uint256 amt) private {
        emit LegSkipped(tokenIn, tokenOut, amt, _selfServableQuote(tokenIn, amt, tokenOut));
    }

    function _retarget(bytes memory route, address tokenIn, address tokenOut, uint256 amountIn)
        internal view
    {
        uint256 minLeg = _selfServableQuote(tokenIn, amountIn, tokenOut);
        if (minLeg != 0) minLeg = (minLeg * (10_000 - CONSOL_SLIP_BPS)) / 10_000;
        uint256 len = route.length;
        if (len == 0) return;
        if (len < 4) revert BadRoute();
        bytes4 sel;
        assembly { sel := mload(add(route, 0x20)) }
        uint256 words = sel == UNOSWAP_SELECTOR  ? 4
                      : sel == UNOSWAP2_SELECTOR ? 5
                      : 0;
        if (words != 0) {
            if (len != 4 + words * 32) revert BadRoute();
            assembly {
                mstore(add(route, 0x24), tokenIn)
                mstore(add(route, 0x44), amountIn)
                mstore(add(route, 0x64), minLeg)
            }

            _deriveBit(route, 0x84, tokenIn, true);
            uint256 lOff = 0x24 + (words - 1) * 32;
            if (lOff != 0x84) _deriveBit(route, lOff, tokenOut, false);
            return;
        }

        uint256 swapMin = minLeg == 0 ? 1 : minLeg;
        if (sel != SWAP_SELECTOR) revert BadRoute();
        if (len < 4 + 10 * 32) revert BadRoute();
        uint256 dataOff;
        assembly { dataOff := mload(add(route, add(0x24, mul(8, 0x20)))) }
        if (dataOff != 9 * 32) revert BadRoute();
        assembly {
            mstore(add(route, 0x44), tokenIn)
            mstore(add(route, 0x64), tokenOut)
            mstore(add(route, 0xA4), address())
            mstore(add(route, 0xC4), amountIn)

            mstore(add(route, 0xE4), swapMin)
        }

    }

    function convertTo(address[] memory inTokens, uint256[] memory inAmounts,
                       address outToken, uint256 minOut, bytes[] memory routes)
        internal returns (uint256 got) {
        uint256 n = inTokens.length;
        require(n == inAmounts.length && n == routes.length, "convertTo/len");
        uint256 before_ = IERC20Min(outToken).balanceOf(address(this));
        uint256 outPrev = before_;
        for (uint256 k; k < n; ++k) {
            uint256 amt = inAmounts[k];
            if (amt == 0 || inTokens[k] == outToken) continue;
            uint256 inPrev = IERC20Min(inTokens[k]).balanceOf(address(this));

            _retarget(routes[k], inTokens[k], outToken, amt);

            IERC20OZ(inTokens[k]).forceApprove(ONEINCH_ROUTER, amt);

            (bool ok, ) = ONEINCH_ROUTER.call{gas: ROUTE_GAS_CAP}(routes[k]);
            IERC20OZ(inTokens[k]).forceApprove(ONEINCH_ROUTER, 0);

            if (!ok) { _noteSkip(inTokens[k], outToken, amt); continue; }

            uint256 outNow = IERC20Min(outToken).balanceOf(address(this));
            if (IERC20Min(inTokens[k]).balanceOf(address(this)) < inPrev && outNow <= outPrev)
                revert RouteTookAndGaveNothing();
            outPrev = outNow;
        }
        got = IERC20Min(outToken).balanceOf(address(this)) - before_;
        if (got < minOut) revert Slippage();
    }

    function routedSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut,
                        bytes memory route) internal returns (uint256) {

        if (route.length == 0)
            route = abi.encodeWithSelector(UNOSWAP_SELECTOR, uint256(0), uint256(0), uint256(0),
                (tokenIn == WBTC_TOKEN || tokenOut == WBTC_TOKEN) ? DEFAULT_WBTC_DEX : DEFAULT_UNWIND_DEX);

        if (tokenIn != USDC && !_startsAt(route, tokenIn)) {
            amountIn = _hubHop(tokenIn, amountIn, true, 0);
            tokenIn  = USDC;
        }
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes[]   memory r = new bytes[](1);
        t[0] = tokenIn; a[0] = amountIn; r[0] = route;
        return convertTo(t, a, tokenOut, minOut, r);
    }

    function sourceWeth(uint want, address weeth, address curvePool) public returns (uint) {
        if (want == 0 || weeth == address(0) || curvePool == address(0)) return 0;
        uint idle = IERC20Min(weeth).balanceOf(address(this));
        if (idle == 0) return 0;
        uint weethFull = IWeETH(weeth).getWeETHByeETH(want);
        if (weethFull == 0) return 0;
        uint weethIn = weethFull > idle ? idle : weethFull;
        if (weethIn == 0) return 0;
        uint fairWeth = FixedPointMathLib.fullMulDiv(want, weethIn, weethFull);
        return sellWeethOnCurve(weeth, curvePool, weethIn, (fairWeth * 995) / 1000);
    }

    function convertShortfall(address aux, address quid, address payoutToken, address owner,
                              uint short18, bytes[] memory routes) public returns (uint) {

        uint drawn18 = IAux(aux).take(address(this), short18, quid, 0);
        if (drawn18 == 0) return 0;
        address[] memory st = IAux(aux).getStables();
        uint[] memory amt = new uint[](st.length);

        for (uint k; k < st.length; ++k) amt[k] = IERC20Min(st[k]).balanceOf(address(this));

        uint floor_ = _fromUsd(aux, payoutToken, drawn18) * (10_000 - _slipBps(drawn18)) / 10_000;

        uint ref_;
        for (uint k; k < st.length; ++k) ref_ += _selfServableQuote(st[k], amt[k], payoutToken);
        if (ref_ > floor_) floor_ = ref_;
        uint extra = convertTo(st, amt, payoutToken, floor_, routes);
        if (extra == 0) return 0;
        IERC20OZ(payoutToken).safeTransfer(owner, extra);
        return scaleTo6(extra, payoutToken);
    }

    function scaleTo6(uint amount, address token) internal view returns (uint) {
        uint8 d = IERC20Min(token).decimals();
        return d == 6 ? amount : (d > 6 ? amount / 10 ** (d - 6) : amount * 10 ** (6 - d));
    }

    function sellWeethOnCurve(address weeth, address pool, uint256 amountIn, uint256 minOut)
        internal returns (uint256) {
        return curveExchange(weeth, pool, int128(1), int128(0), amountIn, minOut, true);
    }

    function curveExchange(address tokenIn, address pool, int128 i, int128 j,
                           uint256 amountIn, uint256 minOut, bool soft) internal returns (uint256) {
        if (pool == address(0) || amountIn == 0) return 0;

        address tokenOut = ICurvePool(pool).coins(uint256(int256(j)));
        uint256 before_ = IERC20Min(tokenOut).balanceOf(address(this));
        IERC20OZ(tokenIn).forceApprove(pool, amountIn);

        (bool ok, ) = pool.call(
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", i, j, amountIn, minOut));
        IERC20OZ(tokenIn).forceApprove(pool, 0);
        uint256 got = IERC20Min(tokenOut).balanceOf(address(this)) - before_;
        if (!ok || got < minOut) {
            if (soft) return 0;
            revert Slippage();
        }
        return got;
    }

    function _weethToWethDex(SellCtx memory c, uint256 pulled) internal returns (uint256) {

        uint256 wethFloor = IWeETH(c.weeth).getEETHByWeETH(pulled) * (10_000 - SELL_SLIP_BPS) / 10_000;
        return sellWeethOnCurve(c.weeth, ETHERFI_CURVE_POOL, pulled, wethFloor);
    }

    function stableToColl(SellCtx memory c, address stable, uint256 stableAmt, uint256 minOut)
        public returns (uint256)
    {
        return _stableToWeeth(c, stable, stableAmt, minOut);
    }

    function _stableToWeeth(SellCtx memory c, address stable, uint256 stableAmt, uint256 minWeethOut) internal returns (uint256 weethOut) {
        weethOut = _wethToWeeth(c, _stableToWethSor(c, stable, stableAmt));
        if (weethOut < minWeethOut) revert Slippage();
    }

    function _wethToWeeth(SellCtx memory c, uint256 wethRem) internal returns (uint256 weethOut) {
        if (wethRem > 0) {
            IERC20Min(c.weth).approve(ETHERFI_ADAPTER_M, wethRem);
            uint256 bef = IERC20Min(c.weeth).balanceOf(address(this));
            IDepositAdapter(ETHERFI_ADAPTER_M).depositWETHForWeETH(wethRem, address(0));
            weethOut += IERC20Min(c.weeth).balanceOf(address(this)) - bef;
        }
    }

    function _stableToWethSor(SellCtx memory c, address stable, uint256 stableAmt) internal returns (uint256) {
        if (stable == c.weth) return stableAmt;
        uint256 usd18_ = _toUsd18(c.aux, stable, stableAmt);

        uint256 floor_ = swapFloor(c.aux, stable, stableAmt, c.weth, _slipBps(usd18_));

        return routedSwap(stable, c.weth, stableAmt, floor_, c.route);
    }

    function _hubHop(address stable, uint256 amt, bool toUsdc, uint256 minOut)
        internal returns (uint256)
    {
        if (amt == 0) return 0;
        if (stable == USDC) return amt;

        if (stable == USDS_TOKEN)
            return toUsdc ? _hubHop(DAI_TOKEN, _sky(amt, true), true, minOut)
                          : _sky(_hubHop(DAI_TOKEN, amt, false, minOut), false);

        (address pool, int128 iS, int128 iU) = _hubRowOf(stable);

        if (pool == address(0)) revert NoStableRoute();

        return toUsdc ? curveExchange(stable, pool, iS, iU, amt, minOut, false)
                      : curveExchange(USDC,   pool, iU, iS, amt, minOut, false);
    }

    function _selfServableQuote(address tokenIn, uint256 amtIn, address tokenOut)
        internal view returns (uint256)
    {
        if (amtIn == 0) return 0;
        if (tokenIn == tokenOut) return amtIn;

        if (tokenIn  == USDS_TOKEN) return _selfServableQuote(DAI_TOKEN, amtIn, tokenOut);
        if (tokenOut == USDS_TOKEN) return _selfServableQuote(tokenIn, amtIn, DAI_TOKEN);
        if (tokenIn == USDC)  return _curveQuote(tokenOut, amtIn, false);
        if (tokenOut == USDC) return _curveQuote(tokenIn,  amtIn, true);
        uint256 viaHub = _curveQuote(tokenIn, amtIn, true);
        if (viaHub == 0) return 0;
        return _curveQuote(tokenOut, viaHub, false);
    }

    function _sky(uint256 amt, bool toDai) private returns (uint256) {
        if (amt == 0) return 0;
        (address give, address want) = toDai ? (USDS_TOKEN, DAI_TOKEN) : (DAI_TOKEN, USDS_TOKEN);
        uint256 before_ = IERC20Min(want).balanceOf(address(this));
        IERC20OZ(give).forceApprove(DAI_USDS, amt);
        (bool ok, ) = DAI_USDS.call(abi.encodeWithSelector(
            toDai ? SKY_USDS_TO_DAI : SKY_DAI_TO_USDS, address(this), amt));
        IERC20OZ(give).forceApprove(DAI_USDS, 0);
        return ok ? IERC20Min(want).balanceOf(address(this)) - before_ : 0;
    }

    function _hubRowOf(address stable) private pure returns (address pool, int128 iStable, int128 iUsdc) {
        if (stable == RLUSD_TOKEN)  return (CURVE_USDC_RLUSD,   CRV_RLUSD_IDX,  CRV_RLUSD_USDC_IDX);
        if (stable == PYUSD_TOKEN)  return (CURVE_PYUSD_USDC,   CRV_PYUSD_IDX,  CRV_PYUSD_USDC_IDX);
        if (stable == USDT_TOKEN)   return (CURVE_3POOL,        CRV_USDT_IDX,   CRV_USDT_USDC_IDX);
        if (stable == DAI_TOKEN)    return (CURVE_3POOL,        CRV_DAI_IDX,    CRV_DAI_USDC_IDX);
        if (stable == USDG_TOKEN)   return (CURVE_USDG_USDC,    CRV_USDG_IDX,   CRV_USDG_USDC_IDX);
        if (stable == CRVUSD_TOKEN) return (CURVE_CRVUSD_USDC,  CRV_CRVUSD_IDX, CRV_CRVUSD_USDC_IDX);
        if (stable == BOLD_TOKEN)   return (CURVE_BOLD_USDC,    CRV_BOLD_IDX,   CRV_BOLD_USDC_IDX);

    }

    function _curveQuote(address stable, uint256 amt, bool toUsdc) private view returns (uint256) {
        (address pool, int128 iStable, int128 iUsdc) = _hubRowOf(stable);
        if (pool == address(0)) return 0;
        try ICurvePool(pool).get_dy(toUsdc ? iStable : iUsdc, toUsdc ? iUsdc : iStable, amt)
            returns (uint256 dy) { return dy; } catch { return 0; }
    }

    function _stableToWbtc(address stable, uint256 amt, uint256 minOut, address wbtc,
                           bytes memory route) internal returns (uint256) {
        return routedSwap(stable, wbtc, amt, minOut, route);
    }

    function _volToStable(address vol, address stable, uint256 amt, uint256 minOut,
                          bytes memory route) internal returns (uint256) {

        return routedSwap(vol, stable, amt, minOut, route);
    }

    function _wethToStableDex(SellCtx memory c, address stable, uint256 wethIn, uint256 minOut) internal returns (uint256) {
        if (stable == c.weth) return wethIn;

        return _volToStable(c.weth, stable, wethIn, minOut, c.route);
    }

    function _wethStableFloor(SellCtx memory c, address stable, uint256 wethAmt) internal view returns (uint256) {
        uint256 usd18 = (wethAmt * IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M)) / 1e18;

        return swapFloor(c.aux, c.weth, wethAmt, stable, _slipBps(usd18));
    }

    function _wethForAssets(SellCtx memory c, address stable, uint256 assets) internal view returns (uint256) {
        uint256 usd18 = _toUsd18(c.aux, stable, assets);
        uint256 weth = (usd18 * 1e18) / IAux(c.aux).getTWAPforAsset(c.weth, TWAP_WIN_M);

        return (weth * 10_000) / (10_000 - _slipBps(usd18));
    }

    function reimburseKeeper(address weth, address keeper, uint256 availWeth, uint256 reserveIn)
        public returns (uint256 skimmed, uint256 reserveOut)
    {
        return _reimburse(weth, keeper, availWeth, reserveIn);
    }

    struct ExtractCfg { address weth; address weeth; address aux; address flashProvider; address keeper; uint256 gasReserve; uint16 maxSlippageBps; uint256 dex; uint256 dex2; bytes route; }

    function _repayAndPull(uint256 assets, address lp, address venueAddr, address stable, uint256 extractUsd, uint256 pxWeth, ExtractCfg memory cfg)
        private returns (uint256 pulled)
    {
        IERC20OZ(stable).safeTransfer(venueAddr, assets);
        uint256 repaid = ILevVenue(venueAddr).repay(lp, assets);
        if (pxWeth == 0) revert NoPrice();
        uint256 ethAmt = ((_toUsd18(cfg.aux,stable, repaid) + extractUsd) * 1e18) / pxWeth;
        uint256 collUnits = (ethAmt * 1e18) / IWeETH(cfg.weeth).getEETHByWeETH(1e18);
        pulled = ILevVenue(venueAddr).withdraw(lp, (collUnits * 10_000) / (10_000 - cfg.maxSlippageBps));
    }

    function _pullForExtract(uint256 assets, address venueAddr, address stable, uint256 extractUsd, ExtractCfg memory cfg)
        private returns (uint256 pulled)
    {
        return _repayAndPullPooled(assets, venueAddr, stable, extractUsd,
            IAux(cfg.aux).getTWAPforAsset(cfg.weth, TWAP_WIN_M), cfg);
    }

    function extractToVaultBody(uint256 assets, address venueAddr, address stable, uint256 extractUsd, address recipient, uint256 minOut, ExtractCfg memory cfg)
        public returns (uint256 newGasReserve, uint256 freed)
    {
        uint256 pulled = _pullForExtract(assets, venueAddr, stable, extractUsd, cfg);

        return _sellAndPay(pulled, stable, minOut, assets, recipient, cfg);
    }

    function _sellAndPay(uint256 pulled, address stable, uint256 minOut, uint256 assets, address recipient, ExtractCfg memory cfg)
        private returns (uint256 newGasReserve, uint256 freed)
    {
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve, dex: cfg.dex, dex2: cfg.dex2, route: cfg.route});
        uint256 stableOut;
        (stableOut, newGasReserve) = sellColl(sc, stable, pulled, minOut, assets);
        IERC20OZ(stable).forceApprove(cfg.flashProvider, assets);
        freed = stableOut > assets ? stableOut - assets : 0;
        if (freed > 0) IERC20OZ(stable).safeTransfer(recipient, freed);
    }

    function collToWethDeliver(uint256 collAmt, address recipient, uint256 minOut, ExtractCfg memory cfg)
        public returns (uint256 wethDelivered) {
        if (collAmt == 0) return 0;
        SellCtx memory sc = SellCtx({weth: cfg.weth, weeth: cfg.weeth, aux: cfg.aux, keeper: cfg.keeper, reserveIn: cfg.gasReserve, dex: cfg.dex, dex2: cfg.dex2, route: cfg.route});
        wethDelivered = _weethToWeth(sc, collAmt);
        require(wethDelivered >= minOut, "swapDelever:minOut");
        if (wethDelivered > 0) IERC20Min(cfg.weth).transfer(recipient, wethDelivered);
    }

    function _reimburse(address weth, address keeper, uint256 availWeth, uint256 reserveIn)
        internal returns (uint256 skimmed, uint256 reserveOut)
    {
        reserveOut = reserveIn;
        if (keeper == address(0)) return (0, reserveOut);
        uint256 gp = tx.gasprice < KEEPER_MAX_GASPRICE ? tx.gasprice : KEEPER_MAX_GASPRICE;
        uint256 owed = gp * DELEVER_GAS;
        if (owed == 0) return (0, reserveOut);
        uint256 want = availWeth >= 2 * owed ? 2 * owed : owed;
        skimmed = availWeth < want ? availWeth : want;
        uint256 keeperCut = skimmed < owed ? skimmed : owed;
        reserveOut += skimmed - keeperCut;
        uint256 shortfall = owed - keeperCut;
        if (shortfall > reserveOut) shortfall = reserveOut;
        reserveOut -= shortfall;
        uint256 pay = keeperCut + shortfall;
        if (pay > 0) {
            IWETH9(weth).withdraw(pay);
            (bool ok, ) = payable(keeper).call{ value: pay }("");
            require(ok, "keeper gas send");
        }
    }

    function protectExec(address quid, address aux, address venue, address lp, uint256 curLtvBps, uint256 minStableOut)
        public returns (uint256 pull, uint256 repaid)
    {
        if (curLtvBps + PROTECT_MARGIN_BPS < ILevVenue(venue).liqThresholdBps()) revert NotNearLiq();
        uint256 debt = ILevVenue(venue).debtOf(lp);
        if (debt == 0) revert NoDebt();
        address stable = ILevVenue(venue).stable();
        {
            uint8 dec = IERC20Min(stable).decimals();
            pull = dec >= 18 ? debt : debt * (10 ** (18 - dec));
            uint256 lim = IERC20Min(quid).allowance(lp, address(this));
            if (pull > lim) pull = lim;
            lim = IERC20Min(quid).balanceOf(lp);
            if (pull > lim) pull = lim;
        }
        if (pull == 0) revert NoOptIn();
        uint256 got = IERC20Min(stable).balanceOf(address(this));
        IERC20Min(quid).transferFrom(lp, address(this), pull);

        IAux(aux).redeem(pull);
        _consolidateTo(aux, stable, lp);
        got = IERC20Min(stable).balanceOf(address(this)) - got;
        if (got < minStableOut) revert Slippage();

        uint256 pay = got > debt ? debt : got;
        IERC20OZ(stable).safeTransfer(venue, pay);
        repaid = ILevVenue(venue).repay(lp, pay);
        if (got > pay) IERC20OZ(stable).safeTransfer(lp, got - pay);
    }

    uint256 internal constant CONSOL_SLIP_BPS = 20;

    function _consolidateTo(address aux, address target, address refundTo) public {
        address[] memory sts = IAux(aux).getStables();
        for (uint256 i; i < sts.length; i++) {
            address s = sts[i];
            if (s == target) continue;
            uint256 bal = IERC20Min(s).balanceOf(address(this));
            if (bal == 0) continue;

            uint256 floor = swapFloor(aux, s, bal, target, CONSOL_SLIP_BPS);

            uint256 q = _selfServableQuote(s, bal, target);

            if (q != 0 && q >= floor) {
                { uint256 b2 = (q * (10_000 - CONSOL_SLIP_BPS)) / 10_000;
                  if (b2 > floor) floor = b2; }
                _hubHop(target, _hubHop(s, bal, true, 0), false, floor);
            }

            uint256 rem = IERC20Min(s).balanceOf(address(this));
            if (rem > 0) IERC20OZ(s).safeTransfer(refundTo, rem);
        }
    }

    function debtDelta(uint256 collUsd, uint256 curDebtUsd, uint256 targetBps, uint256 rangeBps)
        internal pure returns (bool levUp, uint256 amountUsd)
    {
        uint256 cur = ltvBps(curDebtUsd, collUsd);
        if (cur + rangeBps >= targetBps && cur <= targetBps + rangeBps) return (false, 0);
        uint256 targetDebt = (collUsd * targetBps) / 10_000;
        if (targetDebt > curDebtUsd) { levUp = true;  amountUsd = targetDebt - curDebtUsd; }
        else                         { levUp = false; amountUsd = curDebtUsd - targetDebt; }
    }

    function swapOutDeliverUnleveredBody(ILevVenue venue, address lp, uint256 wethWanted, address recipient, uint256 minWethOut, ExtractCfg memory cfg)
        public returns (uint256 wethDelivered) {
        uint256 coll = venue.collateralOf(lp);
        uint256 collInEth = IWeETH(cfg.weeth).getEETHByWeETH(coll);
        if (collInEth == 0) return 0;
        uint256 pull = wethWanted >= collInEth ? coll : (coll * wethWanted) / collInEth;
        if (pull == 0) return 0;
        uint256 got = venue.withdraw(lp, pull);
        uint256 floor = minWethOut;
        { uint256 pullEth = (collInEth * got) / coll;
          uint256 f = (pullEth * (10_000 - cfg.maxSlippageBps)) / 10_000; if (f > floor) floor = f; }
        wethDelivered = collToWethDeliver(got, recipient, floor, cfg);
    }

    function sizeRepayStable(ILevVenue venue, uint256 extractUsd, uint256 debtUsd18, uint256 pxWeth, address weeth, address aux)
        public view returns (uint256 repayStable) {
        uint256 rawColl = ILevPooled(address(venue)).totalCollateral();
        uint256 collUsd = (IWeETH(weeth).getEETHByWeETH(rawColl) * pxWeth) / 1e18;
        uint256 netEq = collUsd > debtUsd18 ? collUsd - debtUsd18 : 0;
        if (netEq == 0) return 0;
        repayStable = _fromUsd(aux,venue.stable(), (extractUsd * debtUsd18) / netEq);
        uint256 debt = ILevPooled(address(venue)).totalDebt();
        if (repayStable > debt) repayStable = debt;
    }

    function deleverSettleBody(uint256 assets, address lp, address venueAddr, address stable, uint256 minOut, uint256 pxWeth, ExtractCfg memory cfg, bytes calldata data)
        public returns (uint256 newGasReserve) {
        (,,,,, cfg.dex, cfg.dex2, cfg.route) =
            abi.decode(data, (uint8, address, address, address, uint256, uint256, uint256, bytes));
        uint256 pulled = _repayAndPull(assets, lp, venueAddr, stable, 0, pxWeth, cfg);
        (newGasReserve, ) = _sellAndPay(pulled, stable, minOut, assets, lp, cfg);
    }

    function deleverFlashBody(ExtractCfg memory cfg, ILevVenue venue, address lp, address stable, uint256 repayUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes memory route)
        public {
        if (repayUsd == 0 || cfg.flashProvider == address(0)) return;
        uint256 debt = venue.debtOf(lp);
        if (debt == 0) return;
        uint256 repayStable = _fromUsd(cfg.aux,stable, repayUsd);
        if (repayStable > debt) repayStable = debt;
        if (repayStable == 0) return;

        IMorphoFlash(cfg.flashProvider).flashLoan(stable, repayStable, abi.encode(uint8(0), lp, address(venue), stable, minOut, dex, dex2, route));
    }

    function _fromUsd(address aux, address stable, uint256 usd) internal view returns (uint256) {
        uint256 pxUsd18 = loanPxUsd18(aux, stable);
        uint8 dec = IERC20Min(stable).decimals();

        return (usd * (10 ** dec)) / pxUsd18;
    }

    function _toUsd18(address aux, address stable, uint256 amt) internal view returns (uint256) {
        uint256 pxUsd18 = loanPxUsd18(aux, stable);
        uint8 dec = IERC20Min(stable).decimals();
        return (amt * pxUsd18) / (10 ** dec);
    }
}

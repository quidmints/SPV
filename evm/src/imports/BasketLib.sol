// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "./Types.sol";

import {ICore} from "./Interfaces.sol";
import {IBasket, IWiredVault, IWiredBasket, ILevSweep, IEthVenue} from "./Interfaces.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Types} from "./Types.sol";
import {FeeLib} from "./FeeLib.sol";
import {IAaveV4Hub} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
import {QuidLib} from "./QuidLib.sol";

library BasketLib {

    error NothingDelivered();

    error AmountTooSmall();

    uint public constant MONTH = 2420000;

    struct Metrics {
        uint total;
        uint last;
        uint yield;
        uint trackingStart;
        uint yieldAccum;
    }

    function computeMetrics(Metrics memory stats,
        uint elapsed, uint raw, uint rateWeighted,
        uint tvl) internal view returns (Metrics memory) {

        if (stats.trackingStart > 0 && stats.last > 0)
            stats.yieldAccum += stats.yield * elapsed;

        else if (stats.trackingStart == 0)
            stats.trackingStart = block.timestamp;

        if (raw != 0) stats.yield = SoladyMath.fullMulDiv(WAD, rateWeighted, raw);
        stats.total = tvl; stats.last = block.timestamp;

        return stats;
    }

    function get_deposits(address aux, address[] memory stables,
        mapping(address => Holding) storage storedHoldings,
        mapping(address => uint) storage tranche) external
        returns (uint[16] memory amounts, uint[16] memory yieldW, uint depegLossOut) {

        uint balance;
        uint len = stables.length - 1;
        for (uint i = 0; i < len; i++) {
            address stable = stables[i];
            uint yieldWeighted;

            Holding storage h = storedHoldings[stable];
            balance = h.balance;
            yieldWeighted = h.yieldWeighted;
            if (balance == 0) continue;
            uint reserved = tranche[stable];
            if (reserved > 0) {
                uint cap = Math.min(balance, reserved);

                uint ywCap = SoladyMath.fullMulDiv(yieldWeighted, cap, balance);
                balance -= cap;
                yieldWeighted -= Math.min(yieldWeighted, ywCap);
            }

            uint sev = IAux(aux).getDepegSeverityBps(stable);
            if (sev > 0) {
                uint lossFrac = sev > 10000 ? 10000 : sev;
                uint loss = SoladyMath.fullMulDiv(balance, lossFrac, 10000);
                yieldWeighted = yieldWeighted > loss ? yieldWeighted - loss : 0;
                depegLossOut += loss;

            }
            amounts[i + 1] = balance;
            amounts[15] += balance;
            amounts[0] += yieldWeighted;
            yieldW[i + 1] = yieldWeighted;

            yieldW[0] += SoladyMath.fullMulDiv(balance, h.rate, WAD);
        }
    }

    struct Holding { uint balance; uint yieldWeighted; uint lastLevel; uint rate; uint40 lastAt; }

    uint internal constant MAX_CREDIBLE_RATE = 0.20e18;
    uint internal constant RATE_SAMPLE_MIN = 1 days;
    uint internal constant YEAR = 365 days;

    function _refreshOne(address stable,
        mapping(address => Holding) storage sh) internal {
        address aux = address(this);
        bool isAave = (stable == IAux(aux).GHO() || stable == IAux(aux).USDG());
        (uint b, uint yw) = _valueStable(stable, isAave, IAux(aux).AAVE_SPOKE());
        Holding storage h = sh[stable];
        (uint lastLevel, uint rate, uint40 lastAt) = (h.lastLevel, h.rate, h.lastAt);
        if (b > 0) {
            uint level = SoladyMath.fullMulDiv(WAD, yw, b);
            if (lastAt == 0) {

                lastLevel = level; lastAt = uint40(block.timestamp);
            } else if (block.timestamp - lastAt >= RATE_SAMPLE_MIN) {

                rate = level > lastLevel
                    ? SoladyMath.fullMulDiv(SoladyMath.fullMulDiv(WAD, level - lastLevel, lastLevel),
                                      YEAR, block.timestamp - lastAt)
                    : 0;
                if (rate > MAX_CREDIBLE_RATE) rate = MAX_CREDIBLE_RATE;
                lastLevel = level; lastAt = uint40(block.timestamp);
            }
        }
        sh[stable] = Holding(b, yw, lastLevel, rate, lastAt);
    }

    function refreshHoldingsBody(address stable,
        mapping(address => Holding) storage sh,
        mapping(address => uint) storage toIndex, uint nStables) external {
        uint ti = toIndex[stable];
        if (ti == 0 || ti == nStables) return;
        _refreshOne(stable, sh);
    }

    function refreshAllHoldingsBody(mapping(address => Holding) storage sh,
        address[] storage stables) external {
        uint len = stables.length == 0 ? 0 : stables.length - 1;
        for (uint i; i < len; i++) _refreshOne(stables[i], sh);
    }

    function _aaveYieldWeighted(address aux, address stable, uint assets)
        internal view returns (uint) {
        if (assets == 0) return 0;
        uint shares = IAux(aux).aaveShares(stable);
        return shares > 0 ? SoladyMath.fullMulDiv(assets, assets, shares) : assets;
    }

    function _yieldWeight(address v, uint b, uint shares, uint assetDec)
        internal view returns (uint) {
        try IERC20(v).decimals() returns (uint8 sd) {
            return SoladyMath.fullMulDiv(b,
                sd > assetDec ? b * (10 ** (uint(sd) - assetDec)) : b, shares);
        } catch { return b; }
    }

    function _valueStable(address stable, bool isAave, address aaveSpoke)
        internal returns (uint balance, uint yieldWeighted) {
        address aux = address(this);

        uint dec = IERC20(stable).decimals();
        address[] memory vs = IAux(aux).getVaults(stable);
        if (vs.length == 0) {

            if (!isAave) return (0, 0);
            balance = IAux(aux).aaveBalance(stable);
            yieldWeighted = _aaveYieldWeighted(aux, stable, balance);
        } else {
            for (uint j = 0; j < vs.length; j++) {
                address v = vs[j];
                if (v == aaveSpoke) {

                    uint ab = IAux(aux).aaveBalance(stable);
                    balance += ab;
                    yieldWeighted += _aaveYieldWeighted(aux, stable, ab);
                    continue;
                }

                uint b; uint shares;
                try IERC4626(v).balanceOf(aux) returns (uint sh) {
                    if (sh == 0) continue;
                    shares = sh;
                    try IERC4626(v).convertToAssets(sh) returns (uint a) { b = a; }
                    catch { continue; }
                } catch { continue; }
                if (b == 0) continue;
                balance += b;

                yieldWeighted += _yieldWeight(v, b, shares, dec);
            }
        }
        if (balance == 0) return (0, 0);

        if (dec < 18) {
            uint scale = 10 ** (18 - dec);
            balance *= scale;
            yieldWeighted *= scale;
        }
    }

    function avgYield(Metrics memory stats)
        external view returns (uint) {
        if (stats.trackingStart == 0) return 0;
        uint totalTime = block.timestamp - stats.trackingStart;
        uint timeSinceUpdate = block.timestamp - stats.last;
        uint currentAccum = stats.yieldAccum
            + stats.yield * timeSinceUpdate;
        return currentAccum / (totalTime + 1);
    }

    function seedFee(uint usd,
        uint trancheTotal, uint target,
        uint avgYieldIn) internal pure returns (uint) {
        if (target == 0 || trancheTotal >= target || avgYieldIn == 0) return 0;
        return Math.min(SoladyMath.fullMulDiv(usd, avgYieldIn, WAD * 12),
                        target - trancheTotal);
    }


    function matureBatches(uint[] memory batches,
        uint currentTimestamp, uint deployedTime)
        external pure returns (int i) {
        if (batches.length == 0) return -1;
        uint currentMonth = (currentTimestamp - deployedTime) / MONTH;
        int start = int(batches.length - 1);
        for (i = start; i >= 0; i--)
            if (batches[uint(i)] <= currentMonth) return i;

        return -1;
    }

    function isManipulated(uint spot, uint twap,
        uint thresholdBps) public pure returns (bool) {
        uint dev = spot > twap ? spot - twap : twap - spot;
        return dev * 10000 > twap * thresholdBps;
    }

    function from6(uint amount6, address token) internal view returns (uint) {
        uint decimals = IERC20(token).decimals();
        return decimals == 6 ? amount6
             : decimals > 6 ? amount6 * (10 ** (decimals - 6))
                            : amount6 / (10 ** (6 - decimals));
    }

    function scaleTokenAmount(uint amount, address token,
        bool scaleUp) internal view returns (uint scaled) {
        uint decimals = IERC20(token).decimals();
        uint scale = decimals < 18 ? 18 - decimals : 0;
        scaled = scale > 0 ? (scaleUp ? amount * (10 ** scale):
              amount / (10 ** scale)) : amount; return scaled;
    }

    function tipBody(mapping(address => uint) storage tranche, uint trancheTotal, uint cut, address token, int sign)
        public returns (uint) {
        cut = scaleTokenAmount(cut, token, true);
        if (sign > 0) {
            tranche[token] += cut;
            return trancheTotal + cut;
        }
        cut = Math.min(cut, tranche[token]);
        tranche[token] -= cut;
        return trancheTotal - Math.min(trancheTotal, cut);
    }

    function convert(uint amount, uint price, bool toVol)
        public pure returns (uint) {
        return toVol
            ? SoladyMath.fullMulDiv(amount * 1e12, 1e18, price)
            : SoladyMath.fullMulDiv(amount, price, 1e18) / 1e12;
    }

    function routeSwap(Types.AuxContext memory ctx,
        Types.RouteParams memory p) external returns
        (uint out, uint poolSupplied, uint consumed) {
        consumed = Math.min(p.amount, convert(p.pooled,
                        p.fillPrice, p.token != address(0)));
        uint pooled = consumed;
        if (pooled > 0) {
            if (p.token != address(0) && ctx.vault != address(0)) {

                pooled = IERC4626(ctx.vault).convertToAssets(
                       IERC4626(ctx.vault).deposit(pooled, address(this)));

                poolSupplied = pooled;
            }
            out = ICore(ctx.core).swap(p.recipient, p.inputIsUsd, p.token, pooled, p.loadBalance);
        }

    }

    function calcMintYield(uint deposited, uint decimals,
        uint when, uint nextMonth,
        uint avgYieldIn, bool isSeed) external pure
        returns (uint normalized, uint month) {
        normalized = decimals < 18 ? deposited
            * (10 ** (18 - decimals)) : deposited;
        month = isSeed ? nextMonth + 1 : nextMonth;
        if (when > month) month = when;

        uint yield = isSeed ? WAD : avgYieldIn;
        normalized += SoladyMath.fullMulDiv(normalized * yield,
                        month - (nextMonth - 1), WAD * 12);
    }

    struct TakeArgs {
        address who;
        uint    amount;
        address token;
        uint    seed;
        address weth;
        address quid;
        uint    index;
        address[] stables;
        address linkAddr;

        bool    softBacking;
    }

    function takeBody(TakeArgs memory a) external returns (uint sent) {
        IAux aux = IAux(address(this));
        if (a.token == a.weth) {
            sent = aux.withdrawSelf(a.weth, a.amount, a.who);
            aux.checkBacking();
            return sent;
        }
        (uint[16] memory amounts, uint[16] memory yieldW,,) = aux.get_deposits();
        sent = _takeCore(a, amounts, yieldW);

        if (a.amount > 0 && sent == 0) revert NothingDelivered();
    }

    function takeBodyWith(TakeArgs memory a, uint[16] memory amounts, uint[16] memory yieldW)
        external returns (uint sent) {
        sent = _takeCore(a, amounts, yieldW);

        if (a.amount > 0 && sent == 0) revert NothingDelivered();

    }

    function _takeCore(TakeArgs memory a, uint[16] memory amounts, uint[16] memory yieldW)
        private returns (uint sent) {
        IAux aux = IAux(address(this));
        FeeLib.FeeCtx memory fc = FeeLib.FeeCtx(a.stables, a.linkAddr);

        bool viaToken = a.token != a.quid;
        address skip = viaToken ? a.token : address(0);
        if (skip != address(0)) {
            uint idx = a.index;
            require(idx > 0 && idx <= a.stables.length, "unknown-stable");
            bool done;
            (sent, a.amount, done) = _takePreferred(aux, a.who, skip,
                viaToken ? a.amount : scaleTokenAmount(a.amount, skip, false),
                a.seed, fc);
            if (done) return sent;
        }
        if (amounts[15] == 0 || a.amount == 0) { _finalBacking(aux, a.softBacking); return sent; }
        if (a.seed == 0) a.amount = Math.min(amounts[15], a.amount);
        {   (uint pr, bool subUnit) = _takeProRata(aux, a.who, a.amount, a.seed, skip, amounts, fc);
            sent += pr;

            if (sent == 0 && subUnit) revert AmountTooSmall();
        }
        _finalBacking(aux, a.softBacking);
    }

    function _finalBacking(IAux aux, bool soft) private {
        if (soft) aux.tryCheckBacking(); else aux.checkBacking();
    }

    function _takePreferred(
        IAux aux, address who, address token, uint amount, uint seed,
        FeeLib.FeeCtx memory fc
    ) private returns (uint sent, uint remaining, bool done) {
        uint needed = FeeLib.calcNeeded(token, amount, fc);
        if (seed > 0) {
            aux.tipSelf(seed, token, -1);
            sent = aux.withdrawSelf(token, needed, who);
            aux.checkBacking();
            return (sent, 0, true);
        }
        try aux.withdrawSelf(token, needed, who) returns (uint s) {
            sent = s;
        } catch {
            sent = 0;
        }
        remaining = needed > sent ? needed - sent : 0;
        sent = scaleTokenAmount(sent, token, true);
        remaining = scaleTokenAmount(remaining, token, true);
    }

    function _takeProRata(
        IAux aux, address who, uint amount, uint seed, address skip,
        uint[16] memory amounts, FeeLib.FeeCtx memory fc
    ) private returns (uint sent, bool subUnit) {
        for (uint i = 1; i <= fc.stables.length; i++) {
            address token = fc.stables[i - 1]; if (token == skip) continue;

            if (amounts[i] != 0) {
                amounts[i] = FeeLib.allocate(token,
                amount, amounts[i], amounts[15], fc);
                if (amounts[i] == 0) subUnit = true;
            }
            if (seed > 0) aux.tipSelf(SoladyMath.fullMulDiv(amounts[i], seed, amount), token, -1);
            if (amounts[i] > 0) {

                uint d;
                try IERC20(token).decimals()
                    returns (uint8 dd) { d = dd; } catch { d = 0; }
                if (d == 0 || d > 18) { amounts[i] = 0; continue; }
                uint divisor = d < 18 ? 10 ** (18 - d) : 1;

                if (amounts[i] / divisor == 0) { subUnit = true; amounts[i] = 0; continue; }
                try aux.withdrawSelf(token, amounts[i] / divisor, who) returns (uint w) {
                    amounts[i] = w; sent += amounts[i] * divisor; } catch { amounts[i] = 0;
                }
            }
        }
    }

    function _depegLoss() internal returns (uint loss) {

        (,,, loss) = IAux(address(this)).get_deposits();
    }

    function depegLoss() external returns (uint) { return _depegLoss(); }

    function illiquidLoss() external view returns (uint) { (uint l,,) = _illiquidLoss(); return l; }

    function illiquidLossFlagging() external returns (uint loss) {
        address worst; uint worstBps;
        (loss, worst, worstBps) = _illiquidLoss();
        if (worst != address(0)) IAux(address(this)).flagIlliquidSelf(worst, worstBps < LIQ_TOL_BPS);
    }

    function _aaveAvail(address aux, address stable) internal view returns (uint) {
        address hub = IAux(aux).AAVE_HUB();
        if (hub == address(0)) return 0;
        try IAaveV4Hub(hub).getAssetId(stable) returns (uint aid) {
            try IAaveV4Hub(hub).getAssetLiquidity(aid) returns (uint liq) {
                uint mine = IAux(aux).aaveBalance(stable);
                return liq < mine ? liq : mine;
            } catch { return 0; }
        } catch { return 0; }
    }

    function _illiquidLoss() internal view returns (uint loss, address worst, uint worstBps) {
        worstBps = type(uint).max;

        address aux = address(this);
        address[] memory stables = IAux(aux).getStables();
        address aaveSpoke = IAux(aux).AAVE_SPOKE();
        uint len = stables.length - 1;
        for (uint i = 0; i < len; i++) {
            address stable = stables[i];
            address[] memory vs = IAux(aux).getVaults(stable);
            uint shortfall;
            for (uint j = 0; j < vs.length; j++) {
                address v = vs[j];
                if (v == aaveSpoke) {

                    uint rid = stable == IAux(aux).GHO()
                        ? IAux(aux).GHO_RESERVE_ID()
                        : stable == IAux(aux).USDG()
                        ? IAux(aux).USDG_RESERVE_ID()
                        : IAux(aux).aaveReserveId(stable);
                    if (rid == 0) continue;
                    uint supA = IAux(aux).aaveBalance(stable);
                    uint avail = _aaveAvail(aux, stable);
                    if (supA > avail) shortfall += supA - avail;

                    if (supA > 0) {
                        uint abps = SoladyMath.fullMulDiv(avail > supA ? supA : avail, 10000, supA);
                        if (abps < worstBps) { worstBps = abps; worst = aaveHealthKey(aaveSpoke, rid); }
                    }
                    continue;
                }
                try IERC4626(v).balanceOf(aux) returns (uint sh) {
                    if (sh == 0) continue;
                    uint solv;
                    try IERC4626(v).convertToAssets(sh) returns (uint a) { solv = a; }
                    catch { continue; }

                    uint deliv = QuidLib._withdrawableOf(v, aux);
                    if (solv > deliv) shortfall += solv - deliv;

                    uint bps = SoladyMath.fullMulDiv(deliv, 10000, solv);
                    if (bps < worstBps) { worstBps = bps; worst = v; }
                } catch { continue; }
            }
            if (shortfall == 0) continue;
            uint dec = IERC20(stable).decimals();
            if (dec < 18) shortfall *= 10 ** (18 - dec);
            loss += shortfall;
        }
    }

    struct RedeemArgs {
        uint amount;
        address source;
        address recipient;
        address core;
        address quid;
        address ETH;
        address weth;

    }

    function _perShare(address quid, uint raw, uint rateWeighted, uint depegLossIn)
        private returns (uint perShare, uint solvent) {
        (solvent,) = IAux(address(this)).get_metricsWith(raw, rateWeighted);
        solvent = solvent > depegLossIn ? solvent - depegLossIn : 0;

        perShare = BasketLib.qdShareValue(WAD, solvent, IBasket(quid).matureSupply());
    }

    function spendClaimBody(address owner, uint usd6, address quid)
        external returns (uint funded6) {
        if (usd6 == 0) return 0;
        (uint[16] memory amts, uint[16] memory yW,, uint depegLossOut) =
            IAux(address(this)).get_deposits();
        (uint perShare,) = _perShare(quid, amts[15], yW[0], depegLossOut);
        if (perShare == 0) return 0;

        uint mature = IERC20(quid).balanceOf(owner);
        { uint imm = IBasket(quid).immatureBalanceOf(owner); mature = mature > imm ? mature - imm : 0; }

        uint wantUsd18 = usd6 * 1e12;
        uint claimUsd18 = SoladyMath.fullMulDiv(mature, perShare, WAD);
        if (claimUsd18 < wantUsd18) wantUsd18 = claimUsd18;
        if (wantUsd18 == 0) return 0;
        (uint burned,) = IBasket(quid).turn(owner, SoladyMath.fullMulDiv(wantUsd18, WAD, perShare));

        funded6 = SoladyMath.fullMulDiv(burned, perShare, WAD) / 1e12;
    }

    function _redeemQuote(RedeemArgs memory r, uint raw, uint rateWeighted, uint depegLossIn)
        private returns (uint perShare, uint freeUsd) {
        uint solvent;
        (perShare, solvent) = _perShare(r.quid, raw, rateWeighted, depegLossIn);
        (uint il, address worst, uint worstBps) = _illiquidLoss();

        if (worst != address(0)) IAux(address(this)).flagIlliquidSelf(worst, worstBps < LIQ_TOL_BPS);
        uint committed = ICore(r.core).committedUsd18();
        uint locked = il > committed ? il : committed;
        freeUsd = solvent > locked ? solvent - locked : 0;
    }

    function redeemAsBody(RedeemArgs memory r) external {

        (uint[16] memory amts, uint[16] memory yW,, uint depegLossOut) =
            IAux(address(this)).get_deposits();

        (uint perShare, uint freeUsd) = _redeemQuote(r, amts[15], yW[0], depegLossOut);

        (uint usdPart, uint seedBurned, bool unwound) = _settleRedeem(r, perShare, freeUsd);
        _dispatchTake(r, usdPart, seedBurned, amts, yW, unwound);
    }

    function _settleRedeem(RedeemArgs memory r, uint perShare, uint freeUsd)
        private returns (uint usdPart, uint seedBurned, bool unwound) {
        if (perShare == 0) return (0, 0, false);
        uint mature = IERC20(r.quid).balanceOf(r.source);
        { uint imm = IBasket(r.quid).immatureBalanceOf(r.source); mature = mature > imm ? mature - imm : 0; }
        uint wantUsd = SoladyMath.fullMulDiv(Math.min(r.amount, mature), perShare, WAD);
        uint delivered = wantUsd < freeUsd ? wantUsd : freeUsd;
        if (wantUsd > freeUsd) {
            uint need = wantUsd - freeUsd;
            uint freed = ICore(r.ETH).unwindForRedeem(need);

            if (freed < need) freed += _deleverBookForRedeem(r.core, need - freed);
            delivered = freeUsd + (freed < need ? freed : need);
            unwound = true;
        }
        uint burned;
        (burned, seedBurned) = IBasket(r.quid).turn(r.source, SoladyMath.fullMulDiv(delivered, WAD, perShare));
        usdPart = SoladyMath.fullMulDiv(burned, perShare, WAD);
    }

    function _deleverBookForRedeem(address core, uint usdWanted) private returns (uint) {
        address vault = ICore(core).btc();
        if (vault == address(0)) return 0;

        address mgr = IEthVenue(IAux(address(this)).ethVenue()).LEV_MANAGER();
        if (mgr == address(0)) return 0;
        return ILevSweep(mgr).deleverBook(usdWanted, address(this), 0);
    }

    function _dispatchTake(RedeemArgs memory r, uint usdPart, uint seedBurned,
        uint[16] memory amts, uint[16] memory yW, bool fresh) private {

        if (seedBurned == 0 && !fresh) {
            IAux(address(this)).takeWith(r.recipient, usdPart, r.quid, 0, amts, yW);
        } else {
            IAux(address(this)).take(r.recipient, usdPart, r.quid, seedBurned);
        }
    }

    function backingCoreBody(address core, address btcCore, address ETH, address btc)
        external returns (uint committedSum, uint totalLiquid) {

        (uint[16] memory deposits,,,) = IAux(address(this)).get_deposits();
        totalLiquid = deposits[15];
        committedSum = ICore(core).committedUsd18();
        if (committedSum <= totalLiquid) return (committedSum, totalLiquid);
        bool ethFirst = ICore(core).POOLED_USD() >= ICore(btcCore).POOLED_USD();

        ICore(ethFirst ? ETH : btc).repack();
        committedSum = ICore(core).committedUsd18();
        if (committedSum > totalLiquid) {
            ICore(ethFirst ? btc : ETH).repack();
            committedSum = ICore(core).committedUsd18();
        }
    }

    function assertFullyWired(address q, address ethVenue, address btcChannels,
        address core, address ETH) external view {

        address btc = ICore(core).btc();
        require(q != address(0),                                    "wire:quid");
        require(ethVenue != address(0),                             "wire:ethv");
        require(btc != address(0),                              "wire:vault");
        require(ethVenue == ETH,                                     "wire:range");
        require(btcChannels != address(0)
             && IWiredVault(btc).btcChannels() == btcChannels,  "wire:chan");
        require(IWiredBasket(q).AUX() == address(this),             "wire:bAux");
        require(IWiredBasket(q).BTC_VAULT() == btc,            "wire:bVlt");
    }

    function redeemableBody(address core) external returns (uint) {
        (uint total,) = IAux(address(this)).get_metrics(false);
        { uint dl = _depegLoss(); total = total > dl ? total - dl : 0; }

        { (uint il, address worst, uint worstBps) = _illiquidLoss();
          total = total > il ? total - il : 0;
          if (worst != address(0)) IAux(address(this)).flagIlliquidSelf(worst, worstBps < LIQ_TOL_BPS); }

        uint btcCommitted = ICore(core).POOLED_USD() * 1e12;
        return total > btcCommitted ? total - btcCommitted : 0;
    }

    uint public constant EVAC_DWELL = 30 minutes;
    uint16 internal constant LIQ_TOL_BPS = 5000;

    struct VaultHealthCfg {
        address ethVenue;
    }

    struct VaultHealth {
        bool   blocked;
        uint40 flaggedAt;
    }

    function setVaultHealthBody(
        address vault, bool blocked,
        mapping(address => VaultHealth) storage vaultHealth
    ) internal {
        VaultHealth storage vh = vaultHealth[vault];
        vh.blocked = blocked;

        if (!blocked) vh.flaggedAt = 0;
    }

    function pokeVaultHealthBody(
        address vault, VaultHealthCfg memory cfg,
        mapping(address => VaultHealth) storage vaultHealth,
        mapping(address => address[]) storage vaultsOf,
        mapping(address => address) storage tokens
    ) external {

        uint reported = IERC4626(vault).convertToAssets(IERC4626(vault).balanceOf(address(this)));

        uint liquid = QuidLib._withdrawableOf(vault, address(this));
        if (reported == 0) return;
        uint liqBps = SoladyMath.fullMulDiv(liquid, 10000, reported);
        if (liqBps >= LIQ_TOL_BPS) {

            if (vaultHealth[vault].blocked && vaultHealth[vault].flaggedAt != 0)
                setVaultHealthBody(vault, false, vaultHealth);
            return;
        }

        setVaultHealthBody(vault, true, vaultHealth);
        uint40 flagged = vaultHealth[vault].flaggedAt;
        if (flagged == 0) vaultHealth[vault].flaggedAt = uint40(block.timestamp);
        else if (block.timestamp - flagged >= EVAC_DWELL)
            evacuateBody(vault, cfg, vaultHealth, vaultsOf, tokens);
    }

    function aaveHealthKey(address spoke, uint reserveId) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(spoke, reserveId)))));
    }

    function flagIlliquidBody(address vault, bool illiquid,
        mapping(address => VaultHealth) storage vaultHealth) external {
        if (illiquid) {
            setVaultHealthBody(vault, true, vaultHealth);
            if (vaultHealth[vault].flaggedAt == 0) vaultHealth[vault].flaggedAt = uint40(block.timestamp);
        } else if (vaultHealth[vault].blocked && vaultHealth[vault].flaggedAt != 0) {
            setVaultHealthBody(vault, false, vaultHealth);
        }
    }

    function evacuateBody(
        address vault, VaultHealthCfg memory ,
        mapping(address => VaultHealth) storage vaultHealth,
        mapping(address => address[]) storage vaultsOf,
        mapping(address => address) storage tokens
    ) public {
        vaultHealth[vault].blocked = true;

        uint sh = IERC4626(vault).balanceOf(address(this));
        if (sh == 0) return;
        address stable = tokens[vault];
        if (stable == address(0)) return;
        try IERC4626(vault).redeem(sh, address(this), address(this))
            returns (uint got) {
            if (got > 0) spreadEquallyBody(stable, got, vaultHealth, vaultsOf);
        } catch {  }
    }

    function spreadEquallyBody(
        address stable, uint amount,
        mapping(address => VaultHealth) storage vaultHealth,
        mapping(address => address[]) storage vaultsOf
    ) internal {
        address[] memory vs = vaultsOf[stable];
        address spoke = IAux(address(this)).AAVE_SPOKE();
        uint n;

        for (uint j; j < vs.length; j++)
            if (vs[j] != spoke && !vaultHealth[vs[j]].blocked) n++;
        if (n == 0) return;
        uint each = amount / n;
        uint rem = amount;
        for (uint j; j < vs.length; j++) {
            if (vs[j] == spoke || vaultHealth[vs[j]].blocked) continue;
            uint a = (--n == 0) ? rem : each;
            rem -= a;
            if (a > 0) IERC4626(vs[j]).deposit(a, address(this));
        }
    }

    function qdShareValue(uint256 burned, uint256 total, uint256 supplyPreBurn)
        internal pure returns (uint256 dollars)
    {
        if (burned == 0 || supplyPreBurn == 0) return burned;
        uint256 share = SoladyMath.fullMulDiv(total, burned, supplyPreBurn);
        return burned < share ? burned : share;
    }

}

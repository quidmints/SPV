// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Aux} from "./Aux.sol";
import {Vault} from "./Vault.sol";
import {Basket} from "./Basket.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {OracleLib, RING} from "./imports/OracleLib.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {SwapLib} from "./imports/SwapLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILevEquity, ICore} from "./imports/Interfaces.sol";

import {IERC20Min} from "./imports/Interfaces.sol";
import {Types, BtcVaultPinned} from "./imports/Types.sol";

contract Core {

    OracleLib.ObsState internal obsState;
    OracleLib.Observation[RING] internal observations;

    uint public basketUsd;

    uint public POOLED_USD;

    uint public POOLED;

    function committedUsd18() public view returns (uint) {
        return AUX.committedTotal();
    }

    function _reportEquity() internal { AUX.report(_rangeEquityUsd18()); }

    function _rangeEquityUsd18() internal view returns (uint) {
        uint pooled18 = basketUsd * 1e12;
        uint debt18 = _levDebtUsd18();
        return pooled18 > debt18 ? pooled18 - debt18 : 0;
    }

    function rangeEquityUsd18() external view returns (uint) { return _rangeEquityUsd18(); }

    function _levDebtUsd18() internal view returns (uint) {
        if (address(BTC) == address(0)) return 0;
        address mgr = RANGE.levManager();
        if (mgr == address(0)) return 0;
        try ILevEquity(mgr).totalDebtUsd() returns (uint d) { return d; } catch { return 0; }
    }

    uint public pendingSwapOutUsd;

    struct Flow { uint128 vol; uint64 ts; }
    Flow internal _flow;

    uint internal constant FLOW_DECAY   = 999759352855809024;
    uint internal constant FLOW_MAX_MIN = 525600000;

    Flow internal _prem;

    function _decayed(Flow storage f) internal view returns (uint) {
        return _decayedBy(f, 1);
    }

    function _decayedBy(Flow storage f, uint slowN) internal view returns (uint) {
        if (f.ts == 0) return f.vol;
        uint mins = (block.timestamp - f.ts) / 60 / slowN;
        return Math.mulDiv(f.vol, FeeLib.decPow(FLOW_DECAY, mins, FLOW_MAX_MIN), 1e18);
    }

    function _bumpEwma(Flow storage f, uint usd6) internal {
        uint v = _decayed(f) + usd6;
        f.vol = v > type(uint128).max ? type(uint128).max : uint128(v);
        f.ts  = uint64(block.timestamp);
    }

    function _bumpFlow(uint usd6) internal {
        _bumpEwma(_flow, usd6);
    }

    function bumpRedeemFlow(uint usd6) external onlyUs {
        if (usd6 != 0) _bumpEwma(_redeemFlow, usd6);
    }

    function redeemEwmaUsd() public view returns (uint) { return _decayed(_redeemFlow); }

    function skewTargetUsd() public view returns (uint) {
        return flowEwmaUsd() + redeemEwmaUsd();
    }

    function flowEwmaUsd() public view returns (uint) {
        return _decayed(_flow);
    }

    function premiumEwmaUsd() public view returns (uint) {
        return _decayed(_prem);
    }

    function levClaimUsd6() public view returns (uint) {
        return _levDebtUsd18() / 1e12;
    }

    function riskParams() external view returns (uint confFracWad, uint spliceFloor) {
        return (CONF_FRAC, SPLICE);
    }

    function levGrossNative() public view returns (uint) {
        if (address(BTC) == address(0)) return 0;
        return RANGE.levGrossNative();
    }

    function realizedVarianceWad() external view returns (uint) {

        uint v = Math.mulDiv(OracleLib.ringVariance(observations, obsState, 9),
                            31536000, 1e18);

        uint a = anchorVarianceWad();
        return v > a ? v : a;
    }

    function anchorVarianceWad() public view returns (uint) {
        uint dt = _varDt.vol;
        if (dt == 0) return 0;
        uint v = Math.mulDiv(_varSq.vol, 31536000, dt);
        return v == 0 ? 1 : v;
    }

    function _sampleAnchorVariance() internal {

        (uint px,) = SwapLib.twapResolve(
            AUX.assetPriceFeed(ASSET), 0, VOL_DECIMALS != 18, 0, 1 days);
        if (px == 0) return;
        uint prev = _varPx;

        if (prev == 0) {
            _varPx = px;
            _bumpVar(0, 0);
            return;
        }
        uint dt = block.timestamp - _varSq.ts;

        if (dt == 0) return;

        if (px == prev) { _bumpVar(0, dt); return; }
        _varPx = px;
        uint lo = px < prev ? px : prev;
        uint r = (px < prev ? prev - px : px - prev) * 1e18 / lo;
        _bumpVar((r * r) / 1e18, dt);
    }

    function _bumpVar(uint sqInc, uint dtInc) private {
        uint ts = _varSq.ts;
        uint factor = 1e18;
        if (ts != 0) factor = FeeLib.decPow(FLOW_DECAY, (block.timestamp - ts) / 60, FLOW_MAX_MIN);
        _decayInto(_varSq, factor, sqInc);
        _decayInto(_varDt, factor, dtInc);
    }

    function _decayInto(Flow storage f, uint factor, uint inc) private {
        uint v = Math.mulDiv(f.vol, factor, 1e18) + inc;
        f.vol = v > type(uint128).max ? type(uint128).max : uint128(v);
        f.ts  = uint64(block.timestamp);
    }

    uint public skewPremium;
    event SkewPremiumRetained(uint256 premiumUsd, uint256 cumulative);

    uint256 public retainedEthPremium;

    function recordSkewPremium(uint256 premiumUsd, uint256 premiumNative) external onlyUs {
        retainedEthPremium += premiumNative;
        if (premiumUsd == 0) return;
        uint256 cum;

        skewPremium += premiumUsd; cum = skewPremium;

        RANGE.creditSkewPremium(premiumUsd);

        POOLED_USD += premiumUsd;

        _bumpEwma(_prem, premiumUsd);
        emit SkewPremiumRetained(premiumUsd, cum);
    }

    function refundUnfilled(address token, uint amount, address to) external onlyUs {
        if (amount != 0 && to != address(0)) AUX.take(to, amount, token, 0);
    }

    uint8 public immutable VOL_DECIMALS;

    uint public immutable CONF_FRAC;
    uint public immutable SPLICE;

    address public ASSET;

    ICore public RANGE;

    uint public RANGE_ANCHOR;

    Aux AUX; Basket BASKET; Vault BTC;

    function setBtcVault(address b) external {
        require(msg.sender == DEPLOYER, "403");
        if (address(BTC) != address(0))
            revert BtcVaultPinned();
        BTC = Vault(payable(b));

        if (address(RANGE) == address(0)) RANGE = ICore(b);
    }

    function btc() external view returns (address) { return address(BTC); }

    function skewPremiumCum() external view returns (uint) {
        return skewPremium;
    }

    function btcThetaBacking() external view returns (uint) {
        return address(BTC) == address(0) ? 0 : BTC.totalShares() + BTC.totalBuffer();
    }

    function _onlyUs() private view {
        require(msg.sender == address(AUX)
             || msg.sender == address(RANGE)
             || msg.sender == address(BTC), "403");
    }

    modifier onlyUs { _onlyUs(); _; } bytes internal constant ZERO_BYTES = bytes("");

    address immutable DEPLOYER;

    constructor(address asset_, SwapLib.Risk memory risk) {
        DEPLOYER = msg.sender;
        ASSET        = asset_;
        VOL_DECIMALS = IERC20Min(asset_).decimals();
        CONF_FRAC    = risk.confFracWad;
        SPLICE       = risk.spliceFloor;
    }

    function setup(address _range, address _aux, address _basket, uint seedPrice)
        external { require(msg.sender == DEPLOYER, "403");

        require(address(AUX) == address(0), "!");

        AUX = Aux(payable(_aux));

        if (_range != address(0)) RANGE = ICore(_range);
        BASKET = Basket(_basket);

        OracleLib.seedRing(obsState, observations, seedPrice);
    }

    function drawPooledUsdBtc(uint usd6) external onlyUs {

        POOLED_USD -= usd6;
    }

    function addPendingSwapOut(uint usd6) external onlyUs {
        pendingSwapOutUsd += usd6;
    }

    function subPendingSwapOut(uint usd6) external onlyUs {
        pendingSwapOutUsd -= usd6;
    }

    function modLP(int256 delta, int256 deltaUSD, address sender)
        public onlyUs returns (uint sent) {

        Delta memory d = Delta(deltaUSD, delta);
        _handleDelta(d, deltaUSD == 0, sender, address(0), true);
        sent = 0;
    }

    function settleOor(address owner, int256 usdDelta, int256 volDelta, bool loadBalance)
        external onlyUs {
        _handleDelta(Delta(usdDelta, volDelta), false, owner, address(0));
        if (loadBalance) _shortfallLoadBalance(owner);
    }

    function _shortfallLoadBalance(address sender) private {
        uint totalSharesPool = RANGE.sharesForShortfall();
        uint pooledTok = RANGE.realInventory();
        if (pooledTok < totalSharesPool) {
            uint shortfall = totalSharesPool - pooledTok;
            if (shortfall * 100 >= totalSharesPool) {
                RANGE.onShortfall(sender, shortfall);
            }
        }
    }

    function swap(address recipient,
        bool inputIsUsd, address token, uint amount, bool loadBalance)
        onlyUs public returns (uint out) {

        uint px = AUX.getTWAPforAsset(ASSET, 1800);
        Delta memory delta;
        (delta, out) = _fillDelta(inputIsUsd, amount, px);

        _observeIfSourced();

        _sampleAnchorVariance();

        _handleDelta(delta, false, recipient, token);

        {
            int256 usdLeg = delta.usd;
            uint usd6 = uint(usdLeg < 0 ? -usdLeg : usdLeg);
            if (usd6 != 0) {
                _bumpFlow(usd6);

                netFlowUsd += usdLeg;
            }
        }

        if (!loadBalance) return out;

        _shortfallLoadBalance(recipient);
    }

    function repack(uint anchorPrice) public onlyUs returns (uint price) {
        RANGE_ANCHOR = anchorPrice;
        price = AUX.getTWAPforAsset(ASSET, 1800);
        _observeIfSourced();
    }

    struct Delta { int256 usd; int256 vol; }

    function _handleDelta(Delta memory d,
        bool keep, address who, address token) internal {
        _handleDelta(d, keep, who, token, false);
    }

    function _handleDelta(Delta memory d, bool keep,
        address who, address token, bool basketLeg) internal {
        _settleUsdSide(d.usd, keep, who, token, basketLeg);
        int256 tokDelta = d.vol;
        if (tokDelta > 0) {
            uint tokAmount = uint(tokDelta);
            POOLED -= Math.min(tokAmount, POOLED);

            if (who != address(0)) RANGE.deliverVolatile(tokAmount, who);
        } else if (tokDelta < 0) {
            uint tokAmount = uint(-tokDelta);
            POOLED += tokAmount;
        }
    }

    function _settleUsdSide(int256 usdDelta, bool keep,
        address who, address token, bool basketLeg) private returns (uint usdAmount) {
        if (usdDelta > 0) {
            usdAmount = uint(usdDelta);
            _poolUsdInRange(usdAmount, false, basketLeg);
            if (!keep && token != address(0)) {
                uint want = BasketLib.from6(usdAmount, token);
                uint sent = AUX.take(who, want, token, 0);
                if (want != 0 && sent < want)
                    _poolUsdInRange(usdAmount - Math.mulDiv(usdAmount, sent, want), true, basketLeg);
            }
        } else if (usdDelta < 0) {
            usdAmount = uint(-usdDelta);
            _poolUsdInRange(usdAmount, true, basketLeg);
        }
    }

    function _poolUsdInRange(uint usdAmount, bool mint, bool basketLeg) private {
        if (mint) {
            (uint[16] memory _d, ,, uint depegLoss) = AUX.get_deposits();

            uint haircutTvl = _d[15] > depegLoss ? _d[15] - depegLoss : 0;
            POOLED_USD += usdAmount;
            if (basketLeg) basketUsd += usdAmount;

            _reportEquity();
            require(committedUsd18() <= haircutTvl, "backing");
        } else {
            POOLED_USD -= Math.min(usdAmount, POOLED_USD);

            uint b = basketUsd;

            uint out_ = b < usdAmount ? b : usdAmount;
            basketUsd = b - out_;

            _reportEquity();
        }
    }

    function absorbPaidUsd(uint lpOwned6) external onlyUs {
        uint pooled = POOLED_USD;
        uint base = pooled > lpOwned6 ? pooled - lpOwned6 : 0;
        basketUsd = base;
    }

    function poolStats() public view returns (uint priceWad, uint liquidity) {
        priceWad = obsState.lastPrice;
        liquidity = POOLED;
    }

    function _fillDelta(bool inputIsUsd, uint amount, uint px)
        private view returns (Delta memory d, uint out) {

        out = BasketLib.convert(amount, px, inputIsUsd);

        uint held = inputIsUsd
            ? (POOLED)
            : (POOLED_USD);
        if (out > held) {
            out = held;
            amount = BasketLib.convert(out, px, !inputIsUsd);
        }
        d = inputIsUsd ? Delta(-int256(amount), int256(out))
                       : Delta(int256(out), -int256(amount));
    }

    address public observationSource;

    bytes public OBS_CALLDATA;

    int256 public netFlowUsd;

    Flow internal _redeemFlow;

    Flow internal _varSq;
    Flow internal _varDt;
    uint internal _varPx;

    function setObservationSource(address src, bytes calldata call_) external {
        require(msg.sender == DEPLOYER, "403");
        require(observationSource == address(0), "!");
        observationSource = src; OBS_CALLDATA = call_;
    }

    function _observeIfSourced() internal {
        address src = observationSource;

        if (src == address(0)) {

            (uint anchorPx,) = SwapLib.twapResolve(
                AUX.assetPriceFeed(ASSET), 0, VOL_DECIMALS != 18, 0, 1 days);
            if (anchorPx != 0) _writeObservationPrice(anchorPx);
            return;
        }

        (bool ok, bytes memory out) = src.staticcall(OBS_CALLDATA);
        if (!ok || out.length < 32) return;
        uint priceWad = abi.decode(out, (uint));
        if (priceWad != 0) _writeObservationPrice(priceWad);
    }

    function _writeObservationPrice(uint price) internal {
        OracleLib.writeObservation(observations, obsState, price);
    }

    function observe(uint32[] calldata secondsAgos)
        external view returns (uint192[] memory) {
        return OracleLib.observe(observations, obsState, secondsAgos);
    }
}

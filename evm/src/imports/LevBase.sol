// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types, Reentrancy} from "./Types.sol";
import {RangeLib} from "./RangeLib.sol";

import {ILevVenue, ILevPooled, IAux, ICore, IERC20Min, IWeETH, DEFAULT_UNWIND_DEX, VenuePosition, TWAP_WINDOW_SECS} from "./Interfaces.sol";
import {LevMath} from "./LevMath.sol";

abstract contract LevBase {

    uint32 public constant TWAP_WINDOW = TWAP_WINDOW_SECS;

    uint256 public constant TARGET_LTV_CAP_BPS = 7500;

    uint256 internal constant GAS_REBALANCE = 1_250_000;

    function _bandBps(uint256 collUsdWad, ILevVenue venue) internal view returns (uint256) {
        uint256 lltv;

        try venue.liqThresholdBps() returns (uint256 t) { lltv = t; } catch { return 0; }

        uint256 capVenueBasis = (TARGET_LTV_CAP_BPS * 10_000) / (10_000 + TARGET_LTV_CAP_BPS);
        uint256 headroom = lltv > capVenueBasis ? lltv - capVenueBasis : 0;
        return LevMath.bandBpsFor(address(AUX), RANGE, TWAP_WINDOW, GAS_REBALANCE, collUsdWad, headroom);
    }

    function debtDeltaToTarget(address lp) public view returns (bool levUp, uint256 amountUsd) {
        (bool open, uint256 e0, uint256 debtNow, uint256 target) = _targetInputs(lp);
        if (!open) return (false, 0);
        return LevMath.debtDelta(e0, debtNow, target, _bandFor(lp, e0));
    }

    function _bandFor(address lp, uint256 collUsdWad) internal view returns (uint256) {
        Types.Pos memory p = pos[lp];
        return _bandBps(collUsdWad, p.venue);
    }

    function _targetInputs(address lp)
        internal view returns (bool open, uint256 e0, uint256 debtNow, uint256 target)
    {
        Types.Pos memory p = pos[lp];
        if (!p.open) return (false, 0, 0, 0);
        uint256 px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return (true, LevMath.entryEquityUsd(p.entryEquity, px), debtUsd(lp), _ilTargetLive(p, px));
    }

    IAux public immutable AUX;

    address public immutable ORACLE_KEY;

    address public immutable GOV;

    address public immutable QUID;

    IERC20Min public immutable COLL;

    IWeETH internal immutable RATE;

    uint256 public immutable MIN_OPEN;

    uint256 internal constant MAX_SLIPPAGE_BPS = 100;

    bool public venuesFrozen;

    address public flashProvider;

    uint256 private _lock = 1;

    modifier nonReentrant() { _enter(); _; _lock = 1; }
    function _enter() private { if (_lock != 1) revert Reentrancy(); _lock = 2; }

    function _collToBase(uint units) internal view returns (uint) {
        if (units == 0 || address(RATE) == address(0)) return units;
        return RATE.getEETHByWeETH(units);
    }

    mapping(address => Types.Pos) public pos;

    address[] internal _openLps;
    mapping(address => uint256) internal _lpIdx;

    address public RANGE;

    function _unwindDex() internal pure returns (uint256) { return DEFAULT_UNWIND_DEX; }

    event Opened(address indexed lp, address venue, uint256 targetLtvBps);
    event Closed(address indexed lp, uint256 assetReturned);
    event VenueAllowed(address indexed venue, bool ok);
    event DeleverFailed(address indexed lp, uint256 ltvBps);
    event ProtectedFromQuid(address indexed lp, uint256 quidRedeemed, uint256 debtRepaid);
    event ReanchoredToRange(address indexed lp, uint syncKeyPx, uint256 entryEquity);

    error NotOpen();
    error BadTarget();

    constructor(address aux, address oracleKey, address gov, address quid,
                address coll, address rate, uint256 minOpen) {
        AUX = IAux(aux); ORACLE_KEY = oracleKey;
        GOV = gov; QUID = quid; COLL = IERC20Min(coll); RATE = IWeETH(rate); MIN_OPEN = minOpen;
    }

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

    function _requireRebalancable(Types.Pos memory p) internal view virtual {}
    function _leverUp(ILevVenue venue, address lp, address stable, uint256 deltaUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) internal virtual;
    function _delever(ILevVenue venue, address lp, address stable, uint256 deltaUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) internal virtual;

    function _syncRange(address lp) internal {
        if (RANGE != address(0)) { try ICore(RANGE).syncLev(lp) {} catch {} }
    }

    function _rangePrice() internal view returns (uint px) {
        if (RANGE != address(0)) {
            try ICore(RANGE).rangePrice() returns (uint s) { px = s; } catch {}
        }
    }

    function _openPos(ILevVenue venue, uint entryPx, uint entryEquity) internal {

        if (poolVenue == address(0)) poolVenue = address(venue);
        else if (poolVenue != address(venue)) revert VenueNotPooled();

        if (!isPoolVenue[address(venue)]) { isPoolVenue[address(venue)] = true; poolVenues.push(address(venue)); }
        RangeLib.openPos(pos, _openLps, _lpIdx, msg.sender,
            Types.Pos({venue: venue, ilBasisPx: uint128(entryPx),
                       entryEquity: uint128(entryEquity), syncKeyPx: _rangePrice(), open: true}));
    }

    function _untrackOpen(address lp) internal {
        RangeLib.untrackOpen(_openLps, _lpIdx, lp);
    }

    function swapOutDeleverAmt(address lp, uint256 maxUsd18)
        external view returns (address venue, address stable, uint256 amtNative) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return (address(0), address(0), 0);
        venue = address(p.venue);
        stable = p.venue.stable();
        amtNative = LevMath._fromUsd(address(AUX), stable, maxUsd18);
        uint256 debtNative = p.venue.debtOf(lp);
        if (amtNative > debtNative) amtNative = debtNative;
    }

    address public poolVenue;
    error VenueNotPooled();

    address[] public poolVenues;
    mapping(address => bool) public isPoolVenue;

    function poolVenueCount() external view returns (uint256) { return poolVenues.length; }

    function totalDeliverableDollars() external view returns (uint usd) {

        uint256 n = poolVenues.length;
        for (uint256 i; i < n; ++i) {
            VenuePosition memory pp = ILevVenue(poolVenues[i]).position();
            uint collUsd = pp.collateral;
            uint d = pp.debt;
            uint netEq = collUsd > d ? collUsd - d : 0;
            usd += LevMath.deliverableDollars(netEq, collUsd, LevMath.ltvBps(d, collUsd), pp.liqThresholdBps);
        }
    }

    function collValueUsd(uint units) public view returns (uint) {
        if (units == 0) return 0;
        return (_collToBase(units) * AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW)) / 1e18;
    }

    function _collNative(ILevVenue v, address lp) internal view returns (uint) {
        return _collToBase(v.collateralOf(lp));
    }

    function debtUsd(address lp) public view returns (uint) {
        ILevVenue v = pos[lp].venue;
        if (address(v) == address(0)) return 0;
        return LevMath._toUsd18(address(AUX), v.stable(), v.debtOf(lp));
    }

    function _protectFromQuidBody(address lp, uint256 minStableOut) internal returns (uint256 repaid) {
        if (!pos[lp].open) revert NotOpen();
        uint256 pull;
        (pull, repaid) = LevMath.protectExec(

            QUID, address(AUX), address(pos[lp].venue), lp,
            _worstLtvBps(lp), minStableOut);
        _afterProtect(msg.sender);
        emit ProtectedFromQuid(lp, pull, repaid);
    }

    function _afterProtect(address keeper) internal virtual {}

    function getCurrentLtvBps(address lp) public view returns (uint) {
        ILevVenue v = pos[lp].venue;
        if (address(v) == address(0)) return 0;
        VenuePosition memory p = v.positionOf(lp);
        return LevMath.ltvBps(p.debt, p.collateral);
    }

    function _worstLtvBps(address lp) internal view returns (uint) {
        uint a = getCurrentLtvBps(lp); uint b = poolLtvBps();
        return a > b ? a : b;
    }

    function poolLtvBps() public view returns (uint) {
        uint256 n = poolVenues.length;
        uint256 debt; uint256 coll;
        for (uint256 i; i < n; ++i) {
            VenuePosition memory p = ILevVenue(poolVenues[i]).position();
            debt += p.debt; coll += p.collateral;
        }
        return coll == 0 ? 0 : LevMath.ltvBps(debt, coll);
    }

    function ilLtvBps(address lp) public view returns (uint) {
        uint px = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);
        return LevMath.ltvBps(debtUsd(lp), LevMath.entryEquityUsd(pos[lp].entryEquity, px));
    }

    function ilTargetLtvBps(address lp) public view returns (uint) {
        return _ilTargetLive(pos[lp], AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW));
    }

    function _deliverableDollarsAt(address lp) internal view returns (uint) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;

        VenuePosition memory vp = p.venue.positionOf(lp);
        uint netEq = vp.collateral > vp.debt ? vp.collateral - vp.debt : 0;
        return LevMath.deliverableDollars(netEq, vp.collateral,
                                          LevMath.ltvBps(vp.debt, vp.collateral), vp.liqThresholdBps);
    }

    function _netEquityAt(address lp, uint px) internal view returns (uint) {
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        return LevMath.netEquityBase(_collNative(p.venue, lp), debtUsd(lp), px);
    }

    function netEquity(address lp) public view returns (uint256) {
        return _netEquityAt(lp, AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW));
    }

    function deliverableDollars(address lp) public view returns (uint256) {
        return _deliverableDollarsAt(lp);
    }

    function openLevCount() external view returns (uint256) { return _openLps.length; }

    function openLpAt(uint256 i) external view returns (address) { return _openLps[i]; }

    function totalDebtUsd() external view returns (uint256 usd18) {
        uint256 n = poolVenues.length;
        for (uint256 i; i < n; ++i) {
            address v = poolVenues[i];
            usd18 += LevMath._toUsd18(address(AUX), ILevVenue(v).stable(), ILevPooled(v).totalDebt());
        }
    }

    function _ilTargetLive(Types.Pos memory p, uint256 px) internal view returns (uint256) {

        return LevMath.ilTargetBps(p.ilBasisPx, px, uint64(TARGET_LTV_CAP_BPS));
    }

    function grossCollateral(address lp) public view returns (uint256) {
        Types.Pos memory p = pos[lp];
        return p.open ? _collNative(p.venue, lp) : 0;
    }

    function totalGrossCollateral() external view returns (uint256 coll) {
        uint256 n = poolVenues.length;
        for (uint256 i; i < n; ++i) coll += _collNativePool(poolVenues[i]);
    }

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

    function _collNativePool(address v) internal view returns (uint256) {
        return _collToBase(ILevPooled(v).totalCollateral());
    }

    function _reanchorIfReseated(address lp) internal {
        if (!pos[lp].open) return;

        RangeLib.reanchorIfReseated(pos, RANGE, lp, netEquity(lp));
    }
}

error NoPrice();

contract RealRateBtcMorphoOracle {
    address public immutable AUX;
    address public immutable WBTC;
    constructor(address aux, address wbtc) { AUX = aux; WBTC = wbtc; }
    function price() external view returns (uint256) {
        uint256 twap = IAux(AUX).getTWAPforAsset(WBTC, 1800);
        if (twap == 0) revert NoPrice();
        return twap * 1e6;
    }
}

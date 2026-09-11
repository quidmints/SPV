// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RangeLib} from "./imports/RangeLib.sol";
import {Core} from "./Core.sol";
import {Aux} from "./Aux.sol";
import {Basket} from "./Basket.sol";

import {SwapLib} from "./imports/SwapLib.sol";
import {BtcLib} from "./imports/BtcLib.sol";
import {VBtc} from "./VBtc.sol";
import {Types, AlreadyInitialized, BtcChannelsPinned, NotBTCChannels, Unauthorized} from "./imports/Types.sol";
import {Shares} from "./Shares.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ILevEquity} from "./imports/Interfaces.sol";
import {QuidLib} from "./imports/QuidLib.sol";

contract Vault is Ownable, ReentrancyGuard, Shares {

    Core public immutable CORE;
    Aux       internal immutable AUX;

    error NoBtcPosition();

    Basket QUID;

    error ZeroTwap();
    error SwapOutShort();

    address public btcChannels;

    function _onlyUs() private view {
        require(msg.sender == address(AUX)
             || msg.sender == address(CORE)
             || msg.sender == address(this), "403");
    }
    modifier onlyUs { _onlyUs(); _; }

    function _onlyBTCChannels() private view {
        if (msg.sender != btcChannels) revert NotBTCChannels();
    }
    modifier onlyBTCChannels() { _onlyBTCChannels(); _; }

    constructor(address _core, address _aux, address)
        Ownable(msg.sender) {
        CORE = Core(_core);
        AUX = Aux(payable(_aux));
        VBTC = new VBtc(address(this), address(Aux(payable(_aux)).WBTC()));
    }

    receive() external payable {}

    function setup(address _quid) external {
        if (msg.sender != owner()) revert Unauthorized();
        if (address(QUID) != address(0)) revert AlreadyInitialized();
        QUID = Basket(_quid);
        (uint priceWad,) = CORE.poolStats();

        RANGE_ANCHOR = priceWad;
    }

    function _onlyPinner() internal view override { _checkOwner(); }
    function _rangeAsset() internal view override returns (address) { return address(AUX.WBTC()); }

    function totalNetEquity() external view returns (uint) {
        if (LEV_MANAGER == address(0)) return 0;
        try ILevEquity(LEV_MANAGER).totalNetEquity() returns (uint ne) { return ne; } catch { return 0; }
    }

    function setBTCChannels(address b) external onlyUs {
        if (btcChannels != address(0)) revert BtcChannelsPinned();
        btcChannels = b;
    }

    VBtc public immutable VBTC;

    error InsufficientChannelBtc();

    function sharesOf(address lp) external view returns (uint) { return autoManaged[lp].pooled; }

    function transferShares(address from, address to, uint amount) external nonReentrant {
        if (msg.sender != address(VBTC)) revert Unauthorized();
        if (amount > 0) _rebalance();

        if (amount > SwapLib.plainNet(autoManaged[from].pooled, levPooled[from]))
            revert InsufficientChannelBtc();
        lpShares += BtcLib.transferSharesBody(
            autoManaged, levBuf, from, to, amount, feesPerShare, USD_FEES, address(QUID));
    }

    function redeemVBtc(address holder, uint sats) external nonReentrant {
        if (msg.sender != address(VBTC)) revert Unauthorized();
        if (sats == 0 || sats > SwapLib.plainNet(autoManaged[holder].pooled, levPooled[holder]))
            revert InsufficientChannelBtc();
        _resize(holder, sats, sats, false, 0);
    }

    function creditSkewPremium(uint premium6) external onlyUs {
        (, uint usdInc) = SwapLib.feeIncrements(0, premium6, lpShares + totalBuffer);
        USD_FEES += usdInc;
    }

    function levManager() external view returns (address) { return LEV_MANAGER; }

    function sharesForShortfall() external view returns (uint) {
        return totalShares() + totalBuffer;
    }

    function realInventory() external view returns (uint) {
        return CORE.POOLED() + AUX.rangeBTC();
    }

    function onShortfall(address sender, uint shortfall) external onlyUs {
        AUX.btcShortfall(sender, shortfall);
    }

    function deliverVolatile(uint, address) external pure returns (uint) { return 0; }

    function totalShares() public view returns (uint) {
        return lpShares;
    }

    function rangeOf(address lp) external view returns (uint) {
        uint p = autoManaged[lp].pooled;
        uint lev = levPooled[lp];
        return SwapLib.plainNet(p, lev);
    }

    function rangePrice() external view returns (uint priceWad) {
        (priceWad,) = CORE.poolStats();
    }

    function soldFractionWad(uint syncKeyPx) external view returns (uint) {
        (uint priceWad,) = CORE.poolStats();
        return SwapLib.soldFractionWad(syncKeyPx, priceWad, _lo(), _hi());
    }

    function _settleBtcLp(address lpEth, address payTo) internal {

        lpShares += BtcLib.settleBtcLp(autoManaged[lpEth],
            payTo, address(QUID), feesPerShare, USD_FEES,
            autoManaged[lpEth].pooled + levBuf[lpEth]);
    }

    function _rebalance() internal returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint resolvedTwap) {
        BtcLib.RebalOut memory o = BtcLib.rebalanceBody(
            _btcCfg(), _lo(), _hi(), lpShares + totalBuffer);

        feesPerShare += o.feesPerShareInc; USD_FEES += o.usdFeesInc;
        RANGE_ANCHOR = o.spotPrice;
        return (o.spotPrice, o.loPrice, o.upPrice, o.myLiquidity, o.resolvedTwap);
    }

    function requestDeposit(address lpEth, uint sats) external nonReentrant onlyBTCChannels {

        lpShares += BtcLib.requestDeposit(
            _btcCfg(), autoManaged[lpEth],
            lpEth, sats, address(QUID), autoManaged[lpEth].pooled + levBuf[lpEth]);
    }

    function addLiq(uint deltaTok, uint price) public onlyUs returns (uint usdOut, uint outDelta) {
        return BtcLib.addLiqChannel(address(CORE), address(AUX), deltaTok, price);
    }

    function syncLev(address lp) external nonReentrant {
        _syncLev(lp);
    }

    function _syncLev(address lp) internal {

        BtcLib.LevDelta memory d = BtcLib.syncLev(
            _btcCfg(), autoManaged[lp], levPooled, levBufferUsd, levBuf,
            lp, LEV_MANAGER, address(QUID));
        lpShares = lpShares + d.addedNet - d.burnedNet;
        totalBuffer = totalBuffer + d.bufAdded - d.bufBurned;
    }

    function _btcCfg() internal view returns (Types.RangeCfg memory) {
        return Types.RangeCfg({ core: address(CORE), aux: address(AUX), asset: address(AUX.WBTC()) });
    }

    function requestRedeem(address lpEth, uint lpPayoutSats)
        external nonReentrant onlyBTCChannels {
        _resize(lpEth, 0, lpPayoutSats, true, 0);
    }

    function resize(address lpEth, uint shrinkSats, uint lpPayoutSats, uint exactUsd)
        external nonReentrant onlyBTCChannels {
        _resize(lpEth, shrinkSats, lpPayoutSats, false, exactUsd);
    }

    function _resize(address lpEth, uint shrinkSats, uint lpPayoutSats, bool full, uint exactUsd)
        internal {

        _syncLev(lpEth);
        uint delevUsd;
        if (!full && exactUsd > 0 && LEV_MANAGER != address(0))
            delevUsd = SwapLib.deleverOnDelivery(address(CORE), address(AUX), LEV_MANAGER,
                autoManaged, levPooled, lpEth, shrinkSats, lpPayoutSats, exactUsd);
        BtcLib.ResizeOut memory o = BtcLib.resize(
            address(CORE), address(QUID), autoManaged, levPooled, levBuf,
            lpEth, shrinkSats, lpPayoutSats, full, exactUsd - delevUsd);

        lpShares = lpShares + o.feeCompounded - o.sharesRemoved;
        totalBuffer -= o.bufRemoved;
        if (o.cleared) {

            if (lpShares == 0 && totalBuffer == 0) { feesPerShare = 0; USD_FEES = 0; }
        }
    }

    function collectFees() external nonReentrant {
        if (autoManaged[msg.sender].pooled == 0) revert NoBtcPosition();
        _rebalance();
        _syncLev(msg.sender);
        _settleBtcLp(msg.sender, msg.sender);
    }

    function compound(address lp) external nonReentrant {
        if (autoManaged[lp].pooled == 0) return;
        _rebalance();
        _syncLev(lp);
        _settleBtcLp(lp, lp);
    }

    function repack() public onlyUs returns (uint spotPrice,
        uint loPrice, uint upPrice, uint myLiquidity, uint resolvedTwap) {
        return _rebalance();
    }

    function creditSwapIn(address seller, uint sats, address token, uint minDeliveredUsd)
        external onlyBTCChannels returns (uint consumedSats) {

        return SwapLib.creditSwapInBody(seller, sats, token, minDeliveredUsd,
            address(CORE), address(this), address(AUX.WBTC()), address(AUX));
    }

    function creditSwapOut(address swapper, address token, uint usdAmount, uint minSats)
        external onlyBTCChannels returns (uint sats, uint usd6) {
        return SwapLib.creditSwapOutBody(swapper, token, usdAmount, minSats,
            address(CORE), address(AUX));
    }

    function addPendingSwapOut(uint usd6) external onlyBTCChannels { CORE.addPendingSwapOut(usd6); }
    function subPendingSwapOut(uint usd6) external onlyBTCChannels { CORE.subPendingSwapOut(usd6); }

    function rangeBounds() public view returns (uint lo, uint hi) {
        return SwapLib.updateBounds(RANGE_ANCHOR, SwapLib.RANGE_DELTA);
    }

    function _lo() internal view returns (uint) { (uint l,) = rangeBounds(); return l; }
    function _hi() internal view returns (uint) { (, uint h) = rangeBounds(); return h; }

}

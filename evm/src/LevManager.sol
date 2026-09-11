// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AlreadyOpen, NotFlash, VenueNotAllowed, Types} from "./imports/Types.sol";
import {ILevVenue, IERC20Min, ILevPooled, IWeETH, IMorphoBase as IMorphoFlash} from "./imports/Interfaces.sol";
import {LevMath} from "./imports/LevMath.sol";
import {LevBase} from "./imports/LevBase.sol";

import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LevManager is LevBase {
    using SafeERC20 for IERC20OZ;

    address   public immutable WETH;

    event RebalanceFailed(address indexed lp, uint256 ltvBps);

    error NotGov();
    error Slippage();
    error LenMismatch();
    error Auth();

    error NoRepay();

    function _onlyRange() private view { if (msg.sender != RANGE) revert NotGov(); }

    mapping(address => bool) public allowedVenue;

    event FlashProviderSet(address provider);

    receive() external payable {}

    constructor(address weeth, address aux, address weth, address gov, address quid)
        LevBase(aux, weth, gov, quid, weeth, weeth, 0.05 ether) { WETH = weth; }

    function init(address range, address flash, address[] calldata venues) external {
        if (msg.sender != GOV || venuesFrozen) revert VenueNotAllowed();
        venuesFrozen = true;
        RANGE = range;
        flashProvider = flash;
        emit FlashProviderSet(flash);
        for (uint i; i < venues.length; i++) {
            address v = venues[i];

            if (LevMath.vetVenue(v, WETH, WETH, _coll())) revert VenueNotAllowed();
            allowedVenue[v] = true; emit VenueAllowed(v, true);
        }
    }

    function _coll() private view returns (address) { return address(COLL); }
    function _px()   private view returns (uint256) { return AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW); }

    function _supplyCollFrom(ILevVenue venue, address lp, uint256 amount) internal {
        address collTok = _coll();
        IERC20Min(collTok).transferFrom(lp, address(this), amount);
        IERC20Min(collTok).transfer(address(venue), amount);
        venue.supply(lp, amount);
    }

    function netEquityUsd(address lp) external view returns (uint256) {
        if (!pos[lp].open) return 0;
        ILevVenue v = pos[lp].venue;
        uint256 coll = collValueUsd(v.collateralOf(lp));
        uint256 d = debtUsd(lp);
        return coll > d ? coll - d : 0;
    }

    function protectFromQuid(address lp, uint256 minStableOut) external nonReentrant returns (uint256) {
        return _protectFromQuidBody(lp, minStableOut);
    }

    function _afterProtect(address keeper) internal override { _reimburseKeeper(keeper, 0); }

    function openLev(ILevVenue venue, uint256 collWeeth)
        external nonReentrant
    {
        if (pos[msg.sender].open) revert AlreadyOpen();

        LevMath.requireOpenable(allowedVenue[address(venue)], address(AUX), address(venue));
        if (collWeeth < MIN_OPEN) revert BadTarget();

        uint256 entryPx = _px();

        uint256 entryEquity = _collToBase(collWeeth);

        _openPos(venue, entryPx, entryEquity);

        _supplyCollFrom(venue, msg.sender, collWeeth);

        emit Opened(msg.sender, address(venue), TARGET_LTV_CAP_BPS);
    }

    function rebalance(address lp, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) external nonReentrant {
        _activeKeeper = msg.sender;
        _rebalance(lp, minOut, dex, dex2, route);
    }

    function rebalanceMany(address[] calldata lps, uint256[] calldata minOuts, uint256[] calldata dexes,
                           uint256[] calldata dex2s, bytes[] calldata routes) external nonReentrant {
        _batch(lps, minOuts, dexes, dex2s, routes, true);
    }

    function _batch(address[] calldata lps, uint256[] calldata minOuts, uint256[] calldata dexes,
                    uint256[] calldata dex2s, bytes[] calldata routes, bool up)
        private
    {
        if (lps.length != minOuts.length || lps.length != dexes.length) revert LenMismatch();

        if ((dex2s.length != 0 && dex2s.length != lps.length)
         || (routes.length != 0 && routes.length != lps.length)) revert LenMismatch();

        _activeKeeper = msg.sender;
        for (uint256 i; i < lps.length; i++) {
            address lp = lps[i];
            if (!pos[lp].open) continue;
            uint256 d2  = dex2s.length  == 0 ? 0 : dex2s[i];
            bytes memory r = routes.length == 0 ? bytes("") : routes[i];
            if (up) {
                try this.rebalanceOne(lp, minOuts[i], dexes[i], d2, r) {}
                catch { emit RebalanceFailed(lp, getCurrentLtvBps(lp)); }
            } else {
                try this.deleverOne(lp, minOuts[i], dexes[i], d2, r) {}
                catch { emit DeleverFailed(lp, getCurrentLtvBps(lp)); }
            }
        }
    }

    function rebalanceOne(address lp, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) external {
        if (msg.sender != address(this) && msg.sender != lp) revert Auth();
        _rebalance(lp, minOut, dex, dex2, route);
    }

    function _leverUp(ILevVenue venue, address lp, address stable, uint256 deltaUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route)
        internal override { _leverUpBuy(venue, lp, stable, deltaUsd, minOut, dex, dex2, route); }

    function _delever(ILevVenue venue, address lp, address stable, uint256, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route)
        internal override { _deleverFlash(venue, lp, stable, deleverRepayUsd(lp), minOut, dex, dex2, route); }

    function deleverOne(address lp, uint256 minOut, uint256 dex, uint256 dex2, bytes calldata route) external {
        _deleverOne(lp, minOut, dex, dex2, route);
    }

    function _deleverOne(address lp, uint256 minOut, uint256 dex, uint256 dex2, bytes memory route) internal {
        if (msg.sender != address(this) && msg.sender != lp) revert Auth();
        Types.Pos memory p = pos[lp];
        if (!p.open) return;
        uint256 repayUsd = deleverRepayUsd(lp);
        if (repayUsd == 0) return;
        uint256 debtBefore = p.venue.debtOf(lp);

        _deleverFlash(p.venue, lp, p.venue.stable(), repayUsd, minOut, dex, dex2, route);
        if (p.venue.debtOf(lp) >= debtBefore) revert NoRepay();
        emit Rebalanced(lp, false, 0, getCurrentLtvBps(lp));

        _syncRange(lp);
    }

    function cascadeDelever(address[] calldata lps, uint256[] calldata minOuts, uint256[] calldata dexes,
                            uint256[] calldata dex2s, bytes[] calldata routes) external nonReentrant {
        _batch(lps, minOuts, dexes, dex2s, routes, false);
    }

    function closeLev(uint256 minOut, uint256 dex) external nonReentrant {
        _closeLev(msg.sender, minOut, false, dex);
    }

    function closeLevFor(address lp, uint256 minOut) external nonReentrant {
        _onlyRange();
        _closeLev(lp, minOut, true, _unwindDex());
    }

    function _closeLev(address lp, uint256 minOut, bool keepState, uint256 dex) internal {
        Types.Pos storage p = pos[lp];
        if (!p.open) revert NotOpen();
        ILevVenue venue = p.venue;
        address stable = venue.stable();

        venue.accrue();
        uint256 d = debtUsd(lp);

        uint256 debtBefore = venue.debtOf(lp);

        if (d > 0) _deleverFlash(venue, lp, stable, d + 1, minOut, dex, 0, "");
        if (debtBefore > 0 && venue.debtOf(lp) >= debtBefore) revert NoRepay();
        uint256 remaining = venue.collateralOf(lp);
        uint256 back = remaining > 0 ? venue.withdraw(lp, remaining) : 0;
        if (back > 0) IERC20Min(_coll()).transfer(lp, back);

        if (keepState) p.open = false; else delete pos[lp];
        _untrackOpen(lp);

        _syncRange(lp);
        emit Closed(lp, back);
    }

    function deleverRepayUsd(address lp) internal view returns (uint256) {
        (bool open, uint256 e0, uint256 debtNow, uint256 target) = _targetInputs(lp);
        if (!open) return 0;

        return LevMath.deleverRepay(e0, debtNow, target, _bandFor(lp, e0));
    }

    function _deleverFlash(ILevVenue venue, address lp, address stable, uint256 repayUsd, uint256 minOut, uint256 dex, uint256 dex2, bytes memory route) internal {

        LevMath.deleverFlashBody(_extractCfg(), venue, lp, stable, repayUsd, minOut, dex, dex2, route);
    }

    uint256 private transient _lastFreed;

    function _extractCfg() internal view returns (LevMath.ExtractCfg memory) {
        return LevMath.ExtractCfg({ weth: WETH, weeth: _coll(), aux: address(AUX),
            flashProvider: flashProvider, keeper: _activeKeeper, gasReserve: gasReserve,

            maxSlippageBps: uint16(MAX_SLIPPAGE_BPS), dex: 0, dex2: 0, route: "" });
    }

    function deleverToVault(address lp, uint256 extractUsd, address vault, uint256 minOut)
        external returns (uint256 freed)
    {
        if (msg.sender != RANGE && msg.sender != address(this)) revert NotGov();
        Types.Pos memory p = pos[lp];
        if (!p.open || extractUsd == 0 || flashProvider == address(0)) return 0;
        uint256 cap = deliverableDollars(lp);

        if (extractUsd > cap) extractUsd = cap;
        if (extractUsd == 0) return 0;

        uint256 repayStable = LevMath.sizeRepayStable(
            p.venue, lp, extractUsd, debtUsd(lp), _px(), _coll(), address(AUX));
        if (repayStable == 0) return 0;

        address stable = p.venue.stable();

        IMorphoFlash(flashProvider).flashLoan(stable, repayStable,
            abi.encode(uint8(2), lp, address(p.venue),
            stable, extractUsd, vault, minOut));

        freed = LevMath._toUsd18(address(AUX), stable, _lastFreed); _lastFreed = 0;

        _syncRange(lp);
    }

    function swapOutDeliverUnlevered(address lp, uint256 wethWanted, address recipient, uint256 minWethOut)
        external nonReentrant returns (uint256 wethDelivered) {
        _onlyRange();
        Types.Pos memory p = pos[lp];
        if (!p.open || wethWanted == 0) return 0;
        if (p.venue.debtOf(lp) != 0) return 0;

        wethDelivered = LevMath.swapOutDeliverUnleveredBody(p.venue, lp, wethWanted, recipient, minWethOut, _extractCfg());
        _syncRange(lp);
    }

    function swapOutDeleverPooled(address venue, uint256 stableUsd, address recipient,
                                  uint256 minWethOut, uint256 askNative)
        external nonReentrant returns (uint256 usedUsd, uint256 wethDelivered) {
        _onlyRange();
        if (stableUsd == 0) return (0, 0);
        address stable = ILevVenue(venue).stable();
        uint256 repaid = ILevPooled(venue).repayPool(LevMath._fromUsd(address(AUX), stable, stableUsd));
        if (repaid == 0) return (0, 0);
        usedUsd = LevMath._toUsd18(address(AUX), stable, repaid);

        if (askNative == 0) return (usedUsd, 0);

        uint256 freeWeeth = IWeETH(_coll())
            .getWeETHByeETH((askNative * usedUsd) / stableUsd);
        uint256 got = ILevPooled(venue).withdrawPool(freeWeeth);
        if (got > 0) wethDelivered = LevMath.collToWethDeliver(got, recipient, minWethOut, _extractCfg());
    }

    function deleverBook(uint256 usdWanted, address sink, uint256 minOut)
        external nonReentrant returns (uint256 freed)
    {
        _onlyRange();

        if (poolVenue == address(0)) return 0;
        uint256 cap = this.totalDeliverableDollars();
        uint256 want = usdWanted > cap ? cap : usdWanted;
        if (want == 0) return 0;

        if (_openLps.length == 0) return 0;
        try this.deleverToVault(_openLps[0], want, sink, minOut) returns (uint256 f) { freed = f; }
        catch {  }
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != flashProvider) revert NotFlash();

        (uint8 mode, address lp, address venueAddr, address stable, uint256 last) =
            abi.decode(data, (uint8, address, address, address, uint256));
        if (mode == 2) { _extractSettle(assets, data); return; }
        _deleverSettle(assets, lp, venueAddr, stable, last, data);
    }

    function _extractSettle(uint256 assets, bytes calldata data) internal {
        (, address lp, address venueAddr, address stable, uint256 extractUsd, address vault, uint256 minOut2) =
            abi.decode(data, (uint8, address, address, address, uint256, address, uint256));
        (gasReserve, _lastFreed) = LevMath.extractToVaultBody(
            assets, lp, venueAddr, stable, extractUsd, address(this), minOut2,
            _extractCfg());
        extractUsd = LevMath._fromUsd(address(AUX), stable, extractUsd);
        if (_lastFreed > extractUsd) {

            IERC20OZ(stable).safeTransfer(lp, _lastFreed - extractUsd);
            _lastFreed = extractUsd;
        }
        if (_lastFreed > 0) IERC20OZ(stable).safeTransfer(vault, _lastFreed);
    }

    function _deleverSettle(uint256 assets, address lp, address venueAddr, address stable, uint256 last, bytes calldata data) internal {

        gasReserve = LevMath.deleverSettleBody(assets, lp, venueAddr, stable, last,
            _px(), _extractCfg(), data);
    }

    function _sellCtx(address keeper, uint256 dex, uint256 dex2, bytes memory route) internal view returns (LevMath.SellCtx memory) {
        return LevMath.SellCtx({ weth: WETH, weeth: _coll(), aux: address(AUX), keeper: keeper, reserveIn: gasReserve, dex: dex, dex2: dex2, route: route });
    }

    function _leverUpBuy(ILevVenue venue, address who, address stable, uint256 usd, uint256 minOut, uint256 dex, uint256 dex2, bytes memory route) internal {
        uint256 coll = LevMath.stableToColl(
            _sellCtx(address(0), dex, dex2, route), stable, venue.borrow(who, LevMath._fromUsd(address(AUX),stable, usd)), minOut);
        IERC20Min(_coll()).transfer(address(venue), coll);
        venue.supply(who, coll);
    }

    uint256 public gasReserve;
    function fundGasReserve(uint256 amount) external {
        if (amount == 0) return;
        IERC20Min(WETH).transferFrom(msg.sender, address(this), amount);
        gasReserve += amount;
    }

    address private transient _activeKeeper;

    function _reimburseKeeper(address keeper, uint256 availWeth) internal returns (uint256 skimmed) {
        (skimmed, gasReserve) = LevMath.reimburseKeeper(WETH, keeper, availWeth, gasReserve);
    }

}

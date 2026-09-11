// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AlreadyOpen, NotFlash, Types} from "./imports/Types.sol";
import {IVaultExposeB, IVBtcToken, ILevVenue, IERC20Min, IMorphoBase as IMorphoFlash} from "./imports/Interfaces.sol";
import {BtcLib} from "./imports/BtcLib.sol";
import {LevBase} from "./imports/LevBase.sol";
import {LevMath} from "./imports/LevMath.sol";

import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BtcLevManager is LevBase {
    using SafeERC20 for IERC20OZ;
    address public immutable WBTC;

    address public immutable VAULT;

    mapping(address => bool) public allowedVenue;

    function init(address range, address flash, address[] calldata venues) external {
        if (msg.sender != GOV || venuesFrozen) revert BadAuth();

        if (flash == address(0)) revert BadAuth();
        venuesFrozen = true; RANGE = range; flashProvider = flash;
        for (uint i; i < venues.length; i++) {
            address v = venues[i];
            if (v == address(0)) revert BadAuth();

            if (LevMath.vetVenue(v, WBTC, address(COLL), WBTC)) revert BadAuth();
            allowedVenue[v] = true; emit VenueAllowed(v, true);
        }
    }

    event Borrowed(address indexed lp, uint stableOut);
    event Supplied(address indexed lp, uint vbtcIn);
    event Withdrawn(address indexed lp, uint vbtcOut);
    event Repaid(address indexed lp, uint stableIn);

    error BadAuth();

    error WbtcSliceNotDeliverable();

    constructor(address vbtc, address aux, address wbtc, address gov, address quid)
        LevBase(aux, wbtc, gov, quid, vbtc, address(0), 50_000) {
        VAULT = IVBtcToken(vbtc).VAULT(); WBTC = wbtc;
    }

    function protectFromQuid(address lp, uint256 minStableOut) external nonReentrant returns (uint256) {
        return _protectFromQuidBody(lp, minStableOut);
    }

    function openBtcLev(uint initialVbtc, ILevVenue venue) external nonReentrant {
        if (pos[msg.sender].open) revert AlreadyOpen();

        LevMath.requireOpenable(allowedVenue[address(venue)], address(AUX), address(venue));
        if (initialVbtc < MIN_OPEN) revert BadTarget();

        uint entryPx = AUX.getTWAPforAsset(ORACLE_KEY, TWAP_WINDOW);

        uint entryEquity = initialVbtc;

        _openPos(venue, entryPx, entryEquity);

        if (ILevVenue(address(venue)).COLLATERAL() == address(COLL)) {
            IVaultExposeB(VAULT).exposeBtcToLev(msg.sender, initialVbtc);
            COLL.transfer(address(venue), initialVbtc);
        } else {
            IERC20Min(WBTC).transferFrom(msg.sender, address(venue), initialVbtc);
        }
        venue.supply(msg.sender, initialVbtc);
        emit Opened(msg.sender, address(venue), TARGET_LTV_CAP_BPS);
    }

    function leverBorrow(uint stableUsd) external nonReentrant returns (uint got) {
        _reanchorIfReseated(msg.sender);
        (bool levUp, uint room) = debtDeltaToTarget(msg.sender);
        got = BtcLib.leverBorrow(pos, address(AUX), msg.sender, stableUsd, levUp, room);
        _syncRange(msg.sender);
    }

    function leverSupply(uint vbtc) external nonReentrant {
        BtcLib.leverSupply(pos, address(COLL), msg.sender, vbtc);
        _syncRange(msg.sender);
    }

    function deleverWithdraw(uint vbtc) external nonReentrant returns (uint out) {
        _reanchorIfReseated(msg.sender);
        out = BtcLib.deleverWithdraw(pos, address(COLL), msg.sender, vbtc);
        _syncRange(msg.sender);
    }

    function repay(uint stableUsd) external nonReentrant returns (uint repaid) {
        repaid = BtcLib.repay(pos, address(AUX), msg.sender, stableUsd);
        _syncRange(msg.sender);
    }

    function rebalanceWbtc(address lp, uint minOut, uint256 dex, uint256 dex2, bytes calldata route)
        external nonReentrant { _rebalance(lp, minOut, dex, dex2, route); }

    function _requireRebalancable(Types.Pos memory p) internal view override {
        if (ILevVenue(address(p.venue)).COLLATERAL() != WBTC) revert BadTarget();
    }

    function _leverUp(ILevVenue venue, address lp, address stable, uint deltaUsd, uint minOut, uint256 dex, uint256 dex2, bytes calldata route)
        internal override { _leverUpBuyWbtc(venue, lp, stable, deltaUsd, minOut, dex, dex2, route); }

    function _delever(ILevVenue venue, address lp, address stable, uint deltaUsd, uint minOut, uint256 dex, uint256 dex2, bytes calldata route)
        internal override {
        _flashDeleverWbtc(venue, lp, stable, deltaUsd, minOut, dex, dex2, route);
    }

    function _leverUpBuyWbtc(ILevVenue venue, address lp, address stable, uint usd, uint minOut, uint256 dex, uint256 dex2, bytes memory route) internal {
        (uint borrowed, uint wbtc) = LevMath.leverUpBuyWbtc(venue, lp, stable, usd, minOut, LevMath.WbtcCfg(address(AUX), WBTC, uint32(TWAP_WINDOW), uint16(MAX_SLIPPAGE_BPS), dex, dex2, route));
        if (borrowed > 0) { emit Borrowed(lp, borrowed); emit Supplied(lp, wbtc); }
    }

    function _flashDeleverWbtc(ILevVenue venue, address lp, address stable, uint repayUsd, uint minOut, uint256 dex, uint256 dex2, bytes memory route) internal {
        if (repayUsd == 0) return;

        IMorphoFlash(flashProvider).flashLoan(stable, LevMath._fromUsd(address(AUX),stable, repayUsd),
            abi.encode(lp, address(venue), stable, minOut, dex, dex2, route));
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != flashProvider) revert NotFlash();

        (address lp, address venueAddr, address stable, uint minOut, uint256 dex, uint256 dex2, bytes memory route) =
            abi.decode(data, (address, address, address, uint256, uint256, uint256, bytes));
        LevMath.flashDeleverWbtcSettle(assets, lp, venueAddr, stable, minOut, flashProvider,
            LevMath.WbtcCfg(address(AUX), WBTC, uint32(TWAP_WINDOW), uint16(MAX_SLIPPAGE_BPS), dex, dex2, route));
        emit Repaid(lp, assets);
        _syncRange(lp);
    }

    function consolidateForRepay(address lp, address refundTo)
        external nonReentrant returns (uint sent) {
        if (msg.sender != RANGE) revert BadAuth();
        Types.Pos memory p = pos[lp];
        if (!p.open) return 0;
        address stable = p.venue.stable();
        LevMath._consolidateTo(address(AUX), stable, refundTo);
        sent = IERC20OZ(stable).balanceOf(address(this));
        if (sent > 0) IERC20OZ(stable).safeTransfer(address(p.venue), sent);
    }

    function swapOutDelever(address lp, uint stableUsd, uint freeSats)
        external nonReentrant returns (uint usedUsd, uint freedSats) {
        if (msg.sender != RANGE) revert BadAuth();
        Types.Pos memory p = pos[lp];
        if (!p.open) return (0, 0);

        uint amt = LevMath._fromUsd(address(AUX),p.venue.stable(), stableUsd);
        uint debt = p.venue.debtOf(lp);

        if (amt > debt) amt = debt;
        if (amt > 0) {
            uint repaid = p.venue.repay(lp, amt);
            usedUsd = LevMath._toUsd18(address(AUX),p.venue.stable(), repaid);
        }
        freedSats = freeSats;
        uint coll = p.venue.collateralOf(lp);
        if (freedSats > coll) freedSats = coll;
        if (freedSats > 0) {

            if (p.venue.COLLATERAL() != address(COLL)) revert WbtcSliceNotDeliverable();
            uint got = p.venue.withdraw(lp, freedSats);
            if (got != freedSats) freedSats = got;

            if (freedSats > 0) IVaultExposeB(VAULT).unexposeBtcFromLev(lp, freedSats);
        }
    }

    function closeBtcLev() external nonReentrant {
        address lp = msg.sender;
        Types.Pos memory p = pos[lp];
        if (!p.open) revert NotOpen();
        if (p.venue.debtOf(lp) != 0) revert BadTarget();

        _syncRange(lp);
        uint rem = p.venue.collateralOf(lp);
        uint back = rem > 0 ? p.venue.withdraw(lp, rem) : 0;
        delete pos[lp];
        _untrackOpen(lp);

        if (p.venue.COLLATERAL() == address(COLL)) {

            if (back > 0) IVaultExposeB(VAULT).unexposeBtcFromLev(lp, back);
        } else {

            if (back > 0) IERC20Min(WBTC).transfer(lp, back);
            _syncRange(lp);
        }
        emit Closed(lp, back);
    }

}

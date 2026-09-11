// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILevVenue, IERC20Min, IIrm, MorphoMarket,
        VenuePosition, IOracle} from "./Interfaces.sol";
import {IMorphoStaticTyping as IMorpho, MarketParams, Id, MarketParamsLib} from "./Interfaces.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {IERC20 as IERC20OZ} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract LevVenueBase is ILevVenue {
    using SafeERC20 for IERC20OZ;

    function accrue() external virtual override {}

    uint256 internal constant UNIT_OFFSET = 1e6;

    mapping(address => uint256) internal collUnits;
    uint256 internal totalCollUnits;
    mapping(address => uint256) internal debtUnits;
    uint256 internal totalDebtUnits;

    function _mintUnits(uint256 amt, uint256 tot, uint256 bal) internal pure returns (uint256) {
        return SoladyMath.fullMulDiv(amt, tot + UNIT_OFFSET, bal + 1);
    }

    function _burnUnits(uint256 amt, uint256 tot, uint256 bal) internal pure returns (uint256) {
        return _mintUnits(amt, tot, bal);
    }

    function _to18(uint256 amt, uint8 dec) internal pure returns (uint256) {
        return dec >= 18 ? amt / (10 ** (dec - 18)) : amt * (10 ** (18 - dec));
    }

    function positionOf(address lp) external view returns (VenuePosition memory p) {
        VenuePosition memory pool = position();
        p.collateral      = _unitSlice(collUnits[lp], totalCollUnits, pool.collateral);
        p.debt            = _unitSlice(debtUnits[lp], totalDebtUnits, pool.debt);
        p.liqThresholdBps = pool.liqThresholdBps;
    }

    function position() public view virtual returns (VenuePosition memory);

    function _unitSlice(uint256 u, uint256 tot, uint256 bal) internal pure returns (uint256) {
        return u == 0 ? 0 : SoladyMath.fullMulDiv(u, bal + 1, tot + UNIT_OFFSET);
    }

    address internal immutable MANAGER;
    address internal immutable STABLE;

    error VenueCannotFund();

    uint256 private _lock = 1;
    modifier nonReentrant() { require(_lock == 1, "reentrant"); _lock = 2; _; _lock = 1; }
    modifier onlyManager() { require(msg.sender == MANAGER, "auth"); _; }

    constructor(address manager, address stable_) { MANAGER = manager; STABLE = stable_; }

    function stable() external view returns (address) { return STABLE; }
}

contract MorphoEscrowVenue is LevVenueBase {
    using SafeERC20 for IERC20OZ;

    IMorpho public immutable MORPHO;
    address public immutable COLLATERAL;
    Id public immutable MARKET_ID;
    uint256 public immutable LLTV;

    address private immutable ORACLE;
    address private immutable IRM;

    function _poolColl() internal view returns (uint256) {
        (,, uint128 c) = MORPHO.position(MARKET_ID, address(this));
        return uint256(c);
    }

    function _poolShares() internal view returns (uint256) {
        (, uint128 bs,) = MORPHO.position(MARKET_ID, address(this));
        return uint256(bs);
    }

    constructor(address morpho, MarketParams memory m, address manager) LevVenueBase(manager, m.loanToken) {
        MORPHO = IMorpho(morpho);
        COLLATERAL = m.collateralToken;
        ORACLE = m.oracle;
        IRM = m.irm;
        LLTV = m.lltv;
        MARKET_ID = MarketParamsLib.id(m);
    }

    function _params() internal view returns (MarketParams memory) {
        return MarketParams({ loanToken: STABLE, collateralToken: COLLATERAL, oracle: ORACLE, irm: IRM, lltv: LLTV });
    }

    function repayFor(address lp, uint256 amount) external nonReentrant returns (uint256 repaid) {
        if (amount == 0) return 0;
        uint256 d = debtOf(lp);
        uint256 r = amount > d ? d : amount;
        if (r == 0) return 0;
        IERC20OZ(STABLE).safeTransferFrom(msg.sender, address(this), r);

        repaid = _repayCreditingLp(lp, r);
    }

    function accrue() external override { MORPHO.accrueInterest(_params()); }

    function supply(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;
        IERC20Min(COLLATERAL).approve(address(MORPHO), collAmount);

        uint256 before = _poolColl();
        MORPHO.supplyCollateral(_params(), collAmount, address(this), "");

        uint256 mint = _mintUnits(collAmount, totalCollUnits, before);
        collUnits[lp] += mint; totalCollUnits += mint;
        return collAmount;
    }

    function borrow(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        if (stableAmount == 0) return 0;

        uint256 before = _poolShares();
        (uint256 got, uint256 sharesUp) = MORPHO.borrow(_params(), stableAmount, 0, address(this), address(this));

        uint256 mint = _mintUnits(sharesUp, totalDebtUnits, before);
        debtUnits[lp] += mint; totalDebtUnits += mint;
        if (got > 0) IERC20OZ(STABLE).safeTransfer(MANAGER, got);
        return got;
    }

    function repay(address lp, uint256 stableAmount) external onlyManager nonReentrant returns (uint256) {
        if (stableAmount == 0) return 0;
        MORPHO.accrueInterest(_params());
        uint256 d = debtOf(lp);
        uint256 r = stableAmount > d ? d : stableAmount;
        if (r == 0) return 0;
        return _repayCreditingLp(lp, r);
    }

    function _repayCreditingLp(address lp, uint256 r) private returns (uint256 repaid) {
        uint256 before = _poolShares();
        uint256 sharesDown;
        uint256 mine = _unitSlice(debtUnits[lp], totalDebtUnits, before);
        uint256 need = mine == 0 ? 0 : _sharesToAssetsUp(mine);
        bool byShares;
        if (mine > 0 && r >= need && IERC20Min(STABLE).balanceOf(address(this)) >= need) {
            IERC20OZ(STABLE).forceApprove(address(MORPHO), need);
            (repaid, sharesDown) = MORPHO.repay(_params(), 0, mine, address(this), "");
            IERC20OZ(STABLE).forceApprove(address(MORPHO), 0);
            byShares = true;
        } else {
            IERC20OZ(STABLE).forceApprove(address(MORPHO), r);
            (repaid, sharesDown) = MORPHO.repay(_params(), r, 0, address(this), "");
        }

        uint256 burn;
        if (byShares) {
            burn = debtUnits[lp];
        } else {
            burn = _burnUnits(sharesDown, totalDebtUnits, before);
            if (burn > debtUnits[lp]) burn = debtUnits[lp];
        }
        debtUnits[lp] -= burn; totalDebtUnits -= burn;
    }

    error RepayNotApplied();

    function repayPool(uint256 stableAmount) external onlyManager nonReentrant returns (uint256 repaid) {
        if (stableAmount == 0) return 0;

        MORPHO.accrueInterest(_params());
        uint256 d = totalDebt();
        uint256 r = stableAmount > d ? d : stableAmount;
        if (r == 0) return 0;
        IERC20OZ(STABLE).forceApprove(address(MORPHO), r);
        (repaid,) = MORPHO.repay(_params(), r, 0, address(this), "");

        if (repaid > 0 && totalDebt() >= d) revert RepayNotApplied();
    }

    function withdraw(address lp, uint256 collAmount) external onlyManager nonReentrant returns (uint256) {
        if (collAmount == 0) return 0;

        uint256 bal = collateralOf(lp);
        uint256 w = collAmount > bal ? bal : collAmount;
        if (w == 0) return 0;
        {
            uint256 pc = _poolColl();
            uint256 burn = _burnUnits(w, totalCollUnits, pc);
            if (burn > collUnits[lp]) burn = collUnits[lp];
            collUnits[lp] -= burn; totalCollUnits -= burn;
        }
        uint256 before = IERC20Min(COLLATERAL).balanceOf(address(this));
        MORPHO.withdrawCollateral(_params(), w, address(this), address(this));
        uint256 got = IERC20Min(COLLATERAL).balanceOf(address(this)) - before;
        if (got > 0) IERC20Min(COLLATERAL).transfer(MANAGER, got);
        return got;
    }

    function debtOf(address lp) public view returns (uint256) {
        uint256 u = debtUnits[lp];
        if (u == 0 || totalDebtUnits == 0) return 0;

        return _sharesToAssetsUp(_unitSlice(u, totalDebtUnits, _poolShares()));
    }

    function totalDebt() public view returns (uint256) { return _sharesToAssetsUp(_poolShares()); }

    function _sharesToAssetsUp(uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(MARKET_ID);
        if (totalBorrowShares == 0) return 0;
        uint256 num = shares * uint256(totalBorrowAssets);
        return (num + uint256(totalBorrowShares) - 1) / uint256(totalBorrowShares);
    }

    function collateralOf(address lp) public view returns (uint256) {
        return _unitSlice(collUnits[lp], totalCollUnits, _poolColl());
    }

    function totalCollateral() external view returns (uint256) { return _poolColl(); }

    function withdrawPool(uint256 collAmount) external onlyManager nonReentrant returns (uint256 got) {
        uint256 pc = _poolColl();
        uint256 w = collAmount > pc ? pc : collAmount;
        if (w == 0) return 0;
        uint256 before = IERC20Min(COLLATERAL).balanceOf(address(this));
        MORPHO.withdrawCollateral(_params(), w, address(this), address(this));
        got = IERC20Min(COLLATERAL).balanceOf(address(this)) - before;
        if (got > 0) IERC20Min(COLLATERAL).transfer(MANAGER, got);
    }

    function supplyHeadroom() external pure returns (uint256) { return type(uint256).max; }

    function position() public view override returns (VenuePosition memory p) {
        (, uint128 borrowShares, uint128 coll) = MORPHO.position(MARKET_ID, address(this));
        uint8 dec = IERC20Min(STABLE).decimals();
        uint256 collInLoan = SoladyMath.fullMulDiv(uint256(coll), IOracle(ORACLE).price(), 1e36);
        p = VenuePosition({
            collateral: _to18(collInLoan, dec),
            debt: _to18(_sharesToAssetsUp(borrowShares), dec),
            liqThresholdBps: LLTV / 1e14 });
    }

    function borrowRateRay(uint256 extraBorrow) external view returns (uint256) {
        (uint128 tsa, uint128 tss, uint128 tba, uint128 tbs, uint128 lu, uint128 fee)
            = MORPHO.market(MARKET_ID);

        uint256 newDebt = uint256(tba) + extraBorrow;
        if (newDebt > tsa) revert VenueCannotFund();
        tba = uint128(newDebt);
        uint256 perSec = IIrm(IRM).borrowRateView(
            _params(), MorphoMarket(tsa, tss, tba, tbs, lu, fee));
        return perSec * 365 days * 1e9;
    }

    function liqThresholdBps() external view returns (uint256) {
        return LLTV / 1e14;
    }
}

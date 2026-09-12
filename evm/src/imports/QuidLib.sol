// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "./Types.sol";

import {IVaultV2} from "./Interfaces.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {SwapLib} from "./SwapLib.sol";
import {LevMath} from "./LevMath.sol";
import {IWETH9} from "./Interfaces.sol";
import {ICore} from "./Interfaces.sol";
import {Types} from "./Types.sol";
import {RangeLib} from "./RangeLib.sol";
import {ILevEquity} from "./Interfaces.sol";
import {IEthVenue} from "./Interfaces.sol";
import {IAux} from "./Interfaces.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IEtherFiLiquidityPool} from "./Interfaces.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IWeETH} from "./Interfaces.sol";
import {ICurvePool} from "./Interfaces.sol";
import {IDepositAdapter} from "./Interfaces.sol";

library QuidLib {

    error VenueUnavailable();

    function _supplyEtherFi(address ev, uint amount) private returns (uint placed) {
        placed = IEthVenue(ev).supplyEtherFi(amount);
    }

    error InsufficientBalance();

    function levManager(address aux) public view returns (address) {
        address host = aux == address(0) ? address(0) : IAux(aux).ethVenue();
        return host == address(0) ? address(0) : IEthVenue(host).LEV_MANAGER();
    }
    function reconcileLegs(
        Types.RangeCfg memory c, Types.Deposit storage LP,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBufferUsd,
        mapping(address => uint) storage levBuf,
        address lp, Types.RangeP memory p
    ) public returns (uint addedNet, uint burnedNet, uint bufAdded, uint bufBurned) {
        if (levPooled[lp] > 0 || levBuf[lp] > 0)
            (burnedNet, bufBurned) = RangeLib.levBurnAll(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
        if (p.gross > 0)
            (addedNet, bufAdded) = RangeLib.levAddGross(c, LP, levPooled, levBufferUsd, levBuf, lp, p);
    }

    function depositETH(
        address weth, address aux, address ev,
        address sender, uint amount
    ) public returns (uint sent) {
        if (msg.value > 0) {
            IWETH9(weth).deposit{value: msg.value}();
            sent = msg.value; amount -= Math.min(amount, msg.value);
        }
        if (amount > 0) {
            uint available = Math.min(
                IWETH9(weth).allowance(sender, address(this)),
                IWETH9(weth).balanceOf(sender));
            uint took = Math.min(amount, available);
            if (took > 0) { IWETH9(weth).transferFrom(sender, address(this), took); sent += took; }
        }
        if (sent > 0) {

            uint toDeposit = IWETH9(weth).balanceOf(address(this));
            IWETH9(weth).approve(aux, toDeposit);
            uint placed = _supplyEtherFi(ev, toDeposit);
            if (placed == 0) revert VenueUnavailable();
        }
    }

    function addLiq(address core, address aux, uint wantTok, uint price, uint grossBuffer)
        public returns (uint usdOut, uint outDelta) {

        return SwapLib.addLiqBody(core, aux, wantTok, price,
            IAux(aux).rangeETH() + grossBuffer);
    }

    struct RebalIn {
        address core; address aux; address weth;
        uint loPrice; uint upPrice;
    }
    struct RebalOut {
        uint    spotPrice; uint    loPrice; uint    upPrice; uint    myLiquidity; uint anchorPrice;
        bool setLastRepack; bool reseatBump;
    }

    function _venueBalanceLib(address ev, address aux) internal returns (uint total) {
        total = IEthVenue(ev).rangeOp(0, 2);
        address lm = levManager(aux);
        if (lm != address(0)) {
            try ILevEquity(lm).totalNetEquity() returns (uint n) { total = total > n ? total - n : 0; } catch {}
        }
    }

    function rebalanceBody(RebalIn memory c) public returns (RebalOut memory o) {
        SwapLib.Rebalanced memory r = SwapLib.rebalanceCore(
            c.core, c.aux, c.weth, c.upPrice, c.loPrice);
        if (r.didRepack) {

            o.setLastRepack = true;
        }
        if (r.loPrice != c.loPrice || r.upPrice != c.upPrice) o.reseatBump = true;
        o.spotPrice = r.spotPrice; o.loPrice = r.loPrice; o.upPrice = r.upPrice;
        o.myLiquidity = r.myLiquidity; o.anchorPrice = r.anchorPrice;
    }

    function _refreshBookmarksLib(
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levBuf,
        address user, uint usdFees
    ) internal {
        Types.Deposit storage LP = autoManaged[user];
        SwapLib.refreshBookmarks(LP, LP.pooled + levBuf[user], usdFees);
    }

    function transferSharesBody(
        mapping(address => Types.Deposit) storage autoManaged,
        mapping(address => uint) storage levPooled,
        mapping(address => uint) storage levBuf,
        address from, address to, uint amount,
        uint usdFees
    ) public returns (uint lpSharesDelta) {
        require(to != address(0), "to=0");
        require(from != to, "self");
        if (amount == 0) return 0;

        Types.Deposit storage L = autoManaged[from];

        uint freeBal = SwapLib.plainNet(L.pooled, levPooled[from]);
        if (amount > freeBal) revert InsufficientBalance();

        if (L.pooled > 0) {
            (uint ethReward, uint usdReward) = ICore(address(this)).pendingRewards(from);
            if (ethReward > 0) { L.pooled += ethReward; lpSharesDelta += ethReward; }
            if (usdReward > 0) L.usd_owed += usdReward;
        }

        Types.Deposit storage R = autoManaged[to];
        if (R.pooled > 0) {
            (uint ethReward, uint usdReward) = ICore(address(this)).pendingRewards(to);
            if (ethReward > 0) { R.pooled += ethReward; lpSharesDelta += ethReward; }
            if (usdReward > 0) R.usd_owed += usdReward;
        }

        L.pooled -= amount; R.pooled += amount;

        _refreshBookmarksLib(autoManaged, levBuf, from, usdFees);
        _refreshBookmarksLib(autoManaged, levBuf, to, usdFees);
    }

    function setupBody(address _aux, address _core)
        external returns (address weth, uint lower, uint upper) {
        weth = IAux(_aux).WETH();
        IWETH9(weth).approve(_aux, type(uint).max);
        (uint spotPrice,) = ICore(_core).poolStats();
        (lower, upper) = SwapLib.updateBounds(spotPrice, SwapLib.RANGE_DELTA);
    }

    function sendEth(address weth, address ev, address aux, uint howMuch, address toWhom)
        external returns (uint sent) {
        uint alreadyInETH = address(this).balance;
        if (alreadyInETH >= howMuch) sent = howMuch;
        else { uint needed = howMuch - alreadyInETH;
            uint inWETH = IWETH9(weth).balanceOf(address(this));
            if (needed > inWETH) {
                inWETH += IEthVenue(ev).rangeOp(needed - inWETH, 1);
                if (inWETH < needed) {
                    address mgr = IEthVenue(ev).LEV_MANAGER();
                    if (mgr != address(0)) {
                        uint px = IAux(aux).assetPrice(weth);
                        inWETH += SwapLib.deleverEthOnDelivery(
                            mgr, aux, px, needed - inWETH, address(this));
                    }
                }
            }

            uint take = inWETH < needed ? inWETH : needed;
            IWETH9(weth).withdraw(take);
            sent = take + alreadyInETH;
        }
        (bool success, ) = payable(toWhom).call{value: sent}("");
        require(success, "ethSend");
    }

    struct EthCfg {
        address weth;
        address aux;
        address curvePool;
        address weeth;
        address eeth;
        address levManager;
    }

    address internal constant ETHERFI_ADAPTER_VL = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;

    function _rangeETH(EthCfg memory c) internal view returns (uint total) {
        if (c.weeth != address(0)) {
            uint w = IERC20(c.weeth).balanceOf(address(this));
            if (w > 0) total += IWeETH(c.weeth).getEETHByWeETH(w);
        }

        total += IERC20(c.weth).balanceOf(address(this));
        total += IERC20(c.weth).balanceOf(c.aux);

        if (c.eeth != address(0)) {
            total += IERC20(c.eeth).balanceOf(address(this));
        }

        if (c.levManager != address(0)) {
            try ILevEquity(c.levManager).totalNetEquity() returns (uint n) { total += n; } catch {}
        }
    }

    function rangeETH(EthCfg memory c) public view returns (uint) {
        return _rangeETH(c);
    }

    function _withdrawableOf(address vault, address holder) internal view returns (uint) {
        try IVaultV2(vault).liquidityAdapter() returns (address adapter) {
            if (adapter != address(0)) {
                try IERC20(vault).balanceOf(holder) returns (uint shares) {
                    if (shares == 0) return 0;
                    try IERC4626(vault).convertToAssets(shares) returns (uint v) { return v; }
                    catch { return 0; }
                } catch { return 0; }
            }
        } catch {}
        try IERC4626(vault).maxWithdraw(holder) returns (uint m) { return m; }
        catch {

            try IERC20(vault).balanceOf(holder) returns (uint shares) {
                if (shares == 0) return 0;
                try IERC4626(vault).convertToAssets(shares) returns (uint v) { return v; }
                catch { return 0; }
            } catch { return 0; }
        }
    }

    function deliverableETH(EthCfg memory c) public view returns (uint total) {
        total = _rangeETH(c);

        if (c.curvePool != address(0) && c.weeth != address(0)) {
            uint w = IERC20(c.weeth).balanceOf(address(this));
            if (w > 0) {
                uint weethEth = IWeETH(c.weeth).getEETHByWeETH(w);
                uint payable_ = (ICurvePool(c.curvePool).balances(0) * 9) / 10;
                if (weethEth > payable_) total -= (weethEth - payable_);
            }
        }

        if (c.levManager != address(0)) {
            try ILevEquity(c.levManager).totalNetEquity() returns (uint n) {
                total = total > n ? total - n : 0;
            } catch {}
        }
    }

    function supplyVenueBody(EthCfg memory c, uint amount, address from) public returns (uint) {
        if (amount == 0) return 0;

        if (ETHERFI_ADAPTER_VL == address(0)) return 0;
        IERC20(c.weth).transferFrom(from, address(this), amount);
        IDepositAdapter(ETHERFI_ADAPTER_VL).depositWETHForWeETH(amount, address(this));
        return amount;
    }

    function withdrawETH(EthCfg memory c, SwapLib.OfframpCfg memory off,
        address token, uint amount, address to) public returns (uint sent) {
        if (amount == 0) return 0;
        require(token == c.weth, "ethv:notWeth");

        uint wethBal = IERC20(c.weth).balanceOf(address(this));
        if (wethBal < amount) {
            uint want = amount - wethBal;
            uint auxIdle = IERC20(c.weth).balanceOf(c.aux);
            uint pull = auxIdle < want ? auxIdle : want;
            if (pull > 0) {
                try IERC20(c.weth).transferFrom(c.aux, address(this), pull) {} catch {}
                wethBal = IERC20(c.weth).balanceOf(address(this));
            }
        }
        if (wethBal < amount) {

            if (LevMath.sourceWeth(amount - wethBal, off.weeth, off.curvePool) > 0)
                wethBal = IERC20(c.weth).balanceOf(address(this));
        }
        if (wethBal < amount) {
            wethBal = IERC20(c.weth).balanceOf(address(this));
        }
        sent = wethBal >= amount ? amount : wethBal;
        if (sent > 0 && to != address(this)) {
            IERC20(c.weth).transfer(to, sent);
        }
        return sent;
    }

    function offrampBody(uint amount, address recipient, SwapLib.OfframpCfg memory c)
        external returns (uint) {
        if (amount == 0 || c.weeth == address(0)) return 0;
        uint weethFull = IWeETH(c.weeth).getWeETHByeETH(amount);
        uint weethIn = weethFull;
        uint bal = IERC20(c.weeth).balanceOf(address(this));
        if (weethIn > bal) weethIn = bal;

        if (c.curvePool != address(0) && weethIn > 0) {
            uint wantOut = (weethFull == 0 || weethIn == weethFull)
                ? amount : SoladyMath.fullMulDiv(amount, weethIn, weethFull);

            uint cap = (ICurvePool(c.curvePool).balances(0) * 9) / 10;
            if (wantOut > cap) weethIn = SoladyMath.fullMulDiv(weethIn, cap, wantOut);
        }
        uint covered = (weethFull == 0 || weethIn == weethFull)
            ? amount : SoladyMath.fullMulDiv(amount, weethIn, weethFull);

        if (weethIn > 0) {
            uint got = LevMath.sellWeethOnCurve(c.weeth, c.curvePool, weethIn, (covered * 9975) / 10_000);
            if (got > 0) {
                IERC20(c.weth).transfer(recipient, got);
                return covered;
            }
        }

        return waitNft(covered, recipient, c);
    }

    function waitNft(uint amount, address recipient, SwapLib.OfframpCfg memory c)
        internal returns (uint) {
        if (amount == 0 || c.weeth == address(0) || c.lp == address(0)) return 0;
        uint weethFull = IWeETH(c.weeth).getWeETHByeETH(amount);
        if (weethFull == 0) return 0;
        uint bal = IERC20(c.weeth).balanceOf(address(this));
        uint weethIn = weethFull > bal ? bal : weethFull;
        if (weethIn == 0) return 0;
        try IWeETH(c.weeth).unwrap(weethIn) returns (uint eeth) {
            if (eeth > 0) {

                try IEtherFiLiquidityPool(c.lp).requestWithdraw(recipient, eeth) returns (uint) {
                    return weethIn == weethFull
                        ? amount : SoladyMath.fullMulDiv(amount, weethIn, weethFull);
                } catch {}
            }
        } catch {}
        return 0;
    }

}

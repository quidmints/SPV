// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as SoladyMath} from "solady/src/utils/FixedPointMathLib.sol";
import {WAD} from "./Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IAggregatorV3, IAux} from "./Interfaces.sol";

library FeeLib {

    function decPow(uint base,
        uint mins, uint cap) public
        pure returns (uint) {
        if (mins > cap) mins = cap;
        if (mins == 0) return 1e18;
        uint y = 1e18;
        uint x = base;
        uint n = mins;
        while (n > 1) {
            if (n % 2 == 0) {
                x = SoladyMath.fullMulDiv(
                         x, x, 1e18);
                              n /= 2;
            } else {
                y = SoladyMath.fullMulDiv(
                         x, y, 1e18);
                x = SoladyMath.fullMulDiv(
                         x, x, 1e18);
                n = (n - 1) / 2;
            }
        } return SoladyMath.fullMulDiv(
                      x, y, 1e18);
    }

    uint public constant DEPEG_DEADZONE_BPS = 50;

    function calcRisk(address token, address range)
        internal view returns (uint)
    {
        if (range == address(0) || token == address(0)) return 0;
        try IAux(range).getDepegSeverityBps(token) returns (uint s) {
            if (s == 0) return 0;
            return s > 10000 ? 10000 : s;
        } catch {
            return 0;
        }
    }

    struct FeeCtx {
        address[] stables;
        address range;
    }

    function grossUpForDepeg(uint amount, uint sev) internal pure returns (uint) {
        return (sev > 0 && sev < 10000) ? SoladyMath.fullMulDiv(amount, 10000, 10000 - sev) : amount;
    }

    function calcNeeded(address token, uint amount, FeeCtx memory c)
        external view returns (uint needed)
    {

        needed = grossUpForDepeg(amount, calcRisk(token, c.range));
    }

    function applyFeeAndHaircut(address token, uint amount, address range)
        external view returns (uint)
    {
        return grossUpForDepeg(amount, calcRisk(token, range));
    }

    function allocate(address token, uint totalAmount, uint slotDep,
        uint totalDep, FeeCtx memory c) external view returns (uint amount)
    {
        if (totalDep == 0 || slotDep == 0) return 0;
        amount = SoladyMath.fullMulDiv(totalAmount,
            SoladyMath.fullMulDiv(WAD, slotDep, totalDep), WAD);
        if (amount == 0) return 0;

        amount = grossUpForDepeg(amount, calcRisk(token, c.range));
    }

    function riskFactor(
        address token,
        address range
    ) external view returns (uint factorBps) {
        if (token == address(0)) return 10000;

        uint sev;
        try IAux(range).getDepegSeverityBps(token) returns (uint s) {
            sev = s;
        } catch {
            return 10000;
        }
        if (sev == 0) return 10000;
        factorBps = sev >= 10000 ? 0 : 10000 - sev;
    }

    function liveDepegBps(address feed, uint maxAge)
        public view returns (uint)
    {
        try IAggregatorV3(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return 0;
            if (maxAge != 0 && block.timestamp > updatedAt
                && block.timestamp - updatedAt > maxAge) return 0;
            uint8 dec;
            try IAggregatorV3(feed).decimals() returns (uint8 d) { dec = d; }
            catch { return 0; }
            uint peg = 10 ** dec;
            uint price = uint(answer);
            if (price >= peg) return 0;
            uint down = ((peg - price) * 10000) / peg;

            return down <= DEPEG_DEADZONE_BPS ? 0 : down;
        } catch {
            return 0;
        }
    }

    function multiVaultWithdrawBody(address[] memory vs, uint amount, address to,
        address aaveSpoke, address stable)
        external returns (uint sent) {
        if (vs.length == 1) {
            if (vs[0] == aaveSpoke) {
                uint cap = IAux(address(this)).aaveBalance(stable);
                if (cap == 0) return 0;
                uint want = Math.min(amount, cap);
                return IAux(address(this)).withdrawAaveLeg(stable, want, to);
            }
            uint shares = _shareCap(vs[0], amount);
            if (shares == 0) return 0;
            return IERC4626(vs[0]).redeem(shares, to, address(this));
        }
        uint n = vs.length;
        uint total;
        uint[] memory bals = new uint[](n);
        for (uint j; j < n; j++) {
            if (vs[j] == aaveSpoke) {

                bals[j] = IAux(address(this)).aaveBalance(stable);
            } else {

                try IERC4626(vs[j]).balanceOf(address(this)) returns (uint sh) {
                    try IERC4626(vs[j]).convertToAssets(sh) returns (uint a) { bals[j] = a; } catch {}
                } catch {}
            }
            total += bals[j];
        }
        if (total == 0) return 0;
        uint remaining = amount;
        for (uint j; j < n && remaining > 0; j++) {
            if (bals[j] == 0) continue;
            uint want = SoladyMath.fullMulDiv(
                        amount, bals[j], total);
            if (want > remaining) want = remaining;
            if (want == 0) continue;
            uint got = _withdrawLeg(vs[j],
             aaveSpoke, stable, want, to);
            sent += got;
            remaining = got >= remaining ?
                           0 : remaining - got;
        }
        for (uint j; j < n && remaining > 0; j++) {
            if (bals[j] == 0) continue;
            uint got = _withdrawLeg(vs[j], aaveSpoke, stable, remaining, to);
            sent += got;
            remaining = got >= remaining
                         ? 0 : remaining - got;
        } return sent;
    }

    function _withdrawLeg(address v, address aaveSpoke, address stable,
        uint want, address to) private returns (uint) {
        if (v == aaveSpoke) {
            uint cap = IAux(address(this)).aaveBalance(stable);
            if (cap == 0) return 0;
            uint w = Math.min(want, cap);
            if (w == 0) return 0;
            return IAux(address(this)).withdrawAaveLeg(stable, w, to);
        }
        uint shares = _shareCap(v, want);
        if (shares == 0) return 0;
        return IERC4626(v).redeem(shares, to, address(this));
    }

    function _shareCap(address vault, uint amount) private view returns (uint) {
        uint bal = IERC4626(vault).balanceOf(address(this));
        uint sh = IERC4626(vault).convertToShares(amount);
        return Math.min(bal, sh);
    }
}

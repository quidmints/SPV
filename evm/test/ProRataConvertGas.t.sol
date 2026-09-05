// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {DEFAULT_UNWIND_DEX, USDC, ONEINCH_ROUTER} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20P {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice **MEASURE THE PRO-RATA → 1inch PATH BEFORE DECIDING ANY VENUE CONCENTRATION.**
///
/// Owner, 2026-09-05: *"dont overconcentrate into aave unless we genuinely need the gas savings for
/// every single swap out or redeem that has to draw from all the vaults pro rata and still 1inch after
/// that (might be more gas than what one transaction can do even)"* — then: *"just measure the gas for
/// real first."* This is that measurement. **A venue-concentration decision taken without it is taken
/// on a hunch**, which standing rule 9 names as the axis nobody measured.
///
/// 🔑 **THE SHAPE OF THE COST, AND WHY LEG COUNT IS THE THING TO SCALE.** `LevMath.convertShortfall`
///    is the pro-rata → convert path: `IAux.take(…, quid, 0)` draws PRO-RATA (so every funded stable
///    contributes), then `getStables()` is read, then `convertTo(st, amt, payoutToken, floor, routes)`
///    runs **one leg per STABLE**. ⇒ the leg count tracks the number of **stables** (14 in
///    `DeployL1_s.STABLECOINS`), **not** the number of Morpho vaults any one stable has.
/// ⚠️ **SO CONCENTRATING USDC's VENUES DOES NOT SHORTEN THIS LOOP AT ALL.** Venue count affects the
///    WITHDRAW-side walk (`getVaults(stable)` inside the take), which is a different cost. Both are
///    measured below, separately, because conflating them is what would make the gas argument look
///    stronger than it is.
///
/// ⚠️ **WHAT IS MEASURED HERE IS THE FLOOR, NOT THE FULL BILL.** The legs below carry a route that
///    FAILS, which isolates `convertTo`'s own per-leg frame (two `balanceOf`, `forceApprove` there and
///    back, the dispatch). A real fill ADDS the router's actual swap on top of every leg. The single
///    real fill at the end sizes that adder, and the total is reported as floor + N × adder rather
///    than pretended to be exact.
contract ProRataConvertGas is ForkPin {
    // A realistic basket slice: the 6-dec majors plus 18-dec stables, all live mainnet tokens.
    address constant USDT  = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI   = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant GHO   = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant CRVUSD= 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant USDS  = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant FRAX  = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
    address constant WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address[8] tokens = [USDC, USDT, DAI, GHO, PYUSD, CRVUSD, USDS, FRAX];

    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// @dev N legs, each with a route that fails, so what is measured is `convertTo`'s own frame
    ///      scaled by N — the term that decides whether the path fits in a block at all.
    function _wrapperAtN(uint256 n) internal returns (uint256 used) {
        address[] memory t = new address[](n);
        uint256[] memory a = new uint256[](n);
        bytes[]   memory r = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            address tok = tokens[i % tokens.length];
            uint256 amt = 1000 * (10 ** IERC20P(tok).decimals());
            deal(tok, address(this), amt);
            t[i] = tok; a[i] = amt;
            r[i] = abi.encodeWithSelector(bytes4(0xdeadbeef));   // fails; `continue` swallows it
        }
        uint256 g0 = gasleft();
        LevMath.convertTo(t, a, WETH, 0, r);
        used = g0 - gasleft();
    }

    /// ⭐ THE ANSWER: how the pro-rata conversion scales, and where it lands against a block.
    function test_ConvertToScalesLinearlyInLegs() public {
        uint256 prev;
        uint256 marginal;
        for (uint256 i; i < 5; ++i) {
            uint256 n = [uint256(1), 2, 4, 8, 14][i];
            uint256 used = _wrapperAtN(n);
            if (prev != 0) marginal = (used - prev) / (n - (n / 2));
            console2.log("legs:", n);
            console2.log("   convertTo frame, gas:", used);
            prev = used;
        }
        console2.log("marginal gas per added leg (last step):", marginal);
        assertGt(prev, 0, "the 14-leg measurement did not run");
        // 30M is the mainnet block gas limit. A FLOOR above it would settle the question outright.
        console2.log("14-leg floor as % of a 30M block:", (prev * 100) / 30_000_000);
    }

    /// @dev The adder a REAL fill puts on top of the frame, measured once through the tree's own
    ///      encoder against the pool word it already ships. Total ≈ floor + N × this.
    function test_RealFillAdderPerLeg() public {
        uint256 amt = 50_000e6;
        deal(USDC, address(this), amt);
        uint256 before = IERC20P(WETH).balanceOf(address(this));
        uint256 g0 = gasleft();
        LevMath._aggSwap(USDC, WETH, amt, 1, DEFAULT_UNWIND_DEX, 0);
        uint256 used = g0 - gasleft();
        assertGt(IERC20P(WETH).balanceOf(address(this)) - before, 0, "the real fill did not fill");
        console2.log("ONE real routed leg (frame + router + swap), gas:", used);
    }
}

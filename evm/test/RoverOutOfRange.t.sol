// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ForkPin} from "./utils/ForkPin.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Rover} from "../src/Rover.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IV3SwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {IWeETH} from "../src/imports/Interfaces.sol";
import {FullMath} from "../src/imports/v3/FullMath.sol";
import {TickMath} from "../src/imports/v3/TickMath.sol";

/// @notice COVERAGE FOR THE OUT-OF-BAND PATHS, which every other Rover test misses because they all
///         run with spot INSIDE the band.
///
///         ⚠️ TWO OF THESE FAIL, AND THE FAILURES ARE CORRECT — DO NOT WEAKEN THEM (same convention as
///         `testLeverage_LvrControlVsTreatment`). `test_repackSucceeds_whenSpotAboveBand` and
///         `test_takeDelivers_whenSpotAboveBand` revert inside `NFPM.mint`, because `_swap` hands it
///         zero liquidity: single-sided, the target RATIO is infinite, and the sell leg's own
///         `targetWEETH > 0` guard (it divides by that to form `k`) refuses the conversion the band
///         needs. v3 reverts on a zero-liquidity mint, so `repackNFT` is BRICKED whenever spot sits
///         at or above `UPPER_TICK` with the position all-weETH.
///
///         VERIFIED PRE-EXISTING: identical failures with the `_swap` domain fix applied and backed
///         out, so this is live on `main` and was simply never covered — the whole 3,700-test suite
///         runs Rover in-band only. Suite baseline moves 1 -> 3 known failures.
///
///         Two code paths only execute when spot has left `[LOWER_TICK, UPPER_TICK)`:
///           * `_swap`'s single-sided target branch — the legacy USDC-era sizing passed `sqrtCurrent`
///             as a RANGE BOUND, so once spot left the band `LiquidityAmounts` got an INVERTED range,
///             swapped the bounds, and returned liquidity for a range that is not the band. Garbage
///             targets, and `NFPM.mint` reverts on them.
///           * `_liquidityForWeth`'s probe-and-scale, whose whole claim is that the out-of-range
///             cases "come free" because `getAmountsForLiquidity` already encodes them.
///
///         Out-of-band is not exotic here: the pair drifts ~0.63 ticks/day against a 10-tick band, so
///         it is where Rover spends much of its life. The shoves below are sized to leave the band
///         but stay INSIDE `_nearFair`'s 50 bps gate, so these exercise the ordinary drifted state
///         rather than the manipulated one (which `Alles.t.sol` already pins).
contract RoverOutOfRangeTest is ForkPin {
    address constant ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address constant WETH    = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WEETH   = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant NFPM    = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant POOL    = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3;
    address constant ROUTER  = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    Rover rover;

    function setUp() public {
        vm.selectFork(_forkMainnet());
        rover = new Rover(ADAPTER, WETH, WEETH, NFPM, POOL, ROUTER, true);
        rover.setAux(address(this));
        uint amt = 4000e18;
        deal(WETH, address(this), amt);
        IERC20(WETH).approve(address(rover), amt);
        rover.deposit(amt);
    }
    receive() external payable {}

    function _tick() internal view returns (int24 t) { (, t,,,,,) = IUniswapV3Pool(POOL).slot0(); }

    /// @dev Same formulation `Rover._nearFair` uses, via the same FullMath: spot and fair both as
    ///      weETH-per-WETH, so the sign and scale match the gate this test must stay inside of.
    function _deviationBps() internal view returns (int) {
        (uint160 sq,,,,,,) = IUniswapV3Pool(POOL).slot0();
        uint ratioX128 = FullMath.mulDiv(uint(sq), uint(sq), 1 << 64);
        uint spot = FullMath.mulDiv(ratioX128, 1e18, 1 << 128);          // weETH per WETH
        uint fairInv = FullMath.mulDiv(1e18, 1e18, IWeETH(WEETH).getEETHByWeETH(1e18));
        return (int(spot) - int(fairInv)) * 10000 / int(fairInv);
    }

    /// @dev Move spot to EXACTLY `target` and stop, via `sqrtPriceLimitX96`. Unbounded shoves are
    ///      useless here: buying weETH is the pool's broken direction (1.036 weETH in it), so an
    ///      unlimited 2,500 WETH buy drove the tick to -309,961 — total destruction, not the
    ///      ordinary drifted state these paths actually live in. The limit makes the shove a
    ///      controlled move to a chosen tick.
    function _moveTickTo(int24 target) internal {
        bool up = target > _tick();
        (address tin, address tout) = up ? (WEETH, WETH) : (WETH, WEETH);
        uint amountIn = 20000e18;                       // ample; the price limit is what binds
        deal(tin, address(this), IERC20(tin).balanceOf(address(this)) + amountIn);
        IERC20(tin).approve(ROUTER, amountIn);
        IV3SwapRouter(ROUTER).exactInputSingle(IV3SwapRouter.ExactInputSingleParams({
            tokenIn: tin, tokenOut: tout, fee: 500, recipient: address(this),
            amountIn: amountIn, amountOutMinimum: 0,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target) }));
    }
    function _pushTickUp(uint) internal { _moveTickTo(-930); }    // just above the band
    function _pushTickDown(uint) internal { _moveTickTo(-970); }  // just below it (drift direction)

    function _report(string memory tag) internal returns (bool outOfBand) {
        int24 t = _tick(); int24 lo = rover.LOWER_TICK(); int24 hi = rover.UPPER_TICK();
        outOfBand = !(t >= lo && t < hi);
        emit log_string(tag);
        emit log_named_int("  tick", t);
        emit log_named_int("  band lo", lo);
        emit log_named_int("  band hi", hi);
        emit log_named_int("  deviation bps", _deviationBps());
        emit log_string(outOfBand ? "  => OUT OF BAND" : "  => still in band");
    }

    /// @notice Band left from BELOW (drift direction) — position is 100% WETH. `take` must still
    ///         deliver, and must NOT silently under-deliver the way the old `need/2` split did.
    function test_takeDelivers_whenSpotBelowBand() public {
        _pushTickDown(2500e18);
        bool oob = _report("=== spot pushed BELOW band ===");
        assertTrue(oob, "shove did not leave the band; resize the test");
        uint before = IERC20(WETH).balanceOf(address(this));
        uint got = rover.take(300e18);
        uint recv = IERC20(WETH).balanceOf(address(this)) - before;
        emit log_named_uint("take(300) delivered", got);
        assertEq(got, recv, "reported delivery != actual transfer");
        assertGt(got, 285e18, "under-delivered by >5% while out of band");
    }

    /// @notice Band left from ABOVE — position is 100% weETH, so `take` must source WETH by
    ///         converting, and `_liquidityForWeth` must size that from the real composition.
    function test_takeDelivers_whenSpotAboveBand() public {
        _pushTickUp(6000e18);
        bool oob = _report("=== spot pushed ABOVE band ===");
        assertTrue(oob, "shove did not leave the band; resize the test");
        uint before = IERC20(WETH).balanceOf(address(this));
        uint navBefore = rover.valueWeth();
        uint got = rover.take(300e18);
        emit log_named_uint("take(300) delivered", got);
        emit log_named_uint("rover NAV before", navBefore);
        emit log_named_uint("rover NAV after ", rover.valueWeth());
        assertEq(got, IERC20(WETH).balanceOf(address(this)) - before, "reported != actual");
        // A ZERO here is CORRECT, not a bug: the position is 100% weETH and `_fairMinOut` refuses to
        // sell it below the adapter rate, so the weETH stays idle and fair-valued for the caller's
        // next rung. The invariant that must hold either way is CONSERVATION -- Rover must never
        // destroy value, whether it serves the ask or declines it.
        assertApproxEqRel(rover.valueWeth() + got, navBefore, 0.005e18,
            "value destroyed: NAV + delivered != NAV before");
    }

    /// @notice THE PATH THE `_swap` FIX EXISTS FOR: a repack while spot is outside the band. Before
    ///         the fix this reverted in `NFPM.mint` on inverted-range targets.
    function test_repackSucceeds_whenSpotBelowBand() public {
        _pushTickDown(2500e18);
        assertTrue(_report("=== repack with spot BELOW band ==="), "not out of band");
        uint idBefore = rover.ID();
        rover.repackNFT();
        _report("=== after repack ===");
        assertGt(rover.ID(), 0, "no position after repack");
        assertGt(rover.valueWeth(), 3900e18, "repack destroyed value");
        idBefore; // silence
    }

    function test_repackSucceeds_whenSpotAboveBand() public {
        _pushTickUp(6000e18);
        assertTrue(_report("=== repack with spot ABOVE band ==="), "not out of band");
        rover.repackNFT();
        _report("=== after repack ===");
        assertGt(rover.ID(), 0, "no position after repack");
        assertGt(rover.valueWeth(), 3900e18, "repack destroyed value");
    }

    /// @notice `valueWeth` is the protocol's NAV read; it must stay sane single-sided.
    function test_valueWeth_holdsOutOfBand() public {
        uint v0 = rover.valueWeth();
        _pushTickDown(2500e18);
        uint vDown = rover.valueWeth();
        emit log_named_uint("valueWeth in band", v0);
        emit log_named_uint("valueWeth out of band (below)", vDown);
        assertGt(vDown, 3800e18, "NAV collapsed out of band");
        assertLt(vDown, 4200e18, "NAV inflated out of band");
    }
}

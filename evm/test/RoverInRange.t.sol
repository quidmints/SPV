// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ForkPin} from "./utils/ForkPin.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Rover} from "../src/Rover.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IWeETH} from "../src/imports/Interfaces.sol";

/// @notice THE PRECONDITION FOR EVERYTHING. `RoverInjectedDepth.t.sol` shows a Rover-sized band
///         collapses the offramp cost to -1 bps — but that was a band minted BY HAND at the live
///         tick. This asks whether the ACTUAL contract ever gets there.
///
///         The suspicion (measured in ROVER-WEETH.md §8): `_repackNFT` picks the band from
///         `_adjustTicks(LAST_TICK)` — the PRE-swap tick — then `_mintOrCompound`'s `_swap` moves
///         the price (measured: even a 1 weETH trade moves 8 ticks in a 10-tick band) and only
///         THEN does `_mintRover` execute. If so, the fresh position lands at or outside its own
///         band, earns nothing, and provides no depth — making the -1 bps unreachable in practice.
contract RoverInRangeTest is ForkPin {
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
    }
    receive() external payable {}

    function _report(string memory tag) internal returns (bool inRange) {
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        int24 lo = rover.LOWER_TICK(); int24 hi = rover.UPPER_TICK();
        inRange = tick >= lo && tick < hi;
        emit log_string(tag);
        emit log_named_int ("  pool tick now", tick);
        emit log_named_int ("  band lower", lo);
        emit log_named_int ("  band upper", hi);
        emit log_named_uint("  liquidityUnderManagement", rover.liquidityUnderManagement());
        emit log_named_uint("  idle WETH left behind", IERC20(WETH).balanceOf(address(rover)));
        emit log_named_uint("  idle weETH left behind", IERC20(WEETH).balanceOf(address(rover)));
        emit log_string(inRange ? "  => IN RANGE" : "  => OUT OF RANGE (earns nothing, provides no depth)");
    }

    /// @notice A single fresh deposit — the very first thing Rover ever does.
    function test_firstDeposit_landsInRange() public {
        uint amt = 1000e18;
        deal(WETH, address(this), amt);
        IERC20(WETH).approve(address(rover), amt);
        rover.deposit(amt);
        bool ok = _report("=== after FIRST deposit of 1,000 WETH ===");
        assertTrue(ok, "fresh position is OUT OF RANGE immediately after mint");
    }

    /// @notice A second deposit on top — this is the path that runs `_swap` against a live position.
    function test_secondDeposit_staysInRange() public {
        uint amt = 500e18;
        deal(WETH, address(this), amt * 2);
        IERC20(WETH).approve(address(rover), amt * 2);
        rover.deposit(amt);
        _report("=== after first deposit ===");
        rover.deposit(amt);
        bool ok = _report("=== after SECOND deposit ===");
        assertTrue(ok, "position OUT OF RANGE after second deposit");
    }

    /// @notice Does the position Rover actually builds deliver the -1 bps the hand-built one did?
    ///         This is the number that decides whether Rover is worth keeping.
    function test_roverPosition_deliversCheapOfframp() public {
        uint amt = 4000e18;
        deal(WETH, address(this), amt);
        IERC20(WETH).approve(address(rover), amt);
        rover.deposit(amt);
        _report("=== Rover funded with 4,000 WETH ===");

        // Now take 500 ETH out through Rover, exactly as the offramp ladder would.
        uint before = IERC20(WETH).balanceOf(address(this));
        uint got = rover.take(500e18);
        emit log_named_uint("take(500e18) delivered WETH", got);
        emit log_named_uint("actually received", IERC20(WETH).balanceOf(address(this)) - before);
        // Value the whole Rover afterwards to see what the round trip really cost.
        emit log_named_uint("rover.valueWeth() after", rover.valueWeth());
    }
}

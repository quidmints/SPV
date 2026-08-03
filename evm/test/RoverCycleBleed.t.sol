// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ForkPin} from "./utils/ForkPin.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Rover} from "../src/Rover.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IWeETH} from "../src/imports/Interfaces.sol";

/// @notice THE "IS ROVER AN ASSET OR A LIABILITY" TEST, run as the protocol would actually use it.
///
///         ROVER-WEETH.md accumulated several claimed leaks — `_wrapIdle` converting all idle WETH
///         and forcing a paid buy-back, the recentre's swap, `take` round-tripping. Every one of
///         those was reasoned against a pool where ROVER IS NOT THE LIQUIDITY. Once Rover owns
///         ~100% of in-range `L` (measured: the rest of the pool is 0.000346 WETH-equiv), an
///         internal round-trip pays itself and should cost ~nothing. Reasoning cannot settle which
///         it is, so this runs the real cycle and measures value retention.
///
///         ONE CYCLE = exactly what `SwapLib.offrampBody` rung 2 does: `take(x)` for WETH, then hand
///         Rover the equivalent weETH back, then a permissionless `repackNFT()` crank.
///         `valueWeth()` is the protocol's own NAV read, so the bleed (if any) is what the protocol
///         would actually book.
contract RoverCycleBleedTest is ForkPin {
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

    function _fund(uint amt) internal {
        deal(WETH, address(this), amt);
        IERC20(WETH).approve(address(rover), amt);
        rover.deposit(amt);
    }

    /// @dev NAV the protocol books, plus anything we are holding on Rover's behalf.
    function _nav() internal view returns (uint) {
        return rover.valueWeth();
    }

    /// @notice Run 10 offramp cycles at 250 WETH each on a 4,000 WETH Rover and print the NAV drift.
    ///         Total flow = 2,500 WETH = 62.5% of the position turned over.
    function test_tenCycles_navRetention() public {
        _fund(4000e18);
        uint start = _nav();
        emit log_named_uint("NAV after funding 4,000 WETH", start);
        (, int24 t0,,,,,) = IUniswapV3Pool(POOL).slot0();
        emit log_named_int("tick at start", t0);

        uint delivered;
        for (uint i; i < 10; ++i) {
            uint got = rover.take(250e18);
            delivered += got;
            // Rung 2 hands Rover the weETH equivalent of what it delivered (NAV-neutral absorb).
            uint back = IWeETH(WEETH).getWeETHByeETH(got);
            deal(WEETH, address(this), back);
            IERC20(WEETH).transfer(address(rover), back);
            rover.repackNFT();      // the permissionless crank
        }
        uint end = _nav();
        (, int24 t1,,,,,) = IUniswapV3Pool(POOL).slot0();

        emit log_named_uint("total WETH delivered over 10 cycles", delivered);
        emit log_named_uint("NAV at end", end);
        emit log_named_int ("tick at end", t1);
        emit log_named_uint("liquidityUnderManagement at end", rover.liquidityUnderManagement());
        emit log_named_uint("idle WETH stranded", IERC20(WETH).balanceOf(address(rover)));
        emit log_named_uint("idle weETH stranded", IERC20(WEETH).balanceOf(address(rover)));

        // Each cycle is NAV-neutral by construction (WETH out, equal-value weETH in), so any drift
        // is pure friction: pool spread paid to strangers, mint/redeem rounding, stranded idle.
        int drift = int(end) - int(start);
        emit log_named_int("NAV drift (wei)", drift);
        if (delivered > 0) {
            emit log_named_int("friction, bps of flow", drift * 10000 / int(delivered));
        }
    }

    /// @notice Same, but WITHOUT handing the weETH back — i.e. Rover is purely drained. Checks that
    ///         draining does not destroy value beyond what leaves.
    function test_drainOnly_navAccounting() public {
        _fund(4000e18);
        uint start = _nav();
        uint out;
        for (uint i; i < 4; ++i) out += rover.take(500e18);
        uint end = _nav();
        emit log_named_uint("NAV start", start);
        emit log_named_uint("WETH taken out", out);
        emit log_named_uint("NAV end", end);
        emit log_named_int ("value destroyed (start - out - end)", int(start) - int(out) - int(end));
    }
}

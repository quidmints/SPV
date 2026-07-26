// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Rover} from "../src/Rover.sol";

/// @notice Fork-validates the adapted (weETH/WETH) Rover: a WETH deposit must
///         mint a balanced concentrated position — the weETH leg coming from the
///         ether.fi adapter (NOT a pool swap) — and `take` must return WETH.
contract RoverForkTest is Test {
    // Fixed mainnet contracts.
    address constant ADAPTER = 0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2;
    address constant WETH    = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WEETH   = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant NFPM    = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant POOL    = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3; // weETH/WETH 0.05%
    address constant ROUTER  = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45; // v3 SwapRouter

    Rover rover;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        rover = new Rover(ADAPTER, WETH, WEETH, NFPM, POOL, ROUTER, true);
        rover.setAux(address(this)); // we drive take() as "Aux"
    }

    receive() external payable {} // to receive the self-funding compound tip

    /// @notice The permissionless self-funding compound crank: after real V3 fees accrue, a crank at
    ///         a live gasprice reimburses the caller from the WETH harvest (never principal), the rest
    ///         compounds, and at zero gasprice the tip is 0. Also prints the crank's gas (feeds #103).
    function test_compound_selfFundingTip() public {
        deal(WETH, address(this), 200 ether);
        IERC20(WETH).approve(address(rover), type(uint).max);
        rover.deposit(200 ether);
        uint liqBefore = rover.liquidityUnderManagement();

        // Generate real fees: round-trip swap volume through the weETH/WETH 0.05% pool.
        address trader = makeAddr("trader");
        deal(WETH, trader, 800 ether);
        vm.startPrank(trader);
        IERC20(WETH).approve(ROUTER, type(uint).max);
        uint got = ISwapRouter02(ROUTER).exactInputSingle(ISwapRouter02.ExactInputSingleParams(
            WETH, WEETH, 500, trader, 400 ether, 0, 0));
        IERC20(WEETH).approve(ROUTER, type(uint).max);
        ISwapRouter02(ROUTER).exactInputSingle(ISwapRouter02.ExactInputSingleParams(
            WEETH, WETH, 500, trader, got, 0, 0));
        vm.stopPrank();

        // Crank at a live gasprice → self-funding tip to the caller.
        vm.txGasPrice(10 gwei);
        uint balBefore = address(this).balance;
        uint g0 = gasleft();
        rover.compound();
        emit log_named_uint("compound() gas used", g0 - gasleft());
        uint tip = address(this).balance - balBefore;
        assertGt(tip, 0, "self-funding: cranker reimbursed from the WETH harvest");
        assertGe(rover.liquidityUnderManagement(), liqBefore, "remaining harvest compounded; principal intact");

        // Zero gasprice ⇒ tip 0 (full compound; default-gasprice tests unchanged).
        vm.txGasPrice(0);
        uint bal2 = address(this).balance;
        rover.compound();
        assertEq(address(this).balance, bal2, "tip=0 at zero gasprice");
    }

    function test_deposit_mints_balanced_position_via_adapter() public {
        uint amount = 5 ether;
        deal(WETH, address(this), amount);
        IERC20(WETH).approve(address(rover), type(uint).max);

        uint weethBefore = IERC20(WEETH).balanceOf(address(rover));
        rover.deposit(amount);

        // A position was minted, and the weETH leg was acquired (minted via the
        // adapter, not bought on the thin pool side).
        assertGt(rover.ID(), 0, "v3 NFT position minted");
        assertGt(rover.liquidityUnderManagement(), 0, "liquidity under management");
        assertGt(IERC20(WEETH).balanceOf(address(rover)) + 1, weethBefore,
            "weETH leg acquired/positioned (adapter mint)");

        // take(): pull WETH back out for the offramp.
        uint wethBefore = IERC20(WETH).balanceOf(address(this));
        uint got = rover.take(2 ether);
        assertGt(got, 0, "take returned WETH");
        assertEq(IERC20(WETH).balanceOf(address(this)), wethBefore + got, "WETH delivered to Aux");
    }
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

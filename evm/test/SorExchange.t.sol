// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwap} from "../src/imports/ISwap.sol";
import {SorExchange, IExchange} from "../src/SorExchange.sol";

/// @notice Stand-in for Aux's SOR swap (the `ISwap` surface Aux implements). Pulls
///         the input token from msg.sender (the convention Aux's swapToBody uses),
///         prices BOLD<->WETH at a fixed ETH/USD, enforces minOut (as the real Aux
///         does), and delivers the output to msg.sender. ExactInput: consumes `amount`.
contract MockAux is ISwap {
    uint256 public ethUsd; // BOLD (1e18) per 1 WETH

    constructor(uint256 _ethUsd) {
        ethUsd = _ethUsd;
    }

    function swap(address token, address asset, bool forVolatile, uint256 amount, uint256 minOut)
        external
        payable
        returns (uint256 out)
    {
        address inTok = forVolatile ? token : asset; // forVolatile: stable(BOLD)->volatile(WETH)
        address outTok = forVolatile ? asset : token;
        IERC20(inTok).transferFrom(msg.sender, address(this), amount);
        out = forVolatile ? (amount * 1e18) / ethUsd // BOLD->WETH
                          : (amount * ethUsd) / 1e18; // WETH->BOLD
        require(out >= minOut, "minOut");
        IERC20(outTok).transfer(msg.sender, out);
    }

    // Unified-quote surface stubs (this mock only exercises `swap`).
    function getTWAPforAsset(address, uint32) external view returns (uint256) { return ethUsd; }
    function resolvedTwap(address, uint32) external view returns (uint256, bool) { return (ethUsd, false); }
    function wellSkew(address) external pure returns (uint256) { return 0; }
    function swapFeePpm() external pure returns (uint24) { return 420; }
}

contract SorExchangeTest is Test {
    MockERC20 bold;
    MockERC20 weth;
    MockAux aux;
    SorExchange ex;

    uint256 constant ETH_USD = 2000e18; // 1 WETH = 2000 BOLD

    function setUp() public {
        bold = new MockERC20("Bold", "BOLD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        aux = new MockAux(ETH_USD);
        ex = new SorExchange(IERC20(address(bold)), IERC20(address(weth)), ISwap(address(aux)));
        // Aux needs reserves of the output token to deliver on each leg.
        bold.mint(address(aux), 1_000_000e18);
        weth.mint(address(aux), 1_000e18);
    }

    // This test contract plays the role of the LeverageWETHZapper.

    function test_swapFromBold_leverUp() public {
        uint256 boldIn = 2000e18;
        bold.mint(address(this), boldIn);
        bold.approve(address(ex), boldIn);

        uint256 wethBefore = weth.balanceOf(address(this));
        ex.swapFromBold(boldIn, 0.9e18); // expect ~1 WETH at $2000

        assertEq(weth.balanceOf(address(this)) - wethBefore, 1e18, "got 1 WETH");
        assertEq(bold.balanceOf(address(this)), 0, "all BOLD spent");
        // ExactInput convention: no dust stranded in the adapter.
        assertEq(bold.balanceOf(address(ex)), 0, "no BOLD dust");
        assertEq(weth.balanceOf(address(ex)), 0, "no WETH dust");
    }

    function test_swapToBold_delever() public {
        uint256 collIn = 1e18;
        weth.mint(address(this), collIn);
        weth.approve(address(ex), collIn);

        uint256 boldBefore = bold.balanceOf(address(this));
        uint256 out = ex.swapToBold(collIn, 1900e18); // expect 2000 BOLD

        assertEq(out, 2000e18, "returns BOLD out");
        assertEq(bold.balanceOf(address(this)) - boldBefore, 2000e18, "got 2000 BOLD");
        assertEq(weth.balanceOf(address(this)), 0, "all WETH spent");
        assertEq(bold.balanceOf(address(ex)), 0, "no BOLD dust");
        assertEq(weth.balanceOf(address(ex)), 0, "no WETH dust");
    }

    function test_swapFromBold_revertsOnSlippage() public {
        uint256 boldIn = 2000e18;
        bold.mint(address(this), boldIn);
        bold.approve(address(ex), boldIn);
        vm.expectRevert(bytes("minOut")); // Aux can't meet minColl -> whole tx reverts
        ex.swapFromBold(boldIn, 1.1e18); // demand >1 WETH for 2000 BOLD at $2000
    }

    function test_swapToBold_revertsOnSlippage() public {
        uint256 collIn = 1e18;
        weth.mint(address(this), collIn);
        weth.approve(address(ex), collIn);
        vm.expectRevert(bytes("minOut"));
        ex.swapToBold(collIn, 2100e18); // demand >2000 BOLD for 1 WETH
    }
}

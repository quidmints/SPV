// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ForkPin} from "./utils/ForkPin.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IV3SwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";
import {IWeETH} from "../src/imports/Interfaces.sol";
import {FullMath} from "../src/imports/v3/FullMath.sol";

/// @notice QUEUE R2: *"Any party can freeze Rover's mint/recenter/compound for ~$5. Unfixed."*
///         That figure was computed against the pool as it stands TODAY — i.e. with no Rover in it.
///         The obvious question nobody asked: what does the same attack cost ONCE ROVER IS
///         DEPLOYED, since Rover's own liquidity is the thing that makes the pool hard to move?
///
///         `Rover._nearFair` refuses when |pool spot - ether.fi fair| > 50 bps (both as weETH per
///         WETH). This walks the attacker's spend upward until the gate trips, in BOTH directions,
///         and prices the attacker's REALISED loss (what they burn to hold the pool off-fair) —
///         with no Rover position, and with one.
contract RoverDosCostTest is ForkPin {
    address constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // token0
    address constant WEETH  = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // token1
    address constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant NFPM   = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant POOL   = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3;
    uint24  constant FEE    = 500;
    uint constant WAD = 1e18;

    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// @dev Exactly Rover._nearFair, read off live pool state. Uses the SAME FullMath the contract
    ///      uses — a naive `a*b/d` overflows once a shove pushes sqrtPrice toward its extreme, which
    ///      silently prints garbage deviations precisely in the range this test is trying to detect.
    function _deviationBps() internal view returns (uint) {
        (uint160 sq,,,,,,) = IUniswapV3Pool(POOL).slot0();
        uint ratioX128 = FullMath.mulDiv(uint(sq), uint(sq), 1 << 64);
        uint spot = FullMath.mulDiv(ratioX128, WAD, 1 << 128);      // weETH per WETH
        uint fairInv = FullMath.mulDiv(WAD, WAD, IWeETH(WEETH).getEETHByWeETH(WAD));
        uint diff = spot > fairInv ? spot - fairInv : fairInv - spot;
        return diff * 10000 / fairInv;
    }

    function _injectRover(uint wethSize) internal {
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
        int24 sp = IUniswapV3Pool(POOL).tickSpacing();
        int24 rem = tick % sp; if (rem < 0) rem += sp;
        uint weethSize = IWeETH(WEETH).getWeETHByeETH(wethSize);
        deal(WETH, address(this), wethSize); deal(WEETH, address(this), weethSize);
        IERC20(WETH).approve(NFPM, type(uint).max); IERC20(WEETH).approve(NFPM, type(uint).max);
        INonfungiblePositionManager(NFPM).mint(INonfungiblePositionManager.MintParams({
            token0: WETH, token1: WEETH, fee: FEE, tickLower: tick - rem, tickUpper: tick - rem + sp,
            amount0Desired: wethSize, amount1Desired: weethSize,
            amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp }));
    }

    /// @dev Spend `amtIn` of `tin` to shove the pool; return the attacker's realised loss in ETH-equiv.
    function _shove(address tin, address tout, uint amtIn) internal returns (uint lossWad, uint devBps) {
        deal(tin, address(this), amtIn);
        IERC20(tin).approve(ROUTER, amtIn);
        uint out = IV3SwapRouter(ROUTER).exactInputSingle(IV3SwapRouter.ExactInputSingleParams({
            tokenIn: tin, tokenOut: tout, fee: FEE, recipient: address(this),
            amountIn: amtIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0 }));
        uint inFair  = tin  == WEETH ? IWeETH(WEETH).getEETHByWeETH(amtIn) : amtIn;
        uint outFair = tout == WEETH ? IWeETH(WEETH).getEETHByWeETH(out)   : out;
        lossWad = inFair > outFair ? inFair - outFair : 0;
        devBps  = _deviationBps();
    }

    function _walk(string memory label, address tin, address tout, uint posSize) internal {
        emit log_string(label);
        uint[8] memory amts = [uint(1e15), 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22];
        for (uint i; i < amts.length; ++i) {
            uint256 s = vm.snapshotState();
            if (posSize > 0) _injectRover(posSize);
            (uint loss, uint dev) = _shove(tin, tout, amts[i]);
            emit log_named_uint("  spend (wei)", amts[i]);
            emit log_named_uint("    resulting deviation bps", dev);
            emit log_named_uint("    attacker loss (wei)", loss);
            if (dev > 50) { emit log_string("    ^^ GATE TRIPPED (>50bps) at this spend"); vm.revertToState(s); break; }
            vm.revertToState(s);
        }
    }

    function test_dosCost_noRover_sellWeeth()  public { _walk("=== NO ROVER: shove by SELLING weETH ===",  WEETH, WETH, 0); }
    function test_dosCost_noRover_buyWeeth()   public { _walk("=== NO ROVER: shove by BUYING weETH ===",   WETH, WEETH, 0); }
    function test_dosCost_withRover_sellWeeth() public { _walk("=== ROVER 4,000 WETH: shove by SELLING weETH ===", WEETH, WETH, 4000e18); }
    function test_dosCost_withRover_buyWeeth()  public { _walk("=== ROVER 4,000 WETH: shove by BUYING weETH ===",  WETH, WEETH, 4000e18); }

    /// @notice Baseline: where does the deviation sit with no attack at all?
    function test_baselineDeviation() public view {
        assertLt(_deviationBps(), 50, "pool already off-fair before any attack");
    }
}

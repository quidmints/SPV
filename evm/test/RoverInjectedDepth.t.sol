// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ForkPin} from "./utils/ForkPin.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IV3SwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";
import {IWeETH} from "../src/imports/Interfaces.sol";

/// @notice THE COUNTERFACTUAL THE DOC SAYS WAS NEVER RUN (QUEUE R11: *"R9 measures the pool WITHOUT
///         Rover. It cannot measure the pool WITH Rover."*). Injects a Rover-sized one-tick position
///         into the REAL pool on a fork, then runs the offramp through it and measures the TRUE
///         all-in cost.
///
///         WHY "realised swap price" IS THE WRONG METRIC HERE. When Rover is BOTH the LP and the
///         swapper, the price impact it pays on its own liquidity is paid TO ITSELF and lands back
///         in the position. Quoting the swap alone counts that as a loss when it is an internal
///         transfer. So this measures TOTAL PORTFOLIO VALUE (idle WETH + idle weETH + everything
///         recovered from the position), valued at the ether.fi fair rate, BEFORE vs AFTER. The
///         difference is the real cost of converting weETH into deliverable WETH.
///
///         Baseline for comparison is the same conversion with NO position (`test_noDepth_baseline`).
contract RoverInjectedDepthTest is ForkPin {
    address constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // token0
    address constant WEETH  = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // token1
    address constant ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant NFPM   = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant POOL_A = 0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3;
    uint24  constant FEE    = 500;

    uint tokenId;

    function setUp() public { vm.selectFork(_forkMainnet()); }

    function _fairValue(uint weth, uint weeth) internal view returns (uint) {
        return weth + (weeth == 0 ? 0 : IWeETH(WEETH).getEETHByWeETH(weeth));
    }

    /// @dev Mint a one-tick band exactly where Rover would (`_adjustTicks`: floor to spacing, +1 spacing),
    ///      funding it generously and letting the NFPM take whatever the ratio requires.
    function _injectRoverPosition(uint wethSize) internal returns (int24 lo, int24 hi) {
        (, int24 tick,,,,,) = IUniswapV3Pool(POOL_A).slot0();
        int24 spacing = IUniswapV3Pool(POOL_A).tickSpacing();
        int24 rem = tick % spacing; if (rem < 0) rem += spacing;
        lo = tick - rem; hi = lo + spacing;

        uint weethSize = IWeETH(WEETH).getWeETHByeETH(wethSize);
        deal(WETH, address(this), wethSize);
        deal(WEETH, address(this), weethSize);
        IERC20(WETH).approve(NFPM, type(uint).max);
        IERC20(WEETH).approve(NFPM, type(uint).max);
        (tokenId,,,) = INonfungiblePositionManager(NFPM).mint(
            INonfungiblePositionManager.MintParams({
                token0: WETH, token1: WEETH, fee: FEE, tickLower: lo, tickUpper: hi,
                amount0Desired: wethSize, amount1Desired: weethSize,
                amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp
            }));
    }

    /// @dev Pull everything back out of the position so the final tally is in plain tokens.
    function _unwindPosition() internal {
        if (tokenId == 0) return;
        (,,,,,,, uint128 liq) = _positionLiquidity(tokenId);
        if (liq > 0) {
            INonfungiblePositionManager(NFPM).decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liq, 0, 0, block.timestamp));
        }
        INonfungiblePositionManager(NFPM).collect(
            INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max));
    }

    function _positionLiquidity(uint id) internal view
        returns (uint96, address, address, address, uint24, int24, int24, uint128 liq) {
        (,,,,,,, liq) = IPos(NFPM).positions(id);
    }

    /// @dev Convert `sellWeeth` weETH into WETH through the pool and report the TRUE all-in bps,
    ///      counting the position's value on both sides of the trade.
    function _convertAndPrice(uint sellWeeth) internal returns (int bps) {
        deal(WEETH, address(this), IERC20(WEETH).balanceOf(address(this)) + sellWeeth);
        uint before = _fairValue(IERC20(WETH).balanceOf(address(this)), IERC20(WEETH).balanceOf(address(this)));
        // the position's value is already ours; count it by unwinding at the end, so `before` must
        // include it too -- add it via the same unwind on a snapshot.
        uint256 snap = vm.snapshotState();
        _unwindPosition();
        uint beforeAll = _fairValue(IERC20(WETH).balanceOf(address(this)), IERC20(WEETH).balanceOf(address(this)));
        vm.revertToState(snap);
        before = beforeAll;

        IERC20(WEETH).approve(ROUTER, sellWeeth);
        IV3SwapRouter(ROUTER).exactInputSingle(IV3SwapRouter.ExactInputSingleParams({
            tokenIn: WEETH, tokenOut: WETH, fee: FEE, recipient: address(this),
            amountIn: sellWeeth, amountOutMinimum: 0, sqrtPriceLimitX96: 0 }));
        _unwindPosition();
        uint afterAll = _fairValue(IERC20(WETH).balanceOf(address(this)), IERC20(WEETH).balanceOf(address(this)));

        uint sellFair = IWeETH(WEETH).getEETHByWeETH(sellWeeth);
        bps = (int(afterAll) - int(before)) * 10000 / int(sellFair);
    }

    /// @notice BASELINE: no Rover position. This is today's pool.
    function test_noDepth_baseline() public {
        emit log_string("=== BASELINE: no Rover position (today's pool) ===");
        uint[4] memory sizes = [uint(100e18), 500e18, 1000e18, 2000e18];
        for (uint i; i < sizes.length; ++i) {
            uint256 s = vm.snapshotState();
            tokenId = 0;
            int bps = _convertAndPrice(sizes[i]);
            emit log_named_uint("sell weETH", sizes[i] / 1e18);
            emit log_named_int ("  TRUE all-in bps", bps);
            vm.revertToState(s);
        }
    }

    /// @notice WETH-ONLY, placed ABOVE spot -- the structure R8 dismissed as "single-sided is dead"
    ///         while only ever considering the weETH side. A position above spot holds 100% token0
    ///         (WETH): it is instantly pullable as the very asset the offramp delivers, it CANNOT be
    ///         ratcheted by the drift (already fully converted, and drift pushes spot further away),
    ///         and it earns fees precisely when someone sells weETH through it -- i.e. on our own flow.
    ///         Placed over [-940,-900], the range the real stranded wall occupies.
    int24 LO; int24 HI;
    function test_wethOnlyAboveSpot() public { LO=-940; HI=-900; _runBand(); }
    /// @notice WIDE band ANCHORED AT SPOT and extending UP: no gap to cross, mostly WETH (spot sits
    ///         2 ticks above the lower edge of a 50-tick range), in range so it earns fees, and only
    ///         the small weETH sliver is exposed to the ratchet.
    function test_wideBandAnchoredAtSpot() public { LO=-950; HI=-900; _runBand(); }
    function test_wideBandAnchoredAtSpot_narrower() public { LO=-950; HI=-920; _runBand(); }
    function _runBand() internal {
        uint size = 4000e18;
        emit log_named_int("=== band lower", LO); emit log_named_int("    band upper", HI);
        uint[4] memory sizes = [uint(100e18), 500e18, 1000e18, 2000e18];
        for (uint i; i < sizes.length; ++i) {
            uint256 s0 = vm.snapshotState();
            deal(WETH, address(this), size); deal(WEETH, address(this), IWeETH(WEETH).getWeETHByeETH(size));
            IERC20(WETH).approve(NFPM, type(uint).max);
            IERC20(WEETH).approve(NFPM, type(uint).max);
            (tokenId,,,) = INonfungiblePositionManager(NFPM).mint(
                INonfungiblePositionManager.MintParams({
                    token0: WETH, token1: WEETH, fee: FEE, tickLower: LO, tickUpper: HI,
                    amount0Desired: size, amount1Desired: IWeETH(WEETH).getWeETHByeETH(size),
                    amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp
                }));
            emit log_named_uint("  WETH deployed", size - IERC20(WETH).balanceOf(address(this)));
            emit log_named_uint("  weETH deployed", IERC20(WEETH).balanceOf(address(this)));
            int bps = _convertAndPrice(sizes[i]);
            emit log_named_uint("sell weETH", sizes[i] / 1e18);
            emit log_named_int ("  TRUE all-in bps", bps);
            vm.revertToState(s0);
        }
    }

    /// @notice WITH a Rover-sized one-tick position injected. If the self-counterparty argument is
    ///         right, the all-in cost collapses for sizes the band can absorb.
    function test_withRoverDepth_1000() public { _run(1000e18); }
    function test_withRoverDepth_4000() public { _run(4000e18); }

    function _run(uint posSize) internal {
        emit log_string("=== WITH injected Rover position ===");
        emit log_named_uint("position size (WETH-equiv)", posSize / 1e18);
        uint[4] memory sizes = [uint(100e18), 500e18, 1000e18, 2000e18];
        for (uint i; i < sizes.length; ++i) {
            uint256 s = vm.snapshotState();
            (int24 lo, int24 hi) = _injectRoverPosition(posSize);
            emit log_named_int("band lower", lo); emit log_named_int("band upper", hi);
            int bps = _convertAndPrice(sizes[i]);
            emit log_named_uint("sell weETH", sizes[i] / 1e18);
            emit log_named_int ("  TRUE all-in bps", bps);
            vm.revertToState(s);
        }
    }
}

interface IPos {
    function positions(uint tokenId) external view
        returns (uint96, address, address, address, uint24, int24, int24, uint128);
}

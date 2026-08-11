// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {ICurvePool} from "../src/imports/Interfaces.sol";

interface IERC20C {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}
interface IOracle { function price() external view returns (uint256); }

/// @notice Pins the Curve `weETH/WETH-ng` pool the weETH offramp now sells into.
///
/// WHY THIS FILE EXISTS. Measured 2026-08-09: **no test in this repo referenced `offrampEtherFi`,
/// `offrampBody` or `sourceWethBody`** — the offramp had ZERO coverage. So when the two-tier Uniswap v3
/// loop was replaced by a single Curve `exchange`, the full suite would have passed identically had the
/// pool address, the coin indices, or the function signature been wrong. A green run could not
/// distinguish working from broken, which is the same gap `LevVenueMarketPins` was written to close for
/// the lev venues.
///
/// WHAT IT GUARDS, and each of these is a way the swap fails SILENTLY or not at all:
///   - the pool is the real weETH/WETH pair, with the coin ORDER the code hardcodes (weETH=1, WETH=0);
///   - the `int128` signature works and the `uint256` one does NOT — the wrong one reverts, and
///      `curveSellWeeth` swallows reverts by design (returns 0), so a signature error would degrade the
///      offramp to the wait-NFT rung on every exit and never announce itself;
///   - execution is at or near fair, which is the entire reason for the switch;
///   - the pool is DEEP enough to matter — a correctly-formed empty pool is the failure mode that has
///      already appeared three times in this repo (two 86% Morpho decoys, Euler's eWETH-14).
contract CurveOfframpPins is ForkPin {
    address constant POOL   = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;  // weETH/WETH-ng
    address constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WEETH  = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant ORACLE = 0xbDd2F2D473E8D63d1BFb0185B5bDB8046ca48a72;  // weETH/WETH, 1e36

    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// The coin ORDER is hardcoded as `exchange(1, 0, …)` in `SwapLib.curveSellWeeth`. If the pool ever
    /// ordered them the other way the swap would sell WETH for weETH — the exact opposite of an offramp,
    /// and it would still "succeed".
    function test_Curve_PoolIdentityAndCoinOrder() public view {
        assertEq(ICurvePool(POOL).coins(0), WETH,  "coin0 is not WETH - exchange(1,0) would be backwards");
        assertEq(ICurvePool(POOL).coins(1), WEETH, "coin1 is not weETH");
    }

    /// @dev The `int128` overload is the one this pool answers; the uint256 `-ng` variant REVERTS.
    ///      `curveSellWeeth` catches reverts and returns 0, so getting this wrong does not fail loudly —
    ///      it silently routes every exit to the wait-NFT rung. Hence a test, not a comment.
    function test_Curve_Int128SignatureIsTheLiveOne() public view {
        uint256 dy = ICurvePool(POOL).get_dy(int128(1), int128(0), 1 ether);
        assertGt(dy, 0, "int128 get_dy returned 0 - the offramp would silently fall through to waitNft");

        (bool ok,) = POOL.staticcall(
            abi.encodeWithSignature("get_dy(uint256,uint256,uint256)", uint256(1), uint256(0), 1 ether));
        assertFalse(ok, "the uint256 variant now answers too - re-check which one curveSellWeeth uses");
    }

    /// Execution at or near fair is the WHOLE reason for replacing Uniswap. Measured 2026-08-09 against
    /// this oracle: -1.39 bps at size 1, -1.51 at 100, -3.47 at 1000, versus the v3 0.01% tier: -17.55 / -18.79 /
    /// -28.16. The bound below is deliberately loose (50 bps) so it fails on a BROKEN pool rather than on
    /// ordinary drift — it is a regression guard, not a pin of today's number.
    function test_Curve_ExecutesNearFair() public view {
        uint256 px = IOracle(ORACLE).price();               // 1e36: WETH per weETH
        for (uint256 i; i < 3; i++) {
            uint256 sz  = [uint256(1 ether), 100 ether, 1000 ether][i];
            uint256 out = ICurvePool(POOL).get_dy(int128(1), int128(0), sz);
            uint256 fair = (sz * px) / 1e36;
            assertGt(out, (fair * 9950) / 10_000, "Curve execution worse than 50 bps from fair");
            assertLt(out, (fair * 10_050) / 10_000, "Curve quote ABOVE fair by >50 bps - suspect oracle/pool mismatch");
        }
    }

    /// Depth, asserted for the same reason `LevVenueMarketPins` asserts it: a correctly-formed EMPTY pool
    /// passes every structural check above and can never fill.
    function test_Curve_HasRealDepth() public view {
        uint256 wethBal = IERC20C(WETH).balanceOf(POOL);
        assertGt(wethBal, 200 ether, "pool WETH too thin - the offramp would cliff into waitNft");
    }

    /// A REAL swap, not a quote. `get_dy` is a view and can be right while `exchange` reverts on approval,
    /// coin order or a paused pool. This is the only assertion here that proves the offramp can actually
    /// convert, and it measures the WETH DELTA rather than trusting the return value.
    function test_Curve_ExchangeActuallyFills() public {
        uint256 amt = 10 ether;
        deal(WEETH, address(this), amt);
        IERC20C(WEETH).approve(POOL, amt);

        uint256 before = IERC20C(WETH).balanceOf(address(this));
        uint256 quoted = ICurvePool(POOL).get_dy(int128(1), int128(0), amt);
        uint256 ret    = ICurvePool(POOL).exchange(int128(1), int128(0), amt, (quoted * 995) / 1000);
        uint256 delta  = IERC20C(WETH).balanceOf(address(this)) - before;

        assertGt(delta, 0, "exchange moved no WETH - the offramp cannot convert");
        assertEq(delta, ret, "returned amount != measured balance delta");
        assertApproxEqRel(delta, quoted, 1e15, "fill drifted >0.1% from the quote in the same block");
    }
}

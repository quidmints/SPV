// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {ONEINCH_ROUTER, UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR, ZERO_FOR_ONE, USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20V2 { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }
interface IV3 { function token0() external view returns (address); function token1() external view returns (address); }

/// @notice §SESS-25 — **THE KEEPER PLANNER'S VENUE TABLE, VERIFIED BY EXECUTION.**
///
/// The planner is `dex_word()`: **one hardcoded pool, env-overridable, returned for every pair.** That is
/// why `dex_word_wbtc()` had to exist at all — its own note says pointing the WETH/USDC word at a
/// `USDC → WBTC` swap *"would send a token that pool does not hold."* A table keyed by PAIR removes the
/// need for per-asset twins.
///
/// 🔑 **A POOL WORD IS ONLY WORTH SHIPPING IF IT FILLS.** §SESS-22 measured `proto=2` (Curve) filling
///    **zero** on two real pools while the router's own bit table claims it is supported, so nothing here
///    is taken from documentation: each row below is executed through `unoswap` on a pinned fork and
///    asserted to move tokens. A row that does not fill is not a row.
/// ⚠️ **`zeroForOne` IS NOT IN THE TABLE, DELIBERATELY.** `_aggSwap` DERIVES it from `tokenIn` and
///    discards whatever the keeper set — *"the keeper names pools, never directions"* — so the planner
///    must not carry a direction bit it cannot be trusted with anyway.
contract PlannerVenues is ForkPin {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Candidates, all Uniswap V3 (proto id 1 — the only id measured to fill).
    address constant V3_USDC_WETH_005 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant V3_WBTC_USDC_030 = 0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35;
    address constant V3_USDT_USDC_001 = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    address constant V3_DAI_USDC_001  = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168;

    function setUp() public { vm.selectFork(_forkMainnet()); }

    function _word(address pool, address tokenIn) internal view returns (uint256 w) {
        w = (uint256(1) << 253) | uint256(uint160(pool));          // PROTO_UNIV3
        if (IV3(pool).token0() == tokenIn) w |= ZERO_FOR_ONE;      // derived, exactly as _aggSwap does
    }

    /// @dev ⚠️ **RAW-CALL `approve`, NOT THE TYPED ONE — AND THIS TEST HIT THE TRAP ON ITS FIRST RUN.**
    ///      `IERC20V2.approve` declares `returns (bool)` and **USDT RETURNS NOTHING**, so the ABI decoder
    ///      reverts on empty returndata. That is the exact hazard `convertTo` records as *"a latent bug,
    ///      not a new need"* — the reason it calls `forceApprove`. A test that cannot approve USDT cannot
    ///      verify the USDT row, and the failure looks like a dead pool rather than a decoder fault.
    function _approveRaw(address tok, uint256 amt) internal {
        (bool ok, ) = tok.call(abi.encodeWithSignature("approve(address,uint256)", ONEINCH_ROUTER, amt));
        require(ok, "approve failed");
    }

    function _fill(address tin, address tout, uint256 amt, address pool) internal returns (uint256 got) {
        deal(tin, address(this), amt);
        _approveRaw(tin, amt);
        uint256 b = IERC20V2(tout).balanceOf(address(this));
        (bool ok, ) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            UNOSWAP_SELECTOR, uint256(uint160(tin)), amt, uint256(1), _word(pool, tin)));
        ok;
        got = IERC20V2(tout).balanceOf(address(this)) - b;
        _approveRaw(tin, 0);
    }

    /// ⭐ EVERY ROW THE PLANNER WILL SHIP, PROVEN TO MOVE TOKENS.
    function test_EveryPlannerRowFills() public {
        uint256 a = _fill(USDC, WETH, 50_000e6, V3_USDC_WETH_005);
        console2.log("USDC -> WETH :", a); assertGt(a, 0, "USDC/WETH row does not fill");
        uint256 b = _fill(USDC, WBTC, 50_000e6, V3_WBTC_USDC_030);
        console2.log("USDC -> WBTC :", b); assertGt(b, 0, "WBTC/USDC row does not fill");
        uint256 c = _fill(USDT, USDC, 50_000e6, V3_USDT_USDC_001);
        console2.log("USDT -> USDC :", c); assertGt(c, 0, "USDT/USDC hub row does not fill");
        uint256 d = _fill(DAI, USDC, 50_000e18, V3_DAI_USDC_001);
        console2.log("DAI  -> USDC :", d); assertGt(d, 0, "DAI/USDC hub row does not fill");
    }

    /// ⭐ AND THE TWO-HOP THE `dex2` PLUMBING EXISTS FOR: USDT -> USDC -> WETH in ONE call, no Curve,
    ///    no keeper calldata. This is what a planner emits once it has a hub row AND a volatile row.
    function test_TwoHopThroughTheHubFills() public {
        uint256 amt = 50_000e6;
        deal(USDT, address(this), amt);
        _approveRaw(USDT, amt);
        uint256 b = IERC20V2(WETH).balanceOf(address(this));
        (bool ok, ) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            UNOSWAP2_SELECTOR, uint256(uint160(USDT)), amt, uint256(1),
            _word(V3_USDT_USDC_001, USDT), _word(V3_USDC_WETH_005, USDC)));
        ok;
        uint256 got = IERC20V2(WETH).balanceOf(address(this)) - b;
        console2.log("USDT -> USDC -> WETH (unoswap2):", got);
        assertGt(got, 0, "the two-hop does not fill - dex2 planning would be dead on arrival");
    }
}

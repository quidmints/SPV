// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {ONEINCH_ROUTER, UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR, ZERO_FOR_ONE, USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IE {function balanceOf(address) external view returns (uint256);}
interface IV3b {function token0() external view returns (address);}

/// @notice §SESS-37 — **WHAT IS ROUTE OPTIMALITY ACTUALLY WORTH?** The question that decides whether the
///         keeper/route design needs re-architecting or merely extending.
///
/// Owner: *"is there a way to make sure that the provided route is optimal among all possible routes"* and
/// *"MEASURE ALL the things."* §SESS-36 argued optimality is not VERIFIABLE on-chain. That says nothing
/// about whether it is VALUABLE — and if the spread between a naive route and the best reachable one is a
/// couple of bps, no amount of architecture is worth paying for. **This measures the spread.**
///
/// ⚠️ **BOUND THE CLAIM UP FRONT: this measures the spread among routes WE CAN REACH.** It cannot bound
///    what an off-chain solver would find outside that set, so it is a **LOWER bound** on the value of
///    optimality, never an estimate of it.
///
/// 🔑 **AND IT IS MEASURED PER USE-SITE, NOT ABSTRACTLY** (owner: *"dont measure abstractly but with
///    respect to our specific uses of 1inch (swap out, redeem, il protect)"*). The three real legs are:
///      · **IL-PROTECT / LEVER-UP** — `_stableToWethSor:1014`: **stable → WETH**, then ether.fi mints
///        weETH (not 1inch). The amount is `venue.borrow(...)`'s return, computed on-chain.
///      · **DELEVER / CLOSE** — `_wethToStableDex` via `_volToStable:581`: **WETH → stable**, the mirror.
///      · **REDEEM / SWAP-OUT** — `convertShortfall:757`: **N stables → payoutToken**, ONE LEG PER
///        STABLE, sized by a PRO-RATA draw. This is the multi-leg path, and the one where a per-leg
///        route choice is made 14 times in a single transaction.
///    The generic USDC→WETH sweep below is kept as the CONTROL for the encoder itself.
contract RouteOptimalityValue is ForkPin {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant P_USDC_WETH_005 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant P_USDC_WETH_030 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant P_USDT_USDC_001 = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    address constant P_USDT_WETH_030 = 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36;
    address constant P_DAI_USDC_001  = 0x5777d92f208679DB4b9778590Fa3CAB3aC9e2168;
    address constant P_DAI_WETH_030  = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8;

    function setUp() public { vm.selectFork(_forkMainnet()); }

    function _w(address pool, address tin) internal view returns (uint256 w) {
        w = (uint256(1) << 253) | uint256(uint160(pool));
        if (IV3b(pool).token0() == tin) w |= ZERO_FOR_ONE;
    }
    function _ap(address t, uint256 a) internal {
        (bool ok,) = t.call(abi.encodeWithSignature("approve(address,uint256)", ONEINCH_ROUTER, a));
        require(ok, "approve");
    }
    /// One hop. Returns WETH received.
    function _one(uint256 amt, address pool) internal returns (uint256) {
        deal(USDC, address(this), amt); _ap(USDC, amt);
        uint256 b = IE(WETH).balanceOf(address(this));
        (bool ok,) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            UNOSWAP_SELECTOR, uint256(uint160(USDC)), amt, uint256(1), _w(pool, USDC)));
        ok; _ap(USDC, 0);
        return IE(WETH).balanceOf(address(this)) - b;
    }
    /// Two hops: USDC -> mid -> WETH.
    function _two(uint256 amt, address p1, address p2, address mid) internal returns (uint256) {
        deal(USDC, address(this), amt); _ap(USDC, amt);
        uint256 b = IE(WETH).balanceOf(address(this));
        (bool ok,) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            UNOSWAP2_SELECTOR, uint256(uint160(USDC)), amt, uint256(1), _w(p1, USDC), _w(p2, mid)));
        ok; _ap(USDC, 0);
        return IE(WETH).balanceOf(address(this)) - b;
    }

    /// ⭐ THE ANSWER: best-vs-worst reachable route, per size, in bps of the trade.
    function test_TheSpreadBetweenTheBestAndWorstReachableRoute() public {
        uint256[4] memory sizes = [uint256(10_000e6), 100_000e6, 1_000_000e6, 5_000_000e6];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 amt = sizes[i];
            uint256 s = vm.snapshotState();
            uint256 a = _one(amt, P_USDC_WETH_005);                       vm.revertToState(s);
            uint256 b = _one(amt, P_USDC_WETH_030);                       vm.revertToState(s);
            uint256 c = _two(amt, P_USDT_USDC_001, P_USDT_WETH_030, USDT); vm.revertToState(s);
            uint256 d = _two(amt, P_DAI_USDC_001,  P_DAI_WETH_030,  DAI);  vm.revertToState(s);
            uint256 best = a; if (b > best) best = b; if (c > best) best = c; if (d > best) best = d;
            uint256 worst = type(uint256).max;
            if (a > 0 && a < worst) worst = a; if (b > 0 && b < worst) worst = b;
            if (c > 0 && c < worst) worst = c; if (d > 0 && d < worst) worst = d;
            console2.log("=== size USDC (6dec):", amt);
            console2.log("   v3 0.05% direct :", a);
            console2.log("   v3 0.30% direct :", b);
            console2.log("   via USDT (2hop) :", c);
            console2.log("   via DAI  (2hop) :", d);
            if (best > 0 && worst != type(uint256).max)
                console2.log("   BEST vs WORST, bps:", (best - worst) * 10_000 / best);
            assertGt(best, 0, "no route filled at this size - the comparison is empty");
        }
    }

    // ───────────────────────── PER USE-SITE ─────────────────────────

    /// @dev ⚠️ **OWN FRAMES, NO `via_ir` — the tree's standing constraint.** A single body doing both
    ///      arms blew the stack at the second `_w(...)`; splitting is the remedy this repo uses
    ///      everywhere rather than turning on the optimiser.
    function _fillOne(address stable, uint256 amt, address pool) internal returns (uint256) {
        deal(stable, address(this), amt); _ap(stable, amt);
        uint256 b = IE(WETH).balanceOf(address(this));
        (bool k,) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            UNOSWAP_SELECTOR, uint256(uint160(stable)), amt, uint256(1), _w(pool, stable))); k;
        return IE(WETH).balanceOf(address(this)) - b;
    }
    function _fillHub(address stable, uint256 amt, address pHub) internal returns (uint256) {
        deal(stable, address(this), amt); _ap(stable, amt);
        uint256 b = IE(WETH).balanceOf(address(this));
        (bool k,) = ONEINCH_ROUTER.call(abi.encodeWithSelector(
            UNOSWAP2_SELECTOR, uint256(uint160(stable)), amt, uint256(1),
            _w(pHub, stable), _w(P_USDC_WETH_005, USDC))); k;
        return IE(WETH).balanceOf(address(this)) - b;
    }
    function _legBothWays(address stable, uint256 amt, address pDirect, address pHub)
        internal returns (uint256 direct, uint256 viaHub) {
        uint256 s1 = vm.snapshotState();
        direct = _fillOne(stable, amt, pDirect);
        vm.revertToState(s1);
        viaHub = _fillHub(stable, amt, pHub);
        vm.revertToState(s1);
    }

    /// ⭐ USE-SITE 1 — **IL-PROTECT / LEVER-UP** (`_stableToWethSor`): stable → WETH.
    ///    The tree's own path hub-hops through USDC FIRST (Curve, contract-side) and then buys WETH,
    ///    so "direct" here is the alternative a route could take and the comparison is the real choice.
    function test_UseSite_IlProtectLeverUp_StableToWeth() public {
        uint256[3] memory sizes = [uint256(100_000), 1_000_000, 5_000_000];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 a6 = sizes[i] * 1e6;
            (uint256 dU, uint256 hU) = _legBothWays(USDT, a6, P_USDT_WETH_030, P_USDT_USDC_001);
            (uint256 dD, uint256 hD) = _legBothWays(DAI, sizes[i] * 1e18, P_DAI_WETH_030, P_DAI_USDC_001);
            console2.log("=== IL-PROTECT size USD:", sizes[i]);
            console2.log("   USDT direct / viaUSDC:", dU, hU);
            console2.log("   DAI  direct / viaUSDC:", dD, hD);
            uint256 bestU = dU > hU ? dU : hU; uint256 wU = dU > hU ? hU : dU;
            if (bestU > 0) console2.log("   USDT best-vs-other bps:", (bestU - wU) * 10_000 / bestU);
            uint256 bestD = dD > hD ? dD : hD; uint256 wD = dD > hD ? hD : dD;
            if (bestD > 0) console2.log("   DAI  best-vs-other bps:", (bestD - wD) * 10_000 / bestD);
            assertGt(bestU, 0, "no USDT->WETH route filled: the IL-protect leg has no venue at this size");
        }
    }

    /// ⭐ USE-SITE 2 — **REDEEM / SWAP-OUT** (`convertShortfall`): the PRO-RATA leg, one per stable.
    ///    A redemption does NOT convert one big ticket; it converts N small ones. This measures the
    ///    per-leg size that actually occurs, which is the whole trade divided by the roster.
    function test_UseSite_RedeemSwapOut_PerLegSizeIsWhatMatters() public {
        uint256[3] memory totals = [uint256(100_000), 1_000_000, 5_000_000];
        for (uint256 i; i < totals.length; ++i) {
            uint256 perLeg = (totals[i] / 13) * 1e6;         // 13 convertible stables, pro-rata
            (uint256 d, uint256 h) = _legBothWays(USDT, perLeg, P_USDT_WETH_030, P_USDT_USDC_001);
            console2.log("=== REDEEM total USD:", totals[i]);
            console2.log("   per-leg USD (13 stables):", perLeg / 1e6);
            console2.log("   USDT direct / viaUSDC   :", d, h);
            uint256 best = d > h ? d : h; uint256 w = d > h ? h : d;
            if (best > 0) console2.log("   best-vs-other bps       :", (best - w) * 10_000 / best);
            assertGt(best, 0, "no route filled for a redeem leg at this size");
        }
    }
}

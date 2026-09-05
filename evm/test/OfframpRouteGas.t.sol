// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {ICurvePool, ONEINCH_ROUTER, UNOSWAP_SELECTOR, DEFAULT_UNWIND_DEX, USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20G {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice §MASTER-ORDER GATE 2.4 — **MEASURE, DO NOT ARGUE, whether routing the weETH offramp through
///         1inch costs more gas than the direct Curve call it does today.**
///
/// WHY THIS FILE EXISTS. The Curve-vs-1inch decision was recorded per use-site (owner, 2026-09-05:
/// *"do what is more gas efficient, for stables its gonna be 1inch for sure. for the il protect borrow
/// or for swap outs or redeems… there are multiple uses"*). Stables are settled — 1inch. The weETH
/// offramp is NOT, because it is a **pinned single-LST venue** with three consumers on different
/// profiles (the IL-protect borrow is keeper-paid; swap-out delivery and the redeem/withdraw offramp are
/// user-facing). A per-hop overhead was ARGUED at ~30-50k from first principles and never measured; this
/// file measures it, because `foundry.toml` already sets `gas_reports = ["*"]` and the argument is
/// otherwise exactly the kind of unmeasured axis standing rule 9 names.
///
/// ⚠️ THE 2026-08-09 MEASUREMENT THAT PUT THE OFFRAMP ON CURVE COMPARED **CURVE vs UNISWAP V3**, NEVER
///    **CURVE vs ROUTED** (-1.39 vs -17.55 bps at size 1 weETH, -3.47 vs -28.16 at size 1000). It settled which POOL
///    is cheaper on price. It says nothing about whether reaching that same pool through the aggregator
///    costs gas — which is the only question here, since 1inch routes to Curve when Curve is best.
///
/// 🔑 WHAT IS BEING SEPARATED, because conflating them is how this question stays open:
///      (1) the WRAPPER overhead — `convertTo`'s two `balanceOf` reads, the per-leg approve-then-zero,
///          and the external dispatch. **Venue-independent**, paid per leg, and the number that
///          generalises to every other routed hop.
///      (2) the ROUTER overhead — 1inch pulling the tokens to itself and pushing them to the pool,
///          i.e. one extra ERC-20 transfer versus approving the pool and letting it pull once.
///
/// ⛔ AND THE PRIOR QUESTION THIS ANSWERS FIRST, WHICH NOBODY HAD ASKED: **can `_aggSwap` even ENCODE a
///    Curve pool word?** `PROTO_UNIV3 = 1` is the ONLY protocol constant in `Interfaces.sol`, and
///    `_aggSwap` derives `ZERO_FOR_ONE` only for that branch — every other protocol id is passed through
///    untouched, but **nothing in the tree ever constructs one**. If Curve is not encodable, "route the
///    offramp through 1inch" is not a drop-in at all and the gas delta is the smaller half of the cost.
///    This test ENUMERATES the protocol ids rather than inferring one, per CLAUDE.md: *"BEFORE CONCLUDING
///    'X DOES NOT SUPPORT Y', ENUMERATE X'S INTERFACE — do not infer it from one call's output."*
contract OfframpRouteGas is ForkPin {
    address constant POOL  = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5; // weETH/WETH-ng
    address constant WETH  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;

    uint256 constant SIZE = 10 ether;

    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// @dev Baseline: the raw pool call, with the approval OUTSIDE the measurement, so this is the
    ///      irreducible cost of the swap itself. Everything else is measured against it.
    function test_Gas_A_DirectCurveExchange() public {
        deal(WEETH, address(this), SIZE);
        IERC20G(WEETH).approve(POOL, SIZE);
        uint256 quoted = ICurvePool(POOL).get_dy(int128(1), int128(0), SIZE);

        uint256 before = IERC20G(WETH).balanceOf(address(this));
        uint256 g0 = gasleft();
        ICurvePool(POOL).exchange(int128(1), int128(0), SIZE, (quoted * 995) / 1000);
        uint256 used = g0 - gasleft();
        uint256 got = IERC20G(WETH).balanceOf(address(this)) - before;

        assertGt(got, 0, "baseline swap moved no WETH");
        console2.log("A. raw ICurvePool.exchange (approve excluded)   gas:", used);
        console2.log("   WETH out:", got);
    }

    /// @dev What the offramp ACTUALLY calls today: `sellWeethOnCurve` -> `curveExchange`, which adds a
    ///      `forceApprove` and a try/catch. This is the honest "direct path" number.
    function test_Gas_B_SellWeethOnCurveAsShipped() public {
        deal(WEETH, address(this), SIZE);
        uint256 quoted = ICurvePool(POOL).get_dy(int128(1), int128(0), SIZE);

        uint256 before = IERC20G(WETH).balanceOf(address(this));
        uint256 g0 = gasleft();
        LevMath.sellWeethOnCurve(WEETH, POOL, SIZE, (quoted * 995) / 1000);
        uint256 used = g0 - gasleft();
        uint256 got = IERC20G(WETH).balanceOf(address(this)) - before;

        assertGt(got, 0, "shipped offramp path moved no WETH");
        console2.log("B. LevMath.sellWeethOnCurve (as shipped)        gas:", used);
        console2.log("   WETH out:", got);
    }

    /// @dev 🔑 THE PRIOR QUESTION. Enumerate 1inch v6 `unoswap` protocol ids against the SAME Curve pool
    ///      and report which, if any, executes. A wrong id cannot do harm here: the call either reverts
    ///      or moves nothing, and we measure the WETH delta rather than trusting a return value — the
    ///      same discipline `convertTo` itself uses.
    ///
    ///      ⚠️ A Curve `exchange` needs COIN INDICES (i, j). A bare `(proto << 253) | uint160(pool)` word
    ///      carries none, so if 1inch encodes Curve at all it must place them in the middle bits. The
    ///      probe therefore tries the bare word AND a small set of index placements before concluding.
    function test_Probe_IsCurveEncodableAsAUnoswapPoolWord() public {
        uint256 quoted = ICurvePool(POOL).get_dy(int128(1), int128(0), SIZE);
        uint256 floor_ = (quoted * 990) / 1000;
        uint256 hits;

        for (uint256 proto; proto < 8; ++proto) {
            uint256 base = (proto << 253) | uint256(uint160(POOL));
            // bare word, then weETH=coin1 -> WETH=coin0 index placements 1inch-style
            uint256[4] memory words = [
                base,
                base | (uint256(1) << 247),               // a single direction/index flag
                base | (uint256(1) << 208),               // i=1 in a middle byte
                base | (uint256(1) << 208) | (uint256(0) << 200)
            ];
            for (uint256 w; w < words.length; ++w) {
                uint256 snap = vm.snapshotState();
                deal(WEETH, address(this), SIZE);
                bytes memory route = abi.encodeWithSelector(
                    UNOSWAP_SELECTOR, uint256(uint160(WEETH)), SIZE, floor_, words[w]);

                IERC20G(WEETH).approve(ONEINCH_ROUTER, SIZE);
                uint256 before = IERC20G(WETH).balanceOf(address(this));
                (bool ok, ) = ONEINCH_ROUTER.call{gas: 3_000_000}(route);
                uint256 got = ok ? IERC20G(WETH).balanceOf(address(this)) - before : 0;
                if (ok && got >= floor_) {
                    hits++;
                    console2.log("   ENCODABLE: proto", proto, "variant", w);
                    console2.log("   WETH out:", got);
                }
                vm.revertToState(snap);
            }
        }
        console2.log("C. curve-as-unoswap-pool-word encodings that filled:", hits);
        // Deliberately NOT an assertion either way. A zero here is a FINDING (the offramp cannot be
        // routed without new encoding work), not a failure; a non-zero is the input to test D.
    }

    /// @dev 🔴🔴 **THE CONTROL, AND WITHOUT IT THE PROBE ABOVE PROVES NOTHING.** CLAUDE.md: *"Run the
    ///      CONTROL before concluding: would this measurement look the same if I were wrong?"* If my
    ///      `unoswap` calldata shape is simply wrong, **all 32 Curve combinations fail for that reason**
    ///      and the zero says nothing about Curve.
    ///
    ///      So: run the SAME encoder against a pool word this tree already ships and trusts —
    ///      `DEFAULT_UNWIND_DEX`, the Uniswap V3 WETH/USDC 0.05% pool `LevBase.rangeUnwindDex` falls back
    ///      to. And call **`LevMath._aggSwap` itself** rather than a re-encoding of it, so what is proven
    ///      is the real path (encode -> `convertTo` -> pinned router -> measured balance delta), not my
    ///      copy of it.
    ///
    ///      ⇒ IF THIS FILLS, the shape is right and the Curve zero is a REAL negative about Curve.
    ///      ⇒ IF THIS ALSO FAILS, the probe is worthless and must not be cited.
    function test_Control_KnownGoodV3PoolWordFillsThroughAggSwap() public {
        uint256 amt = 50_000e6;                       // 50k USDC, comfortably inside this pool
        deal(USDC, address(this), amt);

        uint256 before = IERC20G(WETH).balanceOf(address(this));
        uint256 g0 = gasleft();
        uint256 out = LevMath._aggSwap(USDC, WETH, amt, 1, DEFAULT_UNWIND_DEX, 0);
        uint256 used = g0 - gasleft();
        uint256 delta = IERC20G(WETH).balanceOf(address(this)) - before;

        console2.log("CONTROL. _aggSwap USDC->WETH via DEFAULT_UNWIND_DEX  gas:", used);
        console2.log("   WETH out:", delta);
        assertGt(delta, 0, "CONTROL FAILED - the unoswap encoder does not fill even on the tree's own pool word, so the Curve probe proves nothing");
        assertEq(out, delta, "convertTo returned something other than the measured delta");
    }

    /// @dev The WRAPPER overhead in isolation, and the number that generalises. `convertTo` is measured
    ///      against a route that does nothing, so what is left is exactly its own cost: two `balanceOf`
    ///      reads, `forceApprove` to the router and back to zero, and the dispatch. The floor is set to
    ///      zero so the empty route does not revert the frame we are trying to measure.
    ///      ⚠️ This is the LOWER BOUND on routing overhead. It excludes the router's own transferFrom,
    ///      which only a real fill pays.
    function test_Gas_D_ConvertToWrapperOverheadAlone() public {
        deal(WEETH, address(this), SIZE);
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        bytes[] memory r = new bytes[](1);
        t[0] = WEETH; a[0] = SIZE;
        r[0] = abi.encodeWithSelector(bytes4(0xdeadbeef));  // will fail; `continue` swallows it

        uint256 g0 = gasleft();
        uint256 got = LevMath.convertTo(t, a, WETH, 0, r);
        uint256 used = g0 - gasleft();

        // ⚠️ COLD vs WARM: the first call pays cold SSTORE + cold account access on the approval and on
        //    both token contracts. Steady state is the SECOND number, and quoting only the first
        //    OVERSTATES the per-leg overhead — which is the direction that would wrongly favour Curve.
        deal(WEETH, address(this), SIZE);
        uint256 g1 = gasleft();
        LevMath.convertTo(t, a, WETH, 0, r);
        uint256 warm = g1 - gasleft();

        assertEq(got, 0, "a failing leg must yield zero");
        console2.log("D. convertTo wrapper overhead, 1 leg, no fill   gas (cold):", used);
        console2.log("D. convertTo wrapper overhead, 1 leg, no fill   gas (warm):", warm);
    }
}

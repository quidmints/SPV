// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {UNOSWAP_SELECTOR, PROTO_UNIV3} from "../src/imports/Interfaces.sol";
import {IERC20 as IERC20F} from "forge-std/interfaces/IERC20.sol";

/// @notice ⭐ §SESS-101 — **THE A/B, ON FILLS INSTEAD OF QUOTES.**
///
/// 🔴 **EVERY 1inch FIGURE I PRODUCED BEFORE THIS WAS A QUOTE COMPARISON AGAINST A ROUTE THAT COULD
///    NOT EXECUTE.** §SESS-88's harness asked `/quote` and `best_plan_quoted` and reported 1inch
///    ahead by 57-68 bps on WBTC at $1M — while §SESS-99 later found the generic `swap()` arm reverted
///    `ZeroMinReturn()` on every call, so their side had never filled once. The numbers were real and
///    measured the wrong thing.
/// ⇒ this executes BOTH and compares the WETH/WBTC actually received. A fill cannot be wrong about
///   whether it happened.
contract OneInchRealFillTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant V3_USDC_WETH = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant V3_USDC_WBTC = 0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35;
    address constant FETCH_FROM   = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    function _fetch(address dst, uint256 amt) internal returns (bytes memory) {
        string[] memory c = new string[](6);
        c[0] = "python3"; c[1] = "../tools/fetch_1inch_route.py";
        c[2] = vm.toString(USDC); c[3] = vm.toString(dst);
        c[4] = vm.toString(amt);  c[5] = vm.toString(FETCH_FROM);
        return vm.ffi(c);
    }

    function _selfPlanned(address pool) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UNOSWAP_SELECTOR, uint256(0), uint256(0), uint256(0),
            uint256(uint160(pool)) | (PROTO_UNIV3 << 253));
    }

    function _run(address dst, address ourPool, uint256 amt, uint8 dec, string memory label) internal {
        bytes memory theirs = _fetch(dst, amt);
        if (theirs.length < 4) { emit log("SKIP: bridge returned no route"); vm.skip(true); return; }

        uint256 snap = vm.snapshotState();
        deal(USDC, address(this), amt);
        uint256 ours = LevMath.routedSwap(USDC, dst, amt, 0, _selfPlanned(ourPool));
        vm.revertToState(snap);

        deal(USDC, address(this), amt);
        uint256 got = LevMath.routedSwap(USDC, dst, amt, 0, theirs);

        emit log_named_string("pair", label);
        emit log_named_decimal_uint("  self-planned FILL", ours, dec);
        emit log_named_decimal_uint("  1inch        FILL", got, dec);
        emit log_named_int("  1inch - ours (bps)",
            ours == 0 ? int256(0)
                      : (int256(got) - int256(ours)) * 10_000 / int256(ours));

        // ⛔ THE ONLY ASSERTION IS THAT BOTH SIDES FILLED. Which one leads is a fact about two markets
        //    at one block (§POINT-IN-TIME-IS-NOT-AN-INVARIANT) — §SESS-71 already retracted one
        //    superiority claim that failed at three blocks on identical bytecode. A zero on either
        //    side is what makes the comparison meaningless, and that is what this guards.
        assertGt(ours, 0, "self-planned route did not fill");
        assertGt(got, 0, "the 1inch route did not fill - the generic arm is dead again");
    }

    function test_RealFill_UsdcToWeth_1M() public { _run(WETH, V3_USDC_WETH, 1_000_000e6, 18, "USDC->WETH $1M"); }

    /// ⭐ §SESS-103 — **DOES THE KEY ACTUALLY UNLOCK GHO? RE-ASKED, BECAUSE THE OLD ANSWER RESTED ON
    ///    AN ARM THAT NEVER FILLED.** I said all session that GHO and FRXUSD are reachable WITH the
    ///    API key and unreachable without — on the strength of 1inch QUOTING them at par. §SESS-99
    ///    then found the generic descriptor reverted `ZeroMinReturn()` on every call, so a quote was
    ///    all that claim ever had. This executes it.
    /// ⛔ There is no self-planned arm to compare against ON PURPOSE: GHO's only depth is in the v4
    ///    singleton, which no pool word can name — that is the whole reason the key matters here.
    function test_RealFill_GhoToWeth_100k() public {
        address GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
        string[] memory c = new string[](6);
        c[0] = "python3"; c[1] = "../tools/fetch_1inch_route.py";
        c[2] = vm.toString(GHO); c[3] = vm.toString(WETH);
        c[4] = vm.toString(uint256(100_000e18)); c[5] = vm.toString(FETCH_FROM);
        bytes memory r = vm.ffi(c);
        if (r.length < 4) { emit log("SKIP: bridge returned no route"); vm.skip(true); return; }

        deal(GHO, address(this), 100_000e18);
        uint256 got = LevMath.routedSwap(GHO, WETH, 100_000e18, 0, r);
        emit log_named_decimal_uint("GHO->WETH $100k, 1inch FILL", got, 18);
        assertGt(got, 0,
            "GHO did not fill through the 1inch arm - then GHO is unreachable with OR without the "
            "key, and the coverage matrix's 'v4 only' row is a hole rather than a key-gated venue");
        // Stables are ~1:1 and WETH is ~$2,500-4,000, so a fill this far below the mark means the
        // route executed against something other than $100k of GHO.
        assertGt(got, 15e18, "GHO->WETH filled implausibly low for $100k - wrong token or wrong size");
    }

    // ⛔ **NO WBTC CASE, AND THE REASON IS A HARNESS LIMIT RATHER THAN A RESULT.** Both WBTC sizes
    //    were here and both returned a ZERO fill from 1inch while the IDENTICAL code path filled for
    //    WETH. Ruled out in order: the gas cap (still zero at 12M, so `ROUTE_GAS_CAP` is not
    //    implicated) and the EVM version (`--evm-version prague` made it WORSE — $100k went from
    //    filling to not).
    // 🔑 The discriminating detail is in the calldata: the WBTC routes carry maker SIGNATURES and
    //    EXPIRY TIMESTAMPS — 1inch limit-order/RFQ legs. Those are signed off-chain against live
    //    state and **cannot be replayed on a fork**, whereas the WETH route is pure AMM and replays
    //    fine. ⇒ a zero here would measure our fixture, not their router.
    // ⚠️ SO THE CASES ARE REMOVED RATHER THAN SKIPPED OR LOGGED. A `vm.skip` on a route we cannot
    //    replay reads as coverage we do not have, and a logged verdict is what §SESS-87 deleted nine
    //    tests over. What CAN be verified is verified; what cannot is stated here and nowhere else.
    // 📌 CONSEQUENCE, AND IT IS THE POINT: **the "+57 to +68 bps to 1inch on WBTC at $1M" figure
    //    cannot be confirmed by execution on a fork.** It came from a QUOTE comparison in §SESS-88,
    //    against an arm that §SESS-99 later proved had never filled. It should not be repeated as a
    //    measured result — including by me, who repeated it all day.
}

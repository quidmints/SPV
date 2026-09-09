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

    /// ⭐ §SESS-121 — **A STALE FORK IS AN ABSENT PRECONDITION HERE TOO, AND THIS SUITE HAD NO GUARD.**
    ///
    /// 🔴 **MEASURED 2026-09-09, and the A/B is the point.** `test_RealFill_UsdcToWeth_1M` went red
    ///    after §SESS-120 gave `_retarget` a real `minLeg`. It looked like the new floor rejecting a
    ///    live route. **It was not:** with `minLeg` forced back to 0 the test fails IDENTICALLY —
    ///    same message, gas 3,923,514 vs 3,930,435. And `minLeg` is provably 0 for this pair anyway
    ///    (`_selfServableQuote(USDC, amt, WETH)` → `_curveQuote(WETH, …)` → `_hubRowOf(WETH)` has no
    ///    row → 0 → `swapMin = 1`, byte-identical to before). The route simply did not fill at $1M.
    /// ⛔ **BUT "did not fill" IS NOT THE MESSAGE IT PRINTED.** It printed *"the generic arm is dead
    ///    again"* — a CODE diagnosis for a MARKET condition, which is what sent me to a two-run A/B
    ///    for something no code change caused. §VACUOUS-BOUNDS' sibling: a true failure with a
    ///    misleading cause attached is a false lead with a green pedigree.
    /// ⇒ the same wall-clock-vs-`block.timestamp` guard `ConvertToRouted` carries (see its header for
    ///   why Foundry's fork REUSE makes a long run stale by itself), so an unfillable route on a
    ///   drifted fork ANNOUNCES and skips instead of accusing the contract.
    /// ⚠️ 300s ≈ 25 blocks, and a BATCH is what makes this bite: measured, these tests pass alone and
    ///    fail inside a 7-suite run, because the first suite to fork pins the block for the last.
    uint256 constant MAX_FORK_LAG = 300;

    function _freshOrSkip() internal returns (bool) {
        uint256 nowSec = vm.unixTime() / 1000;               // saturating: a fork can lead the clock
        uint256 lag = nowSec > block.timestamp ? nowSec - block.timestamp : 0;
        if (lag <= MAX_FORK_LAG) return true;
        emit log_named_uint("SKIP: fork is stale by (seconds)", lag);
        emit log("  a live 1inch route cannot execute against a fork this far behind head - ABSENT");
        emit log("  PRECONDITION, not a routing defect. Run this suite alone, not inside a batch.");
        vm.skip(true);
        return false;
    }

    function _run(address dst, address ourPool, uint256 amt, uint8 dec, string memory label) internal {
        if (!_freshOrSkip()) return;
        bytes memory theirs = _fetch(dst, amt);
        // 🔴 §SESS-111 — **AN ABSENT KEY AND A REJECTED ONE BOTH RETURN `0x`, AND ONLY ONE OF THEM IS
        //    A REASON TO SKIP.** `tools/scan-loose-ends.py` asks of every skip: *can a FAILURE reach
        //    this, not just an absence?* Here it could — a 403 (bad `from`, dead key, rate limit)
        //    yields the same empty route as no key at all, so this skipped past exactly the defect
        //    §SESS-99 spent a day on.
        // ⇒ the key's PRESENCE is the discriminator: unset ⇒ genuinely nothing to test, SKIP; set but
        //   empty ⇒ a producer we are paying for returned nothing, which is a FAILURE and must read
        //   as one.
        if (theirs.length < 4) {
            if (bytes(vm.envOr("ONEINCH_API_KEY", string(""))).length == 0) {
                emit log("SKIP: ONEINCH_API_KEY unset - nothing to compare against");
                vm.skip(true); return;
            }
            revert("the 1inch bridge returned an EMPTY route while a key IS configured - that is a "
                   "rejected request (403 on a bad `from`, a dead key, or a rate limit), not an "
                   "absent one. See SESS-88b and SESS-99.");
        }

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

    // ⛔ §SESS-109 — **`test_RealFill_GhoToWeth_100k` REMOVED, AND I SHIPPED IT ONE COMMIT AFTER
    //    DOCUMENTING WHY IT COULD NOT WORK.** §SESS-101 removed the WBTC cases because a 1inch route
    //    may contain maker/RFQ legs that are signed against live state and cannot be replayed on a
    //    fork — then §SESS-103 added GHO on the strength of ONE green run and asserted the fill.
    //    The full suite failed it at block 25932254: same route source, same limitation, and I had
    //    written the limitation down.
    // 📊 **THE MEASUREMENT STANDS AND IS THE POINT — it just is not a repeatable assertion.**
    //    Executed 2026-09-08: **100,000 GHO → 40.081013 WETH**, at par against a ~$2,495 mark. So the
    //    key DOES unlock GHO; that is verified once, by execution, and recorded here rather than
    //    re-asserted every run against a route whose legs expire.
    // ⚠️ A green-once test that fails on re-run is worse than no test: it converts a known harness
    //    limit into an intermittent red that the next reader will misdiagnose — which is exactly the
    //    day §SESS-99 cost. What can be verified is verified; what cannot is stated ONCE.

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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";

interface IERC20t { function balanceOf(address) external view returns (uint256); }

/// @notice §THE-KEY-ONLY-BUYS-SWAP — the M→1 primitive against REAL 1inch `swap()` calldata, sourced
///         through the `vm.ffi` bridge that already existed (`tools/fetch_1inch_route.py`) and was
///         never wired into a test.
/// @dev ⚠️ **THIS TEST SKIPS, LOUDLY, WITHOUT `ONEINCH_API_KEY` IN `evm/.env`.** The bridge prints
///      `0x` when it has no key — deliberately, so the absence surfaces as an empty route rather than
///      a fabricated one. A skip that announces itself is the honest shape here: the code is wired,
///      the input is missing, and nothing pretends otherwise.
///      ⛔ It must NOT be made to pass by mocking a route. The property under test is that REAL
///      aggregator calldata executes through the primitive and clears an oracle-derived floor; a
///      mock would assert the mock.
contract ConvertToRoutedTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// 🔴 **DO NOT RUN THIS SUITE WITH `FORK_BLOCK` SET. IT WILL FAIL AND IT IS NOT A DEFECT.**
    ///    The route is built against CURRENT mainnet state by `fetch_1inch_route.py`, while a pinned
    ///    fork executes at an older block — so the route's pools and maker orders no longer match.
    ///    **Measured: pinned 20 blocks behind head → `got == 0`; the identical test at head → 100.84
    ///    WETH.** The tool's own docstring calls this out: *"if FORK_BLOCK drifts far from head,
    ///    expect routes to stop executing — that is the tell, not a contract defect."*
    ///    ⚠️ This is a DELIBERATE exception to CLAUDE.md's *"quote a pass count only from a pinned
    ///    run"*: a live-route test cannot be pinned, so it runs at head and its result is quoted
    ///    separately from the pinned suite total.
    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    /// ⭐ §SESS-118 — **A STALE FORK IS AN ABSENT PRECONDITION, NOT A ROUTING DEFECT, AND IT COSTS
    ///    NO RPC CALL TO TELL THEM APART.**
    ///
    /// 🔴 **MEASURED 2026-09-08, and it is the §SESS-99 shape a third time.** `createSelectFork(url)`
    ///    does NOT mean "head" inside a long run: Foundry keys a fork by `(url, block)` and REUSES it,
    ///    so the FIRST suite in the process to fork at "latest" pins that number for every later suite
    ///    on the same URL. In the 180-suite run this suite executed at **25934235 while head was
    ///    25934305 — 70 blocks stale** — and `test_OneStableAlone` failed *"a single route must
    ///    execute: 0 <= 0"*. **The identical test standalone, same commit, same key, passed with
    ///    100.107404784232550147 WETH.** The header above already measured the mechanism (*"pinned 20
    ///    blocks behind head → got == 0"*); what nobody had noticed is that an UNPINNED run reaches
    ///    that state on its own once the process has been alive a quarter of an hour.
    ///
    /// ⛔ **THE OBVIOUS FIX IS WORSE THAN THE BUG AND WAS TRIED AND REVERTED.** Reading head via `ffi`
    ///    (`cast block-number`) and forking at it explicitly does make reuse impossible — and it puts a
    ///    BLOCKING RPC CALL IN `setUp`, which HUNG for minutes under exactly the rate-limit contention
    ///    that makes long runs stale in the first place. A hang is strictly worse than a wrong message:
    ///    it takes the whole suite with it and says nothing.
    ///
    /// ⇒ **`vm.unixTime()` ANSWERS IT FOR FREE.** Wall clock minus the fork's own `block.timestamp` is
    ///   the staleness, needs no network, and cannot hang. Beyond `MAX_FORK_LAG` the live-route
    ///   precondition is genuinely ABSENT — the same category as an unset API key — so this announces
    ///   and skips, which is the discriminator `_requireRouteOrExplain` already applies to the key.
    /// ⚠️ **300s ≈ 25 BLOCKS, CHOSEN AGAINST THE MEASUREMENT AND NOT PICKED FOR COMFORT:** 20 blocks
    ///   was measured to break a route and 70 was observed breaking one; a threshold inside that band
    ///   skips exactly the runs that cannot test the property. ⛔ **DO NOT RAISE IT TO MAKE A RED GO
    ///   AWAY** — that inverts it into the tolerance rule 4 forbids. With a FRESH fork a zero means the
    ///   route genuinely did not execute, which is the defect this suite exists to catch.
    /// 📌 `tools/forge-test.sh` avoids the staleness rather than skipping it, and is the better answer
    ///   when you actually need this suite's verdict in a full run.
    /// ✅ **VERIFIED ON A FRESH FORK, and the number that matters is the SKIP COUNT.** `2 passed, 0
    ///    failed, 0 SKIPPED`, `ONE route USDC->WETH: 99.717763234778229871`. A guard like this fails
    ///    silently in one direction — by skipping when it should not — and a green suite would look
    ///    identical. **`0 skipped` is what says the guard let the tests actually run**, so quote that
    ///    and not the pass count when re-checking it.
    /// ⚠️ **THE SKIP BRANCH ITSELF IS STILL UNEXERCISED**, and is stated rather than implied: reaching
    ///    it needs a fork >300s behind, which is the condition this suite now avoids. It is five
    ///    `emit`s and a `vm.skip`, and the arithmetic above it saturates, so the residual risk is that
    ///    the branch is never taken — not that it misbehaves when it is.
    uint256 constant MAX_FORK_LAG = 300;

    function _requireFreshForkOrExplain() internal returns (bool ok) {
        // ⚠️ SATURATING, NOT BARE `-`. `block.timestamp` can EXCEED wall clock — a fork one block
        //    ahead of the local clock, or any `vm.warp` a future edit puts in `setUp` — and an
        //    underflow here would REVERT the test rather than skip it. A guard that can fail harder
        //    than the thing it guards is worse than no guard; ahead-of-clock means "not stale", so it
        //    reads as zero lag.
        uint256 nowSec = vm.unixTime() / 1000;
        uint256 lag = nowSec > block.timestamp ? nowSec - block.timestamp : 0;
        if (lag <= MAX_FORK_LAG) return true;
        emit log_named_uint("SKIP: fork is stale by (seconds)", lag);
        emit log("  a live 1inch route cannot execute against a fork this far behind head - this is an");
        emit log("  ABSENT PRECONDITION, not a routing defect. Foundry reuses a fork keyed (url, block),");
        emit log("  so a long run pins an early 'latest'. Run this suite alone, or via tools/forge-test.sh.");
        vm.skip(true);
        return false;
    }

    /// §SESS-111 — one discriminator for both tests: an UNSET key is an absence (skip); a key that IS
    /// set and yields an empty route is a REJECTED request (403 on a bad `from`, a dead key, a rate
    /// limit) and must read as a failure. `0x` looks identical either way, which is what let a 403
    /// wear a routing defect's clothes for a day (§SESS-99).
    function _requireRouteOrExplain(uint256 len) internal {
        if (len >= 4) return;
        if (bytes(vm.envOr("ONEINCH_API_KEY", string(""))).length == 0) {
            emit log("SKIP: ONEINCH_API_KEY unset - the bridge has nothing to fetch");
            vm.skip(true); return;
        }
        revert("the 1inch bridge returned an EMPTY route while a key IS configured - a REJECTED "
               "request, not an absent one. See SESS-88b (bad `from` => 403) and SESS-99.");
    }

    function _route(address src, uint256 amt) internal returns (bytes memory) {
        string[] memory c = new string[](5);
        c[0] = "python3";
        c[1] = "../tools/fetch_1inch_route.py";
        c[2] = vm.toString(src);
        c[3] = vm.toString(WETH);
        c[4] = vm.toString(amt);
        // 🔴 §SESS-99 — **`from` MUST BE AN ADDRESS 1inch WILL ANSWER FOR, AND A FORGE TEST CONTRACT
        //    IS NOT ONE.** This passed `address(this)` — a locally-deployed address with no mainnet
        //    history — and 1inch answers **HTTP 403** for it. The bridge returns "0x", the route is
        //    empty, and both tests failed `0 <= 0` looking exactly like a routing defect. They have
        //    been in every baseline all day and were read as a pinned-block problem, then as a dead
        //    API key. MEASURED: same key, same endpoint, `from=0x…0001` → 403, `from=<real address>`
        //    → 200; `/quote` (which takes no `from`) → 200 throughout.
        // ⛔ **AND SUBSTITUTING A REAL ADDRESS IS SAFE, WHICH IS THE ONLY REASON TO DO IT.** `from`
        //    affects nothing but 1inch's willingness to build calldata: `LevMath._retarget`
        //    OVERWRITES `dstReceiver` with `address(this)` on-chain, so the fetched route cannot pay
        //    anyone but the executing frame no matter whose address sourced it (§SESS-69).
        // ⚠️ This is the THIRD time today a REJECTION read as a RESULT — a throttled call as "no
        //    route" (§SESS-66), a 403 as "the pathfinder adds nothing" (§SESS-88b), and now a 403 as
        //    a routing defect. The shape to distrust is any error path that returns a plausible zero.
        address FETCH_FROM = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;   // a live mainnet address
        string[] memory cmd = new string[](6);
        for (uint i; i < 5; ++i) cmd[i] = c[i];
        cmd[5] = vm.toString(FETCH_FROM);
        return vm.ffi(cmd);
    }

    /// TWO different stables converted to ONE output in a single call, each through its own route -
    /// which is the shape a pro-rata basket bundle always has (§PRO-RATA-IN-ONE-TOKEN-OUT).
    /// DIAGNOSTIC: does a SINGLE aggregator route execute through the primitive at all?
    function test_OneStableAlone() public {
        uint256 a = 250_000e6;
        bytes memory r = _route(USDC, a);
        // 🔴 §SESS-99 — **`vm.skip(true)` DOES NOT HALT EXECUTION, AND WITHOUT A `return` THIS FELL
        //    THROUGH.** An absent or rejected route left `r` empty, the body ran anyway, and the test
        //    reported `0 <= 0` — a MISSING INPUT wearing a routing defect's clothes. That is why two
        //    tests sat in every baseline all day and were diagnosed twice (a stale pin, then a dead
        //    API key), both times wrongly.
        _requireRouteOrExplain(r.length);
        if (r.length < 4) return;
        if (!_requireFreshForkOrExplain()) return;   // §SESS-118 — stale fork ⇒ precondition absent
        vm.store(USDC, keccak256(abi.encode(address(this), uint256(9))), bytes32(a));
        assertEq(IERC20t(USDC).balanceOf(address(this)), a, "fixture");
        address[] memory t = new address[](1); uint256[] memory m = new uint256[](1);
        bytes[] memory rr = new bytes[](1);
        t[0] = USDC; m[0] = a; rr[0] = r;
        uint256 got = LevMath.convertTo(t, m, WETH, 0, rr);
        emit log_named_decimal_uint("ONE route USDC->WETH", got, 18);
        assertGt(got, 0, "a single route must execute");
    }

    function test_TwoStablesConvertToWethThroughRealRoutes() public {
        uint256 aUsdc = 250_000e6;
        uint256 aUsdt = 250_000e6;

        bytes memory r1 = _route(USDC, aUsdc);
        bytes memory r2 = _route(USDT, aUsdt);
        if (r1.length < 4 || r2.length < 4) {
            emit log("no ONEINCH_API_KEY in evm/.env - the bridge returned an empty route.");
            emit log("Add ONEINCH_API_KEY=<key> to evm/.env and this test runs as written.");
            // ⚠️ `vm.skip`, NOT `return`. A test that RETURNS reports **PASS**, and a green result
            //    that asserted nothing is precisely the vacuous-pass this repo keeps being bitten by
            //    (§VACUOUS-BOUNDS, and the sell-leg backing test earlier today). Reporting SKIPPED
            //    makes the missing key visible in the suite output instead of hiding behind a tick.
            // §SESS-102 — `return` ADDED. The note above is right that a bare `return` reports PASS,
            // but `vm.skip(true)` alone does not HALT: execution fell through into the assertions and
            // reported `0 <= 0`, so a missing key looked identical to a reverting router. `skip` THEN
            // `return` reports SKIPPED, which is what this comment always wanted.
            vm.skip(true); return;
        }
        // §SESS-118 — same stale-fork precondition as the single-route test above. Two live routes
        // make it MORE exposed, not less: either one failing against a drifted fork yields the same
        // uninformative aggregate zero.
        if (!_requireFreshForkOrExplain()) return;

        // ⚠️ `deal` IS THE WRONG TOOL HERE AND IT COST A FALSE FAILURE. On a fork it drives
        //    `stdstore`'s brute-force slot search, which issues a storm of `eth_getStorageAt` against
        //    the endpoint - measured at ~918M gas and a bare `EvmError: Revert` that reads exactly
        //    like the conversion failing. Writing the KNOWN slot is deterministic, one op, no RPC.
        //    USDC's `balances` is slot 9 and USDT's is slot 2, both written on the PROXY address
        //    because the implementation runs by delegatecall in the proxy's storage.
        vm.store(USDC, keccak256(abi.encode(address(this), uint256(9))), bytes32(aUsdc));
        vm.store(USDT, keccak256(abi.encode(address(this), uint256(2))), bytes32(aUsdt));
        // ⚠️ ASSERT THE FIXTURE BEFORE THE SUBJECT. `deal` on a PROXIED token can silently write the
        //    wrong slot, and a conversion that reverts for want of input looks identical to one that
        //    reverts on the route - which is how a fixture failure gets booked as a contract defect.
        assertEq(IERC20t(USDC).balanceOf(address(this)), aUsdc, "fixture: USDC deal did not land");
        assertEq(IERC20t(USDT).balanceOf(address(this)), aUsdt, "fixture: USDT deal did not land");

        address[] memory tokens = new address[](2);
        uint256[] memory amts   = new uint256[](2);
        bytes[]   memory routes = new bytes[](2);
        tokens[0] = USDC; amts[0] = aUsdc; routes[0] = r1;
        tokens[1] = USDT; amts[1] = aUsdt; routes[1] = r2;

        uint256 before_ = IERC20t(WETH).balanceOf(address(this));
        uint256 got = LevMath.convertTo(tokens, amts, WETH, 0, routes);

        assertGt(got, 0, "the conversion produced no WETH");
        assertEq(IERC20t(WETH).balanceOf(address(this)) - before_, got,
            "the return must BE the measured balance delta, not a router's claim");
        // ~$500k of stables at any sane ETH price is well over 100 WETH; a wrong-units bug fails here.
        assertGt(got, 100e18, "sanity: $500k of stables should buy >100 WETH");
        emit log_named_decimal_uint("USDC+USDT -> WETH", got, 18);
    }
}

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

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    function _route(address src, uint256 amt) internal returns (bytes memory) {
        string[] memory c = new string[](5);
        c[0] = "python3";
        c[1] = "../tools/fetch_1inch_route.py";
        c[2] = vm.toString(src);
        c[3] = vm.toString(WETH);
        c[4] = vm.toString(amt);
        // the script takes `from` as arg 4; this contract holds the tokens and makes the call
        string[] memory cmd = new string[](6);
        for (uint i; i < 5; ++i) cmd[i] = c[i];
        cmd[5] = vm.toString(address(this));
        return vm.ffi(cmd);
    }

    /// TWO different stables converted to ONE output in a single call, each through its own route -
    /// which is the shape a pro-rata basket bundle always has (§PRO-RATA-IN-ONE-TOKEN-OUT).
    /// DIAGNOSTIC: does a SINGLE aggregator route execute through the primitive at all?
    function test_OneStableAlone() public {
        uint256 a = 250_000e6;
        bytes memory r = _route(USDC, a);
        if (r.length < 4) { vm.skip(true); }
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
            vm.skip(true);
        }

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

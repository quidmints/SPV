// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkPin} from "./utils/ForkPin.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {ICurvePool, USDC, RLUSD_TOKEN, PYUSD_TOKEN, USDT_TOKEN, DAI_TOKEN, USDG_TOKEN, CRVUSD_TOKEN,
        CURVE_3POOL, CURVE_USDG_USDC, CURVE_CRVUSD_USDC, CURVE_USDC_RLUSD, CURVE_PYUSD_USDC} from "../src/imports/Interfaces.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20P2 { function decimals() external view returns (uint8); }

/// @notice §SESS-24 — **EVERY `_routeOf` ROW PINNED AGAINST THE CHAIN.** Grown from 2 stables to 6.
///
/// §SESS-23 made this table a FLOOR reference, so each row is now worth basis points rather than
/// tidiness. But the table also feeds EXECUTION (`_hubSwap`, and `_routableStable` decides which slices
/// `consolidate` swaps rather than refunds), so a row must be deep enough to TRADE through, not merely
/// to quote — a strictly higher bar than the floor needs.
///
/// ⛔ **WHY "IT DIDN'T REVERT" IS NOT A CANDIDATE FILTER.** `0xEf3a1CaE…` answers `get_dy` for PYUSD,
///    GHO, RLUSD and USDS alike with **427 USDC per 10,000 in** — a 95% loss, cleanly, no revert.
///    Depth is the discriminator, which is the lesson §E292's removed venue already paid for.
/// ⚠️ **AND THE REGISTRY IS NOT THE AUTHORITY:** `find_pool_for_coins(…,0)` returns *a* pool — for
///    PYUSD it returns `0x61fA2c94…`, not the `0x383E6b44…` this tree had already verified. Rows were
///    chosen by depth and verified with `coins()` on the pool itself.
contract CurveTablePins is ForkPin {
    function setUp() public { vm.selectFork(_forkMainnet()); }

    /// ⭐ THE PIN: for every row, the pool really holds (stable, USDC) at exactly those indices.
    function _pinRow(string memory name, address tok, address pool, int128 i, int128 j) internal view {
        assertEq(ICurvePool(pool).coins(uint256(int256(i))), tok,   string.concat(name, ": coins(i) is not the stable"));
        assertEq(ICurvePool(pool).coins(uint256(int256(j))), USDC,  string.concat(name, ": coins(j) is not USDC"));
        console2.log(name, "row verified against coins()");
    }

    function test_EveryRowMatchesTheChain() public view {
        _pinRow("RLUSD",  RLUSD_TOKEN,  CURVE_USDC_RLUSD,   1, 0);
        _pinRow("PYUSD",  PYUSD_TOKEN,  CURVE_PYUSD_USDC,   0, 1);
        _pinRow("USDT",   USDT_TOKEN,   CURVE_3POOL,        2, 1);
        _pinRow("DAI",    DAI_TOKEN,    CURVE_3POOL,        0, 1);
        _pinRow("USDG",   USDG_TOKEN,   CURVE_USDG_USDC,    0, 1);
        _pinRow("crvUSD", CRVUSD_TOKEN, CURVE_CRVUSD_USDC,  1, 0);
    }

    /// ⭐ AND EVERY ROW IS DEEP ENOUGH TO TRADE, NOT MERELY TO QUOTE — flat to $1M.
    ///    The bar is §E292's: the predecessor venue was removed for breaching 1% between $10k and $25k.
    function _pinDepth(string memory name, address tok) internal view {
        uint8 dec = IERC20P2(tok).decimals();
        uint256[3] memory sizes = [uint256(10_000), 100_000, 1_000_000];
        for (uint256 k; k < 3; ++k) {
            uint256 dx = sizes[k] * (10 ** dec);
            uint256 dy = LevMath._selfServableQuote(tok, dx, USDC);
            uint256 par = sizes[k] * 1e6;
            assertGt(dy, 0, string.concat(name, ": quote collapsed to zero"));
            // within 1% of par, in BOTH directions (a wild over-quote is as wrong as an under-quote)
            assertGt(dy, par * 99 / 100, string.concat(name, ": worse than 1% off par - too thin to trade"));
            assertLt(dy, par * 101 / 100, string.concat(name, ": implausibly ABOVE par - suspect indices"));
        }
        console2.log(name, "depth flat to $1M");
    }

    function test_EveryRowIsDeepToOneMillion() public view {
        _pinDepth("USDT",   USDT_TOKEN);
        _pinDepth("DAI",    DAI_TOKEN);
        _pinDepth("USDG",   USDG_TOKEN);
        _pinDepth("crvUSD", CRVUSD_TOKEN);
        _pinDepth("RLUSD",  RLUSD_TOKEN);
        _pinDepth("PYUSD",  PYUSD_TOKEN);
    }

    /// 🔴 THE CONTROL — the excluded stables must still quote ZERO, or the exclusions are silent lies.
    ///    GHO/USDS/AUSD have only garbage pools; cUSD/frxUSD have none; USDE is thin at size (0/4/6592
    ///    bps at 10k/100k/1M) and is deliberately NOT a row.
    function test_Control_ExcludedStablesQuoteZero() public view {
        address GHO  = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
        address USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
        address USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
        assertEq(LevMath._selfServableQuote(GHO,  10_000e18, USDC), 0, "GHO must be unrouted");
        assertEq(LevMath._selfServableQuote(USDS, 10_000e18, USDC), 0, "USDS must be unrouted");
        assertEq(LevMath._selfServableQuote(USDE, 10_000e18, USDC), 0, "USDE must be unrouted - it is thin at $1M");
    }
}

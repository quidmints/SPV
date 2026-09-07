// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {UNOSWAP_SELECTOR, ZERO_FOR_ONE} from "../src/imports/Interfaces.sol";
import {IERC20 as IERC20F} from "forge-std/interfaces/IERC20.sol";

/// @notice ⭐ §SESS-94 EXPERIMENT #2 — **WHICH PROTOCOL IDS ACTUALLY FILL THROUGH `unoswap`?**
///
/// 🔴 **THIS IS THE ONE MEASUREMENT THAT DECIDES WHETHER KEYLESS BREADTH IS AVAILABLE AT ALL.** Our
///    keyless arm can only reach venues 1inch's `unoswap` will execute from a bare pool word, and the
///    only recorded datum is §SESS-22's: *"1inch's own bit table claims Curve support while `proto=2`
///    filled ZERO on two real pools"*, leaving `proto = 1` (UniswapV3) as the only id measured to
///    fill. Everything downstream rests on that one line — keyless coverage is 11/14 BECAUSE V3 is
///    all we can address, and GHO/FRXUSD need an API key for the same reason.
/// ⛔ **SO IT MUST BE RE-MEASURED, NOT CITED.** If UniswapV2-style pools fill under some id, keyless
///    discovery gains UniV2 + Sushi + PancakeSwap for FREE — no new on-chain code, no new executor,
///    just more candidates in `venues_for`. If nothing else fills, keyless is structurally capped and
///    that is a FINDING rather than a gap, and I stop looking.
/// ⚠️ **EXECUTED, NEVER DECODED.** A fill is a measured balance delta. §SESS-22's mistake was reading
///    a bit table; the whole point here is that documentation and behaviour disagreed.
contract UnoswapProtoCensus is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // Deep, long-lived, and NOT UniswapV3 — the whole question is whether a non-V3 pool can fill.
    address constant V2_USDC_WETH    = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc; // Uniswap V2
    address constant SUSHI_USDC_WETH = 0x397FF1542f962076d0BFE58eA045FfA2d347ACa0; // SushiSwap
    // The control: a V3 pool under proto=1, which §SESS-22 says DOES fill. If this row is dead the
    // harness is broken and no other row means anything.
    address constant V3_USDC_WETH    = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    function setUp() public { vm.createSelectFork(vm.envString("ETH_RPC_URL")); }

    function _try(string memory label, address pool, uint256 proto, bool dirBit)
        internal returns (uint256 out)
    {
        uint256 amt = 25_000e6;
        deal(USDC, address(this), amt);
        uint256 w = uint256(uint160(pool)) | (proto << 253) | (dirBit ? ZERO_FOR_ONE : 0);
        try this.hop(amt, w) returns (uint256 o) { out = o; } catch { out = 0; }
        emit log_named_string("  venue", label);
        emit log_named_uint("    proto", proto);
        emit log_named_uint("    dirBit", dirBit ? 1 : 0);
        emit log_named_decimal_uint("    WETH out", out, 18);
    }

    function hop(uint256 amt, uint256 w) external returns (uint256) {
        bytes[] memory rr = new bytes[](1);
        rr[0] = abi.encodeWithSelector(UNOSWAP_SELECTOR, uint256(0), uint256(0), uint256(0), w);
        return LevMath.routedSwap(USDC, WETH, amt, 0, rr);
    }

    /// ⭐ The census. Every id 0..3 against a V2 pool, a Sushi pool, and the V3 control.
    function test_WhichProtocolIdsFill() public {
        uint256 control;
        for (uint256 p = 0; p < 4; ++p) {
            for (uint256 d = 0; d < 2; ++d) {
                bool bit = d == 1;
                uint256 a = _try("UniswapV2 USDC/WETH", V2_USDC_WETH, p, bit);
                uint256 b = _try("Sushi USDC/WETH",     SUSHI_USDC_WETH, p, bit);
                uint256 c = _try("UniswapV3 0.05% (control)", V3_USDC_WETH, p, bit);
                if (c > control) control = c;
                if (a > 0 || b > 0) {
                    emit log_named_uint("*** A NON-V3 POOL FILLED under proto", p);
                }
            }
        }
        // ⛔ The ONLY assertion, and it is about the HARNESS rather than the finding: if even the V3
        //    control never fills, every zero above means "this test is broken", not "that id is dead".
        //    §VACUOUS-BOUNDS — a census of zeros is worthless without a row that is known to work.
        assertGt(control, 0,
            "the UniswapV3 control never filled - the harness is broken and no row above is evidence");
    }
}

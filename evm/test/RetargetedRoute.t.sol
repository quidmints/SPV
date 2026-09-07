// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR, UNOSWAP3_SELECTOR,
        PROTO_UNIV3, ZERO_FOR_ONE, USDC} from "../src/imports/Interfaces.sol";

interface IB { function balanceOf(address) external view returns (uint256); }
interface IV3 { function token0() external view returns (address); }

/// An external frame, so `vm.expectRevert` has something to bind to: `_retarget` is an INLINED
/// `internal` library function and a cheatcode cannot attach to one (CLAUDE.md records this trap).
contract Retargeter {
    function go(bytes memory route, address tokenIn, uint256 amt) external pure returns (bytes memory) {
        LevMath._retarget(route, tokenIn, amt);
        return route;
    }
}

/// @notice §SESS-65 — **THE CALLER CHOOSES THE VENUE. NOTHING ELSE.**
///
/// The supplied route's `token`, `amount` and `minReturn` are overwritten with this frame's own
/// numbers, so a route that is stale, mistaken or hostile in any of those three fields is harmless.
/// What survives untouched is the pool words — the venue choice — which is the one decision an
/// off-chain quote makes better than we can.
contract RetargetedRouteTest is AllesFixture {
    address constant WETHA       = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant P_USDC_WETH = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    Retargeter r;

    function setUp2() internal { r = new Retargeter(); }

    function _word(address pool, address tin) internal view returns (uint256 w) {
        w = (PROTO_UNIV3 << 253) | uint256(uint160(pool));
        if (IV3(pool).token0() == tin) w |= ZERO_FOR_ONE;
    }

    /// ⭐ ① **A ROUTE THAT LIES ABOUT ALL THREE OF OUR FIELDS IS CORRECTED, NOT REJECTED.** This is the
    ///    property that makes a SUPPLIED route safe to accept at all: staleness in the amount — the
    ///    exact reason pool words were invented — stops being a hazard because we rewrite it.
    function test_ASuppliedRouteIsRewrittenOntoOurOwnNumbers() public {
        setUp2();
        // Deliberately wrong on every field this frame owns: someone else's token, a stale amount,
        // and a minReturn the caller would love to set for us.
        bytes memory route = abi.encodeWithSelector(
            UNOSWAP_SELECTOR, uint256(uint160(WETHA)), uint256(123456789), uint256(type(uint256).max),
            _word(P_USDC_WETH, address(USDC)));
        bytes memory fixed_ = r.go(route, address(USDC), 50_000e6);

        (address tok, uint256 amt, uint256 minRet) =
            abi.decode(_tail(fixed_), (address, uint256, uint256));
        assertEq(tok, address(USDC), "token must be what WE are selling, not what the route claimed");
        assertEq(amt, 50_000e6,      "amount must be OURS - this is the staleness fix");
        assertEq(minRet, 0,          "minReturn must be zeroed; the aggregate delta floor is the bound");
        // The venue survives untouched - that is the whole point of accepting a route.
        assertEq(uint256(bytes32(_slice(fixed_, 4 + 96, 32))), _word(P_USDC_WETH, address(USDC)),
            "the POOL WORD must survive - the caller's venue choice is the one thing we keep");
    }

    /// ⭐ ② **HOP COUNT IS NOW A PROPERTY OF THE CALLDATA, NOT OF THE ABI.** All three arities are
    ///    accepted, which is what "no limit to how many hops" actually needed - `unoswap3` reaches
    ///    three pools in one call and cost one constant, because nothing encodes the route any more.
    function test_AllThreeAritiesAreAccepted() public {
        setUp2();
        uint256 w = _word(P_USDC_WETH, address(USDC));
        r.go(abi.encodeWithSelector(UNOSWAP_SELECTOR,  uint256(0), uint256(0), uint256(0), w),
             address(USDC), 1e6);
        r.go(abi.encodeWithSelector(UNOSWAP2_SELECTOR, uint256(0), uint256(0), uint256(0), w, w),
             address(USDC), 1e6);
        r.go(abi.encodeWithSelector(UNOSWAP3_SELECTOR, uint256(0), uint256(0), uint256(0), w, w, w),
             address(USDC), 1e6);
    }

    /// 🔴 ③ **AN UNRECOGNISED SELECTOR IS REFUSED, NOT PATCHED.** The offsets are only meaningful for a
    ///    known member of the family. ⛔ The generic `swap()` descriptor is the important exclusion: it
    ///    carries a caller-chosen `dstReceiver` and a nested struct, so its amount is not at a fixed
    ///    offset and patching it could not be checked.
    function test_AnUnknownSelectorIsRefused() public {
        setUp2();
        vm.expectRevert(LevMath.BadRoute.selector);
        r.go(abi.encodeWithSelector(bytes4(0x07ed2379), uint256(1), uint256(2), uint256(3)),
             address(USDC), 1e6);
    }

    /// 🔴 ④ **THE LENGTH MUST MATCH THE SELECTOR'S ARITY.** A "close enough" length would let a crafted
    ///    blob place our amount somewhere that is not the amount field, which is exactly the failure
    ///    a whitelist without a length check invites.
    function test_ARightSelectorWithAWrongLengthIsRefused() public {
        setUp2();
        uint256 w = _word(P_USDC_WETH, address(USDC));
        // unoswap2's selector carrying unoswap's arity (one pool word short).
        vm.expectRevert(LevMath.BadRoute.selector);
        r.go(abi.encodeWithSelector(UNOSWAP2_SELECTOR, uint256(0), uint256(0), uint256(0), w),
             address(USDC), 1e6);
    }

    /// ⚠️ EMPTY IS LEGAL: it means "no supplied route", and `_aggSwap` encodes one from pool words.
    function test_AnEmptyRouteIsLeftAlone() public {
        setUp2();
        assertEq(r.go("", address(USDC), 1e6).length, 0, "empty must stay empty, not revert");
    }

    function _tail(bytes memory b) internal pure returns (bytes memory) { return _slice(b, 4, 96); }
    function _slice(bytes memory b, uint256 o, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = b[o + i];
    }
}

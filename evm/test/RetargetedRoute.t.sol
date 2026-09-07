// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AllesFixture} from "./Alles.t.sol";
import {LevMath} from "../src/imports/LevMath.sol";
import {UNOSWAP_SELECTOR, UNOSWAP2_SELECTOR, UNOSWAP3_SELECTOR, SWAP_SELECTOR,
        PROTO_UNIV3, ZERO_FOR_ONE, USDC} from "../src/imports/Interfaces.sol";

interface IB { function balanceOf(address) external view returns (uint256); }
interface IV3 { function token0() external view returns (address); }

/// An external frame, so `vm.expectRevert` has something to bind to: `_retarget` is an INLINED
/// `internal` library function and a cheatcode cannot attach to one (CLAUDE.md records this trap).
contract Retargeter {
    function go(bytes memory route, address tokenIn, uint256 amt) external view returns (bytes memory) {
        LevMath._retarget(route, tokenIn, WETH, amt);          // WETH as the wanted token for these cases
        return route;
    }
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
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
    /// ⭐ §SESS-69 — **THE GENERIC `swap()` DESCRIPTOR, AND THE FIELD THAT MATTERS IS `dstReceiver`.**
    ///
    /// 🔑 **THIS IS THE ONLY DOOR TO UNISWAP V4.** A v4 pool has no address — it is a singleton keyed
    ///    by a `PoolKey` inside the PoolManager — so no 160-bit pool word can name one. Same for
    ///    Balancer. Admitting `swap()` is not "one more venue", it is every venue a pool word cannot
    ///    spell.
    /// ⛔ **AND IT IS SAFE ONLY BECAUSE `dstReceiver` IS OVERWRITTEN.** `convertTo`'s own docblock
    ///    records the attack: *"1inch's `swap` descriptor names a `dstReceiver`, so a hacked keeper can
    ///    have the pinned router pull leg k's input and pay ITSELF."* That is what
    ///    `RouteTookAndGaveNothing` exists to DETECT. Forcing the field makes it **unconstructible**
    ///    (standing rule 17) — the guard becomes a backstop rather than the defence.
    /// ⚠️ Asserted on a descriptor that names an ATTACKER as `dstReceiver`, because a test built with
    ///    an honest receiver would pass without the patch doing anything.
    function test_TheGenericDescriptorCannotDivertThePayout() public {
        setUp2();
        address attacker = address(0xBADBAD);
        bytes memory route = abi.encodeWithSelector(SWAP_SELECTOR,
            address(0xE0),                 // w0 executor — 1inch's, left alone
            address(0xAAA1),               // w1 srcToken     ← ours
            address(0xAAA2),               // w2 dstToken     ← ours
            address(0xBBB1),               // w3 srcReceiver  — 1inch plumbing, left alone
            attacker,                      // w4 dstReceiver  ← THE ATTACK
            uint256(999),                  // w5 amount       ← ours
            uint256(type(uint256).max),    // w6 minReturn    ← ours
            uint256(0xF1A65),              // w7 flags        — left alone, booked
            bytes(hex"c0ffee"));           // w8 -> tail
        bytes memory f = r.go(route, address(USDC), 50_000e6);

        assertEq(_w(f, 1), uint256(uint160(address(USDC))), "srcToken must be what WE sell");
        assertEq(_w(f, 2), uint256(uint160(WETHA)),         "dstToken must be what WE want");
        assertEq(_w(f, 4), uint256(uint160(address(r))),    "dstReceiver must be US - the diversion is the whole risk");
        assertNotEq(_w(f, 4), uint256(uint160(attacker)),   "the attacker's receiver survived the patch");
        assertEq(_w(f, 5), 50_000e6,                        "amount must be OURS - the staleness fix");
        assertEq(_w(f, 6), 0,                               "minReturn zeroed; the delta floor is the bound");
        assertEq(_w(f, 3), uint256(uint160(address(0xBBB1))), "srcReceiver is 1inch plumbing and must survive");
        assertEq(_w(f, 7), 0xF1A65,                         "flags must survive untouched - see the booked gap");
    }

    /// 🔴 **THE HEAD MUST END WHERE THE TAIL BEGINS.** `swap()` carries a dynamic `bytes`, so total
    ///    length cannot be pinned the way an unoswap arity can. The offset word is what IS fixed, and
    ///    a blob that moved it would put our amount somewhere that is not the amount field — the same
    ///    failure the arity check prevents, expressed the only way a dynamic call allows.
    function test_ADescriptorWhoseTailOffsetIsWrongIsRefused() public {
        setUp2();
        bytes memory route = abi.encodeWithSelector(SWAP_SELECTOR,
            address(0xE0), address(0xAAA1), address(0xAAA2), address(0xBBB1),
            address(0xCCC1), uint256(1), uint256(2), uint256(3), bytes(hex"c0ffee"));
        // Move the tail offset off the head boundary (9*32 = 0x120).
        assembly { mstore(add(route, add(0x24, mul(8, 0x20))), 0x140) }
        vm.expectRevert(LevMath.BadRoute.selector);
        r.go(route, address(USDC), 1e6);
    }

    /// A head too short to contain the descriptor at all.
    function test_ATruncatedDescriptorIsRefused() public {
        setUp2();
        vm.expectRevert(LevMath.BadRoute.selector);
        r.go(abi.encodeWithSelector(SWAP_SELECTOR, address(0xE0), address(0xAAA1)), address(USDC), 1e6);
    }

    function _w(bytes memory b, uint256 k) internal pure returns (uint256 v) {
        assembly { v := mload(add(b, add(0x24, mul(k, 0x20)))) }
    }

}

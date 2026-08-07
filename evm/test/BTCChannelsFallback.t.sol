// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BTCChannels} from "../src/BTCChannels.sol";

/// @notice (E122) The LP-NAMED FALLBACK HOP. Deliberately fork-free so it runs in
///         milliseconds — the full suite is currently self-rate-limiting against a public
///         RPC (E120: `ForkPin` pins the CURRENT block, so every run refetches), and a
///         security property should not be verifiable only when an endpoint feels like it.
///
///         ⚠️ SCOPE, STATED SO A GREEN RUN IS NOT MISREAD: these cover REGISTRATION only —
///         that the fallback is LP-signed, monotonic, requires a primary, and rejects a
///         self-referential value. **The staleness GATE itself (`_authorizedHopForChannel`:
///         fallback may act only after `FALLBACK_STALENESS_BLOCKS` of primary silence) is
///         NOT exercised here** — it needs a live channel, which needs a real SPV funding
///         proof. ✅ It IS covered, on a real regtest channel, by
///         `test/btc/OpenChannelE2E.t.sol::test_E122_fallbackTakesOverOnlyAfterStaleness`,
///         which asserts the boundary exactly (refused AT the window, allowed one block past).
///
///         Why this design replaces the registry + DCAP verifier: the fallback is named BY
///         THE LP, so it can never become standing-over-everyone, and it drops the Automata
///         verifier and the on-chain PCCS mirror out of the trust chain.
contract BTCChannelsFallbackTest is Test {
    BTCChannels ch;

    uint256 lpPk = 0xA11CE;
    address lpEth;
    address primary  = address(0xB0B);
    address fallbackHop = address(0xFA11);
    bytes32 payout   = bytes32(uint256(0xB7C));

    function setUp() public {
        ch = new BTCChannels(address(0xCA11), address(0xA17), address(0x4006), primary);
        lpEth = vm.addr(lpPk);
    }

    function _sign(uint256 pk, bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _delegate() internal {
        ch.registerDelegation(
            primary, payout, 1, _sign(lpPk, ch.delegationDigest(primary, payout, 1))
        );
    }

    /// A fallback with no primary has nothing to fall back FROM.
    function test_fallback_requires_a_primary_delegation_first() public {
        // ⚠️ Build the sig FIRST. `vm.expectRevert` binds to the next EXTERNAL call, and
        // `ch.fallbackDigest(...)` inline would consume it instead of `registerFallback`.
        bytes memory sig = _sign(lpPk, ch.fallbackDigest(fallbackHop, 2));
        vm.expectRevert(BTCChannels.NotDelegatedHop.selector);
        ch.registerFallback(fallbackHop, 2, sig);
    }

    /// Naming the primary as its own fallback is a no-op that READS as protection.
    function test_fallback_equal_to_primary_is_rejected() public {
        _delegate();
        bytes memory sig = _sign(lpPk, ch.fallbackDigest(primary, 2));
        vm.expectRevert(BTCChannels.InvalidParam.selector);
        ch.registerFallback(primary, 2, sig);
    }

    /// Monotonic: an old fallback cannot be replayed over a newer delegation.
    function test_fallback_version_must_advance() public {
        _delegate();
        bytes memory sig = _sign(lpPk, ch.fallbackDigest(fallbackHop, 1));
        vm.expectRevert(BTCChannels.StaleDelegation.selector);
        ch.registerFallback(fallbackHop, 1, sig);
    }

    /// ⚠️ THE PROPERTY THAT MATTERS: the OPERATOR relays this call gaslessly, so if the
    ///    fallback were an unsigned argument the operator could name its own address.
    ///    Recovery is over the LP's signature, so a mismatched signer simply lands the
    ///    fallback on the SIGNER's record — never on the LP's.
    function test_operator_cannot_name_a_fallback_for_someone_else() public {
        _delegate();
        uint256 attackerPk = 0xBAD;
        // The attacker signs a fallback naming its own choice and relays it. Recovery lands on
        // the ATTACKER, who has no delegation — so it reverts rather than touching the LP.
        bytes memory sig = _sign(attackerPk, ch.fallbackDigest(fallbackHop, 2));
        vm.expectRevert(BTCChannels.NotDelegatedHop.selector);
        ch.registerFallback(fallbackHop, 2, sig);
        assertEq(ch.fallbackAuthority(lpEth), address(0), "LP's fallback must remain unset");
    }

    /// The happy path stores the LP's choice under the LP's own address.
    function test_fallback_registers_under_the_lp() public {
        _delegate();
        ch.registerFallback(fallbackHop, 2, _sign(lpPk, ch.fallbackDigest(fallbackHop, 2)));
        assertEq(ch.fallbackAuthority(lpEth), fallbackHop, "fallback stored for the LP");
        assertEq(ch.delegatedAuthority(lpEth), primary,    "primary unchanged");
        assertEq(ch.delegationVersion(lpEth), 2,           "version advanced");
    }





    /// ✅ THE ANSWER TO "I don't want LPs doing this work": the capability already exists on
    /// `registerDelegation`, which has NO `msg.sender` check — authority is the SIGNATURE. The
    /// LP pre-signs a re-delegation naming a successor at setup, hands the bytes to a
    /// watchtower or the successor, and never acts again. **This is why there is no separate
    /// "disavow" entrypoint: it would be a second path to a capability we already have.**
    function test_presigned_redelegation_lets_a_third_party_switch_operators() public {
        _delegate();
        address successor = address(0xC0FFEE);

        // The LP signs ONCE at setup and hands the bytes over. It is offline from here.
        bytes memory presigned = _sign(lpPk, ch.delegationDigest(successor, payout, 2));

        // Much later, a third party (not the LP, not the primary) submits it.
        vm.prank(address(0xDEADBEEF));
        ch.registerDelegation(successor, payout, 2, presigned);

        assertEq(ch.delegatedAuthority(lpEth), successor, "operator switched, LP did nothing");
        assertEq(ch.delegationVersion(lpEth), 2, "version advanced");
    }

    /// The staleness window is a real constant, not an unbounded hand-over.
    function test_staleness_window_is_about_an_hour() public view {
        assertEq(ch.FALLBACK_STALENESS_BLOCKS(), 300, "~1h at 12s");
    }
}

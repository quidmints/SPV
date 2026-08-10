// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BTCChannels} from "../src/BTCChannels.sol";

/// @notice (E156) What survives of `BTCChannelsFallback.t.sol`. That file's other six tests all
///         exercised the LP-NAMED FALLBACK — `registerFallback`, `fallbackDigest`,
///         `fallbackAuthority`, `FALLBACK_STALENESS_BLOCKS` — which E156 deleted, because a
///         nominated hop holds no funding key (the fleet holds both halves) and so could never
///         sign the exit it was nominated to produce. It could only RELAY bytes the primary had
///         already signed, and arming at open makes those bytes exist unconditionally.
///
///         THIS test is not about the fallback at all, which is why it is kept rather than
///         deleted with the rest: it covers `registerDelegation`, which is live, and it is the
///         direct answer to "I do not want LPs doing this work". Deleting the file wholesale
///         would have taken it silently — the failure mode of removing a feature by filename.
///
///         Deliberately fork-free so it runs in milliseconds: a security property should not be
///         verifiable only when a public RPC feels like it.
contract BTCChannelsDelegationTest is Test {
    BTCChannels ch;

    uint256 lpPk = 0xA11CE;
    address lpEth;
    address primary = address(0xB0B);
    // ⚠️ Must be a REAL x-only key (E130): `0x5120||payout` has to be spendable, so
    //    `_registerBtcRecipient` rejects non-curve values. This is secp256k1's G.x.
    bytes32 payout = bytes32(uint256(0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798));

    function setUp() public {
        ch = new BTCChannels(address(0xCA11), address(0x4006));
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

    /// ✅ THE ANSWER TO "I don't want LPs doing this work": the capability already exists on
    /// `registerDelegation`, which has NO `msg.sender` check — authority is the SIGNATURE. The
    /// LP pre-signs a re-delegation naming a successor at setup, hands the bytes to a watchtower
    /// or the successor, and never acts again. **This is why there is no separate "disavow"
    /// entrypoint: it would be a second path to a capability we already have.**
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

    /// (E156) A pre-signed re-delegation used to be killable by a SECOND mechanism: registering a
    /// fallback bumped `delegationVersion`, silently invalidating bytes at or below it. With the
    /// fallback gone, only a real re-delegation moves the version — so the bytes above stay valid
    /// for exactly as long as the LP intended. Asserted because the guarantee is the point.
    function test_only_a_redelegation_can_invalidate_presigned_bytes() public {
        _delegate();
        assertEq(ch.delegationVersion(lpEth), 1, "open at version 1");
        bytes memory presigned = _sign(lpPk, ch.delegationDigest(address(0xC0FFEE), payout, 2));

        // Nothing an operator can do moves the version. (There is no longer any entrypoint that
        // bumps it without naming a new authority.) The pre-signed bytes still land.
        ch.registerDelegation(address(0xC0FFEE), payout, 2, presigned);
        assertEq(ch.delegationVersion(lpEth), 2, "only the re-delegation advanced it");
    }
}

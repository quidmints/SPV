// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ChannelLib} from "../../src/imports/ChannelLib.sol";

/// (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) THE DERIVATION, CHECKED AGAINST LIGHTNING ITSELF.
///
/// `recordForceClosePermissionless` measures what a force-close commitment paid the LP by scanning
/// its outputs for `0x5120 || lpToRemoteKey`. **If that key is derived even slightly differently
/// from the way LDK builds the output, the scan matches nothing and every force close silently
/// reports `lpPaidSats = 0`** — a check that looks armed and sees nothing, which is a worse state
/// than the one the fix replaced.
///
/// So the derivation is NOT asserted against itself. The vector below is produced by the vendored
/// LDK's own `chan_utils::get_taproot_to_remote_spk` — the code that will actually create the
/// output on chain — by `lightning`'s `test_quid_to_remote_vector_for_solidity`. Two independent
/// implementations, one shared vector; change one and this fails.
contract ForceCloseLpOutputTest is Test {
    /// From `cargo test -p lightning --lib quid_to_remote_vector -- --nocapture`:
    ///   QUID_VECTOR payment_point=034f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa
    ///   QUID_VECTOR to_remote_spk=51202bbbe6d5abe42d7c79892e896869ea739a9a0029e261f9a9e2d2a3a4ca54d57e
    bytes constant LDK_PAYMENT_POINT =
        hex"034f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa";
    bytes32 constant LDK_TO_REMOTE_KEY =
        0x2bbbe6d5abe42d7c79892e896869ea739a9a0029e261f9a9e2d2a3a4ca54d57e;

    function test_toRemoteKeyMatchesLdksOwnDerivation() public view {
        assertEq(ChannelLib.lpToRemoteOutputKey(LDK_PAYMENT_POINT), LDK_TO_REMOTE_KEY,
            "ChannelLib disagrees with chan_utils::get_taproot_to_remote_spk");
    }

    /// The scriptPubKey the contract actually scans for is `0x5120 || key`. Asserted whole, because
    /// the key being right is not the same as the SCRIPT being right, and it is the script that is
    /// compared against a commitment transaction's outputs.
    function test_theScannedScriptPubKeyIsTheOneLdkWouldCreate() public view {
        assertEq(
            abi.encodePacked(hex"5120", ChannelLib.lpToRemoteOutputKey(LDK_PAYMENT_POINT)),
            hex"51202bbbe6d5abe42d7c79892e896869ea739a9a0029e261f9a9e2d2a3a4ca54d57e",
            "the scanned scriptPubKey is not LDK's to_remote output");
    }

    /// It must depend on the PAYMENT BASEPOINT, not on any other key. The whole reason this field
    /// exists is that `to_remote` derives from the basepoint while `lpPubkey` is rotated by every
    /// splice — so a derivation that ignored its argument would pass the vector test above only by
    /// coincidence of the fixture reusing one key.
    function test_aDifferentBasepointGivesADifferentKey() public view {
        bytes memory other = hex"02dca094751109d0bd055d03565874e8276dd53e926b44e3bd1bb6bf4bc130a279";
        assertTrue(ChannelLib.lpToRemoteOutputKey(other) != LDK_TO_REMOTE_KEY,
            "the derivation ignores its argument");
    }

    /// A malformed basepoint is refused rather than hashed into a plausible-looking key nothing
    /// will ever pay to — the same failure shape `tapLeafHash` guards against for scripts.
    function test_aWrongLengthBasepointIsRefused() public {
        vm.expectRevert();
        ChannelLib.lpToRemoteOutputKey(hex"0011");
    }
}

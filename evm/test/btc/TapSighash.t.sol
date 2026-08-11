// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ChannelLib} from "../../src/imports/ChannelLib.sol";
import {ExitLib} from "../../src/imports/ExitLib.sol";

/// @notice (E128) BIP-341 key-path sighash, `SIGHASH_DEFAULT`, checked against the OFFICIAL
///         `bip-0341/wallet-test-vectors.json` — `keyPathSpending[0]`, `inputSpending[3]`
///         (`txinIndex = 4`, `hashType = 0`).
///
///         ⚠️ THE VECTOR CHOICE IS NOT INCIDENTAL. `inputSpending[0]` uses `hashType = 3`
///         (SIGHASH_SINGLE) and would NOT validate this implementation — testing against it would
///         have compared our DEFAULT sighash to a SINGLE sighash and failed for the right reason
///         with the wrong diagnosis. The exit signs `SIGHASH_DEFAULT`
///         (`quid-ln/src/deadman_exit.rs:24`), so only a `hashType = 0` vector is evidence.
///
///         ⚠️ WHY THIS TX IS A GOOD TEST: **9 inputs, 2 outputs, mixed script types** (P2TR, P2WPKH,
///         P2PKH). Every `Prevouts::All` commitment is exercised over a heterogeneous set, and the
///         signed input is index 4 — neither first nor last, so an off-by-one in `input_index` or
///         an accidental "hash only the spent input" shortcut both fail loudly.
contract TapSighashTest is Test {
    /// `keyPathSpending[0].rawUnsignedTx` — 9 inputs, 2 outputs.
    function _rawTx() internal pure returns (bytes memory) {
        return hex"02000000097de20cbff686da83a54981d2b9bab3586f4ca7e48f57f5b55963115f3b334e9c"
               hex"010000000000000000d7b7cab57b1393ace2d064f4d4a2cb8af6def61273e127517d44759b"
               hex"6dafdd990000000000fffffffff8e1f583384333689228c5d28eac13366be082dc57441760"
               hex"d957275419a418420000000000fffffffff0689180aa63b30cb162a73c6d2a38b7eeda2a83"
               hex"ece74310fda0843ad604853b0100000000feffffffaa5202bdf6d8ccd2ee0f0202afbbb746"
               hex"1d9264a25e5bfd3c5a52ee1239e0ba6c0000000000feffffff956149bdc66faa968eb2be2d"
               hex"2faa29718acbfe3941215893a2a3446d32acd050000000000000000000e664b9773b88c09c"
               hex"32cb70a2a3e4da0ced63b7ba3b22f848531bbb1d5d5f4c94010000000000000000e9aa6b8e"
               hex"6c9de67619e6a3924ae25696bb7b694bb677a632a74ef7eadfd4eabf0000000000ffffffff"
               hex"a778eb6a263dc090464cd125c466b5a99667720b1c110468831d058aa1b82af10100000000"
               hex"ffffffff0200ca9a3b000000001976a91406afd46bcdfd22ef94ac122aa11f241244a37ecc"
               hex"88ac807840cb0000000020ac9a87f5594be208f8532db38cff670c450ed2fea8fcdefcc9a6"
               hex"63f78bab962b0065cd1d";
    }

    /// `keyPathSpending[0].utxosSpent`, in input order.
    function _prevValues() internal pure returns (uint64[] memory v) {
        v = new uint64[](9);
        v[0] = 420000000; v[1] = 462000000; v[2] = 294000000; v[3] = 504000000;
        v[4] = 630000000; v[5] = 378000000; v[6] = 672000000; v[7] = 546000000;
        v[8] = 588000000;
    }
    function _prevScripts() internal pure returns (bytes[] memory s) {
        s = new bytes[](9);
        s[0] = hex"512053a1f6e454df1aa2776a2814a721372d6258050de330b3c6d10ee8f4e0dda343";
        s[1] = hex"5120147c9c57132f6e7ecddba9800bb0c4449251c92a1e60371ee77557b6620f3ea3";
        s[2] = hex"76a914751e76e8199196d454941c45d1b3a323f1433bd688ac";          // P2PKH
        s[3] = hex"5120e4d810fd50586274face62b8a807eb9719cef49c04177cc6b76a9a4251d5450e";
        s[4] = hex"512091b64d5324723a985170e4dc5a0f84c041804f2cd12660fa5dec09fc21783605";
        s[5] = hex"00147dd65592d0ab2fe0d0257d571abf032cd9db93dc";                  // P2WPKH
        s[6] = hex"512075169f4001aa68f15bbed28b218df1d0a62cbbcf1188c6665110c293c907b831";
        s[7] = hex"5120712447206d7a5238acc7ff53fbe94a3b64539ad291c7cdbc490b7577e4b17df5";
        s[8] = hex"512077e30a5522dd9f894c3f8b8bd4c4b2cf82ca7da8a3ea6a239655c39c050ab220";
    }

    /// THE assertion: input 4, `hashType = 0`.
    function test_matchesTheOfficialBip341Vector() public view {
        assertEq(
            ExitLib.taprootKeyPathSighash(_rawTx(), _prevValues(), _prevScripts(), 4),
            bytes32(0x4f900a0bae3f1446fd48490c2958b5a023228f01661cda3496a11da502a7f7ef),
            "BIP-341 keyPathSpending[0] / inputSpending[3] (txin 4, SIGHASH_DEFAULT)"
        );
    }

    /// ⚠️ CONTROL — the sighash must DEPEND on the input index. A "hash only the spent input"
    /// shortcut, or an `input_index` left at 0, would still produce a stable-looking 32 bytes.
    function test_theSighashDependsOnTheInputIndex() public view {
        bytes32 a = ExitLib.taprootKeyPathSighash(_rawTx(), _prevValues(), _prevScripts(), 4);
        bytes32 b = ExitLib.taprootKeyPathSighash(_rawTx(), _prevValues(), _prevScripts(), 5);
        assertTrue(a != b, "input_index is committed");
    }

    /// ⚠️ CONTROL — `Prevouts::All` means EVERY prevout, not just the spent one. Changing input
    /// 0's amount while signing input 4 MUST change the sighash. This is the property the
    /// freshness UTXO relies on (`deadman_exit.rs:67-71`); if it failed, spending that outpoint
    /// would no longer invalidate outstanding exits.
    function test_everyPrevoutIsCommittedNotOnlyTheSpentOne() public view {
        uint64[] memory v = _prevValues();
        bytes32 before_ = ExitLib.taprootKeyPathSighash(_rawTx(), v, _prevScripts(), 4);
        v[0] += 1;                                   // a DIFFERENT input's amount
        bytes32 after_ = ExitLib.taprootKeyPathSighash(_rawTx(), v, _prevScripts(), 4);
        assertTrue(before_ != after_, "Prevouts::All must commit to input 0 while signing input 4");
    }

    /// One value and one scriptPubKey per input, exactly — a short array would otherwise index
    /// out of bounds or silently hash fewer commitments.
    function test_prevoutArityIsChecked() public {
        uint64[] memory short_ = new uint64[](8);
        vm.expectRevert(ExitLib.PrevoutCountMismatch.selector);
        ExitLib.taprootKeyPathSighash(_rawTx(), short_, _prevScripts(), 4);
    }
}

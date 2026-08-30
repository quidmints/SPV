// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BitcoinTx} from "../../src/imports/BitcoinTx.sol";

/// @notice (§POOL-SCRIPT) The two-output dead-man ladder, which is how the pool's share stops
///         being handed to the LP.
///
///         ```
///         output 0 -> lpPayoutScript   amountSats - poolOwnedSats
///         output 1 -> poolColdScript   poolOwnedSats
///         ```
///
/// 🔑 WHAT THIS FILE IS ACTUALLY FOR. The design rests on a claim that was asserted and never
///    demonstrated: *"`_exitStructure` needs NO change — it loops `t.outputs` summing only those
///    whose script matches `want`, and places no constraint on output count."* If that were
///    wrong, adding the pool output would break every exit's verification, and the fix would
///    destroy the LP's only escape instead of protecting the pool's sats. So the first test does
///    not check the new feature at all — it checks that the OLD path is indifferent to it.
///
/// ⚠️ BOTH FIXTURES ARE THE SAME CHANNEL — same funding outpoint, same `Q`, same deadline, one
///    signed over one output and one over two. That is deliberate: a difference in behaviour can
///    then only come from the extra output, not from two unrelated fixtures diverging.
contract PoolScriptLadderTest is Test {
    Harness h;
    string  j;

    /// The pool's cold script in the fixture (a P2TR whose key is BIP-340 vector 2's, so it is a
    /// real point rather than a byte pattern that merely looks like one).
    bytes constant POOL_SPK =
        hex"5120c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";

    function setUp() public {
        h = new Harness();
        j = vm.readFile(string.concat(vm.projectRoot(), "/test/btc/deadman_exit_fixture.json"));
    }

    function _check(string memory k) internal view returns (BitcoinTx.ExitCheck memory) {
        return BitcoinTx.ExitCheck({
            fundingTxId:  vm.parseJsonBytes32(j, string.concat(k, ".fundingTxId")),
            fundingVout:  uint32(vm.parseJsonUint(j, string.concat(k, ".fundingVout"))),
            fundingSats:  vm.parseJsonUint(j, string.concat(k, ".fundingSats")),
            q:            vm.parseJsonBytes32(j, string.concat(k, ".fundingTaproot")),
            cltvDeadline: uint64(vm.parseJsonUint(j, string.concat(k, ".cltvDeadline")))
        });
    }

    function _lpScript() internal pure returns (bytes memory) {
        return hex"512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
    }

    /// ⭐ THE LOAD-BEARING ONE. A two-output exit must still verify — structure, BIP-341 sighash
    /// and BIP-340 signature — and must report the LP's payment as the LP's ALONE. If the pool's
    /// 40,000 sats leaked into `paidToLp` the checkpoint comparison would credit the LP for sats
    /// it never receives, which is the same over-claim in the opposite direction.
    function test_twoOutputExitVerifiesAndPaysLpOnlyItsShare() public {
        uint64[] memory v = new uint64[](1); bytes[] memory s_ = new bytes[](1);
        uint paid = BitcoinTx.verifyDeadManExit(
            vm.parseJsonBytes(j, ".exits[1].signedExitTx"), _check(".exits[1]"), _lpScript(), v, s_);
        assertEq(paid, vm.parseJsonUint(j, ".exits[1].paysLp"),
            "the extra output must be ignored by _exitStructure, not summed into the LP's total");
        assertEq(paid, 209_000, "250,000 funding - 1,000 fee - 40,000 pool");
    }

    /// The pool's output is really there and really carries the pool's sats.
    function test_thePoolOutputIsMeasurable() public view {
        assertEq(
            h.toScript(vm.parseJsonBytes(j, ".exits[1].signedExitTx"), POOL_SPK),
            vm.parseJsonUint(j, ".exits[1].paysPool"),
            "the pool's share must be readable from the signed bytes"
        );
    }

    /// ⛔ AND THE CASE THE GUARD EXISTS FOR. The single-output exit is exactly what a hop would
    /// arm today: perfectly valid, correctly signed, and it pays the pool NOTHING while spending
    /// a channel whose sats the pool partly owns. `_armDeadManExit` compares this number against
    /// `poolOwnedSats` and reverts `ExitUnderpaysPool`, which is what makes `PoolSatsLeftWithLp`
    /// unreachable — the leak is prevented at ARM time rather than booked after the BTC is gone.
    function test_theLegacySingleOutputExitPaysThePoolNothing() public view {
        assertEq(
            h.toScript(vm.parseJsonBytes(j, ".exits[0].signedExitTx"), POOL_SPK), 0,
            "a one-output ladder gives the pool nothing -- this is the leak being closed"
        );
    }

    /// SUMS, NOT "FINDS". `sumPaidToScript` adds every matching output, so a pool share
    /// split across two outputs is still full payment. Asserted against the LP's own script on
    /// the two-output fixture, where exactly one output matches, to pin the arithmetic.
    function test_theLpScriptIsSummedIndependentlyOfThePoolScript() public view {
        assertEq(
            h.toScript(vm.parseJsonBytes(j, ".exits[1].signedExitTx"), _lpScript()),
            209_000, "each script is measured on its own outputs"
        );
    }
}

/// `sumPaidToScript` takes `bytes calldata`; an external call supplies it.
contract Harness {
    function toScript(bytes calldata raw, bytes calldata spk) external pure returns (uint) {
        return BitcoinTx.sumPaidToScript(raw, spk);
    }
}

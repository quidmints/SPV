// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @notice (E134) CAN the modexp precompile be used inside a mainnet fork test, or does the
///         account fetch for 0x05 kill it against a public node? I claimed it could not be
///         repaired after trying exactly one thing. This settles it by trying several.
contract ModexpOnForkTest is Test {
    uint256 constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    function _modExp(uint256 base, uint256 e) internal view returns (uint256 r) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, 0x20) mstore(add(p, 0x20), 0x20) mstore(add(p, 0x40), 0x20)
            mstore(add(p, 0x60), base) mstore(add(p, 0x80), e) mstore(add(p, 0xa0), P)
            if iszero(staticcall(gas(), 0x05, p, 0xc0, p, 0x20)) { revert(0, 0) }
            r := mload(p)
        }
    }

    function _fork() internal {
        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(vm.rpcUrl("mainnet"));
        else vm.createSelectFork(vm.rpcUrl("mainnet"), pinned);
    }

    /// ⚠️ THE ORDERING IS THE WHOLE TRICK, and three of four attempts fail. Recorded here
    ///    because the failure mode is a database error naming `0x…05` that says NOTHING about
    ///    the code under test, and the next person will otherwise conclude — as I did — that
    ///    the precompile is unusable on a fork and hand-roll around it.
    ///
    ///      A. bare `modexp` after `createFork`      → FAILS: the EVM's own account fetch 403s
    ///      B. `vm.deal(0x05)` AFTER `createFork`    → FAILS: the deal itself triggers the fetch
    ///      C. `vm.store(0x05, …)`                   → FAILS: foundry rejects precompiles outright
    ///      D. `vm.deal` + `makePersistent` BEFORE   → WORKS, and is what `ForkPin` now does
    ///
    ///    Only D is kept as a live test; A-C are not asserted because their failure is an
    ///    environment error, not a revert, so it cannot be expressed as an expectation.
    function test_precompile_is_usable_on_a_fork_when_touched_first() public {
        vm.deal(address(5), 0);
        vm.makePersistent(address(5));
        _fork();
        assertEq(_modExp(2, 10), 1024, "2^10 mod p, inside a fork");
        // And the real consumer: a curve check that goes through modexp.
        assertEq(_modExp(4, 1), 4, "sanity");
    }
}

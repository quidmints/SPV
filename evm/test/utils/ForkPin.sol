// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @title  ForkPin — reproducible mainnet forking WITHOUT giving up live state.
///
/// @notice THE PROBLEM THIS SOLVES (§A.18, and it cost three wrongly-reverted fixes on 2026-07-31).
///         Every fork test used `vm.createFork(vm.rpcUrl("mainnet"))`, i.e. LATEST BLOCK. Two runs
///         minutes apart therefore see DIFFERENT mainnet state, so a suite comparison cannot attribute
///         a change: three correct fixes (C5, D3, C2-via-`from6`) were each blamed for 31 failures that
///         a CLEAN TREE reproduced exactly. The failures came from ether.fi's live redeemable pool
///         being momentarily thin, not from any edit.
///
///         WHY NOT JUST PIN A FIXED BLOCK: that trades the problem for a worse one — the suite would
///         stop exercising real, current mainnet state, and the user explicitly wants expectations
///         DERIVED FROM LIVE STATE rather than frozen constants (§A.22).
///
///         THE FIX — PIN THE *CURRENT* BLOCK PER COMPARISON, not a historical one:
///           • `FORK_BLOCK` UNSET (default, and CI): latest block. Behaviour is unchanged; the suite
///             still runs against live mainnet, so drift and real integrations are still exercised.
///           • `FORK_BLOCK` SET: every fork in the run uses THAT block, so N runs are byte-identical.
///
///         USE IT WHENEVER ATTRIBUTING A CHANGE:
///           export FORK_BLOCK=$(cast block-number --rpc-url "$MAINNET_RPC")
///           forge test                 # baseline
///           <apply the change>
///           forge test                 # same chain state ⇒ any delta IS the change
///         The block is CURRENT at capture time, so this is live state — just held still long enough
///         to measure against. No realism is given up.
abstract contract ForkPin is Test {
    function _forkMainnet() internal returns (uint forkId) {
        // ⚠️ TOUCH THE PRECOMPILE BEFORE THE FORK EXISTS, NOT AFTER. On a fork, the first
        // access to an address foundry has not cached triggers an eth_getAccount, and a
        // PUBLIC node answers for a non-head block with "Archive requests require a personal
        // token" (403) — so anything reaching `modexp` (0x05) dies with a database error
        // naming the precompile, saying nothing about the code under test.
        // Ordering is the whole trick and three of four attempts fail; see
        // test/ModexpOnFork.t.sol, which asserts the working one. `vm.deal` AFTER
        // `createFork` triggers the very fetch it should avoid, and `vm.store` is rejected
        // outright on precompiles.
        vm.deal(address(5), 0);
        vm.makePersistent(address(5));
        uint pinned = vm.envOr("FORK_BLOCK", uint(0));
        return pinned == 0
            ? vm.createFork(vm.rpcUrl("mainnet"))
            : vm.createFork(vm.rpcUrl("mainnet"), pinned);
    }
}

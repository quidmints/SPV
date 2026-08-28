// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * @title RootValidity
 * @notice The single definition of "is this Merkle root still acceptable to prove against".
 *
 * WHY THIS LIBRARY EXISTS (sec. 2.18o). The rule was written out three separate times -
 * `PoseidonSMT`, `L1RegistrationState`, `RegistrationSMTReplicator` - and all three carried the
 * same defect: an unrecorded root maps to 0, so `0 + validity > block.timestamp` returned TRUE for
 * every invented root until an hour past the epoch. Fixing one left two live, and the copy that
 * mattered most was the L2 replicator, whose deployment target is precisely a chain counting from a
 * low timestamp.
 *
 * THE DUPLICATION WAS THE DEFECT, not the arithmetic. `IPoseidonSMT` is the interface all three
 * answer to, and the RULE lived in none of them - so nothing made them agree, and a fourth
 * implementation would have been free to differ again. This is that rule, once.
 *
 * NO STORAGE. Every caller keeps its own mapping and its own `ROOT_VALIDITY`; only the decision is
 * shared. That is what makes adopting it safe in contracts that are already UUPS-upgradeable -
 * their layouts are untouched.
 */
library RootValidity {
    /**
     * @notice Whether `root_` may still be proven against.
     *
     * @param root_ the root being checked
     * @param isLatest_ whether it is the tree's current root
     * @param recordedAt_ when the root was recorded, or 0 if this tree has NEVER held it
     * @param validityWindow_ how long a superseded root remains acceptable
     *
     * THREE CLAUSES, EACH LOAD-BEARING:
     *
     * 1. THE ZERO ROOT IS NEVER VALID. It is the empty-tree sentinel and the default value of any
     *    unset storage slot, so accepting it would mean accepting an uninitialised anything.
     *
     * 2. THE LATEST ROOT IS ALWAYS VALID, however old. This is what stops inaction becoming
     *    censorship: a tree nobody has updated for a year must still admit its own members, or an
     *    operator could freeze people out by simply doing nothing.
     *
     * 3. A SUPERSEDED ROOT IS VALID ONLY BRIEFLY, AND ONLY IF IT EXISTED. The grace window exists
     *    so a proof built moments before an update is not wasted. `recordedAt_ != 0` is the clause
     *    that was missing everywhere: without it the arithmetic reads `0 + validityWindow_ >
     *    block.timestamp` for a root that never existed, which is TRUE on any chain younger than
     *    the window. A guard that silently passes is worth less than no guard, because it is
     *    trusted.
     */
    function isValid(
        bytes32 root_,
        bool isLatest_,
        uint256 recordedAt_,
        uint256 validityWindow_
    ) internal view returns (bool) {
        if (root_ == bytes32(0)) {
            return false;
        }

        if (isLatest_) {
            return true;
        }

        return recordedAt_ != 0 && recordedAt_ + validityWindow_ > block.timestamp;
    }
}

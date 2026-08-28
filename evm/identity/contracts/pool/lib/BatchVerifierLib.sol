// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {BatchCommitmentLib} from "./BatchCommitmentLib.sol";
import {INoirVerifier} from "../../interfaces/verifiers/INoirVerifier.sol";

/**
 * @notice The VERIFICATION half of the aggregated-withdrawal entrypoint (TODO.md sec. 2.4): given N
 *         withdrawals' public signals and one aggregation proof, establish that a valid
 *         `withdraw_identity` proof exists for EACH of them.
 *
 * @dev DELIBERATELY DOES NOT SETTLE. It spends no nullifier, moves no funds and touches no storage.
 *      Settlement needs `PrivacyPool`'s internals and is a separate, money-path change; keeping the
 *      two apart means this half can be tested exhaustively on its own, and a bug here fails closed
 *      (nothing verifies) rather than paying someone twice.
 *
 *      WHAT THE AGGREGATION PROOF DOES AND DOES NOT ESTABLISH. It proves: N inner proofs verified
 *      against the PINNED `withdraw_identity` key, and their public signals hash to the single field
 *      the verifier exposes. It does NOT prove any of the things `PrivacyPool.withdraw` checks about
 *      those signals - that the state root is known, that the identity root is fresh, that the
 *      nullifier is unspent, that the caller is the processooor. **Every one of those must still be
 *      re-checked per withdrawal by the settlement half.** Aggregation replaces the PROOF check, not
 *      the POLICY checks. Anything less would let a batch settle withdrawals the single-withdrawal
 *      path would reject.
 *
 *      THE COMMITMENT IS THE ONLY LINK between the verifier's one public input and the N withdrawals
 *      in calldata. If `BatchCommitmentLib` and the circuit ever disagree, every batch fails to
 *      verify - which is the safe direction, and is pinned by a circuit-emitted fixture in
 *      `BatchCommitmentTest`.
 */
library BatchVerifierLib {
    uint256 internal constant PUB_LEN = 8;

    /// @notice The aggregation proof did not verify against the recomputed commitment.
    error InvalidBatchProof();
    /// @notice A batch must carry at least one withdrawal; an empty batch commits to the zero
    ///         accumulator and would otherwise "verify" while settling nothing.
    error EmptyBatch();
    /// @notice The batch is larger than the circuit was compiled for. The circuit's `BATCH_N` is a
    ///         compile-time constant, so a longer batch cannot have been proved by it - and the
    ///         commitment alone would not catch this, since it folds however many it is given.
    error BatchTooLarge(uint256 given, uint256 max);

    /**
     * @notice Check one aggregation proof against N withdrawals' public signals.
     * @param verifier  The `TreeRoot<N>HonkVerifier` for the depth that settles `maxBatch`.
     * @param proof     The aggregation proof bytes.
     * @param signals   Each withdrawal's 7 public signals, IN THE ORDER the batch was proved.
     * @param maxBatch  The batch size the deployed verifier's tree depth settles. Passed in rather
     *                  than hardcoded so a deployment at a different depth cannot silently disagree
     *                  with this file - each depth is a SEPARATE contract for exactly that reason.
     * @return commitment The recomputed batch commitment, returned so callers can log or re-check it
     *                    without folding twice.
     *
     * @dev ORDER IS LOAD-BEARING. The fold is order-binding, so `signals` must be in the proved
     *      order; a permutation produces a different commitment and fails. That is what stops a
     *      batcher pairing one user's recipient context with another's nullifier.
     */
    function verifyBatch(
        INoirVerifier verifier,
        bytes calldata proof,
        uint256[PUB_LEN][] memory signals,
        uint256 maxBatch
    ) internal view returns (uint256 commitment) {
        if (signals.length == 0) revert EmptyBatch();
        if (signals.length > maxBatch) revert BatchTooLarge(signals.length, maxBatch);

        commitment = BatchCommitmentLib.treeCommitment(signals);

        bytes32[] memory publicInputs = new bytes32[](1);
        publicInputs[0] = bytes32(commitment);

        if (!verifier.verify(proof, publicInputs)) revert InvalidBatchProof();
    }
}

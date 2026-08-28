// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface INoirVerifier {
    /**
     * @notice Verify a proof against this verifier's circuit.
     *
     * @dev `getVerificationKeyHash()` USED TO BE DECLARED HERE AND WAS REMOVED 2026-08-02. Nothing
     * in this repo ever called it, and the verifiers actually deployed against this interface do not
     * implement it: bb's UltraHonk output has no such function, and every verifier this fusion
     * generates - the escrow envelope, the withdrawal, and now the regenerated passport set - is
     * UltraHonk. Only the inherited UltraPlonk verifiers under `sdk/verifier` and the pre-fork
     * `verifiers2` files ever had it. A declaration that no implementation honours turns a cast into
     * a latent revert, so it goes rather than being left as an invitation.
     * @param _proof The serialized proof data.
     * @param _publicInputs An array of the public inputs for the proof.
     * @return True if the proof is valid, reverts otherwise.
     */
    function verify(
        bytes calldata _proof,
        bytes32[] calldata _publicInputs
    ) external view returns (bool);
}
